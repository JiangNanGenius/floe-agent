#!/bin/bash
# Build the real BridgeCore module (including Engine helpers), then run the
# plain Swift engine-RPC test harness. Nothing is written into the source tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="${ENGINE_RPC_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/engine/build/host}"
CORE_SNAPSHOT="$BUILD/core-snapshot"

rm -rf "$BUILD"
mkdir -p "$BUILD"
mkdir -p "$CORE_SNAPSHOT"

# BridgeCore is primary-owned and may be edited by the integration lane. Compile
# an immutable snapshot and prove it matched the live bytes at copy time.
snapshot_core() {
  rm -rf "$CORE_SNAPSHOT"
  mkdir -p "$CORE_SNAPSHOT"
  cp -R "$ROOT/FloeIOSBridge/Sources/BridgeCore/." "$CORE_SNAPSHOT/"
  (cd "$ROOT/FloeIOSBridge/Sources/BridgeCore" && \
    find . -name '*.swift' -print0 | sort -z | xargs -0 shasum -a 256 | sed 's#  \./#  #') > "$BUILD/core-live.sha256"
  (cd "$CORE_SNAPSHOT" && \
    find . -name '*.swift' -print0 | sort -z | xargs -0 shasum -a 256 | sed 's#  \./#  #') > "$BUILD/core-snapshot.sha256"
  diff -q "$BUILD/core-live.sha256" "$BUILD/core-snapshot.sha256" >/dev/null
}
for attempt in 1 2 3 4 5; do
  if snapshot_core; then break; fi
  if [ "$attempt" = 5 ]; then
    echo "BridgeCore kept changing during snapshot; refusing to compile mixed bytes" >&2
    exit 1
  fi
  sleep 2
done
echo "BridgeCore snapshot files: $(wc -l < "$BUILD/core-snapshot.sha256")"

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -g -Onone
        -sdk "$MAC_SDK" -target "arm64-apple-macosx15.0")

echo "== BridgeCore module + library (real Core + Engine) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -o "$BUILD/libBridgeCore.dylib" \
  "$CORE_SNAPSHOT"/*.swift \
  "$CORE_SNAPSHOT"/RPC/*.swift \
  "$CORE_SNAPSHOT"/Runtime/*.swift \
  "$CORE_SNAPSHOT"/Engine/*.swift \
  -j 6

echo "== Engine RPC test executable =="
# The issue-sanitizer check uses the real product sanitizer, which is compiled
# against the macOS XCTest overlay. This is a host-only helper: no iOS/device
# XCTest session is started.
MAC_XCTEST_FW="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
MAC_XCTEST_OVERLAY="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
"$SWIFTC" "${COMMON[@]}" -parse-as-library \
  -module-name EngineRPCTests \
  -I "$BUILD" -L "$BUILD" -lBridgeCore \
  -I "$MAC_XCTEST_OVERLAY" -F "$MAC_XCTEST_FW" \
  -L "$MAC_XCTEST_OVERLAY" -lXCTestSwiftSupport -framework XCTest \
  "$ROOT"/FloeIOSBridge/Tests/EngineRPC/*.swift \
  "$ROOT"/FloeIOSBridge/Sources/BridgeTests/BridgeEngineIssueSanitizer.swift \
  -o "$BUILD/engine-rpc-tests" \
  -Xlinker -rpath -Xlinker "$BUILD" \
  -Xlinker -rpath -Xlinker "$MAC_XCTEST_OVERLAY" \
  -Xlinker -rpath -Xlinker "$MAC_XCTEST_FW"

echo "== Run =="
DYLD_LIBRARY_PATH="$MAC_XCTEST_OVERLAY:$BUILD" \
DYLD_FRAMEWORK_PATH="$MAC_XCTEST_FW" \
  "$BUILD/engine-rpc-tests"
