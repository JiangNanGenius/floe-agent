#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Focused source checks for the Linux graphics intake.
#
#   bash FloeAgent/Qualification/Graphics/run_source_checks.sh [--mesa-tree DIR]
#
# Compiles the real FloeVirtualGPU budget/ledger sources and runs the
# assertion-free and assertion-preserving contracts. Then builds a temporary
# SwiftPM harness for the FloeLinuxGPU capability types and runs its tests.
# No renderer, GPU, VM, Simulator, App build or device is used. Nothing is
# written inside the repository.
set -euo pipefail

TREE_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mesa-tree)
            [ "$#" -ge 2 ] || { echo "--mesa-tree requires a directory" >&2; exit 2; }
            TREE_ARGS=(--tree "$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

REPO="$(cd -- "$(dirname -- "$0")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
GRAPHICS="$REPO/FloeAgent/LinuxGuest/image/graphics"
FVGPU="$REPO/FloeAgent/ThirdParty/FloeVirtualGPU"
HEADERS="$REPO/FloeAgent/Vendor/FloeGPU/FloeGPU.xcframework/macos-arm64/Headers"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/floe-graphics-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CC=(/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter
    -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE
    -I "$FVGPU/include" -I "$FVGPU/src" -I "$HEADERS")

echo "== source selection and patch digests"
/usr/bin/python3 "$REPO/FloeAgent/scripts/graphics/verify_graphics_sources.py" ${TREE_ARGS[@]+"${TREE_ARGS[@]}"}

echo "== acceleration source contracts"
/usr/bin/python3 "$REPO/FloeAgent/Qualification/Graphics/check_acceleration_sources.py"

echo "== ABI4 layout (unchanged v1-v3 prefix, exact video tail)"
"${CC[@]}" -I "$REPO/FloeAgent/ThirdParty/ARM64EMU/include" \
    "$REPO/FloeAgent/Qualification/Graphics/ABI4LayoutTests.c" -o "$WORK/ABI4LayoutTests"
"$WORK/ABI4LayoutTests"

echo "== FloeVirtualGPU budget/ledger (NDEBUG production path)"
"${CC[@]}" -DNDEBUG \
    "$REPO/FloeAgent/Qualification/Graphics/FVGpuBudgetTests.c" \
    "$FVGPU/src/fvgpu_budget.c" "$FVGPU/src/fvgpu_ledger.c" "$FVGPU/src/fvgpu_trace.c" \
    -o "$WORK/FVGpuBudgetTests"
"$WORK/FVGpuBudgetTests"

echo "== FloeVirtualGPU preserved assertion + fault trace"
"${CC[@]}" \
    "$REPO/FloeAgent/Qualification/Graphics/FVGpuBudgetTests.c" \
    "$FVGPU/src/fvgpu_budget.c" "$FVGPU/src/fvgpu_ledger.c" "$FVGPU/src/fvgpu_trace.c" \
    -o "$WORK/FVGpuBudgetTests-assert"
"$WORK/FVGpuBudgetTests-assert" normal
set +e
{ FLOE_GPU_TRACE=1 "$WORK/FVGpuBudgetTests-assert" fault >"$WORK/assert-fault.log" 2>&1; } 2>/dev/null
FAULT_STATUS=$?
set -e
if [ "$FAULT_STATUS" -eq 0 ] || ! grep -q "ledger-fault what=counter-underflow" "$WORK/assert-fault.log"; then
    echo "FAIL: assertion build did not abort with the preserved ledger invariant trace" >&2
    exit 1
fi
echo "assertion build fault exit=$FAULT_STATUS (expected non-zero); trace preserved"

echo "== FloeLinuxGPU capability tests (temporary SwiftPM harness)"
mkdir -p "$WORK/swift/Sources/FloeLinuxGPU" "$WORK/swift/Tests/FloeLinuxGPUTests"
cp "$REPO"/FloeAgent/Sources/FloeLinuxGPU/*.swift "$WORK/swift/Sources/FloeLinuxGPU/"
cp "$REPO"/FloeAgent/Tests/FloeLinuxGPUTests/*.swift "$WORK/swift/Tests/FloeLinuxGPUTests/"
cat >"$WORK/swift/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FloeLinuxGPUSourceChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FloeLinuxGPU", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FloeLinuxGPUTests", dependencies: ["FloeLinuxGPU"],
                    swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
EOF
( cd "$WORK/swift" && /usr/bin/xcrun swift test -c debug --disable-sandbox )

echo "GRAPHICS_SOURCE_CHECKS_OK"
