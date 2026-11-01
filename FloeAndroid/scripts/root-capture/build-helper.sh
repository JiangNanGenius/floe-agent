#!/usr/bin/env bash
# Build the pinned Full-only root capture helper.
#
# Inputs are the official tcpdump/libpcap release archives with the exact
# SHA-256 values recorded in licenses/root-capture/SOURCES.md. The output is a
# deterministic AArch64/minSdk 28 PIE with 16 KiB-compatible PT_LOAD alignment,
# a digest manifest, and a staged copy for the Full APK.
#
# This script never downloads a prebuilt binary and never trusts a file already
# present at an install path. Run from the FloeAndroid repository root.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly TCPDUMP_VERSION="4.99.5"
readonly LIBPCAP_VERSION="1.10.5"
readonly TCPDUMP_SHA="8c75856e00addeeadf70dad67c9ff3dd368536b2b8563abf6854d7c764cd3adb"
readonly LIBPCAP_SHA="37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0"
readonly TCPDUMP_URL="https://www.tcpdump.org/release/tcpdump-${TCPDUMP_VERSION}.tar.gz"
readonly LIBPCAP_URL="https://www.tcpdump.org/release/libpcap-${LIBPCAP_VERSION}.tar.gz"
readonly NDK_VERSION="30.0.16248370"
readonly API="28"
readonly TARGET="aarch64-linux-android${API}"
readonly SOURCE_DATE_EPOCH_VALUE="1700000000"
readonly OUT_DEFAULT="$REPO_ROOT/build/root-capture"
readonly GUARD_DIR="$SCRIPT_DIR/guard"
readonly GUARD_PATCH="$SCRIPT_DIR/patches/0001-tcpdump-install-guard.patch"
readonly GUARD_SOURCE="$GUARD_DIR/floe_capture_guard.c"
readonly GUARD_HEADER="$GUARD_DIR/floe_capture_guard.h"
PYTHON="${PYTHON:-python3}"

OUT="$OUT_DEFAULT"
SOURCES=""
NDK=""
STAGE=0

usage() {
  cat <<'USAGE'
Usage: scripts/root-capture/build-helper.sh [options]

  --out DIR          Build output directory (default: FloeAndroid/build/root-capture)
  --sources DIR      Directory containing the exact upstream tar.gz files
  --ndk DIR          Android NDK directory (default: $ANDROID_NDK_HOME or SDK ndk/<pinned>)
  --stage            Copy the verified result into app/src/full and the asset manifest
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --sources) SOURCES="$2"; shift 2 ;;
    --ndk) NDK="$2"; shift 2 ;;
    --stage) STAGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[root-capture] %s\n' "$*" >&2; }
fail() { printf '[root-capture] error: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

resolve_ndk() {
  if [[ -n "$NDK" ]]; then
    return
  fi
  local candidate
  for candidate in \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "${ANDROID_HOME:-}/ndk/$NDK_VERSION" \
    "${ANDROID_SDK_ROOT:-}/ndk/$NDK_VERSION"; do
    if [[ -n "$candidate" && -f "$candidate/source.properties" ]]; then
      NDK="$candidate"
      return
    fi
  done
  fail "Android NDK $NDK_VERSION not found (set ANDROID_NDK_HOME or --ndk)"
}

check_ndk() {
  [[ -f "$NDK/source.properties" ]] || fail "not an NDK directory: $NDK"
  local revision
  revision="$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "$NDK/source.properties" | head -1 | tr -d '\r')"
  [[ "$revision" == "$NDK_VERSION" ]] || fail "NDK revision $revision != $NDK_VERSION"
}

fetch_source() {
  local url="$1" expected="$2" destination="$3"
  if [[ -f "$destination" ]]; then
    [[ "$(sha256_file "$destination")" == "$expected" ]] || fail "hash mismatch: $destination"
    return
  fi
  command -v curl >/dev/null 2>&1 || fail "curl is required to fetch $url"
  log "download $url"
  curl --fail --location --silent --show-error --output "$destination.part" "$url"
  local actual
  actual="$(sha256_file "$destination.part")"
  [[ "$actual" == "$expected" ]] || { rm -f "$destination.part"; fail "download hash mismatch: $url"; }
  mv "$destination.part" "$destination"
}

resolve_sources() {
  if [[ -n "$SOURCES" ]]; then
    return
  fi
  SOURCES="$OUT/sources"
}

main() {
  resolve_ndk
  check_ndk
  resolve_sources
  mkdir -p "$SOURCES" "$OUT/work" "$OUT/out"

  local tcpdump_tar="$SOURCES/tcpdump-${TCPDUMP_VERSION}.tar.gz"
  local libpcap_tar="$SOURCES/libpcap-${LIBPCAP_VERSION}.tar.gz"
  fetch_source "$TCPDUMP_URL" "$TCPDUMP_SHA" "$tcpdump_tar"
  fetch_source "$LIBPCAP_URL" "$LIBPCAP_SHA" "$libpcap_tar"

  local host_tag
  case "$(uname -s)" in
    Darwin) host_tag="darwin-x86_64" ;;
    Linux) host_tag="linux-x86_64" ;;
    *) fail "unsupported build host: $(uname -s)" ;;
  esac
  local toolchain="$NDK/toolchains/llvm/prebuilt/$host_tag"
  local clang="$toolchain/bin/${TARGET}-clang"
  local cxx="$toolchain/bin/${TARGET}-clang++"
  local ar="$toolchain/bin/llvm-ar"
  local ranlib="$toolchain/bin/llvm-ranlib"
  local strip="$toolchain/bin/llvm-strip"
  for tool in "$clang" "$cxx" "$ar" "$ranlib" "$strip"; do
    [[ -x "$tool" ]] || fail "missing NDK tool: $tool"
  done

  local common_cflags
  common_cflags="-O2 -fPIE -fPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security -ffile-prefix-map=$OUT/work=/floe-src -fdebug-prefix-map=$OUT/work=/floe-src"
  local common_ldflags="-pie -fPIE -Wl,-z,max-page-size=16384 -Wl,-z,relro -Wl,-z,now -Wl,--build-id=sha1"

  rm -rf "$OUT/work/libpcap-${LIBPCAP_VERSION}" "$OUT/work/tcpdump-${TCPDUMP_VERSION}"
  tar -xzf "$libpcap_tar" -C "$OUT/work"
  tar -xzf "$tcpdump_tar" -C "$OUT/work"

  local guard_source_sha guard_header_sha guard_patch_sha tcpdump_source
  guard_source_sha="$(sha256_file "$GUARD_SOURCE")"
  guard_header_sha="$(sha256_file "$GUARD_HEADER")"
  guard_patch_sha="$(sha256_file "$GUARD_PATCH")"
  tcpdump_source="$OUT/work/tcpdump-${TCPDUMP_VERSION}"
  cp "$GUARD_SOURCE" "$tcpdump_source/floe_capture_guard.c"
  cp "$GUARD_HEADER" "$tcpdump_source/floe_capture_guard.h"
  log "apply local tcpdump guard patch"
  if ! patch -p1 --batch --forward --fuzz=0 \
      -d "$tcpdump_source" -i "$GUARD_PATCH" >/dev/null; then
    fail "guard patch does not apply to the pinned tcpdump source"
  fi
  cat >"$tcpdump_source/floe_guard_identity.h" <<EOF
