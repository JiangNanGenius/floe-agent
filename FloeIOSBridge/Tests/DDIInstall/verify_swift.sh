#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
CACHE="${FLOE_IDEVICE_CACHE:-$HOME/Library/Caches/CodexBuild/FloeIOSBridge/1.0/ddi-native}"
OUTPUT="${FLOE_DDI_SWIFT_OUTPUT:-$PROJECT/../Local/Private/ios-bridge-1.0-20261101/ddi/swift-proof}"
mkdir -p "$OUTPUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ARGS=(-O -strict-concurrency=complete -swift-version 6 -sdk "$SDK" -target arm64-apple-ios26.0 -parse-as-library -whole-module-optimization)
xcrun --sdk iphoneos swiftc "${ARGS[@]}" -module-name BridgeCore -emit-module -emit-module-path "$OUTPUT/BridgeCore.swiftmodule" -emit-object -o "$OUTPUT/BridgeCore.o" "$PROJECT"/Sources/BridgeCore/*.swift
xcrun --sdk iphoneos swiftc "${ARGS[@]}" -module-name DDINativeAdapterProof -I "$OUTPUT" -I "$CACHE/IDevice.xcframework/ios-arm64/Headers" -emit-object -o "$OUTPUT/DDINativeAdapterProof.o" \
    "$PROJECT/Tests/DDIInstall/CompileHostDeclarations.swift" \
    "$PROJECT/Sources/BridgeHost/BridgeDDIManager.swift" \
    "$PROJECT/Sources/BridgeHost/BridgeDDIRemover.swift" \
    "$PROJECT/Sources/BridgeHost/BridgeDDIStageProbeWorker.swift"
file "$OUTPUT/BridgeCore.o" "$OUTPUT/DDINativeAdapterProof.o"
