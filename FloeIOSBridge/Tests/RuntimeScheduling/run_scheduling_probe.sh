#!/bin/bash
set -euo pipefail

# Bounded scheduling-primitive probe for the BridgeHost / embedded-XCTest
# lifetime design. This compiles a small macOS executable and runs each
# scenario in its own process. It does not load XCTest, a DDI or the app.
#
# Evidence produced here is primitive-level only: real SDK / UI acceptance
# remains a physical-device run by the primary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
SCRATCH="${FLOE_BRIDGE_SCHEDULING_SCRATCH:-$REPO_ROOT/Local/Scratch/ios-bridge-20261031/cooperative-repair}"
OUTPUT="${FLOE_BRIDGE_SCHEDULING_OUTPUT:-$REPO_ROOT/Local/Private/ios-bridge-20261031/cooperative-repair/scheduling}"
BINARY="$SCRATCH/bridge-scheduling-probe"
TRANSCRIPT="$OUTPUT/scheduling-probe.log"

mkdir -p "$SCRATCH" "$OUTPUT"

SWIFT_VERSION_TEXT="$(/usr/bin/xcrun --sdk macosx swift --version 2>&1 | tr '\n' ' ')"
{
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(uname -a)"
    echo "swift=$SWIFT_VERSION_TEXT"
    echo "probe_source_sha256=$(shasum -a 256 "$SCRIPT_DIR/SchedulingProbe.swift" | awk '{print $1}')"
} > "$TRANSCRIPT"

echo "== compiling probe =="
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -O \
    -o "$BINARY" \
    "$SCRIPT_DIR/SchedulingProbe.swift" 2>&1 | tee -a "$TRANSCRIPT"

SCENARIOS=(
    gcd-nested-runloop
    runloop-nested-runloop
    runloop-isolated-nested-runloop
    runloop-cooperative
)

overall=0
for scenario in "${SCENARIOS[@]}"; do
    report="$OUTPUT/$scenario.json"
    echo "" | tee -a "$TRANSCRIPT"
    echo "== $scenario ==" | tee -a "$TRANSCRIPT"
    set +e
    SWIFT_VERSION_TEXT="$SWIFT_VERSION_TEXT" "$BINARY" "$scenario" "$report" 2>&1 | tee -a "$TRANSCRIPT"
    rc=${PIPESTATUS[0]}
    set -e
    echo "exit=$rc" | tee -a "$TRANSCRIPT"
    if [ "$rc" -ne 0 ]; then
        overall=1
    fi
done

echo "" | tee -a "$TRANSCRIPT"
if [ "$overall" -eq 0 ]; then
    echo "scheduling probe: all scenarios produced the expected primitive behavior" | tee -a "$TRANSCRIPT"
else
    echo "scheduling probe: at least one scenario was unexpected" | tee -a "$TRANSCRIPT"
fi
echo "transcript: $TRANSCRIPT"
exit "$overall"
