#!/bin/zsh
# Build GLib core + libslirp + smoke binary for one platform.
# Usage: build-platform.sh <macos|ios-device|ios-sim>
set -eu
. "${0:A:h}/env.sh"
plat="$1"
mode="${2:-all}"
[[ "$mode" == all || "$mode" == glib-only || "$mode" == slirp-only ]] || die "usage: build-platform.sh platform [glib-only|slirp-only]"
GB="$BUILDS/glib-$plat"
SB="$BUILDS/slirp-$plat"
ST="$STAGE/$plat"
SMOKE="$BUILDS/smoke-$plat"

mkdir -p "$BUILDS" "$ST" "$SMOKE"

cross_args=()
if [[ "$plat" == ios-device || "$plat" == ios-sim ]]; then
  "${0:A:h}/gen-cross.sh" "$plat" "$BUILDS/cross-$plat.ini"
  cross_args=(--cross-file "$BUILDS/cross-$plat.ini")
fi

pick_target() { # <builddir> <filename-substring> -> build-relative ninja target
  "$MESON" introspect --targets "$1" | "$PYTHON" -c '
import sys, json, os
bd = os.path.abspath(sys.argv[1]); pat = sys.argv[2]
for t in json.load(sys.stdin):
    for fn in t["filename"]:
        if os.path.basename(fn).endswith(pat):
            print(os.path.relpath(os.path.abspath(fn), bd)); sys.exit(0)
sys.exit(1)' "$1" "$2"
}


if [[ "$mode" != slirp-only ]]; then
# ---------- GLib core ----------
# NOTE: -Dpcre2:jit=false explicitly disables PCRE2's sljit code-emitter in the
# static dependency itself; the code emitter is not compiled.
# FLOE_GLIB_NO_TEST_SUBPROCESS: compile-time boundary for patch 0002 — drops
# fork/g_spawn/waitpid code from gtestutils (unit-test traps only).
reconf=()
glib_def=(--cross-file "$BUILDS/cross-$plat-glib.ini")
"${0:A:h}/gen-cross.sh" "$plat" "$BUILDS/cross-$plat-glib.ini" -DFLOE_GLIB_NO_TEST_SUBPROCESS
glib_def=(--cross-file "$BUILDS/cross-$plat-glib.ini")
if [[ ! -f "$GB/meson-info/meson-info.json" ]]; then
  run "setup-glib-$plat" "$MESON" setup "$GB" "$SRC/glib-$GLIB_VER" \
    --wrap-mode=forcefallback \
    --buildtype=release --strip \
    -Ddefault_library=static -Dtests=false -Doss_fuzz=disabled \
    -Dnls=disabled -Dxattr=false -Dsysprof=disabled -Dselinux=disabled \
    -Dlibmount=disabled -Dintrospection=disabled -Ddocumentation=false \
    -Dgtk_doc=false -Dman=false -Dglib_debug=disabled \
    -Dpcre2:jit=disabled \
    -Dwerror=false "${glib_def[@]}"
else
  run "reconf-glib-$plat" "$MESON" setup --reconfigure "$GB" "$SRC/glib-$GLIB_VER" \
    --wrap-mode=forcefallback \
    --buildtype=release --strip \
    -Ddefault_library=static -Dtests=false -Doss_fuzz=disabled \
    -Dnls=disabled -Dxattr=false -Dsysprof=disabled -Dselinux=disabled \
    -Dlibmount=disabled -Dintrospection=disabled -Ddocumentation=false \
    -Dgtk_doc=false -Dman=false -Dglib_debug=disabled \
    -Dpcre2:jit=disabled \
    -Dwerror=false "${glib_def[@]}"
fi

glib_target=$(pick_target "$GB" "libglib-2.0.a") || die "cannot find libglib-2.0.a target in $GB"
run "build-glib-$plat" "$NINJA" -C "$GB" -j "$JOBS" "$glib_target"
# pcre2 static lib (needed for glib-2.0.pc Libs.private completeness; GRegex
# objects are never pulled by slirp, verified in the audit)
pcre_target=$(pick_target "$GB" "libpcre2-8.a") || true
if [[ -n "$pcre_target" ]]; then
  run "build-pcre2-$plat" "$NINJA" -C "$GB" -j "$JOBS" "$pcre_target"
