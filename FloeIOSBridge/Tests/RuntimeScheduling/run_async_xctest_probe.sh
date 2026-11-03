#!/bin/bash
set -euo pipefail

# Supplementary XCTest-shape probe. Builds a macOS .xctest containing one
# never-returning `@MainActor async` test method (the BridgeEngineTests shape),
# runs it under the real XCTest runner for a few seconds, samples the JSON the
# test writes, and terminates the runner. It does not load the iOS SDK, DDI or
# the app; device acceptance remains primary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
SCRATCH="${FLOE_BRIDGE_SCHEDULING_SCRATCH:-$REPO_ROOT/Local/Scratch/ios-bridge-20261031/cooperative-repair}"
OUTPUT="${FLOE_BRIDGE_SCHEDULING_OUTPUT:-$REPO_ROOT/Local/Private/ios-bridge-20261031/cooperative-repair/scheduling}"
BUNDLE="$SCRATCH/AsyncDriverProbe.xctest"
REPORT="$OUTPUT/async-xctest-shape-probe.json"
LOG="$OUTPUT/async-xctest-shape-probe.log"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.app/Contents/Developer}"
XCTEST="$DEVELOPER_DIR/usr/bin/xctest"
FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"

mkdir -p "$SCRATCH" "$OUTPUT"
rm -rf "$BUNDLE" "$REPORT"
mkdir -p "$BUNDLE/Contents/MacOS"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AsyncDriverProbe</string>
<key>CFBundleIdentifier</key><string>org.floeagent.iosbridge.schedulingprobe</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST

{
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(uname -a)"
    echo "swift=$(/usr/bin/xcrun --sdk macosx swift --version 2>&1 | tr '\n' ' ')"
} > "$LOG"

/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -emit-library \
    -o "$BUNDLE/Contents/MacOS/AsyncDriverProbe" \
    "$SCRIPT_DIR/AsyncDriverProbe.swift" \
    -F "$FRAMEWORKS" \
    -framework XCTest \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" 2>&1 | tee -a "$LOG"

FLOE_ASYNC_PROBE_OUTPUT="$REPORT" "$XCTEST" "$BUNDLE" > "$LOG.xctest" 2>&1 &
runner_pid=$!
cleanup() {
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 80); do
    if [ -f "$REPORT" ]; then
        break
    fi
    sleep 0.1
done
# Let the driver and host timer run for another two seconds.
sleep 2.0

if [ ! -f "$REPORT" ]; then
    echo "async XCTest shape probe: no report; runner never entered the test" | tee -a "$LOG"
    exit 1
fi

set +e
/usr/bin/python3 - "$REPORT" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    report = json.load(handle)
main_thread = report.get("mainThread") is True
ticks = int(report.get("hostActorTaskTicks", 0))
iterations = int(report.get("driverIterations", 0))
passed = main_thread and ticks > 5 and iterations > 2
report["verdict"] = "cooperative-progress-observed" if passed else "unexpected"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(report, indent=2, sort_keys=True))
sys.exit(0 if passed else 2)
PY
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "async XCTest shape probe: unexpected measurements" | tee -a "$LOG"
    exit "$rc"
fi
echo "async XCTest shape probe: cooperative progress observed" | tee -a "$LOG"
