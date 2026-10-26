// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.WorkspaceSourceNative
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/** Read-only byte transport over the EXISTING native workspace authority.
 * Call on the service's IO dispatcher, never on the UI thread. A returned
 * file is an immutable input snapshot, not permission to save to its source.
 * The Office session owner retains/removes it after its native reader closes.
 */
internal class WorkspaceOfficeSnapshotStager(
    private val root: File,
    private val channel: Channel = NativeChannel,
) {
    data class Owner(val taskID: String, val workspaceID: String, val nativeEpoch: Long,
                     val hostGeneration: Long) {
        init {
            require(UUID.fromString(taskID).toString().equals(taskID, true))
            require(UUID.fromString(workspaceID).toString().equals(workspaceID, true))
            require(nativeEpoch > 0 && hostGeneration >= 0)
        }
    }

    data class Snapshot(
        val sessionID: String, val owner: Owner, val logicalPath: String,
        val file: File, val bytes: Long, val sha256: String,
        val sourceID: String?, val sourceRevision: String?,
    )

    class Failure(val code: String) : Exception(code)

    interface Channel {
        fun open(owner: Owner, path: String): Long
        fun info(ticket: Long, reply: ByteArray): Int
        fun read(ticket: Long, offset: Long, target: ByteArray): Int
        fun close(ticket: Long): Int
    }

    /** No provider grant, editor slot, Run or native write is minted here.
     * [isCurrent] must check this captured owner, not whichever task is now
     * selected. It also carries the service operation's cancellation fence.
     */
    fun stage(owner: Owner, relativePath: String, isCurrent: () -> Boolean): Snapshot {
        val parts = relativePath.split('/')
        val extension = relativePath.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension !in setOf("docx", "xlsx", "pptx") ||
            relativePath.length > 4096 || relativePath.any { it == '\\' || it.code < 32 } ||
            parts.any { it.isEmpty() || it == "." || it == ".." }) throw Failure("invalidOfficePath")
        fun checkOwner() {
            if (Thread.currentThread().isInterrupted || !isCurrent()) throw Failure("ownerChanged")
        }
        checkOwner()
        val ticket = try { channel.open(owner, relativePath) }
            catch (_: LinkageError) { throw Failure("sourceUnavailable") }
        if (ticket <= 0) throw Failure("sourceRefused:$ticket")
        var directory: File? = null
        var snapshot: Snapshot? = null
        var failure: Throwable? = null
        try {
            checkOwner()
            val info = SourceHostReply.call { channel.info(ticket, it) }
            if (!info.ok) throw Failure("snapshotInfoRefused:${info.status}")
            val bytes = info.number("bytes") ?: throw Failure("snapshotInfoMissing")
            val sha = info.text("sha256")
            if (bytes > MAX_BYTES) throw Failure("contentTooLarge")
            if (bytes !in 1..MAX_BYTES || !sha.matches(Regex("[0-9a-f]{64}")) ||
                info.text("logicalPath") != relativePath || info.text("mode") != "export") {
                throw Failure("invalidSnapshotInfo")
            }
            checkOwner()
            if ((!root.isDirectory && !root.mkdirs()) || Files.isSymbolicLink(root.toPath())) {
                throw Failure("snapshotStorageUnavailable")
            }
            val sessionID = UUID.randomUUID().toString()
            directory = File(root.canonicalFile, sessionID)
            Files.createDirectory(directory.toPath())
            val part = File(directory, "document.part")
            val file = File(directory, "document.$extension")
            val digest = MessageDigest.getInstance("SHA-256")
            FileChannel.open(part.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { output ->
                val page = ByteArray(CHUNK_BYTES)
                var offset = 0L
                while (offset < bytes) {
                    checkOwner()
                    val copied = channel.read(ticket, offset, page)
                    if (copied <= 0 || copied > page.size || copied > bytes - offset) {
                        throw Failure("invalidSnapshotChunk:$copied")
                    }
                    checkOwner()
                    digest.update(page, 0, copied)
                    val buffer = ByteBuffer.wrap(page, 0, copied)
                    while (buffer.hasRemaining()) output.write(buffer)
                    offset += copied
                }
                checkOwner()
                // Exact EOF matters as well as the header's digest/size.
                if (channel.read(ticket, bytes, page) != 0) throw Failure("snapshotLengthMismatch")
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                if (actual != sha) throw Failure("snapshotDigestMismatch")
                output.force(true)
            }
            checkOwner()
            Files.move(part.toPath(), file.toPath())
            if (!file.setReadOnly()) throw Failure("snapshotProtectionFailed")
            snapshot = Snapshot(sessionID, owner, relativePath, file, bytes, sha,
                info.text("sourceID").ifEmpty { null }, info.text("sourceRevision").ifEmpty { null })
        } catch (error: Throwable) {
            failure = error
        } finally {
            // Close the exact ticket even when the owner retired. This is
            // release, not a new read/write admission or a replacement owner.
            try {
                val status = channel.close(ticket)
                if (status != 0) throw Failure("snapshotCloseRefused:$status")
            } catch (error: Throwable) {
                if (failure == null) failure = error else failure.addSuppressed(error)
            }
        }
        try { checkOwner() } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        if (failure != null) {
            // Only this unexposed, randomly allocated transport directory.
            directory?.listFiles()?.forEach { it.delete() }
            directory?.delete()
            throw failure
        }
        return snapshot ?: throw Failure("snapshotMissing")
    }

    private object NativeChannel : Channel {
        override fun open(owner: Owner, path: String): Long = WorkspaceSourceNative.egressOpen(
            owner.nativeEpoch, "export", owner.taskID, owner.workspaceID, path, "")
        override fun info(ticket: Long, reply: ByteArray): Int = WorkspaceSourceNative.egressInfo(ticket, reply)
        override fun read(ticket: Long, offset: Long, target: ByteArray): Int =
            WorkspaceSourceNative.egressRead(ticket, offset, target)
        override fun close(ticket: Long): Int = WorkspaceSourceNative.egressClose(ticket)
    }

    companion object {
        const val MAX_BYTES = 256L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
    }
}
