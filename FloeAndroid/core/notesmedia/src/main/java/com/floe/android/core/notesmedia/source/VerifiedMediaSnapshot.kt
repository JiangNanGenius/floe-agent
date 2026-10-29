// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.source

import com.floe.android.core.notesmedia.media.InkFormat
import com.floe.android.core.notesmedia.media.MediaResourceDescriptor
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.media.Sha256
import com.floe.android.core.notesmedia.media.Sha256Hex
import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSource
import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSourceContract
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest

/**
 * An owned, immutable, DIGEST-PROVED source snapshot.
 *
 * This is a handoff of FACTS only (same trust model as
 * [OfficePdfVerifiedSource]): the producer verified these bytes with its own
 * eyes, owns the file and keeps it immutable/retained for the snapshot
 * lifetime. The module never accepts a model- or UI-supplied path as a
 * verified source; it only accepts this type (or the Office verified source
 * directly for the print path).
 *
 * `mediaType` binds the intended use: only [NotesMediaType.PDF] snapshots are
 * accepted by the PDF adapter, only [NotesMediaType.FLOE_INK] bytes are
 * editable by the ink editor. A PDF snapshot is additionally a valid
 * [OfficePdfVerifiedSource], so the existing Office renderer, print adapter
 * and receipt policy keep their exact meaning.
 */
data class VerifiedMediaSnapshot(
    val file: File,
    val sha256: String,
    val byteCount: Long,
    val mediaType: String,
    val displayName: String,
) : OfficePdfVerifiedSource {

    init {
        require(Sha256.isValid(sha256)) { "Snapshot digest must be 64 lowercase hex" }
        require(byteCount in 1L..MAX_SOURCE_BYTES) { "Snapshot size outside the module cap" }
        require(file.isAbsolute) { "Snapshot file must be absolute" }
        require(displayName.length <= MAX_DISPLAY_NAME) { "Snapshot display name too long" }
    }

    override val readableFile: File get() = file
    override val expectedSha256: String get() = sha256
    override val expectedBytes: Long get() = byteCount

    /**
     * The descriptor the Notes authority can persist for this resource.
     * [resourceId] MUST be the authority's opaque resource ID
     * (`ImportedResource.resourceID`), never [sha256]: the digest is only a
     * byte-verification fact and must not be written into a page's
     * drawing/background/office resource field.
     */
    fun descriptor(resourceId: String, editable: com.floe.android.core.notesmedia.media.MediaEditability) =
        MediaResourceDescriptor(
            resourceId = resourceId,
            mediaType = mediaType,
            // Only Floe ink has a versioned container; a PDF revision is 0
            // (the ink format version must not be stamped onto it).
            formatVersion = if (mediaType == NotesMediaType.FLOE_INK) InkFormat.CURRENT else 0,
            byteCount = byteCount,
            sha256 = sha256,
            editable = editable,
        )

    companion object {
        /** 256 MiB, identical to the Office verified-source cap. */
        const val MAX_SOURCE_BYTES: Long = 256L shl 20
        const val MAX_DISPLAY_NAME: Int = 256

        /**
         * Constructs a snapshot from facts an owner ALREADY proved. Shape is
         * re-validated here (cheap, fail-closed); the bytes are not re-read.
         * Use [MediaSnapshotVerifier] when the module itself must prove bytes.
         */
        fun of(
            file: File,
            sha256: String,
            byteCount: Long,
            mediaType: String,
            displayName: String,
        ): VerifiedMediaSnapshot? {
            if (!Sha256.isValid(sha256)) return null
            if (byteCount !in 1L..MAX_SOURCE_BYTES) return null
            if (!file.isAbsolute) return null
            if (displayName.length > MAX_DISPLAY_NAME) return null
            if (mediaType != NotesMediaType.PDF && mediaType != NotesMediaType.FLOE_INK &&
                mediaType != NotesMediaType.APPLE_PENCILKIT
            ) {
                return null
            }
            return VerifiedMediaSnapshot(file, sha256, byteCount, mediaType, displayName)
        }

        /**
         * Parity guard against the Office contract the renderer really applies
         * (kept as a testable function so drift is caught in JVM tests).
         */
        fun officeShapeAgrees(snapshot: VerifiedMediaSnapshot): Boolean =
            OfficePdfVerifiedSourceContract.shapeOk(snapshot)
    }
}

/** Why the module refused to certify a source file. Values are path-free. */
enum class SnapshotRefusal {
    NOT_FOUND,
    NOT_REGULAR_FILE,
    SYMLINK,
    EMPTY,
    TOO_LARGE,
    CHANGED_DURING_READ,
    CANCELLED,
    IO_ERROR,
    IDENTITY_MISMATCH,
}

sealed class SnapshotResult {
    data class Verified(val snapshot: VerifiedMediaSnapshot) : SnapshotResult()
    data class Refused(val reason: SnapshotRefusal) : SnapshotResult()
}

