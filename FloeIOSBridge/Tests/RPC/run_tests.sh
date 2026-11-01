#!/bin/bash
# Build the RPC Core and Host as separate Swift modules, then run the plain
# Swift test harness. Nothing is written into the source tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="${RPC_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/rpc/build/test}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# Keep the host test target explicit when the Mac OS is newer than this SDK.
# This does not change the iOS application's deployment target.
COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -g -Onone
        -sdk "$MAC_SDK" -target "$(uname -m)-apple-macosx15.0")
CORE_SOURCES=("$ROOT"/FloeIOSBridge/Sources/BridgeCore/RPC/*.swift)
HOST_SOURCES=("$ROOT"/FloeIOSBridge/Sources/BridgeHost/RPC/*.swift)
TEST_SOURCES=("$ROOT"/FloeIOSBridge/Tests/RPC/*.swift)

echo "== BridgeCore module + library =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -o "$BUILD/libBridgeCore.dylib" \
  "${CORE_SOURCES[@]}"

echo "== BridgeHost module (imports BridgeCore) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHost \
  -I "$BUILD" -L "$BUILD" -lBridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -o "$BUILD/libBridgeHost.dylib" \
  "${HOST_SOURCES[@]}"

echo "== Test executable (imports both modules) =="
"$SWIFTC" "${COMMON[@]}" -parse-as-library \
  -module-name RPCTests \
  -I "$BUILD" -L "$BUILD" -lBridgeCore -lBridgeHost \
  "${TEST_SOURCES[@]}" \
  -o "$BUILD/rpc-tests" \
  -Xlinker -rpath -Xlinker "$BUILD"

echo "== Resources =="
for resource in SKILL.md NOTICE.md UPSTREAM_ADAPTATIONS.md LICENSE-iCTRL-Apache-2.0.txt; do
  test -s "$ROOT/FloeIOSBridge/Resources/BridgeRPC/$resource"
  echo "present Resources/BridgeRPC/$resource"
done

echo "== Contract checks =="
for file in BridgeRPCHTTP.swift BridgeRPCNetworkServer.swift BridgeRPCKeychainStore.swift BridgeRPCHostService.swift; do
  grep -q '^import BridgeCore$' "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC/$file"
  echo "BridgeHost/RPC/$file imports BridgeCore"
done
grep -q '_floe-ios-bridge._tcp.' "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC/BridgeRPCNetworkServer.swift"
grep -q 'Floe iOS Bridge' "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC/BridgeRPCNetworkServer.swift"
grep -q 'includesPeerToPeer = false' "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC/BridgeRPCNetworkServer.swift"
echo "Bonjour type/name/peer-to-peer policy present"

echo "== Run =="
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/rpc-tests"
