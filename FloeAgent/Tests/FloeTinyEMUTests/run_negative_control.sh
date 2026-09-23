#!/bin/bash
# run_negative_control.sh — prove that the PTE A/D regression payload
# detects the pre-fix behavior, and that the suite's green result is not
# vacuous.
#
# It builds the qualification library from the pristine pinned TinyEMU
# tarball + patches/ into its own BUILD dir, rewrites the generated
# riscv_cpu.c so the page-walk A/D read-modify-write again only applies
# while the whole PTE word still equals the value the walk loaded (the
# pre-fix "cur == expect" behavior), rebuilds, and runs the same
# smp_host_test payloads. The control passes only when the injected build
# really fails in the expected way:
#
#   - the guest reports SMP-FAIL and lost D (and/or A) epochs from the
#     exact-equality A/D check, and
#   - pte_ad_merges stays 0 (no A/D-only interleaving was merged), which
#     is what the fixed engine's host assertion requires to be > 0.
#
# Usage:  bash run_negative_control.sh [BUILD_DIR]
# Env:    MACOS= (set empty on Linux), TINYEMU_SRC= override pristine tree.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TINYEMU_DIR="$HERE/../../ThirdParty/TinyEMU"
TINYEMU_SRC="${TINYEMU_SRC:-$REPO/Local/Private/tinyemu-vendor/src/tinyemu-2019-12-21}"
BUILD="${1:-${BUILD:-$REPO/Local/Scratch/floetinyemu-smp-tests/negctl-build}}"
MACOS="${MACOS:-1}"

[ -d "$TINYEMU_SRC" ] || {
    echo "negative control: pristine tree missing: $TINYEMU_SRC" >&2
    echo "(run FloeAgent/ThirdParty/TinyEMU/fetch_source.sh first)" >&2
    exit 1
}

log() { printf 'negative-control: %s\n' "$*"; }

# The adapter Makefile requires paths relative to ThirdParty/TinyEMU (the
# workspace can contain spaces, so absolute paths cannot be passed).
rel() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }
REL_SRC="$(rel "$TINYEMU_SRC" "$TINYEMU_DIR")"
REL_BUILD="$(rel "$BUILD" "$TINYEMU_DIR")"

log "building the qualification library (pristine + patches) into $BUILD"
mkdir -p "$BUILD"
rm -f "$BUILD/.prepared"
( cd "$TINYEMU_DIR" && make -f adapter/Makefile \
      TINYEMU_SRC="$REL_SRC" BUILD="$REL_BUILD" MACOS="$MACOS" ) >"$BUILD/negctl-build.log" 2>&1

python3 - "$BUILD/riscv_cpu.c" <<'PY'
import sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()
old = """    want = cur | ((target_ulong)bits & ~cur);
    if (want != cur) {"""
new = """    want = cur | ((target_ulong)bits & ~cur);
    /* NEGATIVE CONTROL (scratch build only): pre-fix behavior. */
    if (cur == (target_ulong)expect && want != cur) {"""
if old not in src:
    raise SystemExit("negative control: merge block not found in " + path)
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
print("negative control: injected the pre-fix cur == expect comparison")
PY

log "rebuilding the injected library"
rm -f "$BUILD/riscv_cpu32.o" "$BUILD/riscv_cpu64.o" "$BUILD/libfloevm.a"
( cd "$TINYEMU_DIR" && make -f adapter/Makefile \
      TINYEMU_SRC="$REL_SRC" BUILD="$REL_BUILD" MACOS="$MACOS" ) >>"$BUILD/negctl-build.log" 2>&1

python3 "$HERE/gen_smp_payload.py" "$BUILD" >/dev/null
cc -O2 -Wall -I"$TINYEMU_DIR/adapter" -o "$BUILD/smp_host_test_negctl" \
    "$HERE/smp_host_test.c" "$BUILD/libfloevm.a" -lpthread -lm
if [ ! -f "$BUILD/stop_test_disk.img" ]; then
    dd if=/dev/zero of="$BUILD/stop_test_disk.img" bs=1m count=8 >/dev/null 2>&1
fi

log "running the payloads against the injected engine (failure is expected)"
set +e
( cd "$BUILD" && ./smp_host_test_negctl ) >"$BUILD/negctl-run.log" 2>&1
rc=$?
set -e
tail -12 "$BUILD/negctl-run.log" || true

problems=""
if [ "$rc" = 0 ]; then
    problems="$problems the injected engine passed the suite (the regression payload is vacuous)"
fi
grep -q 'lost D bit on' "$BUILD/negctl-run.log" \
    || problems="$problems no lost-D detection was reported"
grep -q 'SMP-FAIL in output' "$BUILD/negctl-run.log" \
    || problems="$problems the guest did not report SMP-FAIL"
grep -q 'pte_ad_merges=0' "$BUILD/negctl-run.log" \
    || problems="$problems pte_ad_merges was not 0 in the injected build"
if [ -n "$problems" ]; then
    printf 'negative-control: FAIL:%s\n' "$problems" >&2
    printf 'negative-control: log: %s\n' "$BUILD/negctl-run.log" >&2
    exit 1
fi

printf 'negative-control: PASS — the injected pre-fix engine is rejected exactly as expected\n'
printf 'negative-control: evidence %s/negctl-run.log\n' "$BUILD"