/**
 * Streaming, cancellable, bounded verifier. It is the module's own proof gate
 * for sources that did not come from an Office receipt (e.g. a user-picked
 * PDF imported by the Notes authority) and for re-proving a persisted ink
 * resource before opening it for editing.
 *
 * Properties:
 *  - symbolic links and non-regular files are refused (no path indirection);
 *  - the whole file is streamed once, so memory stays bounded;
 *  - the byte cap aborts as soon as it is exceeded (never reads a 4 GB
 *    "PDF" to discover it is oversized);
 *  - cancellation is polled between 1 MiB chunks and returns a CANCELLED
 *    result without publishing a snapshot;
 *  - the file's length/mtime is re-checked after reading, so a file that
 *    changed while being digested is never presented as verified.
 */
object MediaSnapshotVerifier {

    private const val CHUNK_BYTES = 1 shl 20

    fun verify(
        file: File,
        mediaType: String,
        displayName: String = file.name,
        isCancelled: () -> Boolean = { false },
    ): SnapshotResult {
        if (mediaType != NotesMediaType.PDF && mediaType != NotesMediaType.FLOE_INK &&
            mediaType != NotesMediaType.APPLE_PENCILKIT
        ) {
            return SnapshotResult.Refused(SnapshotRefusal.IO_ERROR)
        }
        val path = file.toPath()
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return SnapshotResult.Refused(SnapshotRefusal.NOT_FOUND)
        if (Files.isSymbolicLink(path)) return SnapshotResult.Refused(SnapshotRefusal.SYMLINK)
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            return SnapshotResult.Refused(SnapshotRefusal.NOT_REGULAR_FILE)
        }
        val before = try {
            Files.readAttributes(path, java.nio.file.attribute.BasicFileAttributes::class.java)
        } catch (_: IOException) {
            return SnapshotResult.Refused(SnapshotRefusal.IO_ERROR)
        }
        val length = before.size()
        if (length <= 0L) return SnapshotResult.Refused(SnapshotRefusal.EMPTY)
        if (length > VerifiedMediaSnapshot.MAX_SOURCE_BYTES) return SnapshotResult.Refused(SnapshotRefusal.TOO_LARGE)

        val digest = MessageDigest.getInstance("SHA-256")
        var read = 0L
        val buffer = ByteArray(CHUNK_BYTES)
        try {
            file.inputStream().buffered(CHUNK_BYTES).use { input ->
                while (true) {
                    if (isCancelled()) return SnapshotResult.Refused(SnapshotRefusal.CANCELLED)
                    val n = input.read(buffer)
                    if (n < 0) break
                    read += n
                    if (read > VerifiedMediaSnapshot.MAX_SOURCE_BYTES) {
                        return SnapshotResult.Refused(SnapshotRefusal.TOO_LARGE)
                    }
                    digest.update(buffer, 0, n)
                }
            }
        } catch (_: IOException) {
            return SnapshotResult.Refused(SnapshotRefusal.IO_ERROR)
        }
        if (read != length) return SnapshotResult.Refused(SnapshotRefusal.CHANGED_DURING_READ)
        val after = try {
            Files.readAttributes(path, java.nio.file.attribute.BasicFileAttributes::class.java)
        } catch (_: IOException) {
            return SnapshotResult.Refused(SnapshotRefusal.IO_ERROR)
        }
        if (after.size() != length ||
            after.lastModifiedTime() != before.lastModifiedTime() ||
            after.fileKey() != before.fileKey()
        ) {
            return SnapshotResult.Refused(SnapshotRefusal.CHANGED_DURING_READ)
        }
        val sha = Sha256Hex.encode(digest.digest())
        return SnapshotResult.Verified(
            VerifiedMediaSnapshot(
                file = file.absoluteFile,
                sha256 = sha,
                byteCount = read,
                mediaType = mediaType,
                displayName = displayName,
            ),
        )
    }

    /**
     * Re-proves an EXISTING descriptor against the current bytes. Used before
     * opening a persisted ink resource for editing, so a swapped or truncated
     * file is refused instead of silently rendering someone else's strokes.
     */
    fun verifyDescriptor(
        file: File,
        descriptor: MediaResourceDescriptor,
        isCancelled: () -> Boolean = { false },
    ): SnapshotResult {
        val result = verify(file, descriptor.mediaType, file.name, isCancelled)
        return when (result) {
            is SnapshotResult.Refused -> result
            is SnapshotResult.Verified ->
                if (result.snapshot.byteCount != descriptor.byteCount ||
                    result.snapshot.sha256 != descriptor.sha256
                ) {
                    SnapshotResult.Refused(SnapshotRefusal.IDENTITY_MISMATCH)
                } else {
                    result
                }
        }
    }
}
