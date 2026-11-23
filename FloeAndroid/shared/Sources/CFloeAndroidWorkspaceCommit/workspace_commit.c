// SPDX-License-Identifier: MPL-2.0
#define _GNU_SOURCE
#include "CFloeAndroidWorkspaceCommit.h"
#include <errno.h>

#if defined(__ANDROID__)
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

int floe_workspace_rename_no_replace(int source_directory, const char *source_name,
                                     int target_directory, const char *target_name) {
#if defined(__ANDROID__)
    // The Android 9 app syscall allowlist already includes renameat2.
    // Bionic's public wrapper is available beginning with API 30.
    return (int) syscall(SYS_renameat2, source_directory, source_name,
                         target_directory, target_name, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
