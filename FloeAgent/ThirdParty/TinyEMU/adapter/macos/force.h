/* Force-included compat shim (-include, build-flag-only) for macOS local
 * smoke builds of TinyEMU 2019-12-21. Pristine sources are NOT modified.
 * Maps Linux struct stat timestamp member names to macOS ones.
 */
#ifndef TINYEMU_MACOS_FORCE_H
#define TINYEMU_MACOS_FORCE_H
#ifdef __APPLE__
#include <sys/stat.h>
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif /* __APPLE__ */
#endif
