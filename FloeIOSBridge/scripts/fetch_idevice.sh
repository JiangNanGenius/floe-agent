#!/bin/bash
# Source builds are mandatory: the upstream prebuilt ABI has no cancellation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE="${FLOE_IDEVICE_CACHE:-$HOME/Library/Caches/CodexBuild/FloeIOSBridge/1.0/ddi-native}"
DEST="$CACHE/IDevice.xcframework"
LINK="$PROJECT_DIR/Frameworks/IDevice.xcframework"
# Immutable upstream release input retained for package-policy validation.
VERSION="v0.1.68"
ASSET_SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
LOCK="$PROJECT_DIR/Vendor/idevice.lock.json"
VERIFY="$PROJECT_DIR/Vendor/verify_idevice.py"
/usr/bin/python3 "$VERIFY" --lock "$LOCK" --project "$PROJECT_DIR"
if [ "${1:-}" = --check ]; then
    if [ -d "$DEST" ]; then /usr/bin/python3 "$VERIFY" --lock "$LOCK" --project "$PROJECT_DIR" --verify-output "$DEST"; fi
    exit 0
fi
if [ ! -d "$DEST" ]; then
    bash "$SCRIPT_DIR/build_idevice.sh"
fi
# A stale or modified patched output is an error, never an unchecked fallback.
/usr/bin/python3 "$VERIFY" --lock "$LOCK" --project "$PROJECT_DIR" --verify-output "$DEST"
mkdir -p "$PROJECT_DIR/Frameworks"
if [ -L "$LINK" ]; then
    rm "$LINK"
elif [ -e "$LINK" ]; then
    echo "error: refusing to replace non-symlink $LINK" >&2
    exit 1
fi
ln -s "$DEST" "$LINK"
echo "linked verified patched idevice ABI v1"
