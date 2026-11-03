#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
SCRATCH="${FLOE_BRIDGE_LAN_SCRATCH:-$REPO_DIR/Local/Scratch/ios-bridge-20261031/lan-control-source}"
OUTPUT="${FLOE_BRIDGE_LAN_OUTPUT:-$REPO_DIR/Local/Private/ios-bridge-20261031/lan-control-source}"
mkdir -p "$SCRATCH/build" "$OUTPUT/sil"

CORE_SOURCES=("$PROJECT_DIR"/Sources/BridgeCore/*.swift)

echo "== existing core checks =="
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -O \
    -o "$SCRATCH/build/bridge-core-self-check" \
    "${CORE_SOURCES[@]}" \
    "$PROJECT_DIR/Tests/SelfCheck/main.swift" 2>&1 | tee "$OUTPUT/core-build.log"
"$SCRATCH/build/bridge-core-self-check" 2>&1 | tee "$OUTPUT/core-checks.log"

echo "== encrypted LAN control loopback checks =="
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -O \
    -o "$SCRATCH/build/lan-control-checks" \
    "${CORE_SOURCES[@]}" \
    "$PROJECT_DIR/Tests/LANControl/main.swift" 2>&1 | tee "$OUTPUT/lan-control-build.log"
"$SCRATCH/build/lan-control-checks" 2>&1 | tee "$OUTPUT/lan-control-checks.log"

echo "== SIL and object compilation for the shared core =="
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -parse-as-library \
    -module-name BridgeCore \
    -whole-module-optimization \
    -emit-silgen \
    "${CORE_SOURCES[@]}" \
    -o "$OUTPUT/sil/BridgeCore.silgen"
mkdir -p "$OUTPUT/objects"
# Remove each target first: swiftc can reuse an existing object whose mtime is
# newer than the unchanged Swift sources, even when a rebuilt imported module
# changed the object. Forced writes keep the evidence tied to this run.
rm -f "$OUTPUT/objects/BridgeCore-macos-arm64.o"
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -parse-as-library \
    -module-name BridgeCore \
    -whole-module-optimization \
    -c \
    "${CORE_SOURCES[@]}" \
    -o "$OUTPUT/objects/BridgeCore-macos-arm64.o"

XCODE27="/Applications/Xcode-27.1.app/Contents/Developer"
if [[ -d "$XCODE27" ]]; then
    echo "== iOS arm64 object and host/test typecheck =="
    IOS_SDK="$(DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos --show-sdk-path)"
    rm -f "$OUTPUT/objects/BridgeCore-ios-arm64.o"
    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -application-extension \
        -parse-as-library \
        -module-name BridgeCore \
        -whole-module-optimization \
        -c \
        "${CORE_SOURCES[@]}" \
        -o "$OUTPUT/objects/BridgeCore-ios-arm64.o" 2>&1 | tee "$OUTPUT/ios-object.log"

    MODULE_DIR="$SCRATCH/ios-module"
    mkdir -p "$MODULE_DIR"
    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -application-extension \
        -module-name BridgeCore \
        -emit-module \
        -emit-module-path "$MODULE_DIR/BridgeCore.swiftmodule" \
        "${CORE_SOURCES[@]}" 2>&1 | tee "$OUTPUT/ios-module.log"

    IDEVPATH="$PROJECT_DIR/Frameworks/IDevice.xcframework/ios-arm64/Headers"
    rm -f "$OUTPUT/objects/BridgeHost-ios-arm64.o"
    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -typecheck \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -I "$MODULE_DIR" \
        -Xcc -fmodule-map-file="$IDEVPATH/module.modulemap" \
        -Xcc -I"$IDEVPATH" \
        -import-objc-header "$PROJECT_DIR/Sources/BridgeHost/BridgeHost-Bridging-Header.h" \
        "$PROJECT_DIR"/Sources/BridgeHost/*.swift 2>&1 | tee "$OUTPUT/host-typecheck.log"

    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -I "$MODULE_DIR" \
        -Xcc -fmodule-map-file="$IDEVPATH/module.modulemap" \
        -Xcc -I"$IDEVPATH" \
        -import-objc-header "$PROJECT_DIR/Sources/BridgeHost/BridgeHost-Bridging-Header.h" \
        -parse-as-library \
        -module-name BridgeHost \
        -whole-module-optimization \
        -c \
        "$PROJECT_DIR"/Sources/BridgeHost/*.swift \
        -o "$OUTPUT/objects/BridgeHost-ios-arm64.o" 2>&1 | tee "$OUTPUT/host-object.log"

    DEV_PLATFORM="/Applications/Xcode-27.1.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer"
    rm -f "$OUTPUT/objects/BridgeTests-ios-arm64.o"
    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -typecheck \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -I "$MODULE_DIR" \
        -I "$DEV_PLATFORM/usr/lib" \
        -F "$DEV_PLATFORM/Library/Frameworks" \
        -F "$DEV_PLATFORM/Library/PrivateFrameworks" \
        -import-objc-header "$PROJECT_DIR/Sources/BridgeTests/BridgeTests-Bridging-Header.h" \
        "$PROJECT_DIR"/Sources/BridgeTests/*.swift 2>&1 | tee "$OUTPUT/bridgetests-typecheck.log"

    # Swift 6 concurrency transfer diagnostics require real SIL/object
    # compilation, not only a typecheck. This emits the XCTest engine object
    # against the real iPhoneOS XCTest slice.
    DEVELOPER_DIR="$XCODE27" /usr/bin/xcrun --sdk iphoneos swiftc \
        -swift-version 6 \
        -target arm64-apple-ios26.0 \
        -sdk "$IOS_SDK" \
        -I "$MODULE_DIR" \
        -I "$DEV_PLATFORM/usr/lib" \
        -F "$DEV_PLATFORM/Library/Frameworks" \
        -F "$DEV_PLATFORM/Library/PrivateFrameworks" \
        -import-objc-header "$PROJECT_DIR/Sources/BridgeTests/BridgeTests-Bridging-Header.h" \
        -parse-as-library \
        -module-name BridgeTests \
        -whole-module-optimization \
        -c \
        "$PROJECT_DIR"/Sources/BridgeTests/*.swift \
        -o "$OUTPUT/objects/BridgeTests-ios-arm64.o" 2>&1 | tee "$OUTPUT/bridgetests-object.log"
else
    echo "Xcode 27.1 not present; skipped iOS object/typecheck" | tee "$OUTPUT/ios-skipped.log"
fi

echo "== normal Stop disarm wiring =="
STOP_LOG="$OUTPUT/stop-disarm-check.log"
: > "$STOP_LOG"
stop_ok=1
if grep -q 'model?.disarmLANControlForStop()' "$PROJECT_DIR/Sources/BridgeHost/BridgeCoordinator.swift"; then
    echo "PASS coordinator stop calls disarmLANControlForStop" | tee -a "$STOP_LOG"
else
    echo "FAIL coordinator stop does not call disarmLANControlForStop" | tee -a "$STOP_LOG"
    stop_ok=0
fi
if grep -q 'BridgeLANControlArmPolicy.shouldDisarm' "$PROJECT_DIR/Sources/BridgeHost/BridgeAppModel.swift"; then
    echo "PASS stop disarm uses the shared arm policy" | tee -a "$STOP_LOG"
else
    echo "FAIL stop disarm does not use the shared arm policy" | tee -a "$STOP_LOG"
    stop_ok=0
fi
if grep -q 'controlEnabled = false' "$PROJECT_DIR/Sources/BridgeHost/BridgeAppModel.swift"; then
    echo "PASS stop disarm clears the owner preference" | tee -a "$STOP_LOG"
else
    echo "FAIL stop disarm does not clear the owner preference" | tee -a "$STOP_LOG"
    stop_ok=0
fi
if grep -q 'model?.fenceLANControl(reason: "stop")' "$PROJECT_DIR/Sources/BridgeHost/BridgeCoordinator.swift"; then
    echo "FAIL coordinator still uses the fence-only stop path" | tee -a "$STOP_LOG"
    stop_ok=0
else
    echo "PASS coordinator no longer uses the fence-only stop path" | tee -a "$STOP_LOG"
fi
[[ "$stop_ok" == "1" ]] || exit 1

echo "== reference controller argument and private-file checks =="
python3 "$PROJECT_DIR/Tests/LANControl/controller_checks.py" \
    --server "$SCRATCH/build/lan-control-checks" \
    --controller "$PROJECT_DIR/scripts/LANControl/bridge_control.py" \
    2>&1 | tee "$OUTPUT/controller-checks.log"

echo "core checks: $OUTPUT/core-checks.log"
echo "LAN control checks: $OUTPUT/lan-control-checks.log"
echo "controller checks: $OUTPUT/controller-checks.log"
