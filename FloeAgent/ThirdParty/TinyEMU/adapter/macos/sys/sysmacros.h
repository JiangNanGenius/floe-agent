/* Replacement for Linux <sys/sysmacros.h> for macOS local smoke builds of
 * TinyEMU 2019-12-21 (build-flag-only via -I; pristine sources untouched).
 * macOS provides major()/minor()/makedev() via <sys/types.h>.
 */
#ifndef TINYEMU_MACOS_SYS_SYSMACROS_H
#define TINYEMU_MACOS_SYS_SYSMACROS_H
#include <sys/types.h>
#endif
