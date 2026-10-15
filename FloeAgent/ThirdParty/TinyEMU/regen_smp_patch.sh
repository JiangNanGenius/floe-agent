#!/bin/bash
# regen_smp_patch.sh — keep patches/0010-smp-dual-hart.patch exactly in sync
# with the vendored SwiftPM engine sources (Sources/FloeTinyEMU/engine/).
#
# The vendored tree is materialized by vendor_swift_sources.sh from the
# pristine pinned tarball + the patches in this directory (0001..0019, in
# sorted order), so patch 0010 must be exactly the delta between
# "pristine + 0001..0009" and "pristine + 0001..0010". Later patches
# (0011..0019) touch some of the same files (0012/0014/0015/0016/0017
# riscv_machine.c, 0013/0015 riscv_cpu.c, 0015 riscv_cpu.h/riscv_cpu_priv.h,
# 0018 virtio.c), so both modes must apply them after 0010 before comparing
# against the committed engine tree; a check that stops at 0010 reports false
# drift. A hand edit of Sources/FloeTinyEMU/engine without regenerating 0010
# makes the qualification build (pristine + patches) and the app build
# (vendored tree) disagree; this script makes that drift detectable and
# rebuildable.
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

# The patch series around 0010. 0001..0009 land before it; 0011..0019 land
# after it and must be replayed for any comparison against the vendored tree.
PRE_PATCHES=( "$HERE"/patches/000[1-9]-*.patch )
POST_PATCHES=( "$HERE"/patches/001[1-9]-*.patch )
[ "${#PRE_PATCHES[@]}" -eq 9 ] || die "expected 9 pre-0010 patches, found ${#PRE_PATCHES[@]}"
[ "${#POST_PATCHES[@]}" -ge 1 ] || die "expected post-0010 patches (0011+), found ${#POST_PATCHES[@]}"

# Files a patch touches (unified-diff "+++ b/<path>" headers; 0010 itself
# carries "diff -ruN" headers, the later ones do not).
patch_files() {
    sed -n 's|^+++ b/\([^	]*\).*|\1|p' "$1" | sort -u
}

apply_patch_list() { # $1 = tree, $2.. = patches (forward)
    local tree="$1"; shift
    local p
    for p in "$@"; do
        ( cd "$tree" && patch -p1 -N -r - --no-backup-if-mismatch < "$p" >/dev/null )
    done
}

apply_0010() { # $1 = source tree, $2 = destination copy
    rm -rf "$2"
    cp -R "$1" "$2"
    ( cd "$2" && patch -p1 -N -r - --no-backup-if-mismatch \
        < "$PATCH10" >/dev/null )
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/regen-smp-patch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp -R "$SRC" "$WORK/a"
apply_patch_list "$WORK/a" "${PRE_PATCHES[@]}"

if [ "$MODE" = check ]; then
    apply_0010 "$WORK/a" "$WORK/applied"
    apply_patch_list "$WORK/applied" "${POST_PATCHES[@]}"
    ok=1
    for f in $FILES; do
        if cmp -s "$WORK/applied/$f" "$ENGINE/$f"; then
            echo "ok: $f"
        else
            echo "DRIFT: $f != pristine + 0001..0019 (run $0)"
            ok=0
        fi
    done
    [ "$ok" = 1 ] || exit 1
    echo "check ok: patch 0010 + patches 0011..0019 reproduce the vendored engine sources"
    exit 0
fi

# ---- regenerate 0010 ---------------------------------------------------
# 0010 must be only its own delta, so first recover "pristine + 0001..0010"
# by reverse-applying every post-0010 patch that touches one of 0010's files
# (0011 and 0019 touch only slirp/fs_disk.c and are skipped here; their
# targets are outside FILES). Then diff against "pristine + 0001..0009".
REVERSE_PATCHES=()
for p in "${POST_PATCHES[@]}"; do
    while read -r pf; do
        case " $FILES " in
            (*" $pf "*) REVERSE_PATCHES+=( "$p" ); break;;
        esac
    done < <(patch_files "$p")
done
[ "${#REVERSE_PATCHES[@]}" -ge 1 ] \
    || die "no post-0010 patch touches 0010's files; patch-series model mismatch"
mkdir -p "$WORK/pre10"
for f in $FILES; do
    mkdir -p "$WORK/pre10/$(dirname "$f")"
    cp "$ENGINE/$f" "$WORK/pre10/$f"
done
# reverse order: the last patch that touched FILES is reverted first
for ((idx = ${#REVERSE_PATCHES[@]} - 1; idx >= 0; idx--)); do
    p="${REVERSE_PATCHES[idx]}"
    ( cd "$WORK/pre10" && patch -R -p1 -N -r - --no-backup-if-mismatch < "$p" >/dev/null ) \
        || die "cannot reverse-apply $(basename "$p") to the engine files; engine and patch series disagree"
done

cp -R "$WORK/a" "$WORK/b"
for f in $FILES; do
    cp "$WORK/pre10/$f" "$WORK/b/$f" || die "engine file not found: $f"
done
( cd "$WORK" && diff -ruN a b > "$WORK/0010-new.patch" ) || true
[ -s "$WORK/0010-new.patch" ] || die "generated patch is empty (no differences?)"

# the regenerated patch must reproduce the engine tree through the FULL
# series: pristine + 0001..0009 + new 0010 + 0011..0019 == engine
cp "$PATCH10" "$WORK/0010-old.patch"
cp "$WORK/0010-new.patch" "$PATCH10"
apply_0010 "$WORK/a" "$WORK/applied"
apply_patch_list "$WORK/applied" "${POST_PATCHES[@]}"
for f in $FILES; do
    cmp -s "$WORK/applied/$f" "$ENGINE/$f" || {
        cp "$WORK/0010-old.patch" "$PATCH10"
        die "regenerated patch does not reproduce $f through the full series; original restored"
    }
done
echo "wrote $PATCH10 ($(wc -l < "$PATCH10") lines, files:$FILES)"
echo "run vendor_swift_sources.sh --check to confirm the full patch series"
