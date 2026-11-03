#!/bin/bash
# Compiles BridgeCore, BridgeHost (including the new Remote adapter) and a tiny
# runtime check against a real .bundle folder reference. macOS host build only;
# this proves the resource lookup and delegation, not the iOS App build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
export DEVELOPER_DIR
SWIFTC="$(xcrun --find swiftc)"
BUILD="${REMOTE_RESOURCE_BUILD_DIR:-$ROOT/Local/Scratch/ios-bridge-1.0-20261101/remote/resource-check}"
rm -rf "$BUILD"
mkdir -p "$BUILD"
SNAP="$(bash "$(dirname "$0")/snapshot_sources.sh" "$BUILD/sources")"
echo "source snapshot: $SNAP"

MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMMON=(-swift-version 6 -strict-concurrency=complete -g -Onone
        -sdk "$MAC_SDK" -target "$(uname -m)-apple-macosx15.0")
CORE=("$SNAP"/BridgeCore/*.swift)
HOST=("$SNAP"/BridgeHost/*.swift)

echo "== BridgeCore module =="
"$SWIFTC" "${COMMON[@]}" -module-name BridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeCore.swiftmodule" \
  -o "$BUILD/libBridgeCore.dylib" "${CORE[@]}"

echo "== BridgeHost module (imports BridgeCore) =="
"$SWIFTC" "${COMMON[@]}" -module-name BridgeHost \
  -I "$BUILD" -L "$BUILD" -lBridgeCore \
  -emit-library -emit-module \
  -emit-module-path "$BUILD/BridgeHost.swiftmodule" \
  -o "$BUILD/libBridgeHost.dylib" "${HOST[@]}"

echo "== resource check executable =="
"$SWIFTC" "${COMMON[@]}" -module-name RemoteResourceCheck \
  -I "$BUILD" -L "$BUILD" -lBridgeCore -lBridgeHost \
  "$ROOT"/FloeIOSBridge/Tests/RemoteClient/ResourceCheck.swift \
  -o "$BUILD/resource-check" \
  -Xlinker -rpath -Xlinker "$BUILD"

BUNDLE="$BUILD/Test.bundle"
mkdir -p "$BUNDLE/Contents/Resources/BridgeRemote" "$BUNDLE/Contents/Resources/BridgeRPC"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.floeagent.remote-resource-check</string>
<key>CFBundleName</key><string>RemoteResourceCheck</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
cp "$ROOT/FloeIOSBridge/Resources/BridgeRemote/REMOTE.html" "$BUNDLE/Contents/Resources/BridgeRemote/REMOTE.html"
printf '# synthetic skill\n\nsynthetic skill for the resource adapter test\n' > "$BUNDLE/Contents/Resources/BridgeRPC/SKILL.md"

EMPTY="$BUILD/Empty.bundle"
mkdir -p "$EMPTY/Contents/Resources"
cp "$BUNDLE/Contents/Info.plist" "$EMPTY/Contents/Info.plist"

DYLD_LIBRARY_PATH="$BUILD" "$BUILD/resource-check" "$BUNDLE" "$EMPTY"
