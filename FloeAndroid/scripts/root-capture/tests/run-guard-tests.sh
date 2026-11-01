#!/usr/bin/env bash
# Host contract tests for the embedded Floe root-capture guard.
# This never builds the Android helper and never links against libpcap.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CAPTURE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT="$(cd "$CAPTURE_DIR/../.." && pwd)"
readonly OUT="${FLOE_GUARD_TEST_OUT:-$REPO_ROOT/Local/Private/capture-guard-tests}"
readonly CC="${CC:-cc}"
readonly GUARD_C="$CAPTURE_DIR/guard/floe_capture_guard.c"
readonly GUARD_H="$CAPTURE_DIR/guard/floe_capture_guard.h"
readonly PATCH="$CAPTURE_DIR/patches/0001-tcpdump-install-guard.patch"

log() { printf '[guard-tests] %s\n' "$*" >&2; }
fail() { printf '[guard-tests] error: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

source_sha="$(sha256_file "$GUARD_C")"
header_sha="$(sha256_file "$GUARD_H")"
patch_sha="$(sha256_file "$PATCH")"

log "compile guard contract test (host cc, macros supplied directly)"
"$CC" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
  -I"$CAPTURE_DIR/guard" \
  -DFLOE_GUARD_SOURCE_SHA256="\"$source_sha\"" \
  -DFLOE_GUARD_HEADER_SHA256="\"$header_sha\"" \
  -DFLOE_GUARD_PATCH_SHA256="\"$patch_sha\"" \
  "$GUARD_C" "$SCRIPT_DIR/guard_contract_test.c" \
  -o "$OUT/guard_contract_test" -pthread

log "run guard contract test"
"$OUT/guard_contract_test" | tee "$OUT/guard_contract_test.log"

log "run verifier guard-binding tests"
python3 "$SCRIPT_DIR/test_verifier_guard.py" \
  --verify-script "$CAPTURE_DIR/verify-helper.py" \
  --stage-script "$CAPTURE_DIR/stage-helper.py" \
  --guard-source "$source_sha" \
  --guard-header "$header_sha" \
  --guard-patch "$patch_sha" \
  | tee "$OUT/verifier_guard_test.log"

if [[ -n "${TCPDUMP_TAR:-}" ]]; then
  log "check the tcpdump patch against the exact pinned archive"
  mkdir -p "$OUT/patch-check"
  tar -xzf "$TCPDUMP_TAR" -C "$OUT/patch-check"
  patch -p1 --batch --dry-run --fuzz=0 \
    -d "$OUT/patch-check/tcpdump-4.99.5" -i "$PATCH" \
    | tee "$OUT/patch-check.log"
else
  log "TCPDUMP_TAR not supplied; archive patch check skipped"
fi

log "PASS: outputs in $OUT"
