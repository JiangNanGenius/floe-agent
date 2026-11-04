// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.gallery

import android.Manifest
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportReceipt
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

enum class GalleryCollection(val wire: String) {
    IMAGE("image"),
    VIDEO("video"),
}

/**
 * Explicit, trusted owner grant for one verified export artifact. It is issued
 * by the App after `resolveProjectMediaRoot(context)` re-proves the live
 * session/project/storage/origin. The receipt path itself is never a grant.
 */
data class GalleryArtifactGrant(
    val canonicalRootPath: String,
    val projectID: String,
    val ownerProof: String,
)

sealed interface GalleryArtifactDecision {
    data class Granted(val grant: GalleryArtifactGrant) : GalleryArtifactDecision

    data class Refused(
        val code: String,
        val reason: String,
        val retryable: Boolean = false,
    ) : GalleryArtifactDecision
}

/**
 * The App supplies the real native-authority adapter; the saver has no
 * fallback root and no path-only authorization. A foreign/stale receipt is a
 * typed refusal, never a best-effort write into a guessed media directory.
 */
fun interface GalleryArtifactAuthority {
    suspend fun authorize(
        receipt: MediaExportReceipt,
        context: CreativeProjectContext,
    ): GalleryArtifactDecision
}

data class GallerySaveOptions(
    val collection: GalleryCollection,
    /** Sanitized to a safe display file name; null derives it from the receipt. */
    val displayName: String? = null,
    /** One safe relative album component below Pictures/DCIM; default Floe. */
    val album: String = "Floe",
)

data class GallerySaveReceipt(
    val contentURI: String,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val readbackByteCount: Long,
    val readbackSha256: String,
    val displayName: String,
    val collection: GalleryCollection,
    val width: Int?,
    val height: Int?,
    val mediaRelativePath: String,
    val projectID: String,
    val projectRevision: Long,
    val attemptID: String,
    val savedAt: String,
)

sealed interface GallerySaveResult {
    data class Saved(val receipt: GallerySaveReceipt) : GallerySaveResult

    /**
     * API 28 only. The actual permission request belongs to the App's user
     * action (Main patch); no dialog is shown from this data layer.
     */
    data class PermissionRequired(val permission: String) : GallerySaveResult

    data class Failed(
        val code: String,
        val message: String,
        val retryable: Boolean = false,
        /** True only when this call's pending MediaStore row is confirmed gone. */
        val pendingCleaned: Boolean = true,
    ) : GallerySaveResult
}

/**
 * Generic verified-artifact gallery publisher. It is shared by image, video
 * and (later) CAD/design callers: the caller passes a real
 * [MediaExportReceipt] plus its explicit editor context, never a raw path.
 *
 * Contract:
 *  * the receipt is re-proved against the live native root and exact
 *    size/SHA-256 before any destination row is created;
 *  * the bytes are staged into App-owned scratch and hashed again;
 *  * API 29+ inserts an `IS_PENDING=1` Images/Video row, writes the staged
 *    bytes, fsyncs, clears pending, then streams the published URI back and
 *    re-checks exact byte count + SHA-256;
 *  * API 28 uses the legacy public Pictures/DCIM directory + MediaStore row
 *    with `WRITE_EXTERNAL_STORAGE` (maxSdk 28);
 *  * a failed/aborted write deletes only this call's pending row and reports
 *    whether cleanup was confirmed; a published item is never relabelled as a
 *    failed save.
 */
