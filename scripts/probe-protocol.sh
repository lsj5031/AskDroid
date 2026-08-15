#!/bin/zsh
set -euo pipefail

DROID_BIN="${DROID_BIN:-$(command -v droid || true)}"
if [[ -z "${DROID_BIN}" ]]; then
  echo "droid not found on PATH" >&2
  exit 1
fi

python3 - "$DROID_BIN" <<'PY'
import json, os, subprocess, sys, time

droid = sys.argv[1]
proc = subprocess.Popen(
    [droid, "exec", "--input-format", "stream-jsonrpc", "--output-format", "stream-jsonrpc"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=os.path.expanduser("~"),
)

def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()

send({
    "jsonrpc": "2.0",
    "factoryApiVersion": "1.0.0",
    "factoryProtocolVersion": "1.1.0",
    "type": "request",
    "id": "1",
    "method": "droid.initialize_session",
    "params": {"machineId": "askdroid-probe", "cwd": os.path.expanduser("~")},
})

deadline = time.time() + 20
got = False
while time.time() < deadline:
    line = proc.stdout.readline()
    if not line:
        break
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue
    print(json.dumps({"id": message.get("id"), "method": message.get("method"), "type": message.get("type"), "hasResult": "result" in message, "hasError": "error" in message}))
    if message.get("id") == "1":
        got = "result" in message
        break

send({
    "jsonrpc": "2.0",
    "factoryApiVersion": "1.0.0",
    "factoryProtocolVersion": "1.1.0",
    "type": "request",
    "id": "close",
    "method": "droid.close_session",
    "params": {"reason": "other"},
})
proc.stdin.close()
try:
    proc.wait(timeout=3)
except subprocess.TimeoutExpired:
    proc.kill()

if not got:
    err = proc.stderr.read() if proc.stderr else ""
    print(err[:1000], file=sys.stderr)
    raise SystemExit("initialize_session did not return a result")
print("ok")
PY
