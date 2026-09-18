#!/bin/bash
# Local-model lifecycle regression harness (build191 feedback follow-up).
#
# Compiles and runs the REAL sources under FloeAgent/Sources/FloeLocalModels:
#   * LocalInferenceBackgroundCanceller.swift + canceller_lifecycle_probe.swift
#     -> foreground admission, lifecycle transitions, unregister and the
#        register->launch cancellation relay (host fixture, non-UIKit branch).
#   * textual extraction of the MLXTextEngine diagnostic helpers -> fixture
#     checks (source drift fails the build instead of testing a stale copy).
#   * static/order assertions on LocalProviderAdapter.completeMeasured and the
#     canceller source (gate-before-prepare, register-before-task,
#     attach-before-await, no dispatch/timer/signal constructs).
#   * Swift 6 SIL and object compilation of the UIKit branch plus the runtime
#     ordering pattern with the Xcode-beta iPhoneOS SDK (no App build).
#
# This is a host harness, not iOS acceptance: no device/simulator run, no App
# build, no root SwiftPM, no network, no commit.
#
# Usage: bash FloeAgent/scripts/tests/local_model/run_local_model_lifecycle_checks.sh
# Exit 0 = every leg passed.
# Exit 2 = SKIP: the iPhoneOS SDK for the SIL/object leg is unavailable and the
#           remaining legs passed (truthful "not verified here", not a pass).
# Exit 1 = FAIL: an executed leg failed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$REPO/FloeAgent/Sources/FloeLocalModels/MLXTextEngine.swift"
CANCELLER="$REPO/FloeAgent/Sources/FloeLocalModels/LocalInferenceBackgroundCanceller.swift"
RUNTIME="$REPO/FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift"
PROBE="$HERE/canceller_lifecycle_probe.swift"
PATTERN="$HERE/runtime_pattern_probe.swift"
SWIFTC="${SWIFTC:-/usr/bin/xcrun swiftc}"
OUT="${HARNESS_SCRATCH:-${TMPDIR:-/tmp}/floe-local-model-lifecycle}"
mkdir -p "$OUT"

echo "== repo:      $REPO"
echo "== engine:    $ENGINE"
echo "== canceller: $CANCELLER"
echo "== runtime:   $RUNTIME"
echo "== scratch:   $OUT"

assert_exit=0
parse_exit=0
probe_exit=0
fixture_build_exit=0
fixture_run_exit=0
macos_sil_exit=0
ios_sil_exit=0
ios_object_exit=0
ios_state="executed"

echo
echo "== static assertions + helper extraction"
python3 "$HERE/extract_and_assert.py" "$ENGINE" "$OUT" "$CANCELLER" "$RUNTIME"
assert_exit=$?

echo
echo "== swiftc -parse (syntax of the three scoped sources)"
$SWIFTC -parse -swift-version 6 -target arm64-apple-macosx15.4 \
    "$ENGINE" "$CANCELLER" "$RUNTIME"
parse_exit=$?
echo "parse_exit=$parse_exit"

echo
echo "== extracted MLX helper fixtures"
if [ -f "$OUT/helpers_probe.swift" ]; then
    $SWIFTC -swift-version 6 -O "$OUT/helpers_probe.swift" -o "$OUT/helpers_probe" 2>&1 | tail -20
    probe_build_exit=${PIPESTATUS[0]}
    echo "helpers_build_exit=$probe_build_exit"
    if [ "$probe_build_exit" -eq 0 ]; then
        "$OUT/helpers_probe"
        probe_exit=$?
        echo "helpers_run_exit=$probe_exit"
    else
        probe_exit=99
    fi
else
    echo "helpers_probe.swift missing"
    probe_exit=99
fi

echo
echo "== lifecycle fixture against the production canceller"
$SWIFTC -swift-version 6 -O "$CANCELLER" "$PROBE" -o "$OUT/lifecycle_probe" 2>&1 | tail -20
fixture_build_exit=${PIPESTATUS[0]}
echo "lifecycle_build_exit=$fixture_build_exit"
if [ "$fixture_build_exit" -eq 0 ]; then
    "$OUT/lifecycle_probe"
    fixture_run_exit=$?
    echo "lifecycle_run_exit=$fixture_run_exit"
else
    fixture_run_exit=99
fi

echo
echo "== macOS SIL (production canceller + runtime ordering pattern)"
$SWIFTC -wmo -emit-sil -swift-version 6 -parse-as-library \
    "$CANCELLER" "$PATTERN" -o "$OUT/macos-lifecycle.sil" 2>&1 | tail -20
