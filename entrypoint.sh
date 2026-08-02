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
adminpass="${PAL_ADMIN_PASSWORD:-}"

log(){ echo "gamectl: $*"; }

mkdir -p "$DATA"
log "entrypoint starting (data: $DATA)"

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
    # Fatal on purpose: there is no game to fall back to.
    "$STEAMCMD" +force_install_dir "$DATA" +login anonymous +app_update "$APPID" validate +quit
    touch "$INSTALLED"
  else
    log "update requested — running steamcmd app_update $APPID validate"
    # NOT fatal: an already-installed server should still come up if Steam is
    # having a bad day. See the header note about the CS2 restart loop.
    if "$STEAMCMD" +force_install_dir "$DATA" +login anonymous +app_update "$APPID" validate +quit; then
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

# Rewrite only the env-managed keys, in place, on every boot. GameCTL owns
# these; everything else in the ini belongs to whoever is running the server.
set_opt(){ # key value -> replace Key=... inside OptionSettings=(...)
  local k="$1" v="$2"
  if grep -q "${k}=" "$CFG/PalWorldSettings.ini"; then
    sed -i -E "s/${k}=[^,)]*/${k}=${v}/" "$CFG/PalWorldSettings.ini"
  fi
}
set_opt ServerName "\"${name//\"/}\""
set_opt ServerPlayerMaxNum "$maxplayers"
set_opt PublicPort "$port"
set_opt ServerPassword "\"${serverpass//\"/}\""
set_opt AdminPassword "\"${adminpass//\"/}\""

log "starting Palworld '${name}' on ${port}/udp (query ${queryport}, public=${public}, max ${maxplayers})"

cd "$DATA"
args=( "-port=${port}" "-queryport=${queryport}" "-players=${maxplayers}"
       -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS )
[ "$public" = "true" ] && args+=( -publiclobby )

# exec so the server is PID 1's child and receives SIGTERM directly -- Palworld
# only flushes its save on a clean shutdown, and a missed signal loses progress.
exec ./PalServer.sh "${args[@]}"
