#!/bin/bash
# Build the real BridgeCore and BridgeHost/RPC modules on this Mac, then run
# the product-host policy and approval gate checks. No App, Simulator, device,
# XCTest target or signing step is involved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD="${PRODUCT_HOST_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/product-host/build/test}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

COMMON=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -g -Onone
        -sdk "$MAC_SDK" -target "arm64-apple-macosx15.0")

CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeCore" -name '*.swift' | sort)
HOST_RPC_SOURCES=()
while IFS= read -r file; do HOST_RPC_SOURCES+=("$file"); done < <(find "$ROOT/FloeIOSBridge/Sources/BridgeHost/RPC" -name '*.swift' | sort)

echo "== BridgeCore module (full Core + RPC + Runtime + Engine + Media) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -o "$BUILD/libBridgeCore.dylib" \
  "${CORE_SOURCES[@]}" -j 6

echo "== BridgeHost module (canonical RPC host) =="
"$SWIFTC" "${COMMON[@]}" \
  -module-name BridgeHost \
  -I "$BUILD" -L "$BUILD" -lBridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -o "$BUILD/libBridgeHost.dylib" \
  "${HOST_RPC_SOURCES[@]}"

echo "== Product policy + approval gate test executable =="
"$SWIFTC" "${COMMON[@]}" -parse-as-library \
  -module-name ProductHostTests \
  -I "$BUILD" -L "$BUILD" -lBridgeCore -lBridgeHost \
  "$ROOT"/FloeIOSBridge/Sources/BridgeHost/Product/BridgeProductPolicy.swift \
  "$ROOT"/FloeIOSBridge/Sources/BridgeHost/Product/BridgeProductDiagnostics.swift \
  "$ROOT"/FloeIOSBridge/Sources/BridgeHost/Product/BridgeProductStatusLog.swift \
  "$ROOT"/FloeIOSBridge/Sources/BridgeHost/Product/BridgePairingApprovalGate.swift \
  "$ROOT"/FloeIOSBridge/Tests/ProductHost/*.swift \
  -o "$BUILD/product-host-tests" \
  -Xlinker -rpath -Xlinker "$BUILD"

echo "== Run =="
DYLD_LIBRARY_PATH="$BUILD" PRODUCT_HOST_TEST_FILTER="${PRODUCT_HOST_TEST_FILTER:-}" "$BUILD/product-host-tests"
