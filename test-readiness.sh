#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
root="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT

special='a&b/c\d, (space value)'
data="$root/data"
cfg="$data/Pal/Saved/Config/LinuxServer"
mkdir -p "$cfg"
touch "$data/.gamectl-palworld-installed"
printf '%s' "$special" > "$root/admin-secret"
chmod 600 "$root/admin-secret"
cat > "$cfg/PalWorldSettings.ini" <<'EOF'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="old",ServerPlayerMaxNum=1,PublicPort=8211,ServerPassword="")
EOF
chmod 644 "$cfg/PalWorldSettings.ini"

run_config() {
  PAL_CONFIG_ONLY=1 \
  PAL_CONFIG_HELPER="$repo/palworld-config" \
  PAL_DATA="$data" \
  PAL_ADMIN_PASSWORD_FILE="$1" \
  PAL_NAME='Name & / \ comma, parens () and spaces' \
  PAL_PASSWORD='join & / \ comma, parens () and spaces' \
  "$repo/entrypoint.sh"
}

# First boot: mounted Secret becomes the canonical persistent credential, missing
# keys are inserted, metacharacters survive, and both secret-bearing files are 0600.
run_config "$root/admin-secret" > "$root/boot1.log" 2>&1
[ "$(stat -c %a "$data/.gamectl-palworld-admin-password")" = 600 ]
[ "$(stat -c %a "$cfg/PalWorldSettings.ini")" = 600 ]
[ "$(cat "$data/.gamectl-palworld-admin-password")" = "$special" ]
! grep -F -- "$special" "$root/boot1.log"

EXPECTED_ADMIN="$special" EXPECTED_NAME='Name & / \ comma, parens () and spaces' \
EXPECTED_JOIN='join & / \ comma, parens () and spaces' INI="$cfg/PalWorldSettings.ini" \
python3 - <<'PY'
import json
import os
import re
from pathlib import Path

text = Path(os.environ["INI"]).read_text()
body = re.search(r"^OptionSettings=\((.*)\)$", text, re.MULTILINE).group(1)

def value(key):
    match = re.search(r"(?:^|,)" + re.escape(key) + r"=(\"(?:\\.|[^\"])*\"|[^,)]*)", body)
    if not match:
        raise AssertionError(f"missing {key}")
    token = match.group(1)
    return json.loads(token) if token.startswith('"') else token

assert value("AdminPassword") == os.environ["EXPECTED_ADMIN"]
assert value("ServerPassword") == os.environ["EXPECTED_JOIN"]
assert value("ServerName") == os.environ["EXPECTED_NAME"]
assert value("RESTAPIEnabled") == "True"
assert value("RESTAPIPort") == "8212"
PY

# Second boot: no Secret input, broader pre-existing modes are repaired, and the
# exact canonical credential is reused rather than regenerated.
rm -f "$root/admin-secret"
chmod 644 "$data/.gamectl-palworld-admin-password" "$cfg/PalWorldSettings.ini"
run_config "$root/missing-secret" > "$root/boot2.log" 2>&1
[ "$(stat -c %a "$data/.gamectl-palworld-admin-password")" = 600 ]
[ "$(stat -c %a "$cfg/PalWorldSettings.ini")" = 600 ]
[ "$(cat "$data/.gamectl-palworld-admin-password")" = "$special" ]
! grep -F -- "$special" "$root/boot2.log"

# Newlines are rejected before the canonical credential or INI can be changed.
printf 'bad\nsecret' > "$root/newline-secret"
if run_config "$root/newline-secret" > "$root/newline.log" 2>&1; then
  echo "newline credential unexpectedly accepted" >&2
  exit 1
fi
[ "$(cat "$data/.gamectl-palworld-admin-password")" = "$special" ]
! grep -F -- 'bad' "$root/newline.log"

# Real HTTP fixture for auth, status, payload, and argv/log secrecy checks.
cat > "$root/server.py" <<'PY'
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        mode = (root / "mode").read_text().strip()
        expected = (root / "expected").read_text()
        auth = self.headers.get("Authorization", "")
        want = "Basic " + base64.b64encode(("admin:" + expected).encode()).decode()
        if self.path != "/v1/api/info" or auth != want or mode == "401":
            self.send_response(401); self.end_headers(); return
        if mode == "503":
            self.send_response(503); self.end_headers(); return
        if mode == "delay":
            time.sleep(1)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"not-json" if mode == "malformed" else b'{"version":"fixture"}')

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
PY
printf '%s' "$special" > "$root/expected"
printf success > "$root/mode"
python3 "$root/server.py" "$root" &
server_pid=$!
for _ in $(seq 1 50); do [ -s "$root/port" ] && break; sleep 0.02; done
port="$(cat "$root/port")"
PAL_DATA="$data" PAL_REST_PORT="$port" "$repo/palworld-readiness" > "$root/ready-ok.log" 2>&1
! grep -F -- "$special" "$root/ready-ok.log"

for mode in 401 503 malformed; do
  printf '%s' "$mode" > "$root/mode"
  if PAL_DATA="$data" PAL_REST_PORT="$port" "$repo/palworld-readiness" > "$root/ready-$mode.log" 2>&1; then
    echo "$mode response unexpectedly accepted" >&2
    exit 1
  fi
  ! grep -F -- "$special" "$root/ready-$mode.log"
done

printf delay > "$root/mode"
PAL_DATA="$data" PAL_REST_PORT="$port" "$repo/palworld-readiness" > "$root/ready-delay.log" 2>&1 &
probe_pid=$!
sleep 0.15
tr '\0' ' ' < "/proc/$probe_pid/cmdline" > "$root/probe.argv"
! grep -F -- "$special" "$root/probe.argv"
wait "$probe_pid"
! grep -F -- "$special" "$root/ready-delay.log"

printf 'palworld readiness/config tests: PASS\n'
