// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

/**
 * Conservative kernel gate for the bulk rootfs durability barrier.
 *
 * Linux man-pages sync(2) HISTORY (syncfs(2)): before Linux 5.8, syncfs()
 * reports only EBADF and does NOT report writeback errors; from 5.8 it reports
 * inode writeback errors. Therefore the bulk barrier may replace per-file
 * fsync only when the RUNNING kernel actually reports those errors. Unknown,
 * unparsable and older kernels keep the original per-file fsync path (Android 9
 * and older Samsung kernels included). This is a measured `uname -r` fact, not
 * an SDK/version assumption.
 */
internal fun reportsSyncfsWritebackErrors(kernelRelease: String): Boolean {
    val match = Regex("^(\\d+)\\.(\\d+)").find(kernelRelease) ?: return false
    val major = match.groupValues[1].toIntOrNull() ?: return false
    val minor = match.groupValues[2].toIntOrNull() ?: return false
    return major > 5 || (major == 5 && minor >= 8)
}
