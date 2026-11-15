#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Install the Floe guest BLAS provider into a prepared Debian ARM64 root.
# This is an image-construction helper, not an App/UI entry.  It never runs on
# the macOS host except with --dry-run/--check, and it never touches the host
# library directories.
set -eu

die() { printf 'install-floe-blas: ERROR: %s\n' "$*" >&2; exit 2; }
note() { printf 'install-floe-blas: %s\n' "$*"; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ROOT=
BUILD="$BASE_DIR/build"
MODE=install

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT=${2:-}; shift 2 ;;
        --build) BUILD=${2:-}; shift 2 ;;
        --dry-run) MODE=dry-run; shift ;;
        --check) MODE=check; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$ROOT" ] || die "--root <prepared-guest-root> is required"
[ -d "$ROOT" ] || die "root does not exist: $ROOT"
case "$BUILD" in /*) ;; *) BUILD="$BASE_DIR/$BUILD" ;; esac

LIBRARY="$BUILD/libfloe_blas.so"
PROBE="$BUILD/floe-blas-probe"
TEST_BINARY="$BUILD/floe-blas-tests"
RUN="$BASE_DIR/scripts/floe-blas-run"
SHELL_LIBRARY="$BASE_DIR/scripts/floe-blas-shell.sh"
ACTIVATION="$BASE_DIR/scripts/floe-blas-activate.sh"
ENV_FILE="$BASE_DIR/image/activation/floe-blas.env"
HEADER="$BASE_DIR/include/floe_blas.h"
LICENSE="$BASE_DIR/LICENSE"
NOTICE="$BASE_DIR/NOTICE"

for required in "$RUN" "$SHELL_LIBRARY" "$ACTIVATION" "$ENV_FILE" "$HEADER" \
                "$LICENSE" "$NOTICE"; do
    [ -f "$required" ] || die "candidate file is missing: $required"
done

if [ "$MODE" = install ] && [ "$(uname -s 2>/dev/null)" != Linux ]; then
    die "installation is guest-Linux only (use --dry-run or --check here)"
fi

for built in "$LIBRARY" "$PROBE"; do
    [ -f "$built" ] || die "build output is missing: $built (run make with the generated SPIR-V headers)"
done
if [ "$MODE" = check ]; then
    note "check: candidate sources and build outputs are present"
    note "library sha256 $(sha256_of "$LIBRARY" || echo unavailable)"
    note "probe sha256 $(sha256_of "$PROBE" || echo unavailable)"
    exit 0
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

check_aarch64_elf() {
    _file=$1
    _header=$(od -An -tx1 -N20 "$_file" | tr -d ' \n')
    case "$_header" in
        7f454c46020101*) ;;
        *) die "not a little-endian ELF64 file: $_file" ;;
    esac
    _machine=$(printf '%s' "$_header" | cut -c37-40)
    [ "$_machine" = "b700" ] || die "not an AArch64 ELF file: $_file"
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$_file" | grep -q 'Machine:.*AArch64' ||
            die "readelf does not report AArch64: $_file"
    fi
}

if [ "$MODE" != check ]; then
    check_aarch64_elf "$LIBRARY"
    check_aarch64_elf "$PROBE"
fi

plan() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

install_file() {
    _source=$1
    _target=$2
    _mode=$3
    if [ "$MODE" = dry-run ]; then
        plan "$_source" "$_target" "$_mode"
        return 0
    fi
    install -d -m 0755 "$(dirname -- "$_target")"
    install -m "$_mode" "$_source" "$_target"
}

install_file "$LIBRARY" \
    "$ROOT/usr/local/lib/floe-acceleration/libfloe_blas.so" 0644
install_file "$PROBE" "$ROOT/usr/local/bin/floe-blas-probe" 0755
install_file "$RUN" "$ROOT/usr/local/bin/floe-blas-run" 0755
install_file "$SHELL_LIBRARY" \
    "$ROOT/usr/local/lib/floe-acceleration/floe-blas-shell.sh" 0644
install_file "$ACTIVATION" \
    "$ROOT/usr/local/share/floe-acceleration/floe-blas-activate.sh" 0644
install_file "$ENV_FILE" \
    "$ROOT/usr/local/share/floe-acceleration/floe-blas.env" 0644
install_file "$HEADER" \
    "$ROOT/usr/local/include/floe-acceleration/floe_blas.h" 0644
install_file "$LICENSE" "$ROOT/usr/local/share/doc/floe-blas/LICENSE" 0644
install_file "$NOTICE" "$ROOT/usr/local/share/doc/floe-blas/NOTICE" 0644

if [ -f "$TEST_BINARY" ]; then
    install_file "$TEST_BINARY" \
        "$ROOT/usr/local/libexec/floe-acceleration/floe-blas-tests" 0755
fi

if [ "$MODE" = dry-run ]; then
    note "dry-run: no file was changed"
    note "library sha256 $(sha256_of "$LIBRARY" || echo unavailable)"
    note "probe sha256 $(sha256_of "$PROBE" || echo unavailable)"
    exit 0
fi

# Verify the installed bytes, not just the source candidate.
installed_library="$ROOT/usr/local/lib/floe-acceleration/libfloe_blas.so"
[ -f "$installed_library" ] || die "installed library is missing"
[ "$(sha256_of "$LIBRARY")" = "$(sha256_of "$installed_library")" ] ||
    die "installed library hash mismatch"
if command -v readelf >/dev/null 2>&1; then
    readelf -d "$installed_library" | grep -q 'SONAME.*libfloe_blas.so' ||
        die "installed library has no libfloe_blas.so SONAME"
fi
note "installed library sha256 $(sha256_of "$installed_library")"
note "entrypoint $ROOT/usr/local/bin/floe-blas-run"
note "provider $installed_library"
