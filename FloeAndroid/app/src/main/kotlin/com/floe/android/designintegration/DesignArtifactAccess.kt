// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.DesignContentType
import com.floe.android.feature.canvas.DesignExportReceipt
import com.floe.android.feature.canvas.DesignPreviewReceipt
import com.floe.android.feature.canvas.DesignStateProjection
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import com.floe.android.feature.canvas.DesignTargetKind
import com.floe.android.feature.canvas.ui.design.DesignExportDeliveryResult
import com.floe.android.feature.canvas.ui.design.DesignPreviewContent
import com.floe.android.host.creative.CreativeAcceptedRoot
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.host.creative.CreativeOwnership
import com.floe.android.host.creative.CreativeWire
import com.floe.android.mediaintegration.MediaWorkbenchExportProof
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.roundToInt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Verified design artifact opener + captured owner registry.
 *
 * Every preview/export receipt is re-proved against:
 *  1. the LIVE accepted Root/epoch of this process;
 *  2. the live native design state (same target, same owner revision);
 *  3. a native-issued root path CONTAINED by the accepted Root (the receipt
 *     root is never accepted as a standalone authority);
 *  4. one bounded relative path, regular-file size and SHA-256 equality.
 *
 * Only after that proof does this class decode a bounded image, text or PDF,
 * parse the real `canvas.snapshot` JSON, or stage the exact bytes for SAF
 * delivery. No `File(receipt.rootPath)` is opened before containment/digest
 * verification and no recorded path is used as a fallback.
 */
