#!/usr/bin/env bash
# ninep_semantics_check.sh — compile and run the focused 9P backend check
# (patch 0009) against the REAL vendored fs_disk engine:
#
#   * unlinkat flags/type semantics: files, empty dirs, non-empty dirs and
#     symlinks (targets are never followed or removed),
#   * xattrwalk list/query responses (empty list; ENODATA for a name; the
#     bogus 524 status is gone so GNU ls -l no longer prints "Unknown error").
#
# No VM, guest image or network is needed. Works on macOS (CI host) and Linux.
#
# Usage: bash FloeAgent/LinuxGuest/tests/ninep_semantics_check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest_root="$(cd "$here/.." && pwd)"
engine="$guest_root/../ThirdParty/TinyEMU/Sources/FloeTinyEMU/engine"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/floe-9p-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

cc="${CC:-cc}"
cflags=(-std=c11 -Wall -Wextra -Wno-unused-parameter -O0 -g)
if [ "$(uname -s)" = "Darwin" ]; then
    # The vendored engine carries an Apple stat timestamp mapping already;
    # shim the sys/ headers the qualification Makefile normally provides.
    # No _POSIX_C_SOURCE: the Darwin st_*timespec members need the SDK's
    # default feature macro set.
    cflags+=(-I"$engine/../shims")
else
    cflags+=(-D_GNU_SOURCE)
fi

"$cc" "${cflags[@]}" \
    "$here/ninep_semantics_check.c" \
    "$engine/fs_disk.c" \
    "$engine/fs.c" \
    "$engine/cutils.c" \
    -I"$engine" \
    -o "$scratch/ninep_check"

"$scratch/ninep_check"
