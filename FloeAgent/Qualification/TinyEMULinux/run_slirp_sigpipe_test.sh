#!/bin/bash
# Compile the actual vendored send paths; no VM image or global signal override.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../ThirdParty/TinyEMU"
BUILD="${1:?Pass a task-owned scratch directory}"
mkdir -p "$BUILD"
FLAGS=(-O1 -DCONFIG_SLIRP -ffunction-sections -fdata-sections
  -I "$ENGINE/Sources/FloeTinyEMU/engine/slirp")
if [[ "$(uname -s)" == Darwin ]]; then
  FLAGS+=(-I "$ENGINE/adapter/macos" -include "$ENGINE/adapter/macos/force.h" -Wl,-dead_strip)
else
  FLAGS+=(-Wl,--gc-sections)
fi
"${CC:-clang}" "${FLAGS[@]}" "$HERE/slirp_sigpipe_test.c" \
  "$ENGINE/Sources/FloeTinyEMU/engine/slirp/slirp.c" \
  "$ENGINE/Sources/FloeTinyEMU/engine/slirp/misc.c" -o "$BUILD/slirp_sigpipe_test"
"$BUILD/slirp_sigpipe_test"
echo 'PASS: live socket, broken socket, zero-length probe, invalid socket; default SIGPIPE'
