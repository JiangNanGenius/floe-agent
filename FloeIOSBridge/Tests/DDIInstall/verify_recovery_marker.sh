#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
OUTPUT="${FLOE_DDI_SWIFT_OUTPUT:-$PROJECT/../Local/Private/ios-bridge-1.0-20261101/ddi/swift-proof}"
mkdir -p "$OUTPUT"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -sdk "$SDK" -target arm64-apple-macosx15.0 -o "$OUTPUT/RecoveryMarkerCheck" "$PROJECT"/Sources/BridgeCore/*.swift "$PROJECT/Tests/DDIInstall/RecoveryMarker/main.swift"
FLOE_DDI_TEST_ROOT="$OUTPUT/recovery-marker-fixture" "$OUTPUT/RecoveryMarkerCheck"
