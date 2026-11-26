#!/usr/bin/env bash
set -euo pipefail

# End-to-end runtime and headless UI smoke test for the installed snap.
#
# What it does:
# 1) Verifies snap installation, required host tools, and product.json ideVersion.
# 2) Runs scripts/e2e-runtime-check.sh (CLI --version + ELF linkage scan).
# 3) Launches the IDE headlessly under Xvfb + D-Bus with a clean temporary profile.
# 4) Verifies an X11 window maps, captures a screenshot, and checks non-blank pixels.
# 5) Inspects the Electron workbench DOM over CDP (readyState, .monaco-workbench,
#    error dialogs, and error notification toasts).
# 6) Verifies process liveness, cleanly terminates test processes, copies artifacts
#    if OUTPUT_DIR is provided, and scans main.log / renderer.log for fatal errors.
#
# Usage:
#   scripts/ui-smoke-test.sh [snap-name] [app-name] [output-dir]

SNAP_NAME="${1:-antigravity-ide-snap}"
APP_NAME="${2:-antigravity-ide}"
OUTPUT_DIR="${3:-}"
APP_REF="${SNAP_NAME}.${APP_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites for ${APP_REF}"
if ! snap list "${SNAP_NAME}" >/dev/null 2>&1; then
  echo "ERROR: snap '${SNAP_NAME}' is not installed." >&2
  exit 1
fi

for cmd in xvfb-run dbus-run-session xwininfo import identify curl python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found." >&2
    exit 1
  fi
done

PRODUCT_JSON="/snap/${SNAP_NAME}/current/usr/share/antigravity-ide/resources/app/product.json"
if [[ ! -f "${PRODUCT_JSON}" ]]; then
  echo "ERROR: product.json not found at ${PRODUCT_JSON}" >&2
  exit 1
fi

IDE_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("ideVersion", ""))' "${PRODUCT_JSON}")"
echo "Installed ideVersion: ${IDE_VERSION}"
if [[ -z "${IDE_VERSION}" ]]; then
  echo "ERROR: ideVersion is missing in ${PRODUCT_JSON}" >&2
  exit 1
fi

if [[ -n "${EXPECTED_IDE_VERSION:-}" && "${IDE_VERSION}" != "${EXPECTED_IDE_VERSION}" ]]; then
  echo "ERROR: ideVersion '${IDE_VERSION}' != EXPECTED_IDE_VERSION '${EXPECTED_IDE_VERSION}'" >&2
  exit 1
fi

echo
echo "==> Running runtime dependency check"
"${SCRIPT_DIR}/e2e-runtime-check.sh" "${SNAP_NAME}" "${APP_NAME}"

TMPDIR="$(mktemp -d)"
DATA_DIR="${TMPDIR}/user-data"
EXT_DIR="${TMPDIR}/extensions"
mkdir -p "${DATA_DIR}" "${EXT_DIR}"

cleanup_test_processes() {
  python3 - "${SNAP_NAME}" "${DATA_DIR}" <<'PY'
import os
import signal
import sys
import time

snap_name = sys.argv[1]
data_dir = sys.argv[2]
own_pid = os.getpid()
snap_prefix = f"/snap/{snap_name}/"

def find_matching_pids():
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == own_pid:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                raw = f.read()
        except OSError:
            continue
        if not raw:
            continue
        args = [a.decode("utf-8", errors="replace") for a in raw.split(b"\x00") if a]
        if not args:
            continue
        exe = args[0]
        is_app = (
            exe.startswith(snap_prefix)
            or exe == "/proc/self/exe"
            or "antigravity-ide" in os.path.basename(exe)
        )
        if is_app and any(data_dir in arg for arg in args):
            pids.append(pid)
    return pids

pids = find_matching_pids()
for pid in pids:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

deadline = time.time() + 3.0
while time.time() < deadline:
    remaining = find_matching_pids()
    if not remaining:
        break
    time.sleep(0.2)

for pid in find_matching_pids():
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
PY
}

