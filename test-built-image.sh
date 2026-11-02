#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 IMAGE" >&2
  exit 2
fi

image="$1"
root="$(mktemp -d)"
cleanup() {
  rm -rf "$root"
}
trap cleanup EXIT

cat > "$root/server.py" <<'PY'
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

root = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        expected = (root / "expected").read_text(encoding="utf-8")
        wanted = "Basic " + base64.b64encode(
            ("admin:" + expected).encode("utf-8")
        ).decode("ascii")
        if self.path != "/v1/api/info" or self.headers.get("Authorization") != wanted:
            self.send_response(401)
            self.end_headers()
            return
        payload = b'{"version":"built-image-fixture"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


server = HTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port), encoding="ascii")
server.handle_request()
PY
chmod 0644 "$root/server.py"
chmod 0755 "$root"

# The image entrypoint is deliberately bypassed: this regression starts only a
# bounded one-request fixture and the real helper installed in the built image.
timeout 20 docker run --rm \
  --entrypoint /bin/bash \
  --mount "type=bind,src=$root/server.py,dst=/fixture-server.py,readonly" \
  "$image" \
  -euo pipefail -c '
    fixture="$(mktemp -d)"
    fixture_pid=""
    cleanup() {
      [ -z "$fixture_pid" ] || kill "$fixture_pid" 2>/dev/null || true
      rm -rf "$fixture"
    }
    trap cleanup EXIT
    mkdir -p "$fixture/data"
    printf "%s" "built-image-secret-a&b/c\\d, spaces" \
      > "$fixture/data/.gamectl-palworld-admin-password"
    printf "%s" "built-image-secret-a&b/c\\d, spaces" > "$fixture/expected"
    chmod 0600 "$fixture/data/.gamectl-palworld-admin-password" "$fixture/expected"
    python3 /fixture-server.py "$fixture" &
    fixture_pid=$!
    for _ in $(seq 1 100); do
      [ -s "$fixture/port" ] && break
      kill -0 "$fixture_pid" 2>/dev/null || exit 1
      sleep 0.02
    done
    [ -s "$fixture/port" ]
    PAL_DATA="$fixture/data" PAL_REST_PORT="$(cat "$fixture/port")" \
      /usr/local/bin/palworld-readiness
    wait "$fixture_pid"
  '

printf 'palworld built-image readiness test: PASS\n'
