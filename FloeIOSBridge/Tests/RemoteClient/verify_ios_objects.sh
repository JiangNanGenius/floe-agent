#!/bin/bash
# Real Swift 6 arm64 iOS 26 object compilation for the remote resource
# adapter, with BridgeCore as a separate imported module. This is not a full
# App build and does not claim simulator/device acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"
BUILD="${REMOTE_IOS_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/remote/ios-objects}"
rm -rf "$BUILD"
mkdir -p "$BUILD"
SNAP="$(bash "$(dirname "$0")/snapshot_sources.sh" "$BUILD/sources")"
echo "source snapshot: $SNAP"

COMMON=(-swift-version 6 -strict-concurrency=complete -target "$TARGET" -sdk "$SDK")

echo "== BridgeCore module + object =="
"$SWIFTC" "${COMMON[@]}" -module-name BridgeCore \
  -emit-module -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -emit-object -whole-module-optimization -o "$BUILD/BridgeCore.o" \
  "$SNAP"/BridgeCore/*.swift

echo "== BridgeHost module + object importing BridgeCore =="
"$SWIFTC" "${COMMON[@]}" -module-name BridgeHost -I "$BUILD" \
  -emit-module -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -emit-object -whole-module-optimization -o "$BUILD/BridgeHost.o" \
  "$SNAP"/BridgeHost/*.swift

echo "== object facts =="
file "$BUILD/BridgeCore.o" "$BUILD/BridgeHost.o" | tee "$BUILD/objects.txt"
grep -q 'arm64' "$BUILD/objects.txt"
nm -gU "$BUILD/BridgeHost.o" | xcrun swift-demangle > "$BUILD/symbols.txt"
if [ "$(grep -c "BridgeRemoteResources" "$BUILD/symbols.txt")" -gt 0 ]; then
  echo "BridgeRemoteResources symbol present"
else
  echo "BridgeRemoteResources symbol missing" >&2
  exit 1
fi
echo "BridgeCore module: $BUILD/BridgeCore.swiftmodule"
echo "BridgeHost module: $BUILD/BridgeHost.swiftmodule"
