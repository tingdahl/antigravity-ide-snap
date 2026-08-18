#!/usr/bin/env bash
set -euo pipefail

# Update snap/snapcraft.yaml with the latest Antigravity IDE release metadata.
#
# Source of truth:
# https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases
#
# Optional usage:
#   scripts/update-upstream-version.sh
#   scripts/update-upstream-version.sh --version 2.1.1 --execution-id 6123990880747520

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPCRAFT_FILE="$ROOT_DIR/snap/snapcraft.yaml"

VERSION=""
EXECUTION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --execution-id)
      EXECUTION_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$EXECUTION_ID" ]]; then
  read -r VERSION EXECUTION_ID <<EOF
$(curl -fsSL "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases" | python3 -c '
import json
import re
import sys

def semver_key(v: str):
    nums = [int(x) for x in re.findall(r"\d+", v)]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3])

releases = json.load(sys.stdin)
if not isinstance(releases, list) or not releases:
    raise SystemExit("No releases found")

best = max(releases, key=lambda r: semver_key(str(r.get("version", "0.0.0"))))
print(best["version"], best["execution_id"])
')
EOF
fi

URL_AMD64="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${VERSION}-${EXECUTION_ID}/linux-x64/Antigravity%20IDE.tar.gz"
URL_ARM64="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${VERSION}-${EXECUTION_ID}/linux-arm/Antigravity%20IDE.tar.gz"

python3 - "$SNAPCRAFT_FILE" "$VERSION" "$URL_AMD64" "$URL_ARM64" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
url_amd64 = sys.argv[3]
url_arm64 = sys.argv[4]

text = path.read_text(encoding="utf-8")

text, n1 = re.subn(r"(?m)^version:\s*'[^']*'\s*$", f"version: '{version}'", text, count=1)
text, n2 = re.subn(
    r'(?m)^(\s*URL=")https://edgedl\.me\.gvt1\.com/edgedl/release2/j0qc3/antigravity/stable/[^\"]*/linux-x64/Antigravity%20IDE\.tar\.gz("\s*)$',
    rf'\1{url_amd64}\2',
    text,
    count=1,
)
text, n3 = re.subn(
    r'(?m)^(\s*URL=")https://edgedl\.me\.gvt1\.com/edgedl/release2/j0qc3/antigravity/stable/[^\"]*/linux-arm/Antigravity%20IDE\.tar\.gz("\s*)$',
    rf'\1{url_arm64}\2',
    text,
    count=1,
)

if (n1, n2, n3) != (1, 1, 1):
    raise SystemExit(f"Failed to update all targets in snapcraft.yaml; matches={n1,n2,n3}")

path.write_text(text, encoding="utf-8")
PY

echo "Updated $SNAPCRAFT_FILE"
echo "Version: $VERSION"
echo "Execution ID: $EXECUTION_ID"
