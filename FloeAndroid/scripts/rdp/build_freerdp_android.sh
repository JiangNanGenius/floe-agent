#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
#
# Build the pinned FreeRDP 3.31.1 core (FreeRDP + WinPR) as static Android
# ARM64 libraries against the pinned OpenSSL prefix. Clients, servers, X11,
# SDL, FFmpeg/SWScale, channels and every optional codec are disabled: the
# Floe bridge only uses the RDP core, GDI framebuffer and input API.
#
# This is a serialized native-dependency build. It is never run by a source
# lane, an ordinary Gradle build or an App device step.
set -euo pipefail

source_dir="${1:?extracted freerdp-3.31.1 source directory required}"
prefix="${2:?absolute install prefix required}"
openssl_prefix="${3:?absolute OpenSSL prefix required}"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ndk" || ! -d "$ndk" ]]; then
  echo "ANDROID_NDK_HOME/ANDROID_NDK_ROOT must point at NDK 30.0.16248370" >&2
  exit 2
fi
if [[ "$prefix" != /* || "$openssl_prefix" != /* ]]; then
  echo "install prefixes must be absolute" >&2
  exit 2
fi
if [[ ! -f "$source_dir/CMakeLists.txt" || ! -f "$source_dir/LICENSE" ]]; then
  echo "not a FreeRDP source tree: $source_dir" >&2
  exit 2
fi
if [[ "$(tr -d '[:space:]' < "$source_dir/.source_tag" 2>/dev/null)" != "3.31.1" ]]; then
  echo "FreeRDP source is not the pinned 3.31.1 release" >&2
  exit 2
fi
if [[ ! -f "$openssl_prefix/lib/libssl.a" || ! -f "$openssl_prefix/lib/libcrypto.a" ]]; then
  echo "OpenSSL static prefix is incomplete: $openssl_prefix" >&2
  exit 2
fi
if [[ "${JOBS:-6}" -lt 1 || "${JOBS:-6}" -gt 6 ]]; then
  echo "JOBS must be 1..6 (serialized native dependency build)" >&2
  exit 2
fi

build="$prefix/build"
mkdir -p "$build" "$prefix/lib" "$prefix/include"

cmake -S "$source_dir" -B "$build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DWITH_CLIENT=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_CHANNELS=OFF \
  -DWITH_CLIENT_COMMON=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_X11=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_SWSCALE_LOADING=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_PULSE=OFF \
  -DWITH_ALSA=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_URIPARSER=OFF \
  -DWITH_CJSON=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_PNG=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_WEBP=OFF \
  -DWITH_KRB5=OFF \
  -DWITH_SDL_IMAGE=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_SHADOW=OFF \
  -DWITH_PLATFORM_SERVER=OFF \
  -DWITH_OPENSSL=ON \
  -DWITH_MBEDTLS=OFF \
  -DOPENSSL_ROOT_DIR="$openssl_prefix" \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a" \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF

cmake --build "$build" --target freerdp winpr --parallel "${JOBS:-6}"
cmake --install "$build"

for library in libfreerdp3.a libwinpr3.a; do
  if [[ ! -f "$prefix/lib/$library" ]]; then
    echo "missing built library: $prefix/lib/$library" >&2
    exit 1
  fi
  file "$prefix/lib/$library"
done
if [[ -e "$prefix/lib/libfreerdp-client3.a" ]]; then
  echo "client library unexpectedly built; this lane only ships the core" >&2
  exit 1
fi
echo "FreeRDP 3.31.1 Android ARM64 static prefix: $prefix"
echo "Set FLOE_FREERDP_PREFIX=$prefix before the SwiftPM Android build."
