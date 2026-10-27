// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.File

/**
 * The module's ONE owned-descriptor helper for the PDF print/host open paths
 * (lane 14 repair). Every member used here was checked against the INSTALLED
 * public SDK (platforms/android-37.0/android.jar javap + data/api-versions.xml
 * via JDK 21 javap), not invented:
 *  - `ParcelFileDescriptor.MODE_RDONLY`, `MODE_NOFOLLOW` and `fileStatus`
 *    DO NOT EXIST on the public surface (the real constants are
 *    MODE_READ_ONLY / MODE_READ_WRITE / MODE_CREATE / MODE_TRUNCATE /
 *    MODE_APPEND / MODE_WRITE_ONLY / MODE_WORLD_*);
 *  - the real read-only + no-follow open shape is the three-argument
 *    `android.system.Os.open(String, int, int)` — there is NO public
 *    two-argument overload — with
 *    `OsConstants.O_RDONLY or O_CLOEXEC or O_NOFOLLOW` (public since 21/27/21)
 *    and mode 0 (ignored without O_CREAT);
 *  - adoption goes through the PUBLIC `ParcelFileDescriptor.dup(FileDescriptor)`
 *    (since 13; a kernel dup): the raw descriptor returned by `Os.open`
 *    stays OURS and is closed exactly once here, so from that point the
 *    [ParcelFileDescriptor] is the only owner and every error path closes
 *    ONLY what it still owns;
 *  - plain-regular + size identity is proven UNDER the descriptor with
 *    `Os.fstat` -> `StructStat.st_mode (int) / st_size (long)` and
 *    `OsConstants.S_ISREG(int)` (all public since 21), never a path stat —
 *    so no check can be re-pointed at another inode between open and verify.
 *
 * No hidden API, no reflection, no new dependency — and NO path re-open as
 * print authority: everything downstream reads through dups of the returned
 * descriptor only.
 */
object OfficePdfSourceAccess {

    /**
     * Opens [file] read-only, close-on-exec, NO-FOLLOW, then proves UNDER
     * the descriptor that it is a plain regular file whose size is exactly
     * [expectedBytes]. Returns null on ANY refusal (open ENOENT/EACCES/ELOOP,
     * dup failure, non-regular file, size drift), with every
     * partially-created descriptor closed exactly once. Never throws.
     */
    fun openPinnedReadOnly(file: File, expectedBytes: Long): ParcelFileDescriptor? {
        val raw = try {
            Os.open(
                file.path,
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                0,
            )
        } catch (_: Exception) {
            return null
        }
        val owned = try {
            ParcelFileDescriptor.dup(raw)
        } catch (_: Exception) {
            runCatching { Os.close(raw) }
            return null
        }
        // dup() took its own kernel reference: the raw descriptor stays OURS
        // and ends right here — nothing else ever touches it.
        runCatching { Os.close(raw) }
        if (!plainRegularUnder(owned, expectedBytes)) {
            runCatching { owned.close() }
            return null
        }
        return owned
    }

    /**
     * fstat identity under an ALREADY-OWNED descriptor: plain regular file
     * with EXACTLY [expectedBytes] (>= 1) length. Used at open above and
     * re-proven by the print adapter through the SAME pinned descriptor for
     * every layout/write pass (Main contract: never a path stat).
     */
    fun plainRegularUnder(fd: ParcelFileDescriptor, expectedBytes: Long): Boolean {
        if (expectedBytes < 1L) return false
        val status = try {
            Os.fstat(fd.fileDescriptor)
        } catch (_: Exception) {
            return false
        }
        return status.st_size == expectedBytes && OsConstants.S_ISREG(status.st_mode)
    }
}
