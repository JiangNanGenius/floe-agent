#!/bin/bash
# Verify real Swift 6 arm64 iOS 26 object compilation for the shipping test
# bundle: BridgeCore is its own module/object; BridgeTests imports that module
# and is emitted separately; the Objective-C private shims are real objects too.
# No full App build, signing, install, Simulator or device run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
CLANG="$(xcrun --find clang)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"
FRAMEWORKS="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/Library/Frameworks"
OVERLAY="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/usr/lib"
BUILD="${ENGINE_RPC_IOS_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/engine/build/ios}"
CORE_SNAPSHOT="$BUILD/core-snapshot"

rm -rf "$BUILD"
mkdir -p "$BUILD"
mkdir -p "$CORE_SNAPSHOT"

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

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors
        -target "$TARGET" -sdk "$SDK" -I "$OVERLAY")

echo "== BridgeCore module + Swift object =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore -parse-as-library \
  -emit-module -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -emit-object -whole-module-optimization -j 6 \
  -o "$BUILD/BridgeCore.o" \
  "$CORE_SNAPSHOT"/*.swift \
  "$CORE_SNAPSHOT"/RPC/*.swift \
  "$CORE_SNAPSHOT"/Runtime/*.swift \
  "$CORE_SNAPSHOT"/Engine/*.swift

echo "== BridgeTests module + Swift object importing BridgeCore =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeTests -parse-as-library \
  -I "$BUILD" -F "$FRAMEWORKS" -I "$ROOT/FloeIOSBridge/Sources/BridgeTests" \
  -import-objc-header "$ROOT/FloeIOSBridge/Sources/BridgeTests/BridgeTests-Bridging-Header.h" \
  -emit-module -emit-module-path "$BUILD/BridgeTests.swiftmodule" \
  -emit-object -whole-module-optimization -j 6 \
  -o "$BUILD/BridgeTests.o" \
  "$ROOT"/FloeIOSBridge/Sources/BridgeTests/*.swift

echo "== BridgeCore SIL (Swift 6) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore -parse-as-library \
  -emit-sil -whole-module-optimization -o "$BUILD/BridgeCore.sil" \
  "$CORE_SNAPSHOT"/*.swift \
  "$CORE_SNAPSHOT"/RPC/*.swift \
  "$CORE_SNAPSHOT"/Runtime/*.swift \
  "$CORE_SNAPSHOT"/Engine/*.swift
grep -q 'sil_stage' "$BUILD/BridgeCore.sil" || {
  echo "BridgeCore.sil is not SIL" >&2
  exit 1
}

echo "== BridgeTests SIL (Swift 6, imports BridgeCore) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeTests -parse-as-library \
  -I "$BUILD" -F "$FRAMEWORKS" -I "$ROOT/FloeIOSBridge/Sources/BridgeTests" \
  -import-objc-header "$ROOT/FloeIOSBridge/Sources/BridgeTests/BridgeTests-Bridging-Header.h" \
  -emit-sil -whole-module-optimization -o "$BUILD/BridgeTests.sil" \
  "$ROOT"/FloeIOSBridge/Sources/BridgeTests/*.swift
grep -q 'sil_stage' "$BUILD/BridgeTests.sil" || {
  echo "BridgeTests.sil is not SIL" >&2
  exit 1
}

echo "== Objective-C private shims + exception catcher objects =="
for source in BridgeEnginePrivateShims ExceptionCatcher; do
  "$CLANG" -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
    -Wall -Wextra -Werror -Wno-unused-parameter \
    -F "$FRAMEWORKS" -I "$ROOT/FloeIOSBridge/Sources/BridgeTests" \
    -c "$ROOT/FloeIOSBridge/Sources/BridgeTests/$source.m" \
    -o "$BUILD/$source.o"
done

echo "== Artifact facts =="
file "$BUILD/BridgeCore.o" "$BUILD/BridgeTests.o" \
     "$BUILD/BridgeEnginePrivateShims.o" "$BUILD/ExceptionCatcher.o" | tee "$BUILD/objects.txt"
for object in BridgeCore BridgeTests BridgeEnginePrivateShims ExceptionCatcher; do
  file "$BUILD/$object.o" | grep -q 'Mach-O 64-bit object arm64' || {
    echo "not an arm64 Mach-O object: $object.o" >&2
    exit 1
  }
done
vtool -show-build "$BUILD/BridgeCore.o" | grep -q 'platform IOS' || {
  echo "BridgeCore.o is not an iOS platform object" >&2
  exit 1
}
vtool -show-build "$BUILD/BridgeTests.o" | grep -q 'platform IOS' || {
  echo "BridgeTests.o is not an iOS platform object" >&2
  exit 1
}
nm "$BUILD/BridgeCore.o" > "$BUILD/BridgeCore.symbols"
nm "$BUILD/BridgeTests.o" > "$BUILD/BridgeTests.symbols"
nm -gU "$BUILD/BridgeEnginePrivateShims.o" > "$BUILD/BridgeEnginePrivateShims.symbols"
grep -q 'BridgeEngineRPCRuntime' "$BUILD/BridgeTests.symbols" || {
  echo "BridgeTests.o does not contain the RPC runtime symbol" >&2
  exit 1
}
grep -q 'BridgeScreenFrameProvider' "$BUILD/BridgeTests.symbols" || true
grep -q 'BRTypeTextRedacted' "$BUILD/BridgeEnginePrivateShims.symbols" || {
  echo "private shims object lacks BRTypeTextRedacted" >&2
  exit 1
}
grep -q 'BRCurrentForegroundBundleID' "$BUILD/BridgeEnginePrivateShims.symbols" || {
  echo "private shims object lacks BRCurrentForegroundBundleID" >&2
  exit 1
}
nm -u "$BUILD/BridgeCore.o" > "$BUILD/BridgeCore.undefined"
if grep -q 'XCTest\|XCUI' "$BUILD/BridgeCore.undefined"; then
  echo "BridgeCore unexpectedly references XCTest/XCUI" >&2
  exit 1
fi
ls -l "$BUILD/BridgeCore.sil" "$BUILD/BridgeTests.sil" | tee "$BUILD/sil.txt"
echo "BridgeCore module: $BUILD/BridgeCore.swiftmodule"
echo "BridgeTests module: $BUILD/BridgeTests.swiftmodule"
echo "IOS-OBJECTS PASS arm64=4 platform=iOS core-xctest-refs=0"
