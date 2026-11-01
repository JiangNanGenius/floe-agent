#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
#
# Build the pinned OpenSSL static libraries for Android ARM64 API 28.
# This is a deliberate, serialized native-dependency build, never part of an
# ordinary App/Gradle build. The caller supplies the extracted source tree and
# an install prefix. The script refuses a different source release.
set -euo pipefail

source_dir="${1:?extracted openssl-4.0.1 source directory required}"
prefix="${2:?absolute install prefix required}"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ndk" || ! -d "$ndk" ]]; then
  echo "ANDROID_NDK_HOME/ANDROID_NDK_ROOT must point at NDK 30.0.16248370" >&2
  exit 2
fi
if [[ "$prefix" != /* ]]; then
  echo "install prefix must be absolute" >&2
  exit 2
fi
if [[ ! -f "$source_dir/Configure" ]]; then
  echo "not an OpenSSL source tree: $source_dir" >&2
  exit 2
fi
if ! grep -qx 'MAJOR=4' "$source_dir/VERSION.dat" 2>/dev/null ||
   ! grep -qx 'MINOR=0' "$source_dir/VERSION.dat" 2>/dev/null ||
   ! grep -qx 'PATCH=1' "$source_dir/VERSION.dat" 2>/dev/null; then
  echo "OpenSSL source is not the pinned 4.0.1 release" >&2
  exit 2
fi
if [[ "${JOBS:-6}" -lt 1 || "${JOBS:-6}" -gt 6 ]]; then
  echo "JOBS must be 1..6 (serialized native dependency build)" >&2
  exit 2
fi

host_tag="android-arm64"
work="$(mktemp -d "${TMPDIR:-/tmp}/floe-openssl.XXXXXX")"
trap 'rm -rf "$work"' EXIT

export ANDROID_NDK_ROOT="$ndk"
export ANDROID_NDK_HOME="$ndk"
(
  cd "$source_dir"
  PATH="$ndk/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin:$PATH" \
    ./Configure "$host_tag" \
      -D__ANDROID_API__=28 \
      no-shared no-tests no-apps no-docs no-module \
      --prefix="$prefix" \
      --openssldir="$prefix/ssl"
  make -j"${JOBS:-6}" build_sw
  make install_sw DESTDIR=
)

mkdir -p "$prefix/lib"
for library in libcrypto.a libssl.a; do
  if [[ ! -f "$prefix/lib/$library" ]]; then
    echo "missing built library: $prefix/lib/$library" >&2
    exit 1
  fi
  file "$prefix/lib/$library"
done
echo "OpenSSL 4.0.1 Android ARM64 static prefix: $prefix"
