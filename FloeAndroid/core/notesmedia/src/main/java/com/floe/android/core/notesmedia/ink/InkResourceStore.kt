// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import android.graphics.Bitmap
import com.floe.android.core.notesmedia.media.ForeignInkResource
import com.floe.android.core.notesmedia.media.InkFormat
import com.floe.android.core.notesmedia.media.MediaEditability
import com.floe.android.core.notesmedia.media.MediaResourceDescriptor
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.media.ResourceIdPolicy
import com.floe.android.core.notesmedia.media.Sha256
import com.floe.android.core.notesmedia.media.Sha256Hex
import com.floe.android.core.notesmedia.source.MediaSnapshotVerifier
import com.floe.android.core.notesmedia.source.SnapshotResult
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

/**
 * On-disk layout for one Notes media resource directory:
 *
 * ```
 * <root>/<resourceId>/
 *   drawing.floeink     editable Android ink document (binary, versioned)
 *   drawing.preview.png optional derived preview (never authority)
 *   foreign.bin         opaque Apple PencilKit bytes (preserve only)
 *   manifest.txt        strict key=value descriptor (media type, sizes, digests)
 * ```
 *
 * The layout object is pure (paths + manifest text + digest helpers) so its
 * grammar and traversal safety are JVM-testable. The caller owns [root] (the
 * Notes authority's resource directory); this module never creates a parallel
 * store root.
 */
object InkResourceLayout {
    const val INK_FILE = "drawing.floeink"
    const val PREVIEW_FILE = "drawing.preview.png"
    const val FOREIGN_FILE = "foreign.bin"
    const val MANIFEST_FILE = "manifest.txt"
    const val MANIFEST_HEADER = "floe.ink.resource"
    const val MANIFEST_VERSION = 1
    const val MAX_PREVIEW_BYTES: Long = 8L shl 20
    const val MAX_PREVIEW_EDGE_PX: Int = 2048

    fun directoryFor(root: File, resourceId: String): File? {
        if (!ResourceIdPolicy.isValid(resourceId)) return null
        val dir = File(root, resourceId)
        // Defence in depth: the resolved path must remain a direct child.
        val parent = dir.canonicalFile.parentFile ?: return null
        if (parent.canonicalPath != root.canonicalFile.canonicalPath) return null
        return dir
    }

    fun encodeManifest(descriptor: MediaResourceDescriptor, pageKey: String?, widthPt: Float?, heightPt: Float?): String {
        val sb = StringBuilder(256)
        sb.append(MANIFEST_HEADER).append('\n')
        sb.append("version=").append(MANIFEST_VERSION).append('\n')
        sb.append("mediaType=").append(descriptor.mediaType).append('\n')
        sb.append("formatVersion=").append(descriptor.formatVersion).append('\n')
        sb.append("editable=").append(descriptor.editable.name).append('\n')
        sb.append("bytes=").append(descriptor.byteCount).append('\n')
        sb.append("sha256=").append(descriptor.sha256).append('\n')
        descriptor.previewMediaType?.let { sb.append("preview.mediaType=").append(it).append('\n') }
        descriptor.previewSha256?.let { sb.append("preview.sha256=").append(it).append('\n') }
        pageKey?.let { sb.append("pageKey=").append(escape(it)).append('\n') }
        widthPt?.let { sb.append("widthPt=").append(it).append('\n') }
        heightPt?.let { sb.append("heightPt=").append(it).append('\n') }
        return sb.toString()
    }

    data class Manifest(
        val descriptor: MediaResourceDescriptor,
        val pageKey: String?,
        val widthPt: Float?,
        val heightPt: Float?,
    )

    sealed class ManifestResult {
        data class Ok(val manifest: Manifest) : ManifestResult()
        object Invalid : ManifestResult()
    }

