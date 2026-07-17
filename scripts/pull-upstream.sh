#!/usr/bin/env bash
# Part lifecycle hook: override-pull for the antigravity-ide part.
# Downloads the upstream IDE tarball for the architecture being built.
# Called by snap/snapcraft.yaml; do not invoke directly.
set -eu

# Resolve the latest release from the auto-updater API.  The API returns a
# JSON array; we pick the entry with the highest semantic version.
# Override with env vars to pin to a specific release (e.g. for roll-backs):
#   ANTIGRAVITY_IDE_VERSION=2.1.1 ANTIGRAVITY_IDE_EXECUTION_ID=6123990880747520
if [[ -n "${ANTIGRAVITY_IDE_VERSION:-}" && -n "${ANTIGRAVITY_IDE_EXECUTION_ID:-}" ]]; then
  VERSION="$ANTIGRAVITY_IDE_VERSION"
  EXECUTION_ID="$ANTIGRAVITY_IDE_EXECUTION_ID"
else
  api_json=$(curl -fsSL \
    "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases")
  version_info=$(echo "$api_json" | python3 -c '
import json, re, sys

def semver_key(v):
    nums = [int(x) for x in re.findall(r"\d+", str(v))]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3])

releases = json.load(sys.stdin)
best = max(releases, key=lambda r: semver_key(r.get("version", "0.0.0")))
print(best["version"], best["execution_id"])
')
  VERSION=$(echo "$version_info" | awk '{print $1}')
  EXECUTION_ID=$(echo "$version_info" | awk '{print $2}')
fi

# Propagate the resolved version to the snap metadata.
craftctl set version="$VERSION"

case "$CRAFT_ARCH_BUILD_FOR" in
  amd64) ARCH_PATH="linux-x64" ;;
  arm64) ARCH_PATH="linux-arm" ;;
  *)
    echo "Unsupported architecture: $CRAFT_ARCH_BUILD_FOR" >&2
    exit 1
    ;;
esac

URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${VERSION}-${EXECUTION_ID}/${ARCH_PATH}/Antigravity%20IDE.tar.gz"
curl -fsSL -o "$CRAFT_PART_SRC/antigravity-ide-build.tar.gz" "$URL"
