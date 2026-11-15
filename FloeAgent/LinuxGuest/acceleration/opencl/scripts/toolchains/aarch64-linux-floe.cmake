# CMake toolchain template for the Floe ARM64 Debian 13 OpenCL build.
# No build was run with this file in the source phase.
#
# Set FLOE_SYSROOT for the Debian trixie arm64 sysroot.
# Set FLOE_CROSS_CC/FLOE_CROSS_CXX for a GNU cross compiler, or use the known
# Apple clang target by also setting FLOE_CROSS_FLAGS.
#
# Example (Apple clang, as used for the prior C probe):
#   FLOE_SYSROOT=.../debian-trixie-arm64 \
#   FLOE_CROSS_CC=/usr/bin/clang FLOE_CROSS_CXX=/usr/bin/clang++ \
#   FLOE_CROSS_FLAGS="--target=aarch64-unknown-linux-gnu -fuse-ld=lld" \
#   cmake -DCMAKE_TOOLCHAIN_FILE=.../aarch64-linux-floe.cmake ...
#
# A GNU aarch64-linux-gnu toolchain is the preferred build host route. This
# file does not download or install a compiler.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(DEFINED ENV{FLOE_SYSROOT})
  set(FLOE_SYSROOT "$ENV{FLOE_SYSROOT}" CACHE PATH "Debian trixie arm64 sysroot")
endif()
if(NOT FLOE_SYSROOT)
  message(FATAL_ERROR "FLOE_SYSROOT must name the Debian trixie arm64 sysroot")
endif()
if(NOT IS_DIRECTORY "${FLOE_SYSROOT}/usr/include")
  message(FATAL_ERROR "FLOE_SYSROOT lacks usr/include: ${FLOE_SYSROOT}")
endif()

set(CMAKE_SYSROOT "${FLOE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${FLOE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

if(DEFINED ENV{FLOE_CROSS_CC} AND NOT "$ENV{FLOE_CROSS_CC}" STREQUAL "")
  set(CMAKE_C_COMPILER "$ENV{FLOE_CROSS_CC}")
elseif(EXISTS "/usr/bin/aarch64-linux-gnu-gcc")
  set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
else()
  message(FATAL_ERROR "set FLOE_CROSS_CC or install aarch64-linux-gnu-gcc")
endif()

if(DEFINED ENV{FLOE_CROSS_CXX} AND NOT "$ENV{FLOE_CROSS_CXX}" STREQUAL "")
  set(CMAKE_CXX_COMPILER "$ENV{FLOE_CROSS_CXX}")
elseif(EXISTS "/usr/bin/aarch64-linux-gnu-g++")
  set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
else()
  message(FATAL_ERROR "set FLOE_CROSS_CXX or install aarch64-linux-gnu-g++")
endif()

if(DEFINED ENV{FLOE_CROSS_FLAGS} AND NOT "$ENV{FLOE_CROSS_FLAGS}" STREQUAL "")
  set(CMAKE_C_FLAGS_INIT "$ENV{FLOE_CROSS_FLAGS}")
  set(CMAKE_CXX_FLAGS_INIT "$ENV{FLOE_CROSS_FLAGS}")
endif()
if(DEFINED ENV{FLOE_CROSS_LDFLAGS} AND NOT "$ENV{FLOE_CROSS_LDFLAGS}" STREQUAL "")
  set(CMAKE_EXE_LINKER_FLAGS_INIT "$ENV{FLOE_CROSS_LDFLAGS}")
  set(CMAKE_SHARED_LINKER_FLAGS_INIT "$ENV{FLOE_CROSS_LDFLAGS}")
endif()

# Optional qemu only if the caller explicitly supplies it.
if(DEFINED ENV{FLOE_CROSS_EMULATOR} AND NOT "$ENV{FLOE_CROSS_EMULATOR}" STREQUAL "")
  set(CMAKE_CROSSCOMPILING_EMULATOR "$ENV{FLOE_CROSS_EMULATOR}")
endif()