cleanup() {
  cleanup_test_processes || true
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

CDP_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

if [[ -x "/snap/bin/${APP_REF}" ]]; then
  LAUNCH_CMD=("/snap/bin/${APP_REF}")
else
  LAUNCH_CMD=("snap" "run" "${APP_REF}")
fi

echo
echo "==> Launching ${APP_REF} headlessly under Xvfb (CDP port ${CDP_PORT})"

export TMPDIR DATA_DIR EXT_DIR CDP_PORT SNAP_NAME
export LAUNCH_BIN="${LAUNCH_CMD[*]}"
unset WAYLAND_DISPLAY XDG_SESSION_TYPE VSCODE_IPC_HOOK_CLI || true

xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- bash -c '
  set -euo pipefail

  read -r -a launch_cmd <<< "${LAUNCH_BIN}"
  "${launch_cmd[@]}" \
    --user-data-dir="${DATA_DIR}" \
    --extensions-dir="${EXT_DIR}" \
    --password-store=basic \
    --disable-gpu \
    --disable-dev-shm-usage \
    --remote-debugging-port="${CDP_PORT}" \
    --new-window \
    >"${TMPDIR}/stdout.log" 2>"${TMPDIR}/stderr.log" &

  ready=0
  for i in $(seq 1 45); do
    cdp_json="$(curl -fsS --max-time 2 "http://127.0.0.1:${CDP_PORT}/json" 2>/dev/null || true)"
    if [[ -n "${cdp_json}" ]] && printf "%s" "${cdp_json}" \
      | python3 -c '\''import json, sys; targets = json.load(sys.stdin); sys.exit(0 if any(t.get("type") == "page" and "workbench.html" in t.get("url", "") for t in targets) else 1)'\'' 2>/dev/null; then
      echo "CDP workbench target ready after ${i}s."
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "${ready}" -ne 1 ]]; then
    echo "ERROR: Timed out waiting for CDP workbench target." >&2
    echo "--- stdout.log ---" >&2
    cat "${TMPDIR}/stdout.log" >&2 || true
    echo "--- stderr.log ---" >&2
    cat "${TMPDIR}/stderr.log" >&2 || true
    exit 1
  fi

  # Allow initial workbench layout, webviews, and startup notifications to settle.
  sleep 8

  echo
  echo "==> Checking X11 top-level window"
  xwin_tree="$(xwininfo -root -tree)"
  echo "${xwin_tree}" | grep -i "Antigravity IDE" || true
  python3 - "${xwin_tree}" <<'\''PY'\''
import re
import sys

tree = sys.argv[1]
matches = re.findall(r"\"[^\"]*Antigravity IDE[^\"]*\".*?(\d+)x(\d+)", tree, re.IGNORECASE)
if not matches:
    print("ERROR: No X11 window matching Antigravity IDE found.", file=sys.stderr)
    sys.exit(1)

valid = [(int(w), int(h)) for w, h in matches if int(w) >= 400 and int(h) >= 300]
if not valid:
    print(f"ERROR: Antigravity IDE X11 windows too small: {matches}", file=sys.stderr)
    sys.exit(1)

print(f"Verified X11 window dimensions: {valid[0][0]}x{valid[0][1]}")
PY

  echo
  echo "==> Capturing Xvfb screenshot and verifying non-blank rendering"
  import -window root "${TMPDIR}/antigravity-ui.png"
  dimensions="$(identify -format "%wx%h" "${TMPDIR}/antigravity-ui.png")"
  color_count="$(identify -format "%k" "${TMPDIR}/antigravity-ui.png")"
  echo "Screenshot: ${dimensions}, unique colors=${color_count}"
  if [[ "${color_count}" -lt 16 ]]; then
    echo "ERROR: Screenshot has too few colors (${color_count} < 16); UI may be blank." >&2
    exit 1
  fi

  echo
  echo "==> Inspecting workbench DOM and error state via CDP"
  python3 - "${CDP_PORT}" <<'\''PY'\''
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import urllib.parse
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=5) as resp:
    targets = json.loads(resp.read().decode("utf-8"))

page = next(
    (t for t in targets if t.get("type") == "page" and "workbench.html" in t.get("url", "")),
    None,
)
if not page:
    print("ERROR: workbench.html page target disappeared.", file=sys.stderr)
    sys.exit(1)

ws_url = page["webSocketDebuggerUrl"]
parsed = urllib.parse.urlparse(ws_url)
host = parsed.hostname or "127.0.0.1"
ws_port = parsed.port or int(port)
path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query

