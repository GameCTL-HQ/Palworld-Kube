#!/usr/bin/env bash
# palworld-kube entrypoint.
#
# The volume is mounted at $DATA and holds the whole install (game + saves +
# config), so a reschedule onto another node keeps everything.
set -euo pipefail

APPID=2394010
DATA="${PAL_DATA:-/palworld}"
STEAMCMD=/home/steam/steamcmd/steamcmd.sh
INSTALLED="$DATA/.gamectl-palworld-installed"
LASTREQ="$DATA/.gamectl-palworld-last-update-request"
REQ="${GAMECTL_UPDATE_REQUEST:-}"

name="${PAL_NAME:-GameCTL Palworld}"
port="${PAL_PORT:-8211}"
queryport="${PAL_QUERY_PORT:-27015}"
maxplayers="${PAL_MAX_PLAYERS:-16}"
public="${PAL_PUBLIC:-false}"
serverpass="${PAL_PASSWORD:-}"
restport="${PAL_REST_PORT:-8212}"
adminpassfile="$DATA/.gamectl-palworld-admin-password"
adminpasssource="${PAL_ADMIN_PASSWORD_FILE:-/run/secrets/palworld-admin/admin-password}"

log(){ echo "gamectl: $*"; }

mkdir -p "$DATA"
log "entrypoint starting (data: $DATA)"

# steamcmd bootstraps and self-updates on first run, and the very first
# app_update after that update can fail before the client has finished
# configuring itself -- observed on a real first boot as:
#
#   ERROR! Failed to install app '2394010' (Missing configuration)
#
# It succeeds on a retry. Without this loop the only thing that saves the
# install is the container exiting and the kubelet restarting it, which
# works but looks like a crash and burns the whole pod startup each time.
# Retrying in place is the same approach Barotrauma-Kube uses.
steamcmd_run() {
  local i
  for i in 1 2 3 4 5; do
    "$STEAMCMD" +force_install_dir "$DATA" +login anonymous +app_update "$APPID" validate +quit && return 0
    log "steamcmd attempt $i failed - clearing appcache and retrying"
    rm -rf "$HOME/Steam/appcache" 2>/dev/null || true
    sleep 10
  done
  return 1
}

# ---------------------------------------------------------------- install/update
MODE=""
if [ ! -f "$INSTALLED" ]; then
  MODE="install"
elif [ -n "$REQ" ] && { [ ! -f "$LASTREQ" ] || [ "$(cat "$LASTREQ" 2>/dev/null)" != "$REQ" ]; }; then
  MODE="update"
fi

if [ -z "$MODE" ]; then
  log "existing install found — skipping steamcmd (trigger an update from GameCTL to refresh)"
else
  if [ "$MODE" = "install" ]; then
    log "first Palworld install on the volume — running steamcmd app_update $APPID"
    # Fatal only after the retries are exhausted: there is no game to fall
    # back to, so a genuinely failed first install must not start the server.
    steamcmd_run || { log "ERROR: first install failed after retries" >&2; exit 1; }
    touch "$INSTALLED"
  else
    log "update requested — running steamcmd app_update $APPID validate"
    # NOT fatal: an already-installed server should still come up if Steam is
    # having a bad day. See the header note about the CS2 restart loop.
    if steamcmd_run; then
      log "update completed"
    else
      log "WARNING: update FAILED — starting on the existing install."
      log "The request is recorded so it will not retry in a loop."
    fi
  fi
  # Recorded unconditionally: this means "we acted on this request", not "it
  # worked". That distinction is what stops an update loop.
  [ -n "$REQ" ] && printf "%s" "$REQ" > "$LASTREQ"
fi

# Palworld refuses to reach the server list without the Steam client libs.
if [ -f "$DATA/linux64/steamclient.so" ]; then
  ln -sf "$DATA/linux64/steamclient.so" /home/steam/.steam/sdk64/steamclient.so
fi

