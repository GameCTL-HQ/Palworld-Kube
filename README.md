# Palworld-Kube

A from-scratch **Palworld dedicated server** image for Kubernetes, maintained by
[GameCTL](https://github.com/GameCTL-HQ/GameCTL) so nothing changes underneath
us. Sources: Debian's official base, Valve's official steamcmd, and the server
from Steam's CDN (app `2394010`, anonymous).

The game (~8GB) installs to the **persistent volume** on first boot, not into
the image, so a pod reschedule does not re-download it.

## Image

`ghcr.io/gamectl-hq/palworld-kube:latest`

## Ports

Palworld uses **two separate UDP ports** and both must be reachable:

| Port | Default | Purpose |
| --- | --- | --- |
| game | `8211` | play traffic |
| query | `27015` | what the in-game server browser probes |

Forward only the game port and players can still join by direct IP while the
server never appears in any list. This is a common way to lose an afternoon.

## Environment

| Var | Default | Notes |
| --- | --- | --- |
| `PAL_NAME` | `GameCTL Palworld` | display name in the server list |
| `PAL_PORT` | `8211` | game port; also written to `PalWorldSettings.ini` |
| `PAL_QUERY_PORT` | `27015` | query port |
| `PAL_REST_PORT` | `8212` | internal-only native REST readiness port |
| `PAL_MAX_PLAYERS` | `16` | |
| `PAL_PUBLIC` | `false` | `true` adds `-publiclobby` |
| `PAL_PASSWORD` | *(unset)* | join password |
| `PAL_ADMIN_PASSWORD_FILE` | `/run/secrets/palworld-admin/admin-password` | optional mounted admin-password file |
| `PAL_ADMIN_PASSWORD` | *(unset)* | compatibility input for direct image use; prefer the file |
| `GAMECTL_UPDATE_REQUEST` | *(unset)* | one-shot update token; changing it triggers one `app_update` |

These are re-applied to `PalWorldSettings.ini` on **every boot**, so editing that
file by hand on the volume is overwritten at startup — set them here instead.
The entrypoint converges the mounted or generated admin credential into the
persistent `.gamectl-palworld-admin-password` file and enforces mode `0600` on
that file and `PalWorldSettings.ini` on every boot. Newlines are rejected;
punctuation and whitespace are preserved exactly. The authenticated
`/v1/api/info` endpoint is used for readiness without putting the credential in
probe arguments or logs; REST port 8212 must not be published to the Internet.

After building the image, run `./test-built-image.sh IMAGE`. The regression
bypasses the game-server entrypoint and runs the installed readiness helper
against a bounded, authenticated loopback fixture inside the built image. This
also verifies that the image contains the helper's complete Python standard
library rather than only the minimal interpreter.

## Update behaviour

A failed **update** is not fatal: the server logs a warning and starts on the
existing install, and the request is recorded so it does not retry in a loop.
Only a failed **first install** exits non-zero, since there is no game to run.

This is deliberate. The sibling CS2 image aborted on a failed update *before*
recording the request, so every restart re-ran the same doomed update — one
stale request cost 119 restarts and ~10h of downtime, with nothing visible in
the UI because main containers never start until init containers finish.

## Resources

Palworld is memory-hungry — UE5 plus per-player pal simulation. `8Gi` is a
realistic floor for 16 players and it grows with base size and world age.
