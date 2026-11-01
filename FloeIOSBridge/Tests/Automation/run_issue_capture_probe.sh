#!/bin/bash
set -euo pipefail

# Native macOS XCTest probe for the actual `XCTestCase.record(_:)` hook used by
# the embedded engine. The fixture records one deliberate issue and checks the
# scoped, content-free counter. XCTest correctly reports that issue as a
# failure; this runner requires the capture marker and exactly one failure.
# No phone, Simulator or App build is involved.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
SCRATCH="${FLOE_BRIDGE_ISSUE_SCRATCH:-$REPO_ROOT/Local/Scratch/ios-bridge-20261031/read-input-control-repair/issue-probe}"
OUTPUT="${FLOE_BRIDGE_ISSUE_OUTPUT:-$REPO_ROOT/Local/Private/ios-bridge-20261031/read-input-control-repair/issue-probe}"
BUNDLE="$SCRATCH/IssueCaptureProbe.xctest"
LOG="$OUTPUT/issue-capture-probe.log"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
XCTEST="$DEVELOPER_DIR/usr/bin/xctest"
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"

mkdir -p "$SCRATCH" "$OUTPUT"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IssueCaptureProbe</string>
<key>CFBundleIdentifier</key><string>org.floeagent.iosbridge.issuecaptureprobe</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST

{
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(uname -a)"
    echo "swift=$(/usr/bin/xcrun --sdk macosx swift --version 2>&1 | tr '\n' ' ')"
    echo "fixture_sha256=$(shasum -a 256 "$SCRIPT_DIR/IssueCaptureProbe.swift" | awk '{print $1}')"
    echo "evidence_sha256=$(shasum -a 256 "$PROJECT_DIR/Sources/BridgeCore/BridgeSDKCallEvidence.swift" | awk '{print $1}')"
} > "$LOG"

/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -emit-library \
    -o "$BUNDLE/Contents/MacOS/IssueCaptureProbe" \
    "$SCRIPT_DIR/IssueCaptureProbe.swift" \
    "$PROJECT_DIR/Sources/BridgeCore/BridgeSDKCallEvidence.swift" \
    -F "$FRAMEWORKS" \
    -framework XCTest \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" 2>&1 | tee -a "$LOG"

set +e
"$XCTEST" "$BUNDLE" >> "$LOG" 2>&1
runner_rc=$?
set -e

marker="FLOE_ISSUE_CAPTURE_OK count=1 classification=returned-with-issue checks_ok=1"
if ! grep -q "$marker" "$LOG"; then
    echo "issue capture probe: marker missing" | tee -a "$LOG"
    exit 1
fi
if ! grep -qi "with 1 failure" "$LOG"; then
    echo "issue capture probe: expected exactly one forwarded XCTest failure" | tee -a "$LOG"
    exit 1
fi
if [ "$runner_rc" -eq 0 ]; then
    echo "issue capture probe: recorded issue did not fail the test" | tee -a "$LOG"
    exit 1
fi
echo "ISSUE-CAPTURE PASS marker=count-1 forwarded-failure=1 exit=$runner_rc" | tee -a "$LOG"
echo "transcript: $LOG"