# ---------------------------------------------------------------- settings
CFG="$DATA/Pal/Saved/Config/LinuxServer"
mkdir -p "$CFG"
if [ ! -s "$CFG/PalWorldSettings.ini" ]; then
  if [ -f "$DATA/DefaultPalWorldSettings.ini" ]; then
    log "seeding PalWorldSettings.ini from the shipped defaults"
    cp "$DATA/DefaultPalWorldSettings.ini" "$CFG/PalWorldSettings.ini"
  else
    log "ERROR: DefaultPalWorldSettings.ini missing — install looks incomplete" >&2
    exit 1
  fi
fi
chmod 600 "$CFG/PalWorldSettings.ini"

# Palworld's authenticated REST /info endpoint is the native serving signal.
# The persistent 0600 file is canonical on every boot. A mounted Kubernetes
# Secret seeds/rotates it without putting the credential in Deployment env or
# argv. PAL_ADMIN_PASSWORD remains a compatibility input for direct image users,
# but GameCTL does not render it.
read_secret_file() {
  local value
  value="$(cat "$1"; printf x)"
  value="${value%x}"
  case "$value" in
    *$'\n'*|*$'\r'*) log "ERROR: admin credential must not contain a newline" >&2; exit 1 ;;
  esac
  [ -n "$value" ] || { log "ERROR: admin credential is empty" >&2; exit 1; }
  printf '%s' "$value"
}

adminpass=""
if [ -f "$adminpasssource" ]; then
  adminpass="$(read_secret_file "$adminpasssource")"
elif [ -n "${PAL_ADMIN_PASSWORD:-}" ]; then
  case "$PAL_ADMIN_PASSWORD" in
    *$'\n'*|*$'\r'*) log "ERROR: admin credential must not contain a newline" >&2; exit 1 ;;
  esac
  adminpass="$PAL_ADMIN_PASSWORD"
elif [ -s "$adminpassfile" ]; then
  adminpass="$(read_secret_file "$adminpassfile")"
else
  adminpass="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
fi

credentialtmp="$adminpassfile.tmp.$$"
( umask 077; printf '%s' "$adminpass" > "$credentialtmp" )
chmod 600 "$credentialtmp"
mv -f "$credentialtmp" "$adminpassfile"
chmod 600 "$adminpassfile"

# Rewrite only the env-managed keys, in place, on every boot. GameCTL owns
# these; everything else in the ini belongs to whoever is running the server.
{
  printf '%s\0%s\0%s\0' ServerName string "$name"
  printf '%s\0%s\0%s\0' ServerPlayerMaxNum raw "$maxplayers"
  printf '%s\0%s\0%s\0' PublicPort raw "$port"
  printf '%s\0%s\0%s\0' ServerPassword string "$serverpass"
  printf '%s\0%s\0%s\0' AdminPassword string "$adminpass"
  printf '%s\0%s\0%s\0' RESTAPIEnabled raw True
  printf '%s\0%s\0%s\0' RESTAPIPort raw "$restport"
} | "${PAL_CONFIG_HELPER:-/usr/local/bin/palworld-config}" "$CFG/PalWorldSettings.ini"
chmod 600 "$CFG/PalWorldSettings.ini"

# Test seam: exercise install-skip, credential convergence, and INI handling
# without launching PalServer on a build or review host.
[ "${PAL_CONFIG_ONLY:-0}" = "1" ] && exit 0

log "starting Palworld '${name}' on ${port}/udp (query ${queryport}, public=${public}, max ${maxplayers})"

cd "$DATA"
args=( "-port=${port}" "-queryport=${queryport}" "-players=${maxplayers}"
       -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS )
[ "$public" = "true" ] && args+=( -publiclobby )

# exec so the server is PID 1's child and receives SIGTERM directly -- Palworld
# only flushes its save on a clean shutdown, and a missed signal loses progress.
exec ./PalServer.sh "${args[@]}"
