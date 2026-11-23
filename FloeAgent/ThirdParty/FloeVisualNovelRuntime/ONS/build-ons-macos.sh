#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <patched ONSlaught checkout> <output directory>" >&2
    exit 64
fi
source_root="$(cd "$1/trunk" && pwd -P)"
mkdir -p "$2"
output_root="$(cd "$2" && pwd -P)"
mkdir -p "$output_root/objects"
brew_prefix="${FLOE_ONS_BREW_PREFIX:-/opt/homebrew}"
clang="$(xcrun -f clang)"
clangxx="$(xcrun -f clang++)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

common_flags=(
    -isysroot "$sdk"
    -O1 -DHAVE_INTTYPES_H -DBUILD_ONSLAUGHT -DNONS_SVN
    "-I$source_root/src"
    "-I$brew_prefix/opt/sdl12-compat/include"
    "-I$brew_prefix/opt/libpng/include/libpng16"
    "-I$source_root/include"
    "-I$brew_prefix/opt/freetype/include/freetype2"
    "-I$brew_prefix/include"
)
sources=(
    src/Archive.cpp
    src/Audio.cpp
    src/AudioFormats.cpp
    src/ErrorCodes.cpp
    src/ExpressionParser.tab.cpp
    src/FileLog.cpp
    src/floe_image_loader.cpp
    src/Functions.cpp
    src/GFX.cpp
    src/GUI.cpp
    src/Image.cpp
    src/INIfile.cpp
    src/INIParser.tab.cpp
    src/IOFunctions.cpp
    src/libFLAC++/metadata.cpp
    src/libFLAC++/stream_decoder.cpp
    src/libFLAC++/stream_encoder.cpp
    src/LZMA.c
    src/ONSlaught.cpp
    src/OpenAL.cpp
    src/Options.cpp
    src/Plugin/LibraryLoader.cpp
    src/ScreenSpace.cpp
    src/Script.cpp
    src/ScriptInterpreter.cpp
    src/sha1.cpp
    src/SJIS.table.cpp
    src/Thread.cpp
    src/ThreadManager.cpp
    src/tinyxml/tinyxml.cpp
    src/tinyxml/tinyxmlerror.cpp
    src/tinyxml/tinyxmlparser.cpp
    src/VariableStore.cpp
    src/VirtualScreen.cpp
)
objects=()
for source in "${sources[@]}"; do
    object="$output_root/objects/${source//\//_}.o"
    objects+=("$object")
    if [[ "$source" == *.c ]]; then
        "$clang" -std=c11 "${common_flags[@]}" -c "$source_root/$source" -o "$object"
    else
        "$clangxx" -std=c++11 -include SDL/SDL_mutex.h "${common_flags[@]}" \
            -c "$source_root/$source" -o "$object"
    fi
done

"$clangxx" -isysroot "$sdk" -std=c++11 "${objects[@]}" -o "$output_root/FloeONSRuntime" \
    "-L$brew_prefix/lib" -lSDLmain -lSDL -lfreetype -lFLAC -lFLAC++ \
    -lvorbisfile -lvorbis -logg -lmpg123 -lpng16 -ljpeg -lz -lbz2 \
    -framework OpenAL -framework Cocoa -framework Carbon -framework CoreFoundation
