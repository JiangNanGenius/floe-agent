#!/bin/bash
# regen_smp_patch.sh — keep patches/0010-smp-dual-hart.patch exactly in sync
# with the vendored SwiftPM engine sources (Sources/FloeTinyEMU/engine/).
#
# The vendored tree is materialized by vendor_swift_sources.sh from the
# pristine pinned tarball + the patches in this directory, so patch 0010
# must be exactly "pristine + 0001..0009 -> committed engine tree". A hand
# edit of Sources/FloeTinyEMU/engine without regenerating 0010 makes the
# qualification build (pristine + patches) and the app build (vendored tree)
# disagree; this script makes that drift detectable and rebuildable.
#
# Usage:
#   regen_smp_patch.sh            regenerate 0010 from the engine tree
#   regen_smp_patch.sh --check    verify 0010 reproduces the engine tree
#
# The pristine tree is the hash-verified TinyEMU 2019-12-21 extraction
# (fetch_source.sh). It defaults to the git-ignored local cache and can be
# overridden with the first non-flag argument or $TINYEMU_PRISTINE.
set -euo pipefail

die() {
    printf 'regen_smp_patch: ERROR: %s\n' "$*" >&2
    exit 1
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/Sources/FloeTinyEMU/engine"
PATCH10="$HERE/patches/0010-smp-dual-hart.patch"

MODE=write
if [ "${1:-}" = "--check" ]; then
    MODE=check
    shift
fi

SRC="${1:-${TINYEMU_PRISTINE:-$HERE/../../../Local/Private/tinyemu-vendor/src/tinyemu-2019-12-21}}"
[ -f "$SRC/VERSION" ] || die "not the extracted pinned tree: $SRC"
[ -f "$PATCH10" ] || die "missing $PATCH10"
[ -d "$ENGINE" ] || die "missing vendored engine: $ENGINE"

# File list is owned by the patch itself: the files it is allowed to touch.
FILES=""
while read -r f; do
    FILES="$FILES $f"
done < <(sed -n 's|^diff -ruN a/\(.*\) b/\1$|\1|p' "$PATCH10")
[ -n "$FILES" ] || die "cannot derive the file list from $PATCH10"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/regen-smp-patch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp -R "$SRC" "$WORK/a"
( cd "$WORK/a" && for p in "$HERE"/patches/000[1-9]-*.patch; do
    patch -p1 -N -r - --no-backup-if-mismatch < "$p" >/dev/null
done )

apply_0010() { # apply the current patch to $WORK/a (a copy in $WORK/applied)
    rm -rf "$WORK/applied"
    cp -R "$WORK/a" "$WORK/applied"
    ( cd "$WORK/applied" && patch -p1 -N -r - --no-backup-if-mismatch \
        < "$PATCH10" >/dev/null )
}

if [ "$MODE" = check ]; then
    apply_0010
    ok=1
    for f in $FILES; do
        if cmp -s "$WORK/applied/$f" "$ENGINE/$f"; then
            echo "ok: $f"
        else
            echo "DRIFT: $f != pristine + 0001..0010 (run $0)"
            ok=0
        fi
    done
    [ "$ok" = 1 ] || exit 1
    echo "check ok: patch 0010 reproduces the vendored engine sources"
    exit 0
fi

cp -R "$WORK/a" "$WORK/b"
for f in $FILES; do
    cp "$ENGINE/$f" "$WORK/b/$f" || die "engine file not found: $f"
done
( cd "$WORK" && diff -ruN a b > "$WORK/0010-new.patch" ) || true
[ -s "$WORK/0010-new.patch" ] || die "generated patch is empty (no differences?)"

# the regenerated patch must reproduce the engine tree byte for byte
cp "$PATCH10" "$WORK/0010-old.patch"
cp "$WORK/0010-new.patch" "$PATCH10"
apply_0010
for f in $FILES; do
    cmp -s "$WORK/applied/$f" "$ENGINE/$f" || {
        cp "$WORK/0010-old.patch" "$PATCH10"
        die "regenerated patch does not reproduce $f; original restored"
    }
done
echo "wrote $PATCH10 ($(wc -l < "$PATCH10") lines, files:$FILES)"
echo "run vendor_swift_sources.sh --check to confirm the full patch series"
