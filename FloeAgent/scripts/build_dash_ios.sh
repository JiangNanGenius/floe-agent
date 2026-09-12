#!/bin/bash
# Build the existing iOS dash port against Floe's pinned ios_system ABI.
set -euo pipefail
floe_root="$(cd "$(dirname "$0")/.." && pwd)"
floe_source="$floe_root/ThirdParty/DashIOS"
floe_work="${FLOE_DASH_BUILD_ROOT:-/tmp/floe-dash-build}"
floe_engine="$floe_root/ThirdParty/FloeShellEngine/.build/artifacts/floeshellengine/ios_system/ios_system.xcframework"
mkdir -p "$floe_work" "$floe_root/Frameworks"
if [ ! -d "$floe_engine" ]; then
  swift package --package-path "$floe_root/ThirdParty/FloeShellEngine" resolve
fi
floe_aux="$(automake --print-libdir)"
if [ -L "$floe_work/source" ]; then unlink "$floe_work/source"; fi
mkdir -p "$floe_work/source"
cp -Rp "$floe_source/" "$floe_work/source/"
for floe_helper in compile missing install-sh config.guess config.sub depcomp; do
  cp "$floe_aux/$floe_helper" "$floe_work/source/$floe_helper"
done
touch "$floe_work/source/aclocal.m4" "$floe_work/source/configure" "$floe_work/source/config.h.in" "$floe_work/source/Makefile.in" "$floe_work/source/src/Makefile.in"
for floe_sdk in iphoneos iphonesimulator; do
  floe_sdkroot="$(xcrun --sdk "$floe_sdk" --show-sdk-path)"
  floe_osxroot="$(xcrun --sdk macosx --show-sdk-path)"
  floe_target=arm64-apple-ios26.0
  floe_slice=ios-arm64
  if [ "$floe_sdk" = iphonesimulator ]; then
    floe_target=arm64-apple-ios26.0-simulator
    floe_slice=ios-arm64_x86_64-simulator
  fi
  floe_build="$floe_work/$floe_sdk"
  mkdir -p "$floe_build"
  # Autoconf's compiler flag handling does not preserve paths containing spaces.
  ln -sfn "$floe_engine" "$floe_work/ios_system.xcframework"
  (
    cd "$floe_build"
    /bin/sh "$floe_work/source/configure" \
      CC="$(xcrun --find clang)" \
      CC_FOR_BUILD="$(xcrun --find clang) -isysroot $floe_osxroot -DJOBS=0" \
      CFLAGS="-target $floe_target -isysroot $floe_sdkroot -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$floe_work/source" \
      LDFLAGS="-target $floe_target -isysroot $floe_sdkroot -dynamiclib -F $floe_work/ios_system.xcframework/$floe_slice -framework ios_system" \
      --build=aarch64-apple-darwin --host=aarch64-apple-darwin --with-libedit cross_compiling=yes > configure.log 2>&1
    make -j2 > build.log 2>&1
  )
  for floe_name in dash dashA dashB dashC dashD dashE; do
    floe_framework="$floe_build/$floe_name.framework"
    mkdir -p "$floe_framework/Headers"
    cp "$floe_build/src/dash" "$floe_framework/$floe_name"
    floe_plist=basic_Info.plist
    if [ "$floe_sdk" = iphonesimulator ]; then floe_plist=basic_Info_Simulator.plist; fi
    cp "$floe_source/$floe_plist" "$floe_framework/Info.plist"
    plutil -replace CFBundleExecutable -string "$floe_name" "$floe_framework/Info.plist"
    plutil -replace CFBundleName -string "$floe_name" "$floe_framework/Info.plist"
    plutil -replace CFBundleIdentifier -string "dev.floe.$floe_name" "$floe_framework/Info.plist"
    install_name_tool -id "@rpath/$floe_name.framework/$floe_name" "$floe_framework/$floe_name"
  done
done
for floe_name in dash dashA dashB dashC dashD dashE; do
  floe_output="$floe_root/Frameworks/$floe_name.xcframework"
  # xcodebuild requires an absent output; only remove our generated framework.
  if [ -d "$floe_output" ]; then rm -rf "$floe_output"; fi
  xcodebuild -create-xcframework -framework "$floe_work/iphoneos/$floe_name.framework" -framework "$floe_work/iphonesimulator/$floe_name.framework" -output "$floe_output"
done
