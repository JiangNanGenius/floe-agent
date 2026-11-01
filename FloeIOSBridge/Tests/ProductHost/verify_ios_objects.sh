#!/bin/bash
# Real Swift 6 object compilation for the product host/UI source on the
# shipping iOS target. BridgeCore is a separate module; BridgeHost imports it
# and includes the real RPC, Remote, Media and Product sources. No full App
# build, archive, signing, Simulator or device action is performed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios26.0"
BUILD="${PRODUCT_HOST_IOS_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/product-host/build/ios-final}"
IDEVICE="${IDEVICE_HEADERS:-$ROOT/FloeIOSBridge/Frameworks/IDevice.xcframework/ios-arm64/Headers}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors
        -target "$TARGET" -sdk "$SDK" -O)

CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeCore" -name '*.swift' | sort)
HOST_SOURCES=()
while IFS= read -r file; do HOST_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeHost" -name '*.swift' | sort)

echo "== BridgeCore module + Swift object (iOS $TARGET) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-module -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -emit-object -whole-module-optimization \
  -o "$BUILD/BridgeCore.o" \
  "${CORE_SOURCES[@]}" -j 6

echo "== BridgeHost module + Swift object importing BridgeCore =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHost \
  -I "$BUILD" -I "$IDEVICE" \
  -import-objc-header "$ROOT/FloeIOSBridge/Sources/BridgeHost/BridgeHost-Bridging-Header.h" \
  -emit-module -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -emit-object -whole-module-optimization \
  -o "$BUILD/BridgeHost.o" \
  "${HOST_SOURCES[@]}"

echo "== Artifact facts =="
python3 "$ROOT/FloeIOSBridge/Tests/ProductHost/verify_product_object.py" "$BUILD/BridgeHost.o"
file "$BUILD/BridgeCore.o" "$BUILD/BridgeHost.o" | tee "$BUILD/objects.txt"
grep -q 'Mach-O 64-bit object arm64' "$BUILD/objects.txt"
nm "$BUILD/BridgeHost.o" > "$BUILD/BridgeHost.symbols.txt"
grep -q 'BridgeProductRunView' "$BUILD/BridgeHost.symbols.txt"
grep -q 'BridgeRPCHostService' "$BUILD/BridgeHost.symbols.txt"
echo "BridgeProductRunView + BridgeRPCHostService symbols present"
if grep -R -n 'import XCTest\|XCUIScreen\|XCTestCase' \
    "$ROOT/FloeIOSBridge/Sources/BridgeHost" \
    "$ROOT/FloeIOSBridge/Sources/BridgeCore"; then
  echo "forbidden XCTest dependency in Host/Core source" >&2
  exit 1
fi
if nm -u "$BUILD/BridgeHost.o" "$BUILD/BridgeCore.o" | grep -q 'XCTest'; then
  echo "forbidden XCTest strong reference in object" >&2
  exit 1
fi
echo "BridgeCore module: $BUILD/BridgeCore.swiftmodule"
echo "BridgeHost module: $BUILD/BridgeHost.swiftmodule"
echo "No XCTest import or strong reference in Host/Core objects"
