#!/bin/bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "Usage: bash FloeMac/scripts/verify_ota_install.sh <FloeMacOTA Debug DerivedData>" >&2
    exit 2
fi

mac_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cache="$(cd "$1" && pwd -P)"
products="$cache/Build/Products/Debug"
frameworks="$cache/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
installed_framework="$products/Floe Agent.app/Contents/Frameworks/Sparkle.framework"
bridge="$mac_root/../FloeMacBridge"
source="$mac_root/Tests/OTA"
root="$mac_root/../Local/Scratch"
mkdir -p "$root"
evidence="$(mktemp -d "$root/floe-ota-verification.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

[[ -f "$products/libFloeMacBridgeProtocol.a" && -d "$installed_framework" && -d "$frameworks" ]] || {
    echo "Build the Mac OTA Debug application and its pinned Sparkle dependency first." >&2
    exit 2
}

xcrun clang -c -fobjc-arc -target arm64-apple-macos15 -isysroot "$sdk" \
    -F "$frameworks" "$source/FixtureDriver.m" -o "$evidence/FixtureDriver.o" > "$evidence/clang.log" 2>&1
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15 -sdk "$sdk" \
    -F "$frameworks" -I "$products" -import-objc-header "$source/FixtureDriver.h" \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$source/FixtureMain.swift" "$bridge/Sources/FloeMacBridgeApp/BridgeUpdateActivity.swift" \
    "$bridge/Sources/FloeMacBridgeApp/BridgeUpdater.swift" "$evidence/FixtureDriver.o" \
    "$products/libFloeMacBridgeProtocol.a" -framework Sparkle -o "$evidence/OTAFixture" \
    > "$evidence/swift.log" 2>&1

echo "OTA fixture evidence is at $evidence"
python3 "$source/rehearse.py" "$evidence/OTAFixture" "$installed_framework" "$evidence"
