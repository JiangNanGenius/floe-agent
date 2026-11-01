#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
MAC_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SCRATCH="${FLOE_BRIDGE_SCRATCH:-$PROJECT_DIR/../Local/Scratch/ios-bridge-20261031/recovery}"
OUTPUT="${FLOE_BRIDGE_CHECK_OUTPUT:-$PROJECT_DIR/../Local/Artifacts/ios-bridge-20261031/recovery}"
mkdir -p "$SCRATCH" "$OUTPUT"
BINARY="$SCRATCH/bridge-core-self-check"
LOG="$OUTPUT/core-checks.log"

/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -sdk "$MAC_SDK" \
    -target "$(uname -m)-apple-macosx15.0" \
    -O \
    -o "$BINARY" \
    "$PROJECT_DIR"/Sources/BridgeCore/*.swift \
    "$PROJECT_DIR/Tests/SelfCheck/main.swift" 2>&1 | tee "$LOG"

"$BINARY" 2>&1 | tee -a "$LOG"
echo "core checks: $LOG"