sock = socket.create_connection((host, ws_port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode("ascii")
handshake = (
    f"GET {path} HTTP/1.1\r\n"
    f"Host: {host}:{ws_port}\r\n"
    f"Upgrade: websocket\r\n"
    f"Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    f"Sec-WebSocket-Version: 13\r\n\r\n"
)
sock.sendall(handshake.encode("ascii"))

buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        raise RuntimeError("WebSocket handshake closed unexpectedly")
    buf += chunk

header_bytes, rest = buf.split(b"\r\n\r\n", 1)
header_text = header_bytes.decode("latin-1")
if " 101 " not in header_text.splitlines()[0]:
    raise RuntimeError(f"WebSocket handshake failed: {header_text.splitlines()[0]}")

expected_accept = base64.b64encode(
    hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
).decode("ascii")
if expected_accept not in header_text:
    raise RuntimeError("Invalid Sec-WebSocket-Accept in WebSocket handshake")

rx_buf = bytearray(rest)

def read_exact(n):
    while len(rx_buf) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("WebSocket connection closed while reading frame")
        rx_buf.extend(chunk)
    out = bytes(rx_buf[:n])
    del rx_buf[:n]
    return out

def send_text(msg):
    payload = msg.encode("utf-8")
    mask = os.urandom(4)
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    header.extend(mask)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + masked)

def send_pong(payload):
    mask = os.urandom(4)
    header = bytearray([0x8A, 0x80 | len(payload)])
    header.extend(mask)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + masked)

def recv_message():
    fragments = []
    while True:
        b1, b2 = read_exact(2)
        fin = (b1 & 0x80) != 0
        opcode = b1 & 0x0F
        masked = (b2 & 0x80) != 0
        length = b2 & 0x7F
        if length == 126:
            (length,) = struct.unpack("!H", read_exact(2))
        elif length == 127:
            (length,) = struct.unpack("!Q", read_exact(8))
        mask_key = read_exact(4) if masked else None
        payload = read_exact(length)
        if mask_key:
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

        if opcode == 0x8:
            raise RuntimeError("WebSocket closed by target")
        if opcode == 0x9:
            send_pong(payload)
            continue
        if opcode == 0xA:
            continue

        fragments.append(payload)
        if fin:
            return b"".join(fragments).decode("utf-8")

expr = """(() => {
  const isVisible = (el) => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") {
      return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const wb = document.querySelector(".monaco-workbench");
  const wbRect = wb ? wb.getBoundingClientRect() : null;
  const dialogs = Array.from(document.querySelectorAll(".monaco-dialog-box"))
    .filter(isVisible)
    .map((el) => (el.innerText || el.textContent || "").trim())
    .filter(Boolean);
  const errorToasts = Array.from(
    document.querySelectorAll(".notifications-toasts .notification-toast, .notifications-list-container .monaco-list-row")
  )
    .filter((el) => isVisible(el) && el.querySelector(".codicon-error"))
    .map((el) => (el.innerText || el.textContent || "").trim())
    .filter(Boolean);
  const allToasts = Array.from(document.querySelectorAll(".notifications-toasts .notification-toast"))
    .filter(isVisible)
    .map((el) => (el.innerText || el.textContent || "").trim())
    .filter(Boolean);
  return {
    readyState: document.readyState,
    title: document.title,
    workbenchRect: wbRect ? { x: wbRect.x, y: wbRect.y, width: wbRect.width, height: wbRect.height } : null,
    dialogs,
    errorToasts,
    allToasts,
  };
})()"""

req_id = 1
send_text(json.dumps({
    "id": req_id,
    "method": "Runtime.evaluate",
    "params": {
        "expression": expr,
        "returnByValue": True,
        "awaitPromise": True,
    },
}))

result_msg = None
while True:
    msg = json.loads(recv_message())
    if msg.get("id") == req_id:
        result_msg = msg
        break

sock.close()

if "error" in result_msg:
    err = result_msg["error"]
    print(f"ERROR: CDP Runtime.evaluate failed: {err}", file=sys.stderr)
    sys.exit(1)

eval_res = result_msg.get("result", {})
if "exceptionDetails" in eval_res:
    exc = eval_res["exceptionDetails"]
    print(f"ERROR: JS exception during DOM inspection: {exc}", file=sys.stderr)
    sys.exit(1)