internal class DesignArtifactAccess(
    private val hostProvider: () -> CreativeHostController,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val epochProvider: () -> Long?,
    private val delivery: DesignExportDelivery,
    /**
     * Trusted, READ-ONLY `assetsBasePath` of the captured native Canvas owner
     * for one canvas id (the live Canvas editor envelope). It is never derived
     * from JSON, a recorded root or a receipt path; a null result simply means
     * this process has no live captured Canvas owner for that canvas, and
     * images stay honest placeholders.
     */
    private val canvasAssetsBasePathProvider: (String) -> String? = { null },
) {
    private val lock = Any()
    private val captures = LinkedHashMap<String, DesignArtifactCapture>()
    private val canvasAssets = DesignCanvasAssetReader()

    suspend fun openPreview(
        receipt: DesignPreviewReceipt,
        binding: DesignTargetBinding,
    ): DesignPreviewContent {
        val view = ReceiptView(
            target = receipt.target,
            ownerRevision = receipt.ownerRevision,
            candidateID = receipt.candidateID,
            revisionID = receipt.revisionID,
            format = receipt.format,
            rootPath = receipt.rootPath,
            relativePath = receipt.relativePath,
            byteCount = receipt.byteCount,
            sha256 = receipt.sha256,
        )
        val capture = verify(view, binding, DesignArtifactKind.PREVIEW)
        return decode(capture, binding)
    }

    suspend fun deliverExport(
        receipt: DesignExportReceipt,
        binding: DesignTargetBinding,
    ): DesignExportDeliveryResult {
        val view = ReceiptView(
            target = receipt.target,
            ownerRevision = receipt.ownerRevision,
            candidateID = receipt.candidateID,
            revisionID = receipt.revisionID,
            format = receipt.format,
            rootPath = receipt.rootPath,
            relativePath = receipt.relativePath,
            byteCount = receipt.byteCount,
            sha256 = receipt.sha256,
        )
        val capture = verify(view, binding, DesignArtifactKind.EXPORT)
        return delivery.deliver(
            capture = capture,
            reverify = { verify(view, binding, DesignArtifactKind.EXPORT) },
        )
    }

    fun clearForRootStop() {
        synchronized(lock) { captures.clear() }
    }

    private suspend fun verify(
        view: ReceiptView,
        binding: DesignTargetBinding,
        kind: DesignArtifactKind,
    ): DesignArtifactCapture {
        DesignTargetResolver.validate(binding)
        if (!sameTarget(view.target, binding.target)) {
            throw CreativeException("designTargetMismatch", "receiptTargetMismatch")
        }
        if (!MediaWorkbenchExportProof.isSha256Hex(view.sha256)) {
            throw CreativeException("invalidCoreResponse", "invalidReceiptDigest")
        }
        if (view.byteCount <= 0L || view.byteCount > MAX_RECEIPT_BYTES) {
            throw CreativeException("designPreviewTooLarge", "receiptSizeRefused")
        }
        val format = view.format.trim().lowercase()
        if (format.isEmpty() || format.length > 32) {
            throw CreativeException("invalidCoreResponse", "invalidReceiptFormat")
        }
        if (view.ownerRevision < 0L) {
            throw CreativeException("invalidCoreResponse", "invalidOwnerRevision")
        }
        val accepted = CreativeOwnership.requireLive(acceptedRootProvider(), epochProvider())
        val status = hostProvider().designHost.status()
        if (!status.bound || status.epoch != accepted.epoch) {
            throw CreativeException(
                "staleGeneration", "designNotBoundToAcceptedRoot", retryable = true)
        }
        val state = hostProvider().designHost.state(binding)
        verifyFreshState(state, view, binding)

        val root = canonicalContainedDirectory(accepted, view.rootPath)
            ?: throw CreativeException("designTargetMismatch", "receiptRootOutsideAcceptedRoot")
        if (!MediaWorkbenchExportProof.isSafeRelativePath(view.relativePath)) {
            throw CreativeException("invalidCoreResponse", "invalidReceiptRelativePath")
        }
        val file = MediaWorkbenchExportProof.resolveContainedFile(root.path, view.relativePath)
            ?: throw CreativeException("designPayloadMissing", "receiptFileMissing")
        if (file.length() != view.byteCount) {
            throw CreativeException("designConflict", "receiptSizeChanged", retryable = false)
        }
        val digest = sha256(file)
        if (!digest.equals(view.sha256, ignoreCase = true)) {
            throw CreativeException("designConflict", "receiptDigestChanged", retryable = false)
        }
        val capture = DesignArtifactCapture(
            epoch = accepted.epoch,
            targetKey = DesignTargetResolver.targetKey(binding),
            rootPath = root.path,
            relativePath = view.relativePath,
            file = file,
            byteCount = view.byteCount,
            sha256 = digest.lowercase(),
            format = format,
            ownerRevision = view.ownerRevision,
            candidateID = view.candidateID,
            revisionID = view.revisionID,
            kind = kind,
        )
        synchronized(lock) {
            // Immutable owner registry: a receipt identity captured for one
            // accepted generation can never be re-used to authorize a later
            // generation, even if the path/digest strings are identical.
            val existing = captures[capture.key]
            if (existing != null && existing.epoch != capture.epoch) {
                throw CreativeException(
                    "staleGeneration", "designReceiptGenerationChanged", retryable = true)
            }
            captures[capture.key] = capture
            while (captures.size > MAX_CAPTURES) {
                val oldest = captures.keys.firstOrNull() ?: break
                captures.remove(oldest)
            }
        }
        return capture
    }

    private fun verifyFreshState(
        state: DesignStateProjection,
        view: ReceiptView,
        binding: DesignTargetBinding,
    ) {
        if (!sameTarget(state.target, binding.target)) {
            throw CreativeException("designTargetMismatch", "stateTargetMismatch")
        }
        if (state.ownerRevision != view.ownerRevision) {
            throw CreativeException("designConflict", "receiptRevisionStale")
        }
        val candidateID = view.candidateID
        if (!candidateID.isNullOrBlank()) {
            val candidate = state.project.candidates.firstOrNull { it.id == candidateID }
                ?: throw CreativeException("candidateNotFound", "candidateNotFound")
            val revisionID = view.revisionID
            if (!revisionID.isNullOrBlank() && candidate.proposedRevisionID != revisionID) {
                throw CreativeException("designConflict", "candidateRevisionMismatch")
            }
        } else {
            val revisionID = view.revisionID
            if (!revisionID.isNullOrBlank() &&
                !projectHasRevision(state.project.rawProject, revisionID)
            ) {
                throw CreativeException("designPayloadMissing", "revisionNotFound")
            }
        }
    }

    private fun canonicalContainedDirectory(
        accepted: CreativeAcceptedRoot,
        rawRoot: String,
    ): File? {
        if (rawRoot.isBlank()) return null
        val acceptedRoot = runCatching { File(accepted.path).canonicalFile }.getOrNull()
            ?: return null
        val root = runCatching { File(rawRoot).canonicalFile }.getOrNull() ?: return null
        if (!root.isDirectory || root.path == acceptedRoot.path) return null
        val prefix = acceptedRoot.path + File.separator
        return root.takeIf { it.path.startsWith(prefix) }
    }

    private suspend fun decode(
        capture: DesignArtifactCapture,
        binding: DesignTargetBinding,
    ): DesignPreviewContent {
        val format = capture.format
        return when {
            format == "canvas.snapshot" || (format == "json" &&
                binding.target.kind == DesignTargetKind.CANVAS_NODE) ->
                decodeCanvasSnapshot(capture, binding)
            format in IMAGE_FORMATS -> decodeImage(capture)
            format == "pdf" -> decodePdf(capture)
            format in TEXT_FORMATS -> decodeText(capture)
            else -> DesignPreviewContent.Unavailable(format)
        }
    }

    private fun decodeImage(capture: DesignArtifactCapture): DesignPreviewContent {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        runCatching { BitmapFactory.decodeFile(capture.file.path, bounds) }
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0 ||
            width.toLong() * height.toLong() > MAX_IMAGE_PIXELS
        ) {
            return DesignPreviewContent.Unavailable(capture.format)
        }
        // Either dimension must be bounded BEFORE the real decode: the old
        // conjunction left a very wide/tall image fully sampled and allocated
        // a huge bitmap (width 4000 x height 100 stayed at sample 1).
        val sample = DesignImageBounds.sampleSize(width, height)
        if (sample <= 0) return DesignPreviewContent.Unavailable(capture.format)
        val bitmap = runCatching {
            BitmapFactory.decodeFile(
                capture.file.path,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            )
        }.getOrNull() ?: return DesignPreviewContent.Unavailable(capture.format)
        if (bitmap.byteCount > MAX_IMAGE_BITMAP_BYTES) {
            bitmap.recycle()
            return DesignPreviewContent.Unavailable(capture.format)
        }
        return DesignPreviewContent.Image(bitmap = bitmap, format = capture.format)
    }

    private fun decodePdf(capture: DesignArtifactCapture): DesignPreviewContent {
        var descriptor: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        val pages = mutableListOf<Bitmap>()
        try {
            val pfd = ParcelFileDescriptor.open(
                capture.file, ParcelFileDescriptor.MODE_READ_ONLY)
            descriptor = pfd
            val pdf = PdfRenderer(pfd)
            renderer = pdf
            val pageCount = pdf.pageCount
            var totalBytes = 0L
            val limit = minOf(pageCount, MAX_PDF_PAGES)
            for (index in 0 until limit) {
                val page = pdf.openPage(index)
                try {
                    val width = page.width
                    val height = page.height
                    if (width <= 0 || height <= 0) continue
                    val scale = minOf(
                        1.5f,
                        MAX_PDF_PAGE_WIDTH / width.toFloat(),
                        MAX_PDF_PAGE_HEIGHT / height.toFloat(),
                    ).coerceIn(0.1f, 1.5f)
                    val targetWidth = (width * scale).roundToInt().coerceAtLeast(1)
                    val targetHeight = (height * scale).roundToInt().coerceAtLeast(1)
                    if (targetWidth.toLong() * targetHeight.toLong() > MAX_PDF_PAGE_PIXELS) {
                        continue
                    }
                    val bitmap = Bitmap.createBitmap(
                        targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    try {
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    } catch (error: Throwable) {
                        bitmap.recycle()
                        throw error
                    }
                    totalBytes += bitmap.byteCount
                    if (totalBytes > MAX_PDF_TOTAL_BYTES) {
                        bitmap.recycle()
                        throw CreativeException("designPreviewTooLarge", "pdfPreviewTooLarge")
                    }
                    pages += bitmap
                } finally {
                    runCatching { page.close() }
                }
            }
            return DesignPreviewContent.PdfPages(
                pages = pages,
                pageCount = pageCount,
                format = capture.format,
            )
        } catch (error: Throwable) {
            pages.forEach { if (!it.isRecycled) it.recycle() }
            if (error is CreativeException) throw error
            return DesignPreviewContent.Unavailable(capture.format)
        } finally {
            runCatching { renderer?.close() }
            runCatching { descriptor?.close() }
        }
    }

    private fun decodeText(capture: DesignArtifactCapture): DesignPreviewContent {
        val bytes = ByteArray(MAX_TEXT_PREVIEW_BYTES)
        var total = 0
        try {
            FileInputStream(capture.file).use { input ->
                while (total < bytes.size) {
                    val read = input.read(bytes, total, bytes.size - total)
                    if (read <= 0) break
                    total += read
                }
            }
        } catch (_: IOException) {
            return DesignPreviewContent.Unavailable(capture.format)
        }
        return DesignPreviewContent.Text(
            text = String(bytes, 0, total, Charsets.UTF_8),
            format = capture.format,
            truncated = capture.byteCount > total,
        )
    }

    private suspend fun decodeCanvasSnapshot(
        capture: DesignArtifactCapture,
        binding: DesignTargetBinding,
    ): DesignPreviewContent {
        val root = parseJson(capture.file) ?: throw CreativeException(
            "invalidCoreResponse", "canvasSnapshotMalformed")
        val canvasID = root.string("canvasID")
        val documentID = root.string("documentID")
        val nodeID = root.string("nodeID")
        val revision = root.long("canvasRevision")
        if (canvasID != binding.target.ownerID ||
            documentID != binding.target.documentID ||
            nodeID != binding.target.sourceID ||
            revision != capture.ownerRevision
        ) {
            throw CreativeException("designTargetMismatch", "canvasSnapshotIdentityMismatch")
        }
        // An older Core omits canvasDocument; a different UUID-dictionary
        // encoding, a bumped schema or a mismatched revision is equally NOT
        // the canonical captured scene. Each is a typed unavailable, never the
        // design metadata summary pretending to be a render.
        val project = projectPayload(root)
            ?: return DesignPreviewContent.Unavailable(CANVAS_SNAPSHOT_FORMAT)
        val document = DesignCanvasSnapshotPayload.document(
            project = project,
            canvasID = canvasID ?: "",
            documentID = documentID ?: "",
            nodeID = nodeID ?: "",
            revision = revision ?: 0L,
        ) ?: return DesignPreviewContent.Unavailable(CANVAS_SNAPSHOT_FORMAT)
        val metadata = parseSnapshotAssets(root)
        // Re-prove the captured Canvas owner's native-issued Materials root
        // against the CURRENT accepted Root, then read only digest-matching
        // image bytes. A missing live owner/root leaves images as honest
        // placeholders; it never falls back to a recorded path.
        val accepted = runCatching {
            CreativeOwnership.requireLive(acceptedRootProvider(), epochProvider())
        }.getOrNull()
        val trustedRoot = accepted?.let { value ->
            canvasAssetsBasePathProvider(canvasID ?: "")
                ?.let { path -> canonicalContainedDirectory(value, path) }
        }
        val bitmaps = if (trustedRoot != null) {
            runCatching {
                canvasAssets.readVerifiedBitmaps(document, metadata, trustedRoot)
            }.getOrDefault(emptyMap())
        } else {
            emptyMap()
        }
        val assets = metadata.map { asset ->
            asset.copy(bitmapAvailable = bitmaps.containsKey(asset.assetID))
        }
        return DesignPreviewContent.CanvasSnapshot(
            canvasID = canvasID ?: "",
            canvasRevision = revision ?: 0L,
            documentID = documentID ?: "",
            nodeID = nodeID ?: "",
            contentType = projectContentType(root),
            briefGoal = (root["project"] as? JsonObject)
                ?.let { it["brief"] as? JsonObject }?.string("goal"),
            specRawMarkdown = (root["project"] as? JsonObject)
                ?.let { it["spec"] as? JsonObject }?.string("rawMarkdown"),
            candidateCount = ((root["project"] as? JsonObject)
                ?.get("candidates") as? JsonArray)?.size ?: 0,
            project = project,
            assetBitmaps = bitmaps,
            assets = assets,
            assetsTruncated = root.boolean("assetsTruncated") ?: false,
        )
    }

    /**
     * Decode the EXACT canonical schema-7 Canvas document the native design
     * snapshot returned. This reuses the existing creative wire decoder (the
     * same shape `canvas.load.project` uses); no second Canvas wire shape and
     * no re-encoding of Swift UUID dictionaries is introduced here.
     */
    private fun projectPayload(root: JsonObject): CanvasProject? {
        val value = root["canvasDocument"] as? JsonObject ?: return null
        return runCatching { CreativeWire.decodeCanvasProject(value) }.getOrNull()
    }

    private fun projectContentType(root: JsonObject): DesignContentType {
        val project = root["project"] as? JsonObject ?: return DesignContentType.COMPOSITION
        return DesignContentType.entries.firstOrNull {
            it.wire == project.string("contentType")
        } ?: DesignContentType.COMPOSITION
    }

    /**
     * Bounded descriptive metadata only (max 64 unique references). No path
     * from this JSON is ever opened; image bytes are resolved by the captured
     * native Canvas owner below and digest-verified there.
     */
    private fun parseSnapshotAssets(root: JsonObject): List<DesignPreviewContent.CanvasSnapshotAsset> {
        val array = root["assets"] as? JsonArray ?: return emptyList()
        val seen = LinkedHashSet<String>()
        return array.mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val assetID = value.string("assetID")
                ?.takeIf { isUuid(it) }
                ?: return@mapNotNull null
            if (!seen.add(assetID)) return@mapNotNull null
            if (seen.size > MAX_SNAPSHOT_ASSETS) return@mapNotNull null
            DesignPreviewContent.CanvasSnapshotAsset(
                assetID = assetID,
                kind = value.string("kind").orEmpty(),
                mimeType = value.string("mimeType"),
                contentHash = value.string("contentHash")
                    ?.takeIf { MediaWorkbenchExportProof.isSha256Hex(it) },
                byteCount = value.long("byteCount"),
                verified = value.boolean("verified") ?: false,
                bitmapAvailable = false,
            )
        }
    }

    private fun parseJson(file: File): JsonObject? = try {
        Json { ignoreUnknownKeys = true }.parseToJsonElement(file.readText()) as? JsonObject
    } catch (_: Throwable) {
        null
    }

    private fun projectHasRevision(project: JsonObject, revisionID: String): Boolean {
        val artifacts = project["artifacts"] as? JsonArray ?: return false
        return artifacts.any { element ->
            val artifact = element as? JsonObject ?: return@any false
            val revisions = artifact["revisions"] as? JsonArray ?: return@any false
            revisions.any { item ->
                (item as? JsonObject)?.string("id") == revisionID
            }
        }
    }

    private fun sameTarget(left: DesignTargetIdentity, right: DesignTargetIdentity): Boolean =
        left.kind == right.kind &&
            left.ownerID == right.ownerID &&
            left.documentID == right.documentID &&
            left.sourceID == right.sourceID

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_RECEIPT_BYTES) {
                    throw CreativeException("designPreviewTooLarge", "receiptSizeRefused")
                }
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.boolean(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun isUuid(value: String): Boolean =
        runCatching { java.util.UUID.fromString(value) }.isSuccess

    internal enum class DesignArtifactKind { PREVIEW, EXPORT }

    private data class ReceiptView(
        val target: DesignTargetIdentity,
        val ownerRevision: Long,
        val candidateID: String?,
        val revisionID: String?,
        val format: String,
        val rootPath: String,
        val relativePath: String,
        val byteCount: Long,
        val sha256: String,
    )

    internal data class DesignArtifactCapture(
        val epoch: Long,
        val targetKey: String,
        val rootPath: String,
        val relativePath: String,
        val file: File,
        val byteCount: Long,
        val sha256: String,
        val format: String,
        val ownerRevision: Long,
        val candidateID: String?,
        val revisionID: String?,
        val kind: DesignArtifactKind,
    ) {
        val key: String
            get() = listOf(
                targetKey, rootPath, relativePath, sha256, byteCount.toString(),
                ownerRevision.toString(), candidateID.orEmpty(), revisionID.orEmpty(),
                kind.name,
            ).joinToString("|")

        val mimeType: String
            get() = when (format) {
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "gif" -> "image/gif"
                "bmp" -> "image/bmp"
                "heif", "heic" -> "image/heic"
                "tif", "tiff" -> "image/tiff"
                "pdf" -> "application/pdf"
                "md", "markdown" -> "text/markdown"
                "txt", "text" -> "text/plain"
                "html", "htm" -> "text/html"
                "svg" -> "image/svg+xml"
                "json", "canvas.snapshot" -> "application/json"
                else -> "application/octet-stream"
            }

        val suggestedName: String
            get() {
                val raw = relativePath.substringAfterLast('/')
                val safe = raw
                    .map { if (it.code < 0x20 || it == '/' || it == '\\') '_' else it }
                    .joinToString("")
                    .trim()
                    .trimStart('.')
                    .take(120)
                return safe.ifBlank { "design.${format.take(12)}" }
            }
    }

    companion object {
        private const val MAX_RECEIPT_BYTES = 64L * 1024 * 1024
        private const val MAX_CAPTURES = 64
        private const val MAX_IMAGE_PIXELS = DesignImageBounds.MAX_IMAGE_PIXELS
        private const val MAX_IMAGE_DIMENSION = DesignImageBounds.MAX_IMAGE_DIMENSION
        private const val MAX_IMAGE_BITMAP_BYTES = DesignImageBounds.MAX_IMAGE_BITMAP_BYTES
        private const val MAX_SNAPSHOT_ASSETS = 64
        private const val CANVAS_SNAPSHOT_FORMAT = DesignCanvasSnapshotPayload.FORMAT
        private const val MAX_PDF_PAGES = 3
        private const val MAX_PDF_PAGE_WIDTH = 1280f
        private const val MAX_PDF_PAGE_HEIGHT = 1600f
        private const val MAX_PDF_PAGE_PIXELS = 2_500_000L
        private const val MAX_PDF_TOTAL_BYTES = 24 * 1024 * 1024L
        private const val MAX_TEXT_PREVIEW_BYTES = 64 * 1024
        private val IMAGE_FORMATS = setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heif", "heic")
        private val TEXT_FORMATS = setOf(
            "txt", "text", "md", "markdown", "html", "htm", "svg", "json", "xml", "css", "js",
        )
    }
}
