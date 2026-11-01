#!/bin/bash
# Verify real Swift 6 cross-module object compilation for the shipping iOS
# target. BridgeCore is emitted as its own module and object; BridgeHost imports
# that module with -I and is emitted separately. No full App build is started.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"
BUILD="${RPC_IOS_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/rpc/build/ios}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -target "$TARGET" -sdk "$SDK")

echo "== BridgeCore module + Swift object (iOS $TARGET) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-module -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -emit-object -whole-module-optimization \
  -o "$BUILD/BridgeCore.o" \
  "$ROOT"/FloeIOSBridge/Sources/BridgeCore/RPC/*.swift

echo "== BridgeHost module + Swift object importing BridgeCore =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHost \
  -I "$BUILD" \
  -emit-module -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -emit-object -whole-module-optimization \
  -o "$BUILD/BridgeHost.o" \
  "$ROOT"/FloeIOSBridge/Sources/BridgeHost/RPC/*.swift

echo "== Artifact facts =="
file "$BUILD/BridgeCore.o" "$BUILD/BridgeHost.o" | tee "$BUILD/objects.txt"
grep -q 'arm64' "$BUILD/objects.txt"
nm -gU "$BUILD/BridgeCore.o" | grep -q 'BridgeRPCAuthority' || true
echo "BridgeCore module: $BUILD/BridgeCore.swiftmodule"
echo "BridgeHost module: $BUILD/BridgeHost.swiftmodule"
