// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes

/** Inspect the actual inode type without following guest links. rdev == 0
 * also describes a major-zero/minor-zero device, so it is not type proof. */
internal fun isGuestRuntimeEndpoint(path: Path, attrs: BasicFileAttributes): Boolean {
    if (!attrs.isOther) return false
    val mode = (runCatching { Files.getAttribute(path, "unix:mode", NOFOLLOW_LINKS) }
        .getOrNull() as? Number)?.toInt() ?: return false
    return when (mode and 0xF000) {
        0x1000, 0xC000 -> true // FIFO or Unix socket; never a device node.
        else -> false
    }
}

/**
 * Typed, closed-vocabulary refusal/failure of a rootfs layer materialization.
 * It is an IllegalStateException so every historical `catch`/assert on the
 * materializer's illegal-state failures keeps working, while the bounded
 * [code] lets the runtime kernel publish an actionable stage/type token
 * (never a path, identifier, command or arbitrary native text) on a failed
 * start receipt.
 *
 * Codes are a FIXED reviewed set. The [cause] chain may carry the original
 * IOException (including its path text) for debugger inspection only; no
 * Floe log line, receipt field or UI string ever reads it.
 */
class RootfsMaterializeException(
    val code: String,
    cause: Throwable? = null,
    val operation: String? = null,
    val sourceMode: Int? = null,
    val sourceOwnerUid: Int? = null,
    val sourceIsDirectory: Boolean? = null,
) : IllegalStateException("Rootfs materialization refused: $code", cause) {

    init {
        require(code in CODES) { "Unknown rootfs materialization code" }
        require(operation == null || operation in setOf("walk", "remove", "mkdir", "stat", "symlink",
            "hardlink", "open_input", "open_output", "read", "write", "force_file", "mode", "timestamp", "force_dir"))
        require(sourceMode == null || sourceMode in 0..0xFFF)
        require(sourceOwnerUid == null || sourceOwnerUid >= 0)
    }

    companion object {
        /**
         * The only tokens that may ever reach a receipt/log. Each names the
         * stage family and the refusal kind; all are lowercase snake-case,
         * printable ASCII, well inside the 48-char receipt ceiling:
         *  - rootfs_copy_io: filesystem I/O failed while copying a layer
         *    (open/read/write/fsync/directory fsync/readdir).
         *  - rootfs_copy_unsupported_entry: a layer entry that is neither a
         *    directory, regular file, symlink nor a skippable guest runtime
         *    endpoint (socket/FIFO): currently a device node.
         *  - rootfs_copy_symlink_refused: a higher layer would have to write
         *    through a guest symlink already staged by a lower layer.
         *  - rootfs_copy_entry_budget / rootfs_copy_byte_budget: bounded copy
         *    budgets exhausted.
         *  - rootfs_marker_mismatch: the writable layer carries a marker for
         *    a DIFFERENT environment/base; an explicit rebuild is required
         *    (user files are never silently reset).
         *  - rootfs_barrier_io: the single durability barrier failed.
         *  - rootfs_publish_io: marker/journal write or the atomic layer
         *    publication renames failed.
         *  - rootfs_snapshot_unsupported: an environment-transaction
         *    image found a non-materializable entry (same policy as copy).
         */
        val CODES: Set<String> = setOf(
            "rootfs_copy_io",
            "rootfs_copy_unsupported_entry",
            "rootfs_copy_symlink_refused",
            "rootfs_copy_entry_budget",
            "rootfs_copy_byte_budget",
            "rootfs_marker_mismatch",
            "rootfs_barrier_io",
            "rootfs_publish_io",
            "rootfs_snapshot_unsupported",
        )

        internal const val CODE_ROOTFS_COPY_IO = "rootfs_copy_io"
        internal const val CODE_ROOTFS_COPY_UNSUPPORTED = "rootfs_copy_unsupported_entry"
        internal const val CODE_ROOTFS_COPY_SYMLINK = "rootfs_copy_symlink_refused"
        internal const val CODE_ROOTFS_COPY_ENTRY_BUDGET = "rootfs_copy_entry_budget"
        internal const val CODE_ROOTFS_COPY_BYTE_BUDGET = "rootfs_copy_byte_budget"
        internal const val CODE_ROOTFS_MARKER_MISMATCH = "rootfs_marker_mismatch"
        internal const val CODE_ROOTFS_BARRIER_IO = "rootfs_barrier_io"
        internal const val CODE_ROOTFS_PUBLISH_IO = "rootfs_publish_io"
        internal const val CODE_ROOTFS_SNAPSHOT_UNSUPPORTED = "rootfs_snapshot_unsupported"
    }
}

/**
 * Cancellation of a rootfs preparation (user stop, foreground-permit loss or
 * a sibling admission change). This is an honest LIFECYCLE refusal, kept
 * distinct from materialization DEFECTS so it can never be misreported as a
 * rootfs failure — while staying an InterruptedException subclass so every
 * historical caller and test contract on preparation cancellation keeps
 * working unchanged.
 */
class RootfsPrepareCancelledException(
    message: String = "Rootfs preparation cancelled",
) : InterruptedException(message)