state = eval_res.get("result", {}).get("value")
print(json.dumps(state, indent=2))

if not isinstance(state, dict):
    print("ERROR: Unexpected DOM inspection result.", file=sys.stderr)
    sys.exit(1)
ready_state = state.get("readyState")
if ready_state != "complete":
    print(f"ERROR: document.readyState is {ready_state!r}, expected 'complete'.", file=sys.stderr)
    sys.exit(1)

rect = state.get("workbenchRect")
if not rect or rect.get("width", 0) < 400 or rect.get("height", 0) < 300:
    print(f"ERROR: .monaco-workbench missing or undersized: {rect!r}", file=sys.stderr)
    sys.exit(1)

dialogs = state.get("dialogs")
if dialogs:
    print(f"ERROR: Unexpected modal dialog(s) displayed: {dialogs}", file=sys.stderr)
    sys.exit(1)

error_toasts = state.get("errorToasts")
if error_toasts:
    print(f"ERROR: Unexpected error toast(s) displayed: {error_toasts}", file=sys.stderr)
    sys.exit(1)
PY

  echo
  echo "==> Checking Electron process liveness"
  python3 - "${SNAP_NAME}" "${DATA_DIR}" <<'\''PY'\''
import os
import sys

snap_name = sys.argv[1]
data_dir = sys.argv[2]
snap_prefix = f"/snap/{snap_name}/"
alive = []

for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
    except OSError:
        continue
    if not raw:
        continue
    args = [a.decode("utf-8", errors="replace") for a in raw.split(b"\x00") if a]
    if not args:
        continue
    exe = args[0]
    is_app = (
        exe.startswith(snap_prefix)
        or exe == "/proc/self/exe"
        or "antigravity-ide" in os.path.basename(exe)
    )
    if is_app and any(data_dir in arg for arg in args):
        alive.append((pid, os.path.basename(exe)))

if not alive:
    print("ERROR: No live antigravity-ide process found after UI checks.", file=sys.stderr)
    sys.exit(1)

print(f"Confirmed {len(alive)} live process(es), e.g. pid={alive[0][0]} ({alive[0][1]}).")
PY
'

echo
echo "==> Stopping test IDE processes and inspecting logs"
cleanup_test_processes

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  cp -f "${TMPDIR}/antigravity-ui.png" "${OUTPUT_DIR}/antigravity-ui.png"
  cp -f "${TMPDIR}/stdout.log" "${OUTPUT_DIR}/stdout.log"
  cp -f "${TMPDIR}/stderr.log" "${OUTPUT_DIR}/stderr.log"
  if [[ -d "${DATA_DIR}/logs" ]]; then
    rm -rf "${OUTPUT_DIR}/logs"
    cp -a "${DATA_DIR}/logs" "${OUTPUT_DIR}/logs"
  fi
  echo "Saved UI smoke test artifacts to ${OUTPUT_DIR}"
fi

python3 - "${DATA_DIR}/logs" <<'PY'
import os
import re
import sys

logs_root = sys.argv[1]
if not os.path.isdir(logs_root):
    print(f"ERROR: Log directory missing: {logs_root}", file=sys.stderr)
    sys.exit(1)

target_logs = []
for root, _, files in os.walk(logs_root):
    for name in files:
        if name in ("main.log", "renderer.log"):
            target_logs.append(os.path.join(root, name))

if not target_logs:
    print(f"ERROR: Neither main.log nor renderer.log found under {logs_root}", file=sys.stderr)
    sys.exit(1)

fatal_re = re.compile(
    r"(FATAL|SIGSEGV|cannot open shared object file|Uncaught Error|Uncaught TypeError|Uncaught ReferenceError)"
)

findings = []
for path in sorted(target_logs):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, start=1):
            if fatal_re.search(line):
                findings.append(f"{path}:{lineno}: {line.rstrip()}")

print(f"Scanned {len(target_logs)} log file(s): {', '.join(os.path.basename(p) for p in sorted(target_logs))}")
if findings:
    print("ERROR: Fatal error pattern(s) found in logs:", file=sys.stderr)
    for item in findings:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

echo
echo "PASS: UI smoke test completed."