fi
# proxy-libintl static archive: glib-2.0.pc's -lintl must resolve in staging
intl_target=$(pick_target "$GB" "libintl.a") || true
if [[ -n "$intl_target" ]]; then
  run "build-intl-$plat" "$NINJA" -C "$GB" -j "$JOBS" "$intl_target"
fi
run "stage-glib-$plat" env MESON="$MESON" PYTHON="$PYTHON" "$PYTHON" "${0:A:h}/stage-glib.py" "$GB" "$SRC/glib-$GLIB_VER" "$ST"
if [[ "$plat" == ios-device || "$plat" == ios-sim ]]; then
  run "strip-exec-glib-$plat" "${0:A:h}/strip-exec-glib.sh" "$plat"
fi

fi
[[ "$mode" == glib-only ]] && { log "GLib-only $plat COMPLETE"; exit 0; }

# ---------- libslirp ----------
# The exec-guard define must live INSIDE the cross file's built-in c_args for
# iOS: a command-line -Dc_args REPLACES the cross file c_args and would drop
# the -target/-isysroot flags (minos would silently become the SDK default).
# The macOS profile also uses an explicit cross file for its macOS 15.0 target.
slirp_def=(--cross-file "$BUILDS/cross-$plat-slirp.ini")
"${0:A:h}/gen-cross.sh" "$plat" "$BUILDS/cross-$plat-slirp.ini" -DSLIRP_NO_HOST_EXEC -DSLIRP_FLOE_HOST_HOOKS
slirp_def=(--cross-file "$BUILDS/cross-$plat-slirp.ini")
if [[ ! -f "$SB/meson-info/meson-info.json" ]]; then
  PKG_CONFIG_PATH="$ST/lib/pkgconfig" PKG_CONFIG_LIBDIR="$ST/lib/pkgconfig" \
  run "setup-slirp-$plat" "$MESON" setup "$SB" "$SRC/libslirp-$SLIRP_VER" \
    --prefix "$ST" \
    --buildtype=debugoptimized -Doptimization=2 -Ddebug=true -Db_ndebug=false \
    -Ddefault_library=static -Dstatic=true \
    -Dwerror=false "${slirp_def[@]}"
fi
run "build-slirp-$plat" "$NINJA" -C "$SB" -j "$JOBS"
run "install-slirp-$plat" "$MESON" install -C "$SB" --no-rebuild
# static_library is not installed by meson; place the archive ourselves
slirp_target=$(pick_target "$SB" "libslirp.a") || die "no libslirp.a in $SB"
cp "$SB/$slirp_target" "$ST/lib/libslirp.a"
cp "$SRC/libslirp-$SLIRP_VER/src/floe_host_net.h" "$ST/include/slirp/"
log "staged libslirp.a ($slirp_target)"

# ---------- smoke executable ----------
slirp_inc=("$ST/include/slirp")
if [[ "$plat" == macos ]]; then
  cc=(xcrun --sdk macosx clang -target arm64-apple-macos15.0 -isysroot "$(xcrun_sdk_path macosx)")
else
  case "$plat" in
    ios-device) triple="arm64-apple-ios$MIN_OS_IOS" ;;
    ios-sim)    triple="arm64-apple-ios$MIN_OS_IOS-simulator" ;;
  esac
  sdk=iphoneos; [[ "$plat" == ios-sim ]] && sdk=iphonesimulator
  cc=(xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$(xcrun_sdk_path $sdk)")
fi
  export PKG_CONFIG_PATH="$ST/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$ST/lib/pkgconfig"
smoke_cflags=$($PKG_CONFIG --static --cflags slirp)
smoke_libs=$($PKG_CONFIG --static --libs slirp)
log "smoke pkg-config cflags: $smoke_cflags"
log "smoke pkg-config libs: $smoke_libs"
run "link-smoke-$plat" "${cc[@]}" -Wall -Wextra "-I$ST/include" ${=smoke_cflags} \
  "$DOMAIN/smoke/slirp_smoke.c" -o "$SMOKE/slirp_smoke" ${=smoke_libs}

log "build-platform $plat COMPLETE"
ls -la "$ST/lib"
