#!/usr/bin/env bash
# Part lifecycle hook: override-pull for the antigravity-ide part.
# Downloads the upstream IDE tarball for the architecture being built.
# Called by snap/snapcraft.yaml; do not invoke directly.
set -eu

RELEASES_URL="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases"
CURL_RETRY_ARGS=(
  --fail
  --location
  --silent
  --show-error
  --retry 8
  --retry-all-errors
  --retry-delay 2
  --connect-timeout 20
  --max-time 900
)

# Resolve the target release:
# 1. Explicit ANTIGRAVITY_IDE_VERSION + ANTIGRAVITY_IDE_EXECUTION_ID env vars.
# 2. Pinned UPSTREAM_VERSION sentinel file in the project root.
# 3. Fallback to the highest semantic version returned by the auto-updater API.
if [[ -n "${ANTIGRAVITY_IDE_VERSION:-}" && -n "${ANTIGRAVITY_IDE_EXECUTION_ID:-}" ]]; then
  VERSION="$ANTIGRAVITY_IDE_VERSION"
  EXECUTION_ID="$ANTIGRAVITY_IDE_EXECUTION_ID"
else
  api_json=$(curl "${CURL_RETRY_ARGS[@]}" "$RELEASES_URL")
  if [[ -n "${CRAFT_PROJECT_DIR:-}" && -f "$CRAFT_PROJECT_DIR/UPSTREAM_VERSION" ]]; then
    TARGET_VERSION="$(tr -d '[:space:]' < "$CRAFT_PROJECT_DIR/UPSTREAM_VERSION")"
    version_info=$(echo "$api_json" | python3 -c '
import json, sys

target = sys.argv[1]
releases = json.load(sys.stdin)
matches = [r for r in releases if str(r.get("version", "")).strip() == target]
if not matches:
    sys.stderr.write(f"ERROR: No execution_id found for UPSTREAM_VERSION={target!r}\n")
    sys.exit(1)
print(matches[0]["version"], matches[0]["execution_id"])
' "$TARGET_VERSION")
  else
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
  fi
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
curl "${CURL_RETRY_ARGS[@]}" -o "$CRAFT_PART_SRC/antigravity-ide-build.tar.gz" "$URL"