    fun decodeManifest(text: String, resourceId: String): ManifestResult {
        val lines = text.split('\n')
        if (lines.firstOrNull() != MANIFEST_HEADER) return ManifestResult.Invalid
        val values = HashMap<String, String>(12)
        for (line in lines.drop(1)) {
            if (line.isEmpty()) continue
            val eq = line.indexOf('=')
            if (eq <= 0) return ManifestResult.Invalid
            values[line.substring(0, eq)] = line.substring(eq + 1)
        }
        if (values["version"]?.toIntOrNull() != MANIFEST_VERSION) return ManifestResult.Invalid
        val mediaType = values["mediaType"] ?: return ManifestResult.Invalid
        val formatVersion = values["formatVersion"]?.toIntOrNull() ?: return ManifestResult.Invalid
        val editable = runCatching { MediaEditability.valueOf(values["editable"] ?: "") }.getOrNull()
            ?: return ManifestResult.Invalid
        val bytes = values["bytes"]?.toLongOrNull() ?: return ManifestResult.Invalid
        val sha = values["sha256"] ?: return ManifestResult.Invalid
        if (!Sha256.isValid(sha) || bytes !in 1L..InkFormat.MAX_DOCUMENT_BYTES) return ManifestResult.Invalid
        val previewSha = values["preview.sha256"]
        val previewType = values["preview.mediaType"]
        if ((previewSha == null) != (previewType == null)) return ManifestResult.Invalid
        if (previewSha != null && (!Sha256.isValid(previewSha) || previewType != NotesMediaType.PREVIEW_PNG)) {
            return ManifestResult.Invalid
        }
        val descriptor = try {
            MediaResourceDescriptor(
                resourceId = resourceId,
                mediaType = mediaType,
                formatVersion = formatVersion,
                byteCount = bytes,
                sha256 = sha,
                editable = editable,
                previewMediaType = previewType,
                previewSha256 = previewSha,
            )
        } catch (_: IllegalArgumentException) {
            return ManifestResult.Invalid
        }
        val pageKey = values["pageKey"]?.let { unescape(it) ?: return ManifestResult.Invalid }
        val width = values["widthPt"]?.toFloatOrNull()
        val height = values["heightPt"]?.toFloatOrNull()
        if (width != null && (!width.isFinite() || width <= 0f)) return ManifestResult.Invalid
        if (height != null && (!height.isFinite() || height <= 0f)) return ManifestResult.Invalid
        return ManifestResult.Ok(Manifest(descriptor, pageKey, width, height))
    }

    private fun escape(raw: String): String {
        val sb = StringBuilder(raw.length)
        for (c in raw) {
            when (c) {
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }

    private fun unescape(raw: String): String? {
        val sb = StringBuilder(raw.length)
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c != '\\') {
                sb.append(c)
                i++
                continue
            }
            if (i + 1 >= raw.length) return null
            when (raw[i + 1]) {
                '\\' -> sb.append('\\')
                'n' -> sb.append('\n')
                'r' -> sb.append('\r')
                else -> return null
            }
            i += 2
        }
        return sb.toString()
    }
}

/** Why the store refused a write/import. Path-free. */
enum class InkStoreRefusal {
    INVALID_RESOURCE_ID,
    ALREADY_EXISTS,
    IDENTITY_MISMATCH,
    NOT_EDITABLE,
    TOO_LARGE,
    PREVIEW_INVALID,
    CANCELLED,
    IO_ERROR,
    CORRUPT,
    NOT_FOUND,
}

sealed class InkWriteResult {
    data class Ok(val descriptor: MediaResourceDescriptor, val directory: File) : InkWriteResult()
    data class Refused(val refusal: InkStoreRefusal) : InkWriteResult()
}

sealed class InkReadResult {
    data class Editable(
        val snapshot: InkSnapshot,
        val descriptor: MediaResourceDescriptor,
        val directory: File,
        val previewFile: File?,
    ) : InkReadResult()

    data class Foreign(val resource: ForeignInkResource, val directory: File) : InkReadResult()
    data class Refused(val refusal: InkStoreRefusal) : InkReadResult()
}

/**
 * Atomic resource store for editable ink documents and opaque foreign ink.
 *
 * Write protocol (cancel/failure NEVER destroys the old resource):
 *  1. write everything into `<root>/.staging-<uuid>/` (drawing, preview, manifest),
 *     fsync each file;
 *  2. when the destination already exists, only replace it if the caller
 *     supplied the exact existing SHA-256 (compare-and-swap on identity) —
 *     otherwise refuse [InkStoreRefusal.ALREADY_EXISTS];
 *  3. rename the staging directory to the destination (same filesystem, atomic
 *     directory rename), moving the old directory to `.trash-<uuid>` and
 *     deleting it only AFTER the new one is in place.
 *
 * Read protocol: manifest parse → digest+length re-proof of the exact bytes →
 * codec decode. A file that no longer matches its manifest is refused
 * ([InkStoreRefusal.IDENTITY_MISMATCH]) and never partially decoded. Foreign
 * media types are returned as opaque bytes and are never handed to the codec.
 */
class InkResourceStore(private val root: File) {

