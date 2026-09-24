#!/usr/bin/env bash
# Read-only audit for the Floe-vendored MLXSwiftLM package.
#
# Verifies:
#   1. the pinned SwiftPM checkout is at the recorded upstream revision;
#   2. the vendored patched files and the patch itself match their recorded
#      SHA-256 digests;
#   3. the patch series applies to a pristine copy of the pinned checkout and
#      reproduces the vendored tree byte-for-byte.
#
# Does not modify the checkout, the vendored package, or any other file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENDOR_DIR="$REPO_ROOT/FloeAgent/ThirdParty/MLXSwiftLM"
SRC_DIR="$REPO_ROOT/FloeAgent/.build/out/checkouts/mlx-swift-lm"
PIN_REV="d5d8b290e601ac1bf11f24635f8f811a83b98bf8"

PRISTINE_GATED_SHA="2e81ef2359b9d28fe850a04b1a45e8881144ebca84276a2d5aeff77f7c683b49"
PATCHED_GATED_SHA="b882b63af7cb8259d4759a726768dce14753af7d5a5f539a92e0d79aa1208eaf"
TEST_FILE_SHA="cb720698b962e85fa666dc9ea6a4380e1fc4214506c42803ec2d8c57f5f0d218"
PATCH_FILE_SHA="a634c9b0e7b54a1fd5d6e6934e60495361a465e29a9bea42f891bb3198dcafd2"

fail() { echo "FAIL: $*" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "== 1. pinned checkout revision =="
[ -d "$SRC_DIR/.git" ] || fail "checkout missing: $SRC_DIR"
REV="$(git -C "$SRC_DIR" rev-parse HEAD)"
[ "$REV" = "$PIN_REV" ] || fail "checkout HEAD $REV != pin $PIN_REV"
echo "ok: $REV"

echo "== 2. vendored file digests =="
[ "$(sha256_of "$SRC_DIR/Libraries/MLXLMCommon/GatedDelta.swift")" = "$PRISTINE_GATED_SHA" ] \
    || fail "pristine GatedDelta.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/Libraries/MLXLMCommon/GatedDelta.swift")" = "$PATCHED_GATED_SHA" ] \
    || fail "vendored GatedDelta.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/Tests/MLXLMTests/GatedDeltaPrefillRouteTests.swift")" = "$TEST_FILE_SHA" ] \
    || fail "GatedDeltaPrefillRouteTests.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/patches/0001-gdn-prefill-t1-ops-route.patch")" = "$PATCH_FILE_SHA" ] \
    || fail "patch digest changed"
echo "ok: all four digests match"

echo "== 3. patch series round-trip on a pristine copy =="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/floe-mlxlm-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
rsync -a --exclude='.git' --exclude='.build' --exclude='DerivedData' "$SRC_DIR/" "$TMP/src/"
for p in "$VENDOR_DIR"/patches/*.patch; do
    patch -d "$TMP/src" -p1 -s --dry-run < "$p" >/dev/null || fail "patch does not apply: $p"
    patch -d "$TMP/src" -p1 -s < "$p" >/dev/null
done
if ! diff -rq \
    --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' \
    "$TMP/src" "$VENDOR_DIR" >/dev/null; then
    diff -rq --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' \
        "$TMP/src" "$VENDOR_DIR" >&2 || true
    fail "pristine + patches does not reproduce the vendored tree"
fi
echo "ok: patch series reproduces the vendored tree"

echo "PASS: MLXSwiftLM vendored package audit"
