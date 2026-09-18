#!/bin/bash
# Build191 media focused fixture suites (tracked copy of the media-review
# harness).
#
# What it proves: the current FloeCore, FloeProviders, FloePersistence
# media-job store/migrations and FloeMedia GIF support behave as documented
# (optional canvas/document ownership, atomic idempotent job creation,
# reference-image policy and adapter bodies, GIF disposal/timing/bounds).
#
# How: FloeCore is compiled FRESH from the edited sources into a temporary
# module, so no stale prebuilt FloeCore interface is ever linked. The fixtures
# are then compiled against that module and the prebuilt dependency objects in
# FloeAgent/.build/apple/Products/Debug (FloeModels/Crypto for the provider
# suite, GRDB/Crypto for the persistence suite).
#
# No SwiftPM, no root `swift build`/`test`, no App build, no network and no
# paid provider call. The suites use only in-repo sources and generated
# fixtures; nothing is read from Local/Private.
#
# Run from anywhere:
#   bash FloeAgent/scripts/tests/media_review/run_media_review_tests.sh
#
# Env overrides:
#   SWIFTC                 explicit swiftc (must be compatible with the
#                          prebuilt modules; default: Xcode-beta, then xcrun)
#   MEDIA_REVIEW_BUILD_DIR output directory (default: mktemp)
#
# Exit codes: 0 = all suites passed, 1 = a suite or compile failed,
#             2 = prerequisites unavailable (prebuilt modules/toolchain) -
#                 a SKIP, not a pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLOE_AGENT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ROOT="$(cd "$FLOE_AGENT/.." && pwd)"
TESTS="$SCRIPT_DIR"
APPLE_DEBUG="$FLOE_AGENT/.build/apple/Products/Debug"
GRDB_MAP="$FLOE_AGENT/.build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
BUILD="${MEDIA_REVIEW_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/floe-media-review.XXXXXX")}"

if [ -z "${SWIFTC:-}" ]; then
  XCODE_BETA_SWIFTC="/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
  if [ -x "$XCODE_BETA_SWIFTC" ]; then
    SWIFTC="$XCODE_BETA_SWIFTC"
  else
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
  fi
fi

if [ ! -x "${SWIFTC:-}" ] || [ ! -d "$APPLE_DEBUG" ] || [ ! -f "$GRDB_MAP" ]; then
  echo "SKIP: missing swiftc, prebuilt module dir ($APPLE_DEBUG) or GRDB module map."
  echo "SKIP: build the package once (or restore the cached artifacts) to run these fixture suites."
  exit 2
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
echo "== build dir $BUILD"
echo "== swiftc $SWIFTC ($("$SWIFTC" --version 2>/dev/null | head -2 | tail -1))"

COMMON=(-parse-as-library -swift-version 6)
failures=0
run() { # name binary
  echo "== run $1"
  if ! "$BUILD/$2"; then failures=$((failures + 1)); fi
}

echo "== compile fresh FloeCore (current sources)"
"$SWIFTC" "${COMMON[@]}" -I "$APPLE_DEBUG" -module-name FloeCore \
  -emit-library -emit-module -emit-module-path "$BUILD/FloeCore.swiftmodule" \
  -o "$BUILD/libFloeCore.dylib" \
  "$FLOE_AGENT"/Sources/FloeCore/*.swift > "$BUILD/floecore.compile.log" 2>&1 || {
    echo "COMPILE-FAIL FloeCore"; tail -30 "$BUILD/floecore.compile.log"; exit 1;
  }

echo "== compile providers fixture (fresh FloeCore + current FloeProviders)"
"$SWIFTC" "${COMMON[@]}" -I "$BUILD" -I "$APPLE_DEBUG" \
  "$TESTS/ReviewProviderTests.swift" \
  "$FLOE_AGENT"/Sources/FloeProviders/*.swift \
  "$FLOE_AGENT"/Sources/FloeProviders/SSE/*.swift \
  "$FLOE_AGENT"/Sources/FloeProviders/Wire/*.swift \
  -L "$BUILD" -lFloeCore -Xlinker -rpath -Xlinker "$BUILD" \
  "$APPLE_DEBUG/FloeModels_Module.o" "$APPLE_DEBUG/Crypto_Module.o" \
  -o "$BUILD/review-providers" > "$BUILD/providers.compile.log" 2>&1 || {
    echo "COMPILE-FAIL providers"; tail -30 "$BUILD/providers.compile.log"; failures=$((failures + 1));
  }
[ -x "$BUILD/review-providers" ] && run providers review-providers

echo "== compile ownership fixture (fresh FloeCore + current FloePersistence)"
"$SWIFTC" "${COMMON[@]}" -I "$BUILD" -I "$APPLE_DEBUG" \
  -Xcc -fmodule-map-file="$GRDB_MAP" \
  "$TESTS/ReviewOwnershipTests.swift" "$TESTS/DatabaseManagerShim.swift" \
  "$FLOE_AGENT"/Sources/FloePersistence/MediaJobOwnership.swift \
  "$FLOE_AGENT"/Sources/FloePersistence/MediaGenerationJobStore.swift \
  "$FLOE_AGENT"/Sources/FloePersistence/Migrations/V42MediaJobOwners.swift \
  "$FLOE_AGENT"/Sources/FloePersistence/Migrations/V43MediaJobIdempotency.swift \
  -L "$BUILD" -lFloeCore -Xlinker -rpath -Xlinker "$BUILD" \
  "$APPLE_DEBUG/GRDB_Module.o" "$APPLE_DEBUG/Crypto_Module.o" -lsqlite3 \
  -o "$BUILD/review-ownership" > "$BUILD/ownership.compile.log" 2>&1 || {
    echo "COMPILE-FAIL ownership"; tail -30 "$BUILD/ownership.compile.log"; failures=$((failures + 1));
  }
[ -x "$BUILD/review-ownership" ] && run ownership review-ownership

echo "== compile GIF fixture (current FloeMedia GIF support)"
"$SWIFTC" "${COMMON[@]}" \
  "$TESTS/ReviewGIFTests.swift" \
  "$FLOE_AGENT"/Sources/FloeMedia/MediaGIFSupport.swift \
  -o "$BUILD/review-gif" > "$BUILD/gif.compile.log" 2>&1 || {
    echo "COMPILE-FAIL gif"; tail -30 "$BUILD/gif.compile.log"; failures=$((failures + 1));
  }
[ -x "$BUILD/review-gif" ] && run gif review-gif

echo
if [ "$failures" -eq 0 ]; then
  echo "MEDIA REVIEW SUITES PASSED"
else
  echo "MEDIA REVIEW SUITES FAILED: $failures"
fi
exit "$failures"
