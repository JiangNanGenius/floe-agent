/* Replacement for Linux <sys/statfs.h> for macOS local smoke builds of
 * TinyEMU 2019-12-21 (build-flag-only via -I; pristine sources untouched).
 * macOS provides statfs(2) and struct statfs via <sys/mount.h>.
 */
#ifndef TINYEMU_MACOS_SYS_STATFS_H
#define TINYEMU_MACOS_SYS_STATFS_H
#include <sys/param.h>
#include <sys/mount.h>
#endif
