// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.LargeImportPolicy
import com.floe.android.feature.workbench.WorkbenchR2Limits
import com.floe.android.host.SourceHostReply
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/**
 * Exact identity of the workspace operation that owns one read-only source
 * snapshot. Every value is captured once; nothing re-reads "the current task"
 * late. `hostGeneration` fences the App command client generation as well as
 * the native accepted epoch.
 */
internal data class MediaWorkspaceOwner(
    val taskID: String,
    val workspaceID: String,
    val nativeEpoch: Long,
    val hostGeneration: Long,
) {
    init {
        require(UUID.fromString(taskID).toString().equals(taskID, true))
        require(UUID.fromString(workspaceID).toString().equals(workspaceID, true))
        require(nativeEpoch > 0 && hostGeneration >= 0)
    }
}

/**
 * Media-only ceilings for a source read from the workspace.
 *
 * The reviewed R2 large-import policy is image 128 MiB / audio 1 GiB / video
 * 8 GiB. The generic Office/Canvas 64 MiB and 256 MiB limits are deliberately
 * NOT touched here and are not used by this route.
 *
 * The native workspace egress lane now has TWO closed channels: the original
 * generic save/export snapshot (still bounded by
 * `G04WorkspaceSourceCoordinator.maximumProviderCopyBytes`, 1 GiB, untouched)
 * and this media-only `export-media` channel, which streams the pinned source
 * body without a second snapshot under the reviewed per-kind ceilings. This
 * stager uses only the media channel; `NATIVE_EGRESS_MAX_BYTES` is the
 * channel's absolute ceiling (the per-kind policy above is the primary gate).
 * A Core that predates the media entry has no such symbol, so the App refuses
 * honestly (`assetStagingUnavailable`) instead of claiming a larger channel.
 */
internal object MediaWorkspaceStagingPolicy {
    /** Absolute closed media egress ceiling (video); the per-kind cap wins. */
    const val NATIVE_EGRESS_MAX_BYTES: Long = 8L shl 30

    private val IMAGE_EXTENSIONS =
        setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif")
    private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "m4v")
    private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "wav", "flac", "ogg", "opus")

    fun extensions(kind: String): Set<String>? = when (kind.lowercase(Locale.ROOT)) {
        "image" -> IMAGE_EXTENSIONS
        "video" -> VIDEO_EXTENSIONS
        "audio" -> AUDIO_EXTENSIONS
        else -> null
    }

    fun maxBytes(kind: String): Long? = when (kind.lowercase(Locale.ROOT)) {
        "image" -> WorkbenchR2Limits.IMPORT_IMAGE_BYTES
        "audio" -> WorkbenchR2Limits.IMPORT_AUDIO_BYTES
        "video" -> WorkbenchR2Limits.IMPORT_VIDEO_BYTES
        else -> null
    }

    /** Reviewed floor: the App snapshot plus the import staging/final copy and headroom. */
    fun requiredFreeBytes(sourceBytes: Long): Long =
        LargeImportPolicy.requiredFreeBytes(sourceBytes)

    /** `usableSpace == 0` means the filesystem could not report it; do not fake a refusal. */
    fun hasFreeSpace(available: Long, required: Long): Boolean =
        available <= 0L || required <= 0L || available >= required
}

/** The injected seam: mirrors the CLOSED media `WorkspaceSourceNative`
 * entry only (never the generic save/export `egressOpen`). */
internal interface MediaWorkspaceSourceChannel {
    fun open(owner: MediaWorkspaceOwner, logicalPath: String, kind: String): Long
    fun info(ticket: Long, reply: ByteArray): Int
    fun read(ticket: Long, offset: Long, target: ByteArray): Int
    fun close(ticket: Long): Int
}

internal object NativeMediaWorkspaceSourceChannel : MediaWorkspaceSourceChannel {
    override fun open(owner: MediaWorkspaceOwner, logicalPath: String, kind: String): Long =
        WorkspaceSourceNative.egressOpenMedia(
            owner.nativeEpoch,
            kind,
            owner.taskID,
            owner.workspaceID,
            logicalPath,
        )

