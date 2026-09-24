#!/usr/bin/env bash
# Read-only audit for the Floe-vendored MLXSwiftLM package.
#
# Verifies every committed vendored file against FLOE_SHA256SUMS on a clean
# checkout. When the pinned upstream checkout is available, additionally
# verifies its revision and replays the patch series byte-for-byte.
#
# Does not modify the checkout, the vendored package, or any other file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENDOR_DIR="$REPO_ROOT/FloeAgent/ThirdParty/MLXSwiftLM"
SRC_DIR="$REPO_ROOT/FloeAgent/.build/out/checkouts/mlx-swift-lm"
PIN_REV="d5d8b290e601ac1bf11f24635f8f811a83b98bf8"
MANIFEST="$VENDOR_DIR/FLOE_SHA256SUMS"

PRISTINE_GATED_SHA="2e81ef2359b9d28fe850a04b1a45e8881144ebca84276a2d5aeff77f7c683b49"
PATCHED_GATED_SHA="b882b63af7cb8259d4759a726768dce14753af7d5a5f539a92e0d79aa1208eaf"
TEST_FILE_SHA="cb720698b962e85fa666dc9ea6a4380e1fc4214506c42803ec2d8c57f5f0d218"
PATCH_FILE_SHA="a634c9b0e7b54a1fd5d6e6934e60495361a465e29a9bea42f891bb3198dcafd2"

fail() { echo "FAIL: $*" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "== 1. committed vendored tree =="
python3 - "$VENDOR_DIR" "$MANIFEST" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
excluded = {"FLOE_SHA256SUMS", "FLOE_VENDOR.md", "floe_vendor_check.sh"}
actual = {}
for path in root.rglob("*"):
    if not path.is_file() or any(part in {".git", ".build"} for part in path.parts):
        continue
    name = path.relative_to(root).as_posix()
    if name in excluded:
        continue
    actual[name] = hashlib.sha256(path.read_bytes()).hexdigest()
expected = {}
for line in manifest.read_text().splitlines():
    digest, name = line.split("  ", 1)
    if name in expected:
        raise SystemExit(f"duplicate manifest entry: {name}")
    expected[name] = digest
if expected != actual:
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(k for k in set(expected) & set(actual) if expected[k] != actual[k])
    raise SystemExit(f"vendor digest mismatch: missing={missing[:5]} extra={extra[:5]} changed={changed[:5]}")
print(f"ok: {len(actual)} vendored files match FLOE_SHA256SUMS")
PY

echo "== 2. pinned upstream checkout (when available) =="
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "note: upstream checkout unavailable; vendored tree digest verified"
    exit 0
fi
REV="$(git -C "$SRC_DIR" rev-parse HEAD)"
[ "$REV" = "$PIN_REV" ] || fail "checkout HEAD $REV != pin $PIN_REV"
echo "ok: $REV"

echo "== 3. patched file digests =="
[ "$(sha256_of "$SRC_DIR/Libraries/MLXLMCommon/GatedDelta.swift")" = "$PRISTINE_GATED_SHA" ] \
    || fail "pristine GatedDelta.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/Libraries/MLXLMCommon/GatedDelta.swift")" = "$PATCHED_GATED_SHA" ] \
    || fail "vendored GatedDelta.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/Tests/MLXLMTests/GatedDeltaPrefillRouteTests.swift")" = "$TEST_FILE_SHA" ] \
    || fail "GatedDeltaPrefillRouteTests.swift digest changed"
[ "$(sha256_of "$VENDOR_DIR/patches/0001-gdn-prefill-t1-ops-route.patch")" = "$PATCH_FILE_SHA" ] \
    || fail "patch digest changed"
echo "ok: all four digests match"

echo "== 4. patch series round-trip on a pristine copy =="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/floe-mlxlm-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
rsync -a --exclude='.git' --exclude='.build' --exclude='DerivedData' "$SRC_DIR/" "$TMP/src/"
for p in "$VENDOR_DIR"/patches/*.patch; do
    patch -d "$TMP/src" -p1 -s --dry-run < "$p" >/dev/null || fail "patch does not apply: $p"
    patch -d "$TMP/src" -p1 -s < "$p" >/dev/null
done
if ! diff -rq \
    --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' --exclude='FLOE_SHA256SUMS' \
    "$TMP/src" "$VENDOR_DIR" >/dev/null; then
    diff -rq --exclude='patches' --exclude='FLOE_VENDOR.md' --exclude='floe_vendor_check.sh' --exclude='FLOE_SHA256SUMS' \
        "$TMP/src" "$VENDOR_DIR" >&2 || true
    fail "pristine + patches does not reproduce the vendored tree"
fi
echo "ok: patch series reproduces the vendored tree"

echo "PASS: MLXSwiftLM vendored package audit"
