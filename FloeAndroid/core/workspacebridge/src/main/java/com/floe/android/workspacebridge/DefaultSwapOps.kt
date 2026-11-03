// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.os.ParcelFileDescriptor
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

    private data class ParentAnchor(val descriptor: ParcelFileDescriptor, val leaf: String) : java.io.Closeable {
        override fun close() = descriptor.close()
        val path: String get() = "/proc/self/fd/${descriptor.fd}/$leaf"
    }

    private fun parentAnchor(root: File, relativePath: String, createParents: Boolean): ParentAnchor {
        val parts = WorkspaceRelativeValidation.validate(relativePath)
            ?: throw IllegalArgumentException("inputPathInvalid")
        // O_DIRECTORY is not exposed by Android's public OsConstants. Validate
        // the opened descriptor itself; NONBLOCK also refuses a FIFO race
        // without waiting for a writer.
        val flags = OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or
            OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC
        fun ownedDirectory(path: String): ParcelFileDescriptor {
            val fd = Os.open(path, flags, 0)
            return try {
                check(OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) { "inputParentNotDirectory" }
                ParcelFileDescriptor.dup(fd)
            } finally { Os.close(fd) }
        }
        var cursor = ownedDirectory(root.absolutePath)
        try {
            for (part in parts.dropLast(1)) {
                val child = "/proc/self/fd/${cursor.fd}/$part"
                if (createParents) {
                    try { Os.mkdir(child, WorkspaceFileModes.DIR_DEFAULT) }
                    catch (error: ErrnoException) { if (error.errno != OsConstants.EEXIST) throw error }
                }
                val next = ownedDirectory(child)
                cursor.close()
                cursor = next
            }
            return ParentAnchor(cursor, parts.last())
        } catch (error: Exception) {
            cursor.close()
            throw error
        }
    }

    override fun kindNoFollow(root: File, relativePath: String): SwapKind = try {
        parentAnchor(root, relativePath, false).use { anchor -> kind(File(anchor.path)) }
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) SwapKind.MISSING else SwapKind.UNREADABLE
    } catch (_: Exception) { SwapKind.UNREADABLE }

    private fun commitNew(root: File, relativePath: String, install: (String) -> Unit): Boolean {
        var committed = false
        return try {
            parentAnchor(root, relativePath, true).use { anchor ->
                install(anchor.path)
                committed = true
                Os.fsync(anchor.descriptor.fileDescriptor)
                true
            }
        } catch (error: Exception) {
            // A link/mkdir succeeded but its durability could not be proved.
            // Keep the new entry (a live guest may already use it), fail the
            // transfer, and never misreport it as a concurrent retained file.
            if (committed) throw WorkspaceSwapException("inputCommitUncertain")
            false
        }
    }

    override fun installNewFile(stage: File, root: File, relativePath: String): Boolean {
        val source = try { Os.lstat(stage.absolutePath) } catch (_: Exception) { return false }
        if (!OsConstants.S_ISREG(source.st_mode)) return false
        // The source is our private import journal, never a guest path.
        // link() atomically refuses an existing destination.
        return commitNew(root, relativePath) { target -> Os.link(stage.absolutePath, target) }
    }

    override fun createNewDirectory(root: File, relativePath: String): Boolean =
        commitNew(root, relativePath) { target -> Os.mkdir(target, WorkspaceFileModes.DIR_DEFAULT) }

    override fun createNewSymlink(root: File, relativePath: String, target: String): Boolean =
        commitNew(root, relativePath) { destination -> Os.symlink(target, destination) }

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