    override fun info(ticket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.egressInfo(ticket, reply)

    override fun read(ticket: Long, offset: Long, target: ByteArray): Int =
        WorkspaceSourceNative.egressRead(ticket, offset, target)

    override fun close(ticket: Long): Int = WorkspaceSourceNative.egressClose(ticket)
}

internal data class MediaWorkspaceStagedSource(
    val file: File,
    val displayName: String,
    val byteCount: Long,
    val sha256: String,
    val sourceID: String?,
    val sourceRevision: String?,
    val logicalPath: String,
)

/**
 * Dedicated media-only workspace snapshot stager.
 *
 * The source is read through the CLOSED native media egress authority with
 * the exact captured owner (task/workspace/epoch/generation); the native lane
 * holds the exact owner lease and streams the pinned source body without a
 * second native snapshot. The App never receives a host path and never writes
 * to the workspace. The App's own snapshot goes into a new random directory
 * beneath the App staging root only after:
 *
 *  * the native header proves the exact logical path, mode `export-media`, a
 *    bounded size and a native SHA-256;
 *  * the media-only size ceiling, the closed media channel ceiling and a disk
 *    pre-flight for the App's snapshot + import staging + headroom pass;
 *  * every 64 KiB chunk carries the exact captured owner check and is hashed
 *    and written incrementally;
 *  * exact EOF is probed and the streamed digest equals the header digest.
 *
 * The part file is fsynced and atomically renamed; a failed/cancelled/owner
 * changed stage deletes only the random directory this call created.
 */
internal class MediaWorkspaceStager(
    private val root: File,
    private val channel: MediaWorkspaceSourceChannel = NativeMediaWorkspaceSourceChannel,
) {
    companion object {
        private const val CHUNK_BYTES = 64 * 1024
        private const val MAX_PATH_LENGTH = 4096
        private val SHA_REGEX = Regex("[0-9a-f]{64}")
    }

    fun stage(
        owner: MediaWorkspaceOwner,
        relativePath: String,
        kind: String,
        isCurrent: () -> Boolean,
        onProgress: (stagedBytes: Long, totalBytes: Long) -> Unit = { _, _ -> },
    ): MediaWorkspaceStagedSource {
        val extensions = MediaWorkspaceStagingPolicy.extensions(kind)
            ?: throw CreativeException("invalidRequest", "unsupportedMediaKind")
        val cap = MediaWorkspaceStagingPolicy.maxBytes(kind)
            ?: throw CreativeException("invalidRequest", "unsupportedMediaKind")
        val trimmedPath = relativePath
        if (!isSafeWorkspacePath(trimmedPath)) {
            throw CreativeException("invalidRequest", "invalidWorkspacePath")
        }
        val extension = trimmedPath.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension !in extensions) {
            throw CreativeException("unsupportedSourceFormat", "unsupportedMediaExtension")
        }
        val displayName = trimmedPath.substringAfterLast('/')
        if (!isSafeDisplayName(displayName)) {
            throw CreativeException("invalidRequest", "invalidWorkspaceName")
        }
        fun checkOwner() {
            if (Thread.currentThread().isInterrupted || !isCurrent()) {
                throw CreativeException(
                    "staleGeneration", "workspaceSourceOwnerChanged", retryable = true)
            }
        }

        checkOwner()
        val ticket = try {
            // The closed media entry. An installed Core that predates it has
            // no JNI symbol: that LinkageError is the honest old-core
            // refusal, never a fabricated 8 GiB capability.
            channel.open(owner, trimmedPath, kind.lowercase(Locale.ROOT))
        } catch (_: LinkageError) {
            throw CreativeException(
                "assetStagingUnavailable", "workspaceSourceUnavailable", retryable = true)
        } catch (error: Exception) {
            throw CreativeException(
                "assetStagingUnavailable", "workspaceSourceUnavailable",
                retryable = true, cause = error)
        }
        if (ticket <= 0L) {
            // Native status space (G04WorkspaceSourceHostAPI): -509/-510 are
            // size bounds (the media opening reports its closed per-kind
            // ceiling as -509 BEFORE reading), -511 disk, -502/-503/-507 and
            // -505 an owner/epoch/identity fence, -518 a bounded hop timeout.
            val code = when (ticket) {
                -509L, -510L -> "importTooLarge"
                -511L -> "insufficientStorage"
                -502L, -503L, -505L, -507L -> "staleGeneration"
                else -> "assetStagingUnavailable"
            }
            val reason = when (ticket) {
                -509L, -510L -> "workspaceSourceTooLarge"
                -511L -> "workspaceStagingNoSpace"
                -502L, -503L, -505L, -507L -> "workspaceSourceOwnerChanged"
                else -> "workspaceSourceOpenRefused"
            }
            throw CreativeException(code, reason, retryable = code == "assetStagingUnavailable")
        }
        var directory: File? = null
        var snapshot: MediaWorkspaceStagedSource? = null
        var failure: Throwable? = null
        try {
            checkOwner()
            val info = SourceHostReply.call { reply -> channel.info(ticket, reply) }
            if (!info.ok) {
                throw CreativeException(
                    "assetStagingUnavailable", "workspaceSourceInfoRefused", retryable = true)
            }
            val bytes = info.number("bytes")
                ?: throw CreativeException("invalidCoreResponse", "workspaceSourceInfoMissing")
            val sha = info.text("sha256")
            if (bytes <= 0L) {
                throw CreativeException("assetEmpty", "workspaceSourceEmpty")
            }
            if (bytes > cap) {
                throw CreativeException("importTooLarge", "workspaceSourceTooLarge")
            }
            // Absolute closed media ceiling (the per-kind cap above is the
            // real policy gate). This is a truthful header guard, not a
            // promise: the native open already refused anything larger.
            if (bytes > MediaWorkspaceStagingPolicy.NATIVE_EGRESS_MAX_BYTES) {
                throw CreativeException(
                    "importTooLarge", "workspaceSourceExceedsNativeEgress")
            }
            if (!SHA_REGEX.matches(sha)) {
                throw CreativeException("assetStagingInvalid", "workspaceSourceDigestMissing")
            }
            // The ticket came from the closed media entry; an `export` reply
            // here would mean the body was not served by that channel.
            if (info.text("logicalPath") != trimmedPath || info.text("mode") != "export-media") {
                throw CreativeException("assetStagingInvalid", "workspaceSourceInfoMismatch")
            }
            checkOwner()

            val canonicalRoot = runCatching { root.canonicalFile }.getOrNull()
                ?: throw CreativeException(
                    "storageUnavailable", "workspaceStagingUnavailable", retryable = true)
            if ((!canonicalRoot.isDirectory && !canonicalRoot.mkdirs()) ||
                Files.isSymbolicLink(canonicalRoot.toPath())
            ) {
                throw CreativeException(
                    "storageUnavailable", "workspaceStagingUnavailable", retryable = true)
            }
            val required = MediaWorkspaceStagingPolicy.requiredFreeBytes(bytes)
            if (!MediaWorkspaceStagingPolicy.hasFreeSpace(canonicalRoot.usableSpace, required)) {
                throw CreativeException(
                    "insufficientStorage", "workspaceStagingNoSpace", retryable = true)
            }

            val sessionID = UUID.randomUUID().toString()
            val created = File(canonicalRoot, sessionID)
            Files.createDirectory(created.toPath())
            directory = created
            val part = File(created, "source.part")
            val file = File(created, "source.$extension")
            val digest = MessageDigest.getInstance("SHA-256")
            FileChannel.open(
                part.toPath(),
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { output ->
                val page = ByteArray(CHUNK_BYTES)
                var offset = 0L
                while (offset < bytes) {
                    checkOwner()
                    val want = minOf(page.size.toLong(), bytes - offset).toInt()
                    val copied = channel.read(ticket, offset, page)
                    if (copied <= 0 || copied > want) {
                        throw CreativeException(
                            "assetStagingInvalid", "workspaceSourceChunkInvalid")
                    }
                    checkOwner()
                    digest.update(page, 0, copied)
                    writeFully(output, page, copied)
                    offset += copied
                    onProgress(offset, bytes)
                }
                checkOwner()
                if (channel.read(ticket, offset, page) != 0) {
                    throw CreativeException(
                        "assetStagingInvalid", "workspaceSourceLengthMismatch")
                }
                val actual = digest.digest().joinToString("") {
                    String.format(Locale.ROOT, "%02x", it.toInt() and 0xff)
                }
                if (actual != sha) {
                    throw CreativeException(
                        "assetStagingInvalid", "workspaceSourceDigestMismatch")
                }
                output.force(true)
            }
            checkOwner()
            Files.move(part.toPath(), file.toPath())
            if (!file.setReadOnly()) {
                throw CreativeException(
                    "storageUnavailable", "workspaceStagingProtectionFailed", retryable = true)
            }
            snapshot = MediaWorkspaceStagedSource(
                file = file,
                displayName = displayName,
                byteCount = bytes,
                sha256 = sha,
                sourceID = info.text("sourceID").ifEmpty { null },
                sourceRevision = info.text("sourceRevision").ifEmpty { null },
                logicalPath = trimmedPath,
            )
        } catch (error: Throwable) {
            failure = error
        } finally {
            // Release is allowed even when the owner retired; it is not a new
            // read/write admission. A refused close keeps the failure visible.
            try {
                if (channel.close(ticket) != 0) {
                    throw CreativeException(
                        "assetStagingUnavailable", "workspaceSourceCloseRefused", retryable = true)
                }
            } catch (error: Throwable) {
                if (failure == null) failure = error else failure.addSuppressed(error)
            }
        }
        try {
            checkOwner()
        } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        val error = failure
        if (error != null) {
            // Only the random directory this call created; originals and any
            // native-owned commit are untouched.
            directory?.listFiles()?.forEach { runCatching { it.delete() } }
            runCatching { directory?.delete() }
            if (error is CreativeException) throw error
            if (error is java.io.IOException) {
                throw CreativeException(
                    "assetStagingUnavailable", "workspaceStagingFailed",
                    retryable = true, cause = error)
            }
            throw error
        }
        return snapshot ?: throw CreativeException(
            "assetStagingInvalid", "workspaceStagingMissing")
    }

    private fun writeFully(output: FileChannel, data: ByteArray, length: Int) {
        val buffer = ByteBuffer.wrap(data, 0, length)
        while (buffer.hasRemaining()) output.write(buffer)
    }

    private fun isSafeWorkspacePath(path: String): Boolean {
        if (path.isBlank() || path.length > MAX_PATH_LENGTH) return false
        if (path.startsWith("/") || path.startsWith("~") || path.contains('\\') ||
            path.contains('\u0000')
        ) {
            return false
        }
        return path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    private fun isSafeDisplayName(name: String): Boolean =
        name.isNotBlank() && !name.contains('/') && !name.contains('\\') &&
            name != "." && name != ".." &&
            name.toByteArray(Charsets.UTF_8).size <= 255
}
