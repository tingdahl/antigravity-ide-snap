#!/usr/bin/env bash
set -euo pipefail

# End-to-end runtime dependency check for the installed snap.
#
# What it does:
# 1) Runs a headless smoke command: --version
# 2) Runs an ELF linkage scan from inside `snap run --shell`, so ldd resolves
#    dependencies using the same runtime environment as real execution.
#
# Usage:
#   scripts/e2e-runtime-check.sh [snap-name] [app-name]
#
# Examples:
#   scripts/e2e-runtime-check.sh antigravity-ide-snap antigravity-ide
#   scripts/e2e-runtime-check.sh

SNAP_NAME="${1:-antigravity-ide-snap}"
APP_NAME="${2:-antigravity-ide}"
APP_REF="${SNAP_NAME}.${APP_NAME}"

if ! command -v snap >/dev/null 2>&1; then
  echo "ERROR: snap command not found." >&2
  exit 1
fi

if ! snap list "${SNAP_NAME}" >/dev/null 2>&1; then
  echo "ERROR: snap '${SNAP_NAME}' is not installed." >&2
  echo "Install it first, for example:" >&2
  echo "  sudo snap install ./antigravity-ide-snap_<version>_amd64.snap --dangerous --classic" >&2
  exit 1
fi

echo "==> Smoke test: ${APP_REF} --version"
if ! snap run "${APP_REF}" --version; then
  echo "ERROR: smoke test failed." >&2
  exit 1
fi

echo
echo "==> Runtime linkage scan inside snap shell"

# The script below executes INSIDE snap run shell.
read -r -d '' INNER_SCRIPT <<'EOF' || true
set -euo pipefail

TARGET_DIR="$SNAP/usr/share/antigravity-ide"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "ERROR: target directory missing: $TARGET_DIR" >&2
  exit 1
fi

count=0
missing=0

while IFS= read -r -d '' f; do
  # Skip non-ELF files.
  if ! file "$f" | grep -q 'ELF'; then
    continue
  fi

  count=$((count + 1))

  # ldd can fail for some ELF classes; only treat explicit 'not found' as missing dependency.
  out="$(ldd "$f" 2>/dev/null || true)"
  if echo "$out" | grep -q 'not found'; then
    echo "MISSING: $f"
    echo "$out" | grep 'not found'
    echo
    missing=$((missing + 1))
  fi
done < <(
  find "$TARGET_DIR" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' -o -name '*.node' \) -print0
)

echo "Scanned ELF files: $count"

if [[ "$missing" -gt 0 ]]; then
  echo "Missing dependency findings: $missing" >&2
  exit 2
fi

echo "No missing dependencies reported by runtime linkage scan."
EOF

snap run --shell "${APP_REF}" -c "$INNER_SCRIPT"

echo
echo "PASS: smoke test and runtime dependency scan completed."