    init {
        require(root.isAbsolute) { "Ink store root must be absolute" }
    }

    fun write(
        snapshot: InkSnapshot,
        preview: Bitmap? = null,
        expectedExistingSha256: String? = null,
        isCancelled: () -> Boolean = { false },
    ): InkWriteResult {
        val dir = InkResourceLayout.directoryFor(root, snapshot.documentId)
            ?: return InkWriteResult.Refused(InkStoreRefusal.INVALID_RESOURCE_ID)
        if (!root.isDirectory && !root.mkdirs()) return InkWriteResult.Refused(InkStoreRefusal.IO_ERROR)
        if (dir.exists() && expectedExistingSha256 == null) {
            return InkWriteResult.Refused(InkStoreRefusal.ALREADY_EXISTS)
        }
        if (!dir.exists() && expectedExistingSha256 != null) {
            return InkWriteResult.Refused(InkStoreRefusal.IDENTITY_MISMATCH)
        }
        val encoded = when (val result = InkDocumentCodec.encode(snapshot)) {
            is InkEncodeResult.Refused -> return InkWriteResult.Refused(InkStoreRefusal.CORRUPT)
            is InkEncodeResult.Ok -> result.bytes
        }
        if (encoded.size.toLong() > InkFormat.MAX_DOCUMENT_BYTES) {
            return InkWriteResult.Refused(InkStoreRefusal.TOO_LARGE)
        }
        val staging = File(root, ".staging-${UUID.randomUUID()}")
        try {
            if (!staging.mkdirs()) return InkWriteResult.Refused(InkStoreRefusal.IO_ERROR)
            val inkFile = File(staging, InkResourceLayout.INK_FILE)
            writeBytes(inkFile, encoded)
            val inkSha = Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(encoded))
            var previewSha: String? = null
            if (preview != null) {
                if (isCancelled()) return cleanupAndRefuse(staging, InkStoreRefusal.CANCELLED)
                val png = encodePreview(preview) ?: return cleanupAndRefuse(staging, InkStoreRefusal.PREVIEW_INVALID)
                if (png.size.toLong() > InkResourceLayout.MAX_PREVIEW_BYTES) {
                    return cleanupAndRefuse(staging, InkStoreRefusal.PREVIEW_INVALID)
                }
                writeBytes(File(staging, InkResourceLayout.PREVIEW_FILE), png)
                previewSha = Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(png))
            }
            val descriptor = MediaResourceDescriptor(
                resourceId = snapshot.documentId,
                mediaType = NotesMediaType.FLOE_INK,
                formatVersion = InkFormat.CURRENT,
                byteCount = encoded.size.toLong(),
                sha256 = inkSha,
                editable = MediaEditability.EDITABLE,
                previewMediaType = if (previewSha != null) NotesMediaType.PREVIEW_PNG else null,
                previewSha256 = previewSha,
            )
            writeBytes(
                File(staging, InkResourceLayout.MANIFEST_FILE),
                InkResourceLayout.encodeManifest(
                    descriptor,
                    snapshot.geometry.pageKey,
                    snapshot.geometry.widthPt,
                    snapshot.geometry.heightPt,
                ).toByteArray(Charsets.UTF_8),
            )
            if (isCancelled()) return cleanupAndRefuse(staging, InkStoreRefusal.CANCELLED)
            if (dir.exists()) {
                val current = InkResourceLayout.directoryFor(root, snapshot.documentId)
                    ?: return cleanupAndRefuse(staging, InkStoreRefusal.INVALID_RESOURCE_ID)
                val currentSha = readDescriptor(current)?.sha256
                if (currentSha == null || currentSha != expectedExistingSha256) {
                    return cleanupAndRefuse(staging, InkStoreRefusal.IDENTITY_MISMATCH)
                }
                val trash = File(root, ".trash-${UUID.randomUUID()}")
                if (!current.renameTo(trash)) return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
                if (!staging.renameTo(current)) {
                    // Best effort: put the old resource back, then refuse.
                    trash.renameTo(current)
                    return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
                }
                trash.deleteRecursively()
            } else {
                if (!staging.renameTo(dir)) return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
            }
            return InkWriteResult.Ok(descriptor, dir)
        } catch (_: IOException) {
            return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
        } catch (_: SecurityException) {
            return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
        }
    }

    /** Imports opaque foreign ink (Apple PencilKit or unknown) WITHOUT decoding it. */
    fun importForeign(
        resourceId: String,
        mediaType: String,
        bytes: ByteArray,
        expectedExistingSha256: String? = null,
    ): InkWriteResult {
        if (mediaType == NotesMediaType.FLOE_INK) return InkWriteResult.Refused(InkStoreRefusal.NOT_EDITABLE)
        if (bytes.isEmpty() || bytes.size.toLong() > InkFormat.MAX_DOCUMENT_BYTES) {
            return InkWriteResult.Refused(InkStoreRefusal.TOO_LARGE)
        }
        val dir = InkResourceLayout.directoryFor(root, resourceId)
            ?: return InkWriteResult.Refused(InkStoreRefusal.INVALID_RESOURCE_ID)
        if (!root.isDirectory && !root.mkdirs()) return InkWriteResult.Refused(InkStoreRefusal.IO_ERROR)
        if (dir.exists() && expectedExistingSha256 == null) return InkWriteResult.Refused(InkStoreRefusal.ALREADY_EXISTS)
        val staging = File(root, ".staging-${UUID.randomUUID()}")
        try {
            if (!staging.mkdirs()) return InkWriteResult.Refused(InkStoreRefusal.IO_ERROR)
            writeBytes(File(staging, InkResourceLayout.FOREIGN_FILE), bytes)
            val sha = Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(bytes))
            val descriptor = MediaResourceDescriptor(
                resourceId = resourceId,
                mediaType = mediaType,
                formatVersion = 0,
                byteCount = bytes.size.toLong(),
                sha256 = sha,
                editable = MediaEditability.PRESERVE_ONLY,
            )
            writeBytes(
                File(staging, InkResourceLayout.MANIFEST_FILE),
                InkResourceLayout.encodeManifest(descriptor, null, null, null).toByteArray(Charsets.UTF_8),
            )
            if (dir.exists()) {
                val currentSha = readDescriptor(dir)?.sha256
                if (currentSha == null || currentSha != expectedExistingSha256) {
                    return cleanupAndRefuse(staging, InkStoreRefusal.IDENTITY_MISMATCH)
                }
                val trash = File(root, ".trash-${UUID.randomUUID()}")
                if (!dir.renameTo(trash)) return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
                if (!staging.renameTo(dir)) {
                    trash.renameTo(dir)
                    return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
                }
                trash.deleteRecursively()
            } else if (!staging.renameTo(dir)) {
                return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
            }
            return InkWriteResult.Ok(descriptor, dir)
        } catch (_: IOException) {
            return cleanupAndRefuse(staging, InkStoreRefusal.IO_ERROR)
        }
    }

    /** Reads an editable document with full identity re-proof before decoding. */
    fun readEditable(resourceId: String, isCancelled: () -> Boolean = { false }): InkReadResult {
        val dir = InkResourceLayout.directoryFor(root, resourceId)
            ?: return InkReadResult.Refused(InkStoreRefusal.INVALID_RESOURCE_ID)
        if (!dir.isDirectory) return InkReadResult.Refused(InkStoreRefusal.NOT_FOUND)
        val manifest = readManifest(dir) ?: return InkReadResult.Refused(InkStoreRefusal.CORRUPT)
        val descriptor = manifest.descriptor
        if (descriptor.mediaType != NotesMediaType.FLOE_INK) {
            return InkReadResult.Refused(InkStoreRefusal.NOT_EDITABLE)
        }
        if (descriptor.editable != MediaEditability.EDITABLE) {
            return InkReadResult.Refused(InkStoreRefusal.NOT_EDITABLE)
        }
        val inkFile = File(dir, InkResourceLayout.INK_FILE)
        when (val verified = MediaSnapshotVerifier.verifyDescriptor(inkFile, descriptor, isCancelled)) {
            is SnapshotResult.Refused -> return InkReadResult.Refused(
                if (verified.reason == com.floe.android.core.notesmedia.source.SnapshotRefusal.CANCELLED) {
                    InkStoreRefusal.CANCELLED
                } else {
                    InkStoreRefusal.IDENTITY_MISMATCH
                },
            )
            is SnapshotResult.Verified -> Unit
        }
        val bytes = try {
            inkFile.readBytes()
        } catch (_: IOException) {
            return InkReadResult.Refused(InkStoreRefusal.IO_ERROR)
        }
        return when (val decoded = InkDocumentCodec.decode(bytes)) {
            is InkDecodeResult.Invalid -> InkReadResult.Refused(InkStoreRefusal.CORRUPT)
            is InkDecodeResult.Ok -> {
                val preview = if (descriptor.previewSha256 != null) {
                    File(dir, InkResourceLayout.PREVIEW_FILE).takeIf { it.isFile }
                } else {
                    null
                }
                InkReadResult.Editable(decoded.snapshot, descriptor, dir, preview)
            }
        }
    }

    /** Reads opaque foreign ink without decoding it. */
    fun readForeign(resourceId: String): InkReadResult {
        val dir = InkResourceLayout.directoryFor(root, resourceId)
            ?: return InkReadResult.Refused(InkStoreRefusal.INVALID_RESOURCE_ID)
        if (!dir.isDirectory) return InkReadResult.Refused(InkStoreRefusal.NOT_FOUND)
        val manifest = readManifest(dir) ?: return InkReadResult.Refused(InkStoreRefusal.CORRUPT)
        val descriptor = manifest.descriptor
        if (descriptor.editable == MediaEditability.EDITABLE) return InkReadResult.Refused(InkStoreRefusal.NOT_EDITABLE)
        val file = File(dir, InkResourceLayout.FOREIGN_FILE)
        val bytes = try {
            file.readBytes()
        } catch (_: IOException) {
            return InkReadResult.Refused(InkStoreRefusal.IO_ERROR)
        }
        if (bytes.size.toLong() != descriptor.byteCount ||
            Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(bytes)) != descriptor.sha256
        ) {
            return InkReadResult.Refused(InkStoreRefusal.IDENTITY_MISMATCH)
        }
        return InkReadResult.Foreign(ForeignInkResource(descriptor, bytes), dir)
    }

    fun readDescriptor(resourceId: String): MediaResourceDescriptor? {
        val dir = InkResourceLayout.directoryFor(root, resourceId) ?: return null
        return readDescriptor(dir)
    }

    /** Deletes a resource only when the caller proves the exact current identity. */
    fun delete(resourceId: String, expectedSha256: String): Boolean {
        val dir = InkResourceLayout.directoryFor(root, resourceId) ?: return false
        val descriptor = readDescriptor(dir) ?: return false
        if (!Sha256.isValid(expectedSha256) || descriptor.sha256 != expectedSha256) return false
        return dir.deleteRecursively()
    }

    private fun readDescriptor(dir: File): MediaResourceDescriptor? = readManifest(dir)?.descriptor

    private fun readManifest(dir: File): InkResourceLayout.Manifest? {
        val file = File(dir, InkResourceLayout.MANIFEST_FILE)
        val text = try {
            if (!file.isFile || file.length() > 64 * 1024) return null
            file.readText(Charsets.UTF_8)
        } catch (_: IOException) {
            return null
        }
        return when (val parsed = InkResourceLayout.decodeManifest(text, dir.name)) {
            is InkResourceLayout.ManifestResult.Invalid -> null
            is InkResourceLayout.ManifestResult.Ok -> parsed.manifest
        }
    }

    private fun encodePreview(bitmap: Bitmap): ByteArray? {
        if (bitmap.isRecycled) return null
        if (bitmap.width <= 0 || bitmap.height <= 0) return null
        if (maxOf(bitmap.width, bitmap.height) > InkResourceLayout.MAX_PREVIEW_EDGE_PX) return null
        val out = java.io.ByteArrayOutputStream(64 * 1024)
        return if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) out.toByteArray() else null
    }

    private fun writeBytes(file: File, bytes: ByteArray) {
        FileOutputStream(file).use { out ->
            out.write(bytes)
            out.flush()
            runCatching { out.fd.sync() }
        }
    }

    private fun cleanupAndRefuse(staging: File, refusal: InkStoreRefusal): InkWriteResult {
        runCatching { staging.deleteRecursively() }
        return InkWriteResult.Refused(refusal)
    }

    /** Preview bytes go through a caller-supplied sink (no path authority here). */
    fun copyPreview(resourceId: String, openOutput: () -> OutputStream): Boolean {
        val dir = InkResourceLayout.directoryFor(root, resourceId) ?: return false
        val descriptor = readDescriptor(dir) ?: return false
        val expected = descriptor.previewSha256 ?: return false
        val file = File(dir, InkResourceLayout.PREVIEW_FILE)
        if (!file.isFile || file.length() > InkResourceLayout.MAX_PREVIEW_BYTES) return false
        val bytes = try {
            file.readBytes()
        } catch (_: IOException) {
            return false
        }
        if (Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(bytes)) != expected) return false
        openOutput().use { it.write(bytes) }
        return true
    }
}
