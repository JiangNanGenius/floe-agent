#!/bin/bash
# Prove real Swift 6 cross-module compilation for the shipping iOS target:
# BridgeCore (including Runtime and the new Media muxer) is emitted as its own
# module/object, then BridgeHostMedia is emitted separately while importing it.
# Also emits verified SIL for the host media code. No App build is started.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"
BUILD="${MEDIA_IOS_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/media/build/ios}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeCore" -name '*.swift' | sort)
HOST_SOURCES=()
while IFS= read -r file; do HOST_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeHost/Media" -name '*.swift' | sort)

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors
        -O
        -target "$TARGET" -sdk "$SDK")

echo "== BridgeCore module + Swift object (iOS $TARGET, includes Runtime + Media) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-module -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -emit-object -whole-module-optimization -j 6 \
  -o "$BUILD/BridgeCore.o" \
  "${CORE_SOURCES[@]}"

echo "== BridgeHostMedia module + Swift object importing BridgeCore =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHostMedia \
  -I "$BUILD" \
  -emit-module -emit-module-path "$BUILD/BridgeHostMedia.swiftmodule" \
  -emit-object -whole-module-optimization -j 6 \
  -o "$BUILD/BridgeHostMedia.o" \
  "${HOST_SOURCES[@]}"

echo "== Verified SIL for host media against the real BridgeCore module =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHostMedia \
  -I "$BUILD" \
  -emit-sil -whole-module-optimization -Onone -Xfrontend -sil-verify-all \
  -o "$BUILD/BridgeHostMedia.sil" \
  "${HOST_SOURCES[@]}"

echo "== Artifact facts =="
file "$BUILD/BridgeCore.o" "$BUILD/BridgeHostMedia.o" | tee "$BUILD/objects.txt"
grep -q 'arm64' "$BUILD/objects.txt"
grep -q 'Mach-O 64-bit object' "$BUILD/objects.txt"
test -s "$BUILD/BridgeHostMedia.sil"
otool -l "$BUILD/BridgeCore.o" | grep -A4 'LC_BUILD_VERSION' | head -8 | tee "$BUILD/build-version.txt"
grep -q 'platform 2' "$BUILD/build-version.txt"
grep -q 'minos 26.0' "$BUILD/build-version.txt"
grep -q 'sdk 27.1' "$BUILD/build-version.txt"

nm "$BUILD/BridgeCore.o" > "$BUILD/core-symbols.txt"
nm "$BUILD/BridgeHostMedia.o" > "$BUILD/host-symbols.txt"
strings "$BUILD/BridgeHostMedia.o" > "$BUILD/host-strings.txt"
grep -q 'BridgeScreenFrameRegistry' "$BUILD/core-symbols.txt"
grep -q 'BridgeFMP4Muxer' "$BUILD/core-symbols.txt"
grep -q 'BridgeVideoService' "$BUILD/host-symbols.txt"
grep -q 'BridgeVideoEncoder' "$BUILD/host-symbols.txt"
if grep -qiE 'XCTest|UIKit|XCUI' "$BUILD/host-strings.txt"; then
  echo "host media object must not contain XCTest/UIKit/XCUI references" >&2
  exit 1
fi
echo "symbols: BridgeScreenFrameRegistry + BridgeFMP4Muxer + BridgeVideoService + BridgeVideoEncoder"
echo "no XCTest/UIKit/XCUI references in host media object"
echo "BridgeCore module: $BUILD/BridgeCore.swiftmodule"
echo "BridgeHostMedia module: $BUILD/BridgeHostMedia.swiftmodule"
echo "BridgeHostMedia SIL: $BUILD/BridgeHostMedia.sil"