/* Generated by build-helper.sh. Do not edit. */
#define FLOE_GUARD_SOURCE_SHA256 "$guard_source_sha"
#define FLOE_GUARD_HEADER_SHA256 "$guard_header_sha"
#define FLOE_GUARD_PATCH_SHA256 "$guard_patch_sha"
EOF

  log "configure libpcap ${LIBPCAP_VERSION}"
  (
    cd "$OUT/work/libpcap-${LIBPCAP_VERSION}"
    export CC="$clang" CXX="$cxx" AR="$ar" RANLIB="$ranlib" STRIP="$strip"
    export CFLAGS="$common_cflags -I$OUT/work/libpcap-${LIBPCAP_VERSION}"
    export LDFLAGS="$common_ldflags"
    export SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE"
    export ZERO_AR_DATE=1
    ./configure \
      --host="$TARGET" \
      --target="$TARGET" \
      --prefix="$OUT/out" \
      --disable-shared \
      --enable-static \
      --disable-dbus \
      --disable-bluetooth \
      --disable-netmap \
      --disable-usb \
      --without-libnl \
      --without-dag \
      --without-septel \
      --without-snf \
      --without-turbocap \
      --without-dpdk \
      ac_cv_linux_vers=2 \
      >/dev/null
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
    make install >/dev/null
  )

  export PATH="$OUT/out/bin:$PATH"
  export PCAP_CONFIG="$OUT/out/bin/pcap-config"
  log "configure tcpdump ${TCPDUMP_VERSION}"
  (
    cd "$OUT/work/tcpdump-${TCPDUMP_VERSION}"
    export CC="$clang" CXX="$cxx" AR="$ar" RANLIB="$ranlib" STRIP="$strip"
    export CFLAGS="$common_cflags -I$OUT/out/include"
    export LDFLAGS="$common_ldflags"
    export LIBS="$OUT/out/lib/libpcap.a"
    export SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE"
    export ZERO_AR_DATE=1
    ./configure \
      --host="$TARGET" \
      --target="$TARGET" \
      --prefix="$OUT/out" \
      --without-crypto \
      --without-cap-ng \
      --disable-smb \
      >/dev/null
    make CSRC="fptype.c tcpdump.c floe_capture_guard.c" \
      -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
  )

  local built="$OUT/work/tcpdump-${TCPDUMP_VERSION}/tcpdump"
  [[ -f "$built" ]] || fail "tcpdump was not produced"
  "$strip" --strip-all "$built"
  cp "$built" "$OUT/out/libfloecapture_helper.so"
  chmod 0755 "$OUT/out/libfloecapture_helper.so"

  command -v "$PYTHON" >/dev/null 2>&1 || fail "python3 is required for helper verification"
  log "verify ELF and write manifest"
  "$PYTHON" "$SCRIPT_DIR/verify-helper.py" \
    --binary "$OUT/out/libfloecapture_helper.so" \
    --write-manifest "$OUT/out/helper.json" \
    --source "tcpdump-${TCPDUMP_VERSION}:$TCPDUMP_SHA" \
    --source "libpcap-${LIBPCAP_VERSION}:$LIBPCAP_SHA" \
    --guard-source "$guard_source_sha" \
    --guard-header "$guard_header_sha" \
    --guard-patch "$guard_patch_sha" \
    --ndk-version "$NDK_VERSION"

  if [[ "$STAGE" == "1" ]]; then
    log "stage Full APK native library, asset manifest and notices"
    "$PYTHON" "$SCRIPT_DIR/stage-helper.py" \
      --repo-root "$REPO_ROOT" \
      --binary "$OUT/out/libfloecapture_helper.so" \
      --manifest "$OUT/out/helper.json"
  fi

  log "done: $OUT/out/libfloecapture_helper.so"
}

main "$@"
