#!/usr/bin/env bash
#
# build_occt_ios.sh — reproducible OCCT.xcframework build for iOS (spike M0).
#
# Cross-compiles a MINIMAL headless OCCT (modeling only — no visualization,
# no Draw, no third-party deps) for iOS device + simulator and assembles a
# single-static-lib-per-slice xcframework at ThirdParty/OCCT.xcframework.
#
# Modules built: FoundationClasses (TKernel, TKMath), ModelingData (TKG2d,
# TKG3d, TKGeomBase, TKBRep), ModelingAlgorithms (TKGeomAlgo, TKTopAlgo,
# TKPrim, TKBO, TKBool, TKFillet, TKOffset, TKMesh, TKShHealing, …) — 18
# toolkits, everything the B-rep port needs (extrude/boolean/fillet/shell/mesh).
#
# DataExchange (STEP/IGES) + ApplicationFramework (XDE) are ON — spec §12 needs
# STEP interchange. They roughly double the static lib (18→47 toolkits,
# ~74MB→~140MB/arch, measured); flip both to OFF for a modeling-only build if
# binary size ever matters more than interchange.
#
# Prereqs: cmake (>=3.16; tested with 4.4), Xcode with iOS SDK, an OCCT source
# tree, and the leetal ios-cmake toolchain file. Paths are passed via env:
#
#   OCCT_SRC=/path/to/OCCT-7_8_1 \
#   IOS_TOOLCHAIN=/path/to/ios.toolchain.cmake \
#   WORK=/path/to/build-scratch \
#   PLATFORMS="SIMULATORARM64 OS64" \
#   scripts/build_occt_ios.sh
#
# ADDING a slice to the existing xcframework (e.g. Mac Catalyst for the desktop
# build) without rebuilding the ones you already have — the whole point of
# REUSE_EXISTING_SLICES, since assembling an xcframework REPLACES it and a
# Catalyst-only run would otherwise delete both iOS slices:
#
#   PLATFORMS="MAC_CATALYST_ARM64" REUSE_EXISTING_SLICES=1 \
#   OCCT_SRC=… IOS_TOOLCHAIN=… scripts/build_occt_ios.sh
#
# Catalyst note: DEPLOYMENT_TARGET is an iOS version (Catalyst is versioned on
# the iOS scale), so it must stay <= the app's IPHONEOS_DEPLOYMENT_TARGET.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCCT_SRC="${OCCT_SRC:?set OCCT_SRC to the extracted OCCT source dir}"
IOS_TOOLCHAIN="${IOS_TOOLCHAIN:?set IOS_TOOLCHAIN to ios.toolchain.cmake}"
WORK="${WORK:-$REPO_ROOT/.occt-build}"
PLATFORMS="${PLATFORMS:-SIMULATORARM64 OS64}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-16.0}"
OUT_XCFRAMEWORK="$REPO_ROOT/ThirdParty/OCCT.xcframework"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
# Carry the slices already in OUT_XCFRAMEWORK into the new one, so a run that
# builds a single platform ADDS to the framework instead of replacing it.
REUSE_EXISTING_SLICES="${REUSE_EXISTING_SLICES:-0}"

echo "OCCT_SRC=$OCCT_SRC"
echo "WORK=$WORK  PLATFORMS=$PLATFORMS  JOBS=$JOBS"

mkdir -p "$WORK"
declare -a CREATE_ARGS=()

# Harvest the existing slices FIRST — the assembly step deletes the framework,
# so the libs and headers have to be copied out beforehand.
if [ "$REUSE_EXISTING_SLICES" = "1" ] && [ -d "$OUT_XCFRAMEWORK" ]; then
  STAGE="$WORK/existing-slices"
  rm -rf "$STAGE"
  for SLICE in "$OUT_XCFRAMEWORK"/*/; do
    NAME="$(basename "$SLICE")"
    LIB="$(find "$SLICE" -maxdepth 1 -name '*.a' | head -1)"
    [ -n "$LIB" ] || continue
    [ -d "$SLICE/Headers" ] || continue
    mkdir -p "$STAGE/$NAME"
    cp "$LIB" "$STAGE/$NAME/"
    cp -R "$SLICE/Headers" "$STAGE/$NAME/Headers"
    CREATE_ARGS+=( -library "$STAGE/$NAME/$(basename "$LIB")" -headers "$STAGE/$NAME/Headers" )
    echo "==> Reusing existing slice: $NAME"
  done
fi

for PLAT in $PLATFORMS; do
  BUILD_DIR="$WORK/build-$PLAT"
  INSTALL_DIR="$WORK/install-$PLAT"
  rm -rf "$BUILD_DIR" "$INSTALL_DIR"
  mkdir -p "$BUILD_DIR"

  echo "=================================================================="
  echo "==> Configuring OCCT for $PLAT"
  echo "=================================================================="
  cmake -S "$OCCT_SRC" -B "$BUILD_DIR" \
    -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$IOS_TOOLCHAIN" \
    -DPLATFORM="$PLAT" \
    -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=OFF \
    -DENABLE_VISIBILITY=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DBUILD_LIBRARY_TYPE=Static \
    -DBUILD_CPP_STANDARD=C++17 \
    -DBUILD_MODULE_FoundationClasses=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_ApplicationFramework=ON \
    -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_DETools=OFF \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_DOC_Overview=OFF \
    -DUSE_FREETYPE=OFF -DUSE_TK=OFF -DUSE_TCL=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_EIGEN=OFF \
    -DUSE_FREEIMAGE=OFF -DUSE_FFMPEG=OFF -DUSE_TBB=OFF \
    -DUSE_VTK=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF \
    -DUSE_XLIB=OFF -DUSE_OPENVR=OFF -DUSE_D3D=OFF

  echo "==> Building OCCT for $PLAT (jobs=$JOBS)"
  cmake --build "$BUILD_DIR" --config Release --target install -- -j"$JOBS"

  # Merge all per-toolkit static libs into a single libOCCT.a for this slice.
  LIBDIR="$(find "$INSTALL_DIR" -name 'libTKernel.a' -exec dirname {} \; | head -1)"
  INCDIR="$(find "$INSTALL_DIR" -type d -name 'inc' -o -type d -name 'include' | head -1)"
  echo "==> Slice libs in: $LIBDIR"
  echo "==> Slice headers in: $INCDIR"
  MERGED="$WORK/libOCCT-$PLAT.a"
  libtool -static -o "$MERGED" "$LIBDIR"/libTK*.a
  echo "==> Merged $(ls "$LIBDIR"/libTK*.a | wc -l | tr -d ' ') toolkits -> $MERGED ($(du -h "$MERGED" | cut -f1))"

  CREATE_ARGS+=( -library "$MERGED" -headers "$INCDIR" )
done

echo "=================================================================="
echo "==> Assembling $OUT_XCFRAMEWORK"
echo "=================================================================="
rm -rf "$OUT_XCFRAMEWORK"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$OUT_XCFRAMEWORK"
echo "==> Done: $OUT_XCFRAMEWORK"
du -sh "$OUT_XCFRAMEWORK"
