# palworld-kube — Palworld dedicated server (SteamCMD app 2394010).
#
# Rules this image holds to (same as iw4x-kube):
#   - Never sleep on failure. Exit non-zero so Kubernetes shows CrashLoopBackOff
#     and the reason is in `kubectl logs`.
#   - A failed *update* is not fatal when a playable install already exists.
#     GameCTL's CS2 init container learned this the hard way: `set -e` aborting
#     on a failed steamcmd meant the "already updated" marker was never written,
#     so every restart re-ran the same failing update — 119 restarts and ~10h of
#     downtime from one stale request. Only a failed FIRST install is fatal.
#   - Bind the game port explicitly. Barotrauma in this same cluster crashes with
#     EADDRINUSE because it takes the IPv6 wildcard (which also claims IPv4) and
#     then tries to bind IPv4 separately. Palworld takes -port, so we always pass
#     it rather than relying on whatever the ini happens to hold.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="palworld-kube" \
      org.opencontainers.image.description="Palworld dedicated server (SteamCMD app 2394010) for GameCTL" \
      org.opencontainers.image.source="https://github.com/GameCTL-HQ/GameCTL" \
      org.opencontainers.image.licenses="MIT"

# PalServer is a 64-bit UE5 binary but SteamCMD itself is 32-bit, so i386 is
# required for the downloader even though the game is not.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      lib32gcc-s1 \
      libc6-i386 \
      xdg-user-dirs \
      procps \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# uid/gid 1000 matches GameCTL's NFS convention (exports are chowned 1000:1000)
# and the fsGroup its generators set.
RUN useradd -u 1000 -m -s /bin/bash steam

USER steam
ENV HOME=/home/steam
WORKDIR /home/steam

# SteamCMD lives in the image; the game itself lives on the volume so it
# survives pod moves and is not re-downloaded on every reschedule.
RUN mkdir -p /home/steam/steamcmd \
 && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /home/steam/steamcmd

# Palworld looks for the Steam client libs here regardless of where the app is
# installed; without them the server starts but never reaches the server list.
RUN mkdir -p /home/steam/.steam/sdk64

COPY --chown=steam:steam entrypoint.sh /usr/local/bin/entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint"]