class AndroidMediaGallerySaver(
    context: Context,
    private val authority: GalleryArtifactAuthority,
) {
    private val applicationContext = context.applicationContext
    private val resolver: ContentResolver = applicationContext.contentResolver
    private val stagingRoot = File(applicationContext.cacheDir, "MediaGalleryStaging")

    suspend fun save(
        receipt: MediaExportReceipt,
        context: CreativeProjectContext,
        options: GallerySaveOptions,
        cancellationSignal: CancellationSignal? = null,
    ): GallerySaveResult = withContext(Dispatchers.IO) {
        val identity = GalleryReceiptIdentity.of(receipt)
            ?: return@withContext GallerySaveResult.Failed(
                "invalidReceipt",
                "The export receipt is incomplete or malformed",
            )
        val mime = receipt.mimeType.lowercase(Locale.ROOT)
        val collection = when {
            mime.startsWith("image/") -> GalleryCollection.IMAGE
            mime.startsWith("video/") -> GalleryCollection.VIDEO
            else -> return@withContext GallerySaveResult.Failed(
                "unsupportedMimeType",
                "Gallery save supports image and video exports",
            )
        }
        if (collection != options.collection) {
            return@withContext GallerySaveResult.Failed(
                "collectionMismatch",
                "The export MIME type does not match the requested gallery collection",
            )
        }
        if (!receipt.verification.playable) {
            return@withContext GallerySaveResult.Failed(
                "unverifiedReceipt",
                "The export was not verified as playable",
            )
        }
        if (Build.VERSION.SDK_INT <= 28 &&
            applicationContext.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return@withContext GallerySaveResult.PermissionRequired(
                Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
        val decision = try {
            authority.authorize(receipt, context)
        } catch (error: CreativeException) {
            return@withContext GallerySaveResult.Failed(
                error.code,
                error.reason ?: "The export owner could not be verified",
                error.retryable,
            )
        } catch (_: Throwable) {
            return@withContext GallerySaveResult.Failed(
                "galleryAuthorityUnavailable",
                "The export owner could not be verified",
                retryable = true,
            )
        }
        val grant = when (decision) {
            is GalleryArtifactDecision.Granted -> decision.grant
            is GalleryArtifactDecision.Refused -> return@withContext GallerySaveResult.Failed(
                decision.code,
                decision.reason,
                decision.retryable,
            )
        }
        if (grant.projectID != receipt.binding.projectID ||
            grant.canonicalRootPath.isBlank() ||
            grant.ownerProof.isBlank()
        ) {
            return@withContext GallerySaveResult.Failed(
                "galleryOwnerMismatch",
                "The export owner proof does not match this receipt",
            )
        }
        val sourceRoot = runCatching { File(grant.canonicalRootPath).canonicalFile }.getOrNull()
            ?: return@withContext GallerySaveResult.Failed(
                "galleryRootRefused",
                "The project media root is unavailable",
            )
        if (!sourceRoot.isDirectory) {
            return@withContext GallerySaveResult.Failed(
                "galleryRootRefused",
                "The project media root is unavailable",
            )
        }
        val receiptRoot = runCatching { File(receipt.binding.mediaRootPath).canonicalFile }
            .getOrNull()
        if (receiptRoot == null || receiptRoot.path != sourceRoot.path) {
            return@withContext GallerySaveResult.Failed(
                "galleryOwnerMismatch",
                "The receipt root does not match the live project root",
            )
        }
        val source = galleryContainedFile(sourceRoot, receipt.outputRelativePath)
            ?: return@withContext GallerySaveResult.Failed(
                "gallerySourceRefused",
                "The export path is not a verified file under the project root",
            )
        if (source.length() != receipt.byteCount) {
            return@withContext GallerySaveResult.Failed(
                "gallerySourceChanged",
                "The export file size changed after verification",
            )
        }
        val staged = try {
            stageVerified(
                source = source,
                expectedBytes = receipt.byteCount,
                expectedSha = receipt.sha256,
            )
        } catch (_: Throwable) {
            null
        } ?: return@withContext GallerySaveResult.Failed(
            "gallerySourceChanged",
            "The export bytes do not match the verified receipt",
        )
        try {
            val displayName = safeDisplayName(
                options.displayName ?: receipt.displayName,
                receipt,
                collection,
            )
            val album = safeAlbum(options.album)
            if (Build.VERSION.SDK_INT >= 29) {
                saveModern(
                    receipt = receipt,
                    staged = staged,
                    displayName = displayName,
                    album = album,
                    collection = collection,
                    cancellationSignal = cancellationSignal,
                )
            } else {
                saveLegacy(
                    receipt = receipt,
                    staged = staged,
                    displayName = displayName,
                    album = album,
                    collection = collection,
                    cancellationSignal = cancellationSignal,
                )
            }
        } finally {
            runCatching { staged.delete() }
        }
    }

    // MARK: - API 29+ pending row

    @android.annotation.SuppressLint("NewApi")
    private suspend fun saveModern(
        receipt: MediaExportReceipt,
        staged: File,
        displayName: String,
        album: String,
        collection: GalleryCollection,
        cancellationSignal: CancellationSignal?,
    ): GallerySaveResult {
        val collectionUri = collectionUri(collection)
        val relativePath = relativePath(collection, album)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, receipt.mimeType.lowercase(Locale.ROOT))
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            receipt.verification.width.takeIf { it > 0 }?.let {
                put(MediaStore.MediaColumns.WIDTH, it)
            }
            receipt.verification.height.takeIf { it > 0 }?.let {
                put(MediaStore.MediaColumns.HEIGHT, it)
            }
        }
        val uri = try {
            resolver.insert(collectionUri, values)
        } catch (_: Throwable) {
            null
        } ?: return GallerySaveResult.Failed(
            "galleryPendingInsertFailed",
            "The gallery could not create a pending item",
        )
        var published = false
        try {
            writeToUri(uri, staged, cancellationSignal)
            currentCoroutineContext().ensureActive()
            val complete = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            if (resolver.update(uri, complete, null, null) != 1) {
                throw GalleryWriteException("galleryPublishFailed", "The gallery item could not be published")
            }
            published = true
            val actualName = queryDisplayName(uri) ?: displayName
            val readback = readback(uri, cancellationSignal)
                ?: throw GalleryWriteException(
                    "galleryReadbackFailed",
                    "The published gallery item could not be read back",
                )
            if (readback.byteCount != receipt.byteCount ||
                !readback.sha256.equals(receipt.sha256, ignoreCase = true)
            ) {
                throw GalleryWriteException(
                    "galleryReadbackMismatch",
                    "The published gallery item differs from the verified export",
                )
            }
            return GallerySaveResult.Saved(
                GallerySaveReceipt(
                    contentURI = uri.toString(),
                    mimeType = receipt.mimeType.lowercase(Locale.ROOT),
                    byteCount = receipt.byteCount,
                    sha256 = receipt.sha256.lowercase(Locale.ROOT),
                    readbackByteCount = readback.byteCount,
                    readbackSha256 = readback.sha256,
                    displayName = actualName,
                    collection = collection,
                    width = receipt.verification.width.takeIf { it > 0 },
                    height = receipt.verification.height.takeIf { it > 0 },
                    mediaRelativePath = "$relativePath$actualName",
                    projectID = receipt.binding.projectID,
                    projectRevision = receipt.binding.projectRevision,
                    attemptID = receipt.binding.attemptID,
                    savedAt = Instant.now().toString(),
                ),
            )
        } catch (failure: Throwable) {
            val cleaned = withContext(NonCancellable + Dispatchers.IO) {
                runCatching { resolver.delete(uri, null, null) }.getOrDefault(0) == 1
            }
            if (failure is CancellationException) throw failure
            if (published) {
                return GallerySaveResult.Failed(
                    "galleryPublishVerifyFailed",
                    failure.message ?: "The published gallery item could not be verified",
                    retryable = false,
                    pendingCleaned = cleaned,
                )
            }
            return GallerySaveResult.Failed(
                (failure as? GalleryWriteException)?.code ?: "galleryWriteFailed",
                failure.message ?: "The gallery item could not be written",
                retryable = false,
                pendingCleaned = cleaned,
            )
        }
    }

    // MARK: - API 28 legacy public media

    private suspend fun saveLegacy(
        receipt: MediaExportReceipt,
        staged: File,
        displayName: String,
        album: String,
        collection: GalleryCollection,
        cancellationSignal: CancellationSignal?,
    ): GallerySaveResult {
        val publicDirectory = if (collection == GalleryCollection.IMAGE) {
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
        } else {
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
        }
        val directory = File(publicDirectory, album)
        if (!directory.isDirectory && !directory.mkdirs()) {
            return GallerySaveResult.Failed(
                "galleryDirectoryUnavailable",
                "The public media directory is unavailable",
            )
        }
        val target = uniqueFile(directory, displayName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, target.name)
            put(MediaStore.MediaColumns.MIME_TYPE, receipt.mimeType.lowercase(Locale.ROOT))
            put(MediaStore.MediaColumns.DATA, target.absolutePath)
            receipt.verification.width.takeIf { it > 0 }?.let {
                put(MediaStore.MediaColumns.WIDTH, it)
            }
            receipt.verification.height.takeIf { it > 0 }?.let {
                put(MediaStore.MediaColumns.HEIGHT, it)
            }
        }
        val uri = try {
            resolver.insert(collectionUri(collection), values)
        } catch (_: Throwable) {
            null
        } ?: return GallerySaveResult.Failed(
            "galleryPendingInsertFailed",
            "The gallery could not create a media row",
        )
        try {
            writeFile(target, staged, cancellationSignal)
            currentCoroutineContext().ensureActive()
            val readback = readFile(target)
                ?: throw GalleryWriteException(
                    "galleryReadbackFailed",
                    "The saved media file could not be read back",
                )
            if (readback.byteCount != receipt.byteCount ||
                !readback.sha256.equals(receipt.sha256, ignoreCase = true)
            ) {
                throw GalleryWriteException(
                    "galleryReadbackMismatch",
                    "The saved media file differs from the verified export",
                )
            }
            val actualName = queryDisplayName(uri) ?: target.name
            return GallerySaveResult.Saved(
                GallerySaveReceipt(
                    contentURI = uri.toString(),
                    mimeType = receipt.mimeType.lowercase(Locale.ROOT),
                    byteCount = receipt.byteCount,
                    sha256 = receipt.sha256.lowercase(Locale.ROOT),
                    readbackByteCount = readback.byteCount,
                    readbackSha256 = readback.sha256,
                    displayName = actualName,
                    collection = collection,
                    width = receipt.verification.width.takeIf { it > 0 },
                    height = receipt.verification.height.takeIf { it > 0 },
                    mediaRelativePath = target.absolutePath,
                    projectID = receipt.binding.projectID,
                    projectRevision = receipt.binding.projectRevision,
                    attemptID = receipt.binding.attemptID,
                    savedAt = Instant.now().toString(),
                ),
            )
        } catch (failure: Throwable) {
            val cleaned = withContext(NonCancellable + Dispatchers.IO) {
                val rowGone = runCatching { resolver.delete(uri, null, null) }.getOrDefault(0) == 1
                val fileGone = !target.exists() || target.delete()
                rowGone && fileGone
            }
            if (failure is CancellationException) throw failure
            return GallerySaveResult.Failed(
                (failure as? GalleryWriteException)?.code ?: "galleryWriteFailed",
                failure.message ?: "The gallery item could not be written",
                retryable = false,
                pendingCleaned = cleaned,
            )
        }
    }

    // MARK: - Byte IO

    private fun stageVerified(source: File, expectedBytes: Long, expectedSha: String): File {
        if (!MediaGalleryLimits.isSha256(expectedSha)) {
            throw GalleryWriteException("invalidReceipt", "The receipt digest is not a SHA-256")
        }
        if (expectedBytes !in 1L..MediaGalleryLimits.MAX_BYTES) {
            throw GalleryWriteException("invalidReceipt", "The receipt size is outside the bound")
        }
        if (!stagingRoot.isDirectory && !stagingRoot.mkdirs()) {
            throw GalleryWriteException("galleryStagingUnavailable", "Gallery staging is unavailable")
        }
        val target = File(stagingRoot, "gallery-${UUID.randomUUID()}.part")
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        try {
            FileInputStream(source).use { input ->
                FileOutputStream(target).use { output ->
                    copyBounded(input, output, expectedBytes, digest, null)
                    output.flush()
                    runCatching { output.fd.sync() }
                }
            }
            val sha = hex(digest.digest())
            if (!sha.equals(expectedSha, ignoreCase = true)) {
                throw GalleryWriteException("gallerySourceChanged", "The export digest changed")
            }
            return target
        } catch (failure: Throwable) {
            target.delete()
            throw failure
        }
    }

    private fun writeToUri(
        uri: Uri,
        staged: File,
        cancellationSignal: CancellationSignal?,
    ) {
        val output = try {
            resolver.openOutputStream(uri, "w")
        } catch (_: Throwable) {
            null
        } ?: throw GalleryWriteException("galleryOpenFailed", "The gallery item could not be opened")
        try {
            FileInputStream(staged).use { input ->
                copyBounded(input, output, staged.length(), null, cancellationSignal)
                output.flush()
                if (output is FileOutputStream) {
                    runCatching { output.fd.sync() }
                }
            }
        } finally {
            runCatching { output.close() }
        }
    }

    private fun writeFile(
        target: File,
        staged: File,
        cancellationSignal: CancellationSignal?,
    ) {
        FileInputStream(staged).use { input ->
            FileOutputStream(target).use { output ->
                copyBounded(input, output, staged.length(), null, cancellationSignal)
                output.flush()
                runCatching { output.fd.sync() }
            }
        }
    }

    private fun readback(uri: Uri, cancellationSignal: CancellationSignal?): ByteDigest? {
        val input = try {
            resolver.openInputStream(uri)
        } catch (_: Throwable) {
            null
        } ?: return null
        return try {
            digestStream(input, cancellationSignal)
        } finally {
            runCatching { input.close() }
        }
    }

    private fun readFile(file: File): ByteDigest? = try {
        FileInputStream(file).use { digestStream(it, null) }
    } catch (_: Throwable) {
        null
    }

    private fun digestStream(
        input: InputStream,
        cancellationSignal: CancellationSignal?,
    ): ByteDigest {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(MediaGalleryLimits.CHUNK_BYTES)
        var total = 0L
        while (true) {
            cancellationSignal?.throwIfCanceled()
            val read = input.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            total += read
            if (total > MediaGalleryLimits.MAX_BYTES) {
                throw GalleryWriteException("galleryReadbackTooLarge", "The gallery item is too large")
            }
            digest.update(buffer, 0, read)
        }
        return ByteDigest(total, hex(digest.digest()))
    }

    private fun copyBounded(
        input: InputStream,
        output: OutputStream,
        expectedBytes: Long,
        digest: java.security.MessageDigest?,
        cancellationSignal: CancellationSignal?,
    ) {
        val buffer = ByteArray(MediaGalleryLimits.CHUNK_BYTES)
        var total = 0L
        while (true) {
            cancellationSignal?.throwIfCanceled()
            val read = input.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            total += read
            if (total > expectedBytes) {
                throw GalleryWriteException("gallerySizeMismatch", "The source is larger than the receipt")
            }
            output.write(buffer, 0, read)
            digest?.update(buffer, 0, read)
        }
        if (total != expectedBytes) {
            throw GalleryWriteException("gallerySizeMismatch", "The source size does not match the receipt")
        }
    }

    // MARK: - Small helpers

    private fun collectionUri(collection: GalleryCollection): Uri =
        if (collection == GalleryCollection.IMAGE) {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }

    private fun relativePath(collection: GalleryCollection, album: String): String =
        if (collection == GalleryCollection.IMAGE) "Pictures/$album/" else "DCIM/$album/"

    private fun queryDisplayName(uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
            } else {
                null
            }
        }
    } catch (_: Throwable) {
        null
    }

    private fun uniqueFile(directory: File, name: String): File {
        val safe = File(directory, name)
        if (!safe.exists()) return safe
        val base = name.substringBeforeLast('.', name)
        val extension = name.substringAfterLast('.', "")
        for (index in 1..9_999) {
            val candidate = File(
                directory,
                if (extension.isEmpty()) "$base ($index)" else "$base ($index).$extension",
            )
            if (!candidate.exists()) return candidate
        }
        return File(directory, "${base}-${UUID.randomUUID()}.${extension.ifEmpty { "bin" }}")
    }

    private fun safeDisplayName(
        requested: String?,
        receipt: MediaExportReceipt,
        collection: GalleryCollection,
    ): String {
        val fallbackExtension = if (collection == GalleryCollection.IMAGE) {
            when (receipt.mimeType.lowercase(Locale.ROOT)) {
                "image/png" -> "png"
                "image/heic" -> "heic"
                "image/jpeg" -> "jpg"
                else -> "img"
            }
        } else {
            "mp4"
        }
        val raw = requested?.trim()?.takeIf { it.isNotEmpty() }
            ?: receipt.outputRelativePath.substringAfterLast('/')
        val withoutPath = raw.substringAfterLast('/').substringAfterLast('\\')
        val base = withoutPath
            .take(120)
            .map { ch ->
                if (ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == '.' || ch == ' ') ch else '_'
            }
            .joinToString("")
            .trim()
            .trim('.')
            .ifBlank { "floe-export" }
        val hasKnownExtension = base.substringAfterLast('.', "").lowercase(Locale.ROOT) in
            setOf("png", "jpg", "jpeg", "heic", "heif", "webp", "mp4", "mov", "m4v")
        return if (hasKnownExtension) base else "$base.$fallbackExtension"
    }

    private fun safeAlbum(raw: String): String {
        val cleaned = raw.trim().take(48).map { ch ->
            if (ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == ' ') ch else '-'
        }.joinToString("").trim().trim('-')
        return cleaned.ifBlank { "Floe" }
    }

    private fun hex(bytes: ByteArray): String {
        val chars = "0123456789abcdef".toCharArray()
        val out = CharArray(bytes.size * 2)
        var i = 0
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            out[i++] = chars[value ushr 4]
            out[i++] = chars[value and 0x0f]
        }
        return String(out)
    }

    private data class ByteDigest(val byteCount: Long, val sha256: String)

    private class GalleryWriteException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private data class GalleryReceiptIdentity(
        val projectID: String,
        val outputRelativePath: String,
        val byteCount: Long,
        val sha256: String,
    ) {
        companion object {
            private val ATTEMPT = Regex("[A-Za-z0-9._-]{1,64}")

            fun of(receipt: MediaExportReceipt): GalleryReceiptIdentity? {
                val binding = receipt.binding
                if (binding.projectID.isBlank() || binding.mediaRootPath.isBlank()) return null
                if (binding.projectRevision < 0L) return null
                if (!ATTEMPT.matches(binding.attemptID)) return null
                if (!MediaGalleryLimits.isSafeRelativePath(receipt.outputRelativePath)) return null
                if (!receipt.outputRelativePath.startsWith("Workbench/Exports/")) return null
                if (receipt.byteCount !in 1L..MediaGalleryLimits.MAX_BYTES) return null
                if (!MediaGalleryLimits.isSha256(receipt.sha256)) return null
                if (!receipt.mimeType.contains('/') || receipt.mimeType.contains('*')) return null
                return GalleryReceiptIdentity(
                    projectID = binding.projectID,
                    outputRelativePath = receipt.outputRelativePath,
                    byteCount = receipt.byteCount,
                    sha256 = receipt.sha256.lowercase(Locale.ROOT),
                )
            }
        }
    }
}

private object MediaGalleryLimits {
    const val MAX_BYTES = 8L * 1024L * 1024L * 1024L
    const val CHUNK_BYTES = 64 * 1024

    fun isSha256(value: String): Boolean =
        value.length == 64 && value.all { it in "0123456789abcdefABCDEF" }

    fun isSafeRelativePath(value: String): Boolean {
        if (value.isEmpty() || value.length > 512) return false
        if (value.startsWith("/") || value.contains('\\') || value.contains('\u0000')) return false
        val segments = value.split('/')
        return segments.none { it.isEmpty() || it == "." || it == ".." }
    }
}

private fun galleryContainedFile(root: File, relativePath: String): File? {
    if (!MediaGalleryLimits.isSafeRelativePath(relativePath)) return null
    val candidate = runCatching { File(root, relativePath).canonicalFile }.getOrNull() ?: return null
    val prefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
    if (!candidate.path.startsWith(prefix) || !candidate.isFile || candidate.isDirectory) return null
    if (java.nio.file.Files.isSymbolicLink(candidate.toPath())) return null
    return candidate
}
