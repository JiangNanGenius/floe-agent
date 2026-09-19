#!/bin/bash
# Build the real DashIOS sources for the macOS host and prove the interactive
# stdin fix (ThirdParty/DashIOS/src/input.c: the top-level parser reads the
# session's thread_stdin, not the App process fd 0) actually behaves: `dash -i`
# receives input through thread_stdin while fd 0 is /dev/null.
#
# Why this exists: the app links git-ignored Frameworks/dash*.xcframework that
# scripts/build_dash_ios.sh produces from ThirdParty/DashIOS. This harness
# compiles the same tracked dash sources for the host against a stub of the
# pinned ios_system symbols (fixtures/dash_host/ios_system_stub.c), so a
# source-only edit cannot masquerade as fixed behavior: the check below fails
# on the pre-patch input.c and passes on the patched one.
#
# The host build compiles the iOS branches with -DTARGET_OS_IPHONE=1 so the
# real patched INIT code is what runs. It is a source-behavior harness, not an
# ios_system or app qualification; the app-side evidence chain is the dash
# provenance manifest (scripts/tests/test_dash_framework_provenance.py) plus
# the simulator regression test LocalShellRuntimeTests.interactiveSession*.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FLOE_ROOT="$ROOT/FloeAgent"
BUILD="${HARNESS_SCRATCH:-${TMPDIR:-/tmp}/floe-feedback-dash-interactive}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

CLANG="$(xcrun --find clang)"
OSXROOT="$(xcrun --sdk macosx --show-sdk-path)"

echo "== staging DashIOS sources in $BUILD"
rm -rf "$BUILD/source" "$BUILD/host"
mkdir -p "$BUILD/source" "$BUILD/host"
cp -Rp "$FLOE_ROOT/ThirdParty/DashIOS/" "$BUILD/source/"
floe_aux="$(automake --print-libdir)"
for floe_helper in compile missing install-sh config.guess config.sub depcomp; do
  cp "$floe_aux/$floe_helper" "$BUILD/source/$floe_helper"
done
touch "$BUILD/source/aclocal.m4" "$BUILD/source/configure" "$BUILD/source/config.h.in" \
  "$BUILD/source/Makefile.in" "$BUILD/source/src/Makefile.in"

echo "== building the host ios_system stub"
"$CLANG" -isysroot "$OSXROOT" -O2 -c -o "$BUILD/ios_system_stub.o" "$SCRIPT_DIR/fixtures/dash_host/ios_system_stub.c"
ar rcs "$BUILD/libfloe_dash_stub.a" "$BUILD/ios_system_stub.o"

echo "== configuring dash for the macOS host (iOS branches enabled)"
floe_host="$(uname -m)-apple-darwin"
(
  cd "$BUILD/host"
  /bin/sh "$BUILD/source/configure" \
    CC="$CLANG -isysroot $OSXROOT" \
    CC_FOR_BUILD="$CLANG -isysroot $OSXROOT" \
    CFLAGS="-DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -DTARGET_OS_IPHONE=1 -Wno-macro-redefined -I$BUILD/source" \
    LDFLAGS="-L$BUILD -lfloe_dash_stub" \
    --build="$floe_host" --host="$floe_host" --with-libedit > configure.log 2>&1
)

echo "== building dash for the host"
make -C "$BUILD/host" -j4 LDFLAGS="-L$BUILD -lfloe_dash_stub" > "$BUILD/build.log" 2>&1 || {
  tail -40 "$BUILD/build.log" >&2
  echo "host dash build failed" >&2
  exit 1
}

echo "== running interactive stdin checks against the real DashIOS build"
python3 "$SCRIPT_DIR/feedback_dash_interactive_driver.py" "$BUILD/host/src/dash"
