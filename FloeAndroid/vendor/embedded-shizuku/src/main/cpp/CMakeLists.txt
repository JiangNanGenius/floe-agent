cmake_minimum_required(VERSION 3.22)

project(floe_embedded_shizuku CXX)

# Produced from pinned sources only. No prebuilt executable, DEX, APK or
# unsigned native blob is checked into the repository. NDK 30 / CMake 3.22.1
# from TOOLCHAINS.md. Every produced shared object/executable is linked with a
# 16 KiB maximum page size for 16 KiB-page devices.
set(CMAKE_CXX_STANDARD 17)

add_compile_options(
        -fdata-sections
        -ffunction-sections
        -fno-exceptions
        -fno-rtti
        -fno-threadsafe-statics
        -Os
        -fvisibility=hidden
        -fvisibility-inlines-hidden)

add_link_options(
        -Wl,--gc-sections
        -Wl,--exclude-libs,ALL
        -Wl,-z,max-page-size=16384
        -Wl,-z,common-page-size=16384)

find_package(boringssl REQUIRED CONFIG)
find_package(cxx REQUIRED CONFIG)

# Executable named like a library, matching upstream Shizuku packaging: the
# Full APK extracts it into nativeLibraryDir and adb shell can execute it.
add_executable(libfloe_starter.so
        floe_starter.cpp
        floe_starter_ownership.cpp
        upstream/misc.cpp)

target_link_libraries(libfloe_starter.so log cxx::cxx)

# JNI pairing crypto: BoringSSL SPAKE2 + HKDF + AES-128-GCM, as upstream.
add_library(floe_adb_pairing SHARED
        floe_pairing_jni.cpp)

target_link_libraries(floe_adb_pairing log boringssl::crypto_static cxx::cxx)

if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_custom_command(TARGET libfloe_starter.so POST_BUILD
            COMMAND ${CMAKE_STRIP} --remove-section=.comment
            "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libfloe_starter.so")
    add_custom_command(TARGET floe_adb_pairing POST_BUILD
            COMMAND ${CMAKE_STRIP} --remove-section=.comment
            "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libfloe_adb_pairing.so")
endif ()

# Main must additionally verify the packaged binaries with
# llvm-readelf -lW (LOAD align 0x4000) and zipalign -c -P 16 on the final APK.
