// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.security.MessageDigest

/**
 * Production [WorkspaceSwapOps] on `android.system.Os`. Every open is
 * O_NOFOLLOW; renames stay within the runtime app-data filesystem (the
 * engine workspace and its sibling journal directory share the volume), so
 * each swap step is an atomic rename, never a copy-then-delete.
 */
class DefaultSwapOps : WorkspaceSwapOps {
    override fun kind(path: File): SwapKind = try {
        val stat = Os.lstat(path.absolutePath)
        when {
            OsConstants.S_ISREG(stat.st_mode) -> SwapKind.FILE
            OsConstants.S_ISDIR(stat.st_mode) -> SwapKind.DIRECTORY
            OsConstants.S_ISLNK(stat.st_mode) -> SwapKind.SYMLINK
            else -> SwapKind.OTHER
        }
    } catch (failure: ErrnoException) {
        if (failure.errno == OsConstants.ENOENT) SwapKind.MISSING else SwapKind.UNREADABLE
    } catch (_: Exception) {
        SwapKind.UNREADABLE
    }

    override fun size(path: File): Long = try {
        Os.lstat(path.absolutePath).st_size
    } catch (_: Exception) {
        -1
    }

    override fun rename(from: File, to: File): Boolean = try {
        Os.rename(from.absolutePath, to.absolutePath)
        true
    } catch (_: Exception) {
        false
    }

    override fun mkdir(path: File): Boolean = try {
        Os.mkdir(path.absolutePath, WorkspaceFileModes.DIR_DEFAULT)
        true
    } catch (_: ErrnoException) {
        false
    }

    // android.system.Os exposes remove() only (POSIX remove: unlink a file,
    // rmdir an EMPTY directory; a non-empty directory fails, which is exactly
    // the preserve-on-new-descendants behaviour the swap engine requires).
    override fun rmdir(path: File): Boolean = try {
        Os.remove(path.absolutePath)
        true
    } catch (_: ErrnoException) {
        false
    }

    override fun unlink(path: File): Boolean = try {
        Os.remove(path.absolutePath)
        true
    } catch (_: ErrnoException) {
        false
    }

    override fun symlink(target: String, path: File): Boolean = try {
        Os.symlink(target, path.absolutePath)
        true
    } catch (_: ErrnoException) {
        false
    }

    override fun streamDigest(path: File): Pair<String, Long>? {
        val fd = try {
            Os.open(path.absolutePath,
                    OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        } catch (_: Exception) {
            return null
        }
        try {
            val hasher = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(65_536)
            var total = 0L
            while (true) {
                val count = try {
                    Os.read(fd, buffer, 0, buffer.size)
                } catch (_: ErrnoException) {
                    return null
                }
                if (count == 0) break
                hasher.update(buffer, 0, count)
                total += count
            }
            return hasher.digest().joinToString("") { "%02x".format(it) } to total
        } finally {
            runCatching { Os.close(fd) }
        }
    }

    override fun freeBytes(path: File): Long = android.os.StatFs(path.absolutePath).availableBytes

    override fun fsyncDirectory(path: File) {
        val fd = try {
            Os.open(path.absolutePath, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC, 0)
        } catch (_: Exception) {
            return
        }
        try {
            runCatching { Os.fsync(fd) }
        } finally {
            runCatching { Os.close(fd) }
        }
    }
}
