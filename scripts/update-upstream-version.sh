#!/usr/bin/env bash
set -euo pipefail

# Query the Antigravity IDE auto-updater API and report the latest release.
#
# Since snap/snapcraft.yaml now uses `adopt-info` with a dynamic API fetch in
# override-pull, running `snapcraft pack` always picks up the latest release
# automatically — no YAML patching is needed.
#
# This script is kept as a convenience tool:
#   - Run it to see what the latest upstream version is.
#   - Use the printed env-var snippet to pin a specific release when building,
#     e.g. for CI roll-backs or reproducible builds:
#
#       ANTIGRAVITY_IDE_VERSION=2.1.1 \
#       ANTIGRAVITY_IDE_EXECUTION_ID=6123990880747520 \
#       snapcraft pack
#
# Source of truth:
# https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases

curl -fsSL \
  "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases" \
| python3 -c '
import json
import re
import sys

def semver_key(v: str):
    nums = [int(x) for x in re.findall(r"\d+", str(v))]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:3])

releases = json.load(sys.stdin)
if not isinstance(releases, list) or not releases:
    raise SystemExit("No releases found")

best = max(releases, key=lambda r: semver_key(str(r.get("version", "0.0.0"))))
version = best["version"]
execution_id = best["execution_id"]

print(f"Latest Antigravity IDE: {version}  (execution_id={execution_id})")
print()
print("To pin this release for a reproducible build:")
print(f"  ANTIGRAVITY_IDE_VERSION={version} \\")
print(f"  ANTIGRAVITY_IDE_EXECUTION_ID={execution_id} \\")
print("  snapcraft pack")
'
