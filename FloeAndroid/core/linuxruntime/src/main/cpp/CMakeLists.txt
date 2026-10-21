cmake_minimum_required(VERSION 3.18)
project(floe_linuxruntime CXX C)

# JNI PTY transport library (bionic only, no third-party code).
add_library(floepty SHARED floe_pty_jni.c)

find_library(log-lib log)
target_link_libraries(floepty PRIVATE ${log-lib})

# 16 KiB page alignment is mandatory for API 35+ 16 KB devices (and harmless
# on 4 KB devices). NDK r30 already defaults to 16 KB; pin it explicitly so a
# future NDK default change cannot silently regress the layout.
target_link_options(floepty PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")

# The probe executable is built by native-build/build-probe.sh with the NDK
# toolchain directly (it must be a static, dependency-free ELF shipped as a
# jniLibs .so payload), so it is intentionally NOT an externalNativeBuild
# target here.
