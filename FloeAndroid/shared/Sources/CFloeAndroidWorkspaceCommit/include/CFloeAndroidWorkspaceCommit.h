// SPDX-License-Identifier: MPL-2.0
#ifndef CFLOE_ANDROID_WORKSPACE_COMMIT_H
#define CFLOE_ANDROID_WORKSPACE_COMMIT_H

/// Rename between pinned directory descriptors without replacing a destination.
/// Uses standard POSIX status and errno values.
int floe_workspace_rename_no_replace(int source_directory, const char *source_name,
                                     int target_directory, const char *target_name);

#endif