macos_sil_exit=${PIPESTATUS[0]}
echo "macos_sil_exit=$macos_sil_exit"
if [ "$macos_sil_exit" -eq 0 ]; then
    wc -c "$OUT/macos-lifecycle.sil"
fi

echo
echo "== iOS SIL + object (UIKit observer branch, Xcode-beta SDK)"
IOS_SDK="${IOS_SDK:-}"
if [ -z "$IOS_SDK" ]; then
    for dev in "${DEVELOPER_DIR:-}" \
        /Applications/Xcode-beta.app/Contents/Developer \
        /Applications/Xcode.app/Contents/Developer; do
        [ -n "$dev" ] || continue
        [ -d "$dev" ] || continue
        candidate="$(DEVELOPER_DIR="$dev" /usr/bin/xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
        if [ -n "$candidate" ]; then
            IOS_SDK="$candidate"
            break
        fi
    done
fi
if [ -n "$IOS_SDK" ] && [ -d "$IOS_SDK" ]; then
    echo "ios_sdk=$IOS_SDK"
    $SWIFTC -wmo -emit-sil -swift-version 6 -target arm64-apple-ios26.0 -sdk "$IOS_SDK" \
        -parse-as-library "$CANCELLER" "$PATTERN" -o "$OUT/ios-lifecycle.sil" 2>&1 | tail -20
    ios_sil_exit=${PIPESTATUS[0]}
    echo "ios_sil_exit=$ios_sil_exit"
    if [ "$ios_sil_exit" -eq 0 ]; then
        wc -c "$OUT/ios-lifecycle.sil"
        # The UIKit branch must be present in the emitted module, not silently
        # compiled out. `applicationState` only appears through the real probe.
        if grep -q "UIApplication.applicationState" "$OUT/ios-lifecycle.sil"; then
            echo "ios_sil_uikit_branch=present"
        else
            echo "ios_sil_uikit_branch=MISSING"
            ios_sil_exit=1
        fi
    fi

    $SWIFTC -wmo -c -swift-version 6 -target arm64-apple-ios26.0 -sdk "$IOS_SDK" \
        -parse-as-library "$CANCELLER" "$PATTERN" -o "$OUT/ios-lifecycle.o" 2>&1 | tail -20
    ios_object_exit=${PIPESTATUS[0]}
    echo "ios_object_exit=$ios_object_exit"
    if [ "$ios_object_exit" -eq 0 ]; then
        ls -la "$OUT/ios-lifecycle.o"
        # Capture symbols once: grepping a live `nm` pipe trips pipefail via
        # SIGPIPE when grep -q exits early.
        nm "$OUT/ios-lifecycle.o" > "$OUT/ios-lifecycle.symbols" 2>/dev/null || true
        if grep -q "installObserversIfNeeded" "$OUT/ios-lifecycle.symbols"; then
            echo "ios_object_observers=present"
        else
            echo "ios_object_observers=MISSING"
            ios_object_exit=1
        fi
        if grep -q "LocalInferenceCancellationRelay" "$OUT/ios-lifecycle.symbols"; then
            echo "ios_object_relay=present"
        else
            echo "ios_object_relay=MISSING"
            ios_object_exit=1
        fi
    fi
else
    echo "iPhoneOS SDK unavailable via Xcode-beta/Xcode/DEVELOPER_DIR — SIL/object leg SKIPPED"
    ios_state="skipped"
    ios_sil_exit=0
    ios_object_exit=0
fi

echo
failed=0
for pair in \
    "static:$assert_exit" \
    "parse:$parse_exit" \
    "helpers:$probe_exit" \
    "fixture_build:$fixture_build_exit" \
    "fixture_run:$fixture_run_exit" \
    "macos_sil:$macos_sil_exit" \
    "ios_sil:$ios_sil_exit" \
    "ios_object:$ios_object_exit"; do
    name="${pair%%:*}"
    code="${pair##*:}"
    if [ "$code" -ne 0 ]; then
        echo "LEG FAILED: $name exit=$code"
        failed=1
    fi
done

if [ "$failed" -eq 1 ]; then
    echo "RESULT: FAIL (static=$assert_exit parse=$parse_exit helpers=$probe_exit lifecycle_build=$fixture_build_exit lifecycle_run=$fixture_run_exit macos_sil=$macos_sil_exit ios_sil=$ios_sil_exit ios_object=$ios_object_exit)"
    exit 1
fi

if [ "$ios_state" = "skipped" ]; then
    echo "RESULT: SKIP (all executed legs passed; iPhoneOS SIL/object not verified on this machine)"
    exit 2
fi
echo "RESULT: PASS (static + fixture + lifecycle + macOS SIL + iOS SIL/object)"
exit 0
