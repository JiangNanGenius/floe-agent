// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.presentation

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorMatrix
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativePathGuard
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.NormalizedRect
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

enum class MediaFailureKind {
    NEEDS_CORE_UPDATE,
    RUNTIME_NOT_READY,
    SESSION_LOST,
    REVISION_CONFLICT,
    OUTCOME_UNKNOWN,
    NOT_FOUND,
    CORRUPT,
    TOO_LARGE,
    OWNER_BLOCKED,
    ORIGIN_REQUIRED,
    STORAGE,
    ASSET,
    INVALID_REQUEST,
    /** G09-R2 generation/candidate failure (catalog, provider or job state). */
    GENERATION,
    /** G09-R2 verified export/render failure that is not a capability refusal. */
    EXPORT,
    /** G09-R2 honest refusal from actual render capabilities. */
    UNSUPPORTED,
    UNKNOWN,
}

data class MediaFailure(
    val kind: MediaFailureKind,
    val code: String? = null,
    val retryable: Boolean = false,
) {
    val availability: CreativeAvailability?
        get() = when (kind) {
            MediaFailureKind.NEEDS_CORE_UPDATE -> CreativeAvailability.NeedsCoreUpdate
            MediaFailureKind.RUNTIME_NOT_READY -> CreativeAvailability.WaitingForRuntime
            else -> null
        }
}

object MediaFailures {
    fun from(error: Throwable): MediaFailure {
        val typed = error as? CreativeException
        return MediaFailure(
            kind = kindForCode(typed?.code),
            code = typed?.code,
            retryable = typed?.retryable == true ||
                kindForCode(typed?.code) == MediaFailureKind.RUNTIME_NOT_READY,
        )
    }

    /**
     * Maps a bounded platform/playback error code (already free of secrets and
     * file paths) to the shared failure surface. Used by the playback
     * controller where the async platform handle reports terminal refusal
     * codes through [com.floe.android.feature.workbench.PlaybackState] rather
     * than a thrown exception.
     */
    fun fromCode(code: String?): MediaFailure? {
        if (code.isNullOrEmpty()) return null
        return MediaFailure(
            kind = kindForCode(code),
            code = code,
            retryable = kindForCode(code) == MediaFailureKind.RUNTIME_NOT_READY,
        )
    }

    internal fun kindForCode(code: String?): MediaFailureKind = when (code) {
            "needsCoreUpdate", "coreTooNew", "unsupportedSchema" ->
                MediaFailureKind.NEEDS_CORE_UPDATE
            "runtimeUnavailable", "acceptedRootNotLive" ->
                MediaFailureKind.RUNTIME_NOT_READY
            "staleSession", "staleGeneration", "sessionRequired", "invalidSession" ->
                MediaFailureKind.SESSION_LOST
            "revisionConflict" -> MediaFailureKind.REVISION_CONFLICT
            "outcomeUnknown" -> MediaFailureKind.OUTCOME_UNKNOWN
            "mediaProjectNotFound" -> MediaFailureKind.NOT_FOUND
            "corruptProject" -> MediaFailureKind.CORRUPT
            "projectTooLarge", "responseTooLarge" -> MediaFailureKind.TOO_LARGE
            "storageLayerRequired", "invalidOrigin" ->
                MediaFailureKind.ORIGIN_REQUIRED
            "workspaceStorageUnavailable" -> MediaFailureKind.ORIGIN_REQUIRED
            "untrustedOwner", "provenanceMismatch", "crossOwnerRefused" ->
                MediaFailureKind.OWNER_BLOCKED
            "assetTooLarge", "assetEmpty", "assetDigestMismatch",
            "assetStagingInvalid", "assetStagingUnavailable", "assetMissing",
            "assetReferenceInvalid",
            -> MediaFailureKind.ASSET
            "storageUnavailable", "writeFailed" -> MediaFailureKind.STORAGE
            "invalidRequest", "invalidPayload", "sessionLimit" ->
                MediaFailureKind.INVALID_REQUEST
            // G09-R2 generation/candidates.
            "generationUnavailable", "modelUnavailable", "providerRejected",
            "providerTimeout", "jobNotFound", "jobTerminal", "candidateNotFound",
            "candidateStale", "generationUnavailableForProject" ->
                MediaFailureKind.GENERATION
            // G09-R2 actual-capability refusals.
            "renderUnsupported", "unsupportedCodec", "unsupportedTransition",
            "unsupportedSourceFormat", "rendererUnavailable" ->
                MediaFailureKind.UNSUPPORTED
            // G09-R2 export/render lifecycle.
            "renderCancelled", "renderTimeout", "renderTicketNotFound",
            "renderTicketExpired", "renderTicketAlreadySettled", "foregroundStartDenied" ->
                MediaFailureKind.EXPORT
            else -> MediaFailureKind.UNKNOWN
    }
}

enum class MediaNotice {
    ASSET_IMPORTED,
    ASSET_IMPORTED_NO_LAYER,
    RELOADED,
    LAYER_REMOVED,
    MISSING_ASSETS,
}

/**
 * Canonical preview path for one project-relative asset reference. The trusted
 * root is always [MediaProjectEnvelope.mediaRootPath]; a recorded
 * `taskWorkspacePath` or an absolute asset path is never accepted here.
 */
object MediaPreviewPaths {
    fun resolve(mediaRootPath: String, relativePath: String?): String? {
        if (relativePath.isNullOrEmpty() || mediaRootPath.isEmpty()) return null
        if (!CreativePathGuard.isSafeRelativePath(relativePath)) return null
        return try {
            val root = File(mediaRootPath).canonicalFile
            if (!root.isDirectory) return null
            val target = File(root, relativePath).canonicalFile
            val prefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
            target.path.takeIf { it.startsWith(prefix) && File(it).isFile }
        } catch (_: Throwable) {
            null
        }
    }
}

object MediaBitmapLoader {
    private const val MAX_EDGE = 2048
    private const val MAX_PIXELS = 4_000_000L
    private const val MAX_SAMPLE = 64

    private val cache = object : LruCache<String, Bitmap>(64 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    suspend fun load(path: String): Bitmap? = withContext(Dispatchers.IO) {
        synchronized(cache) { cache.get(path) }?.let { if (!it.isRecycled) return@withContext it }
        val decoded = decode(path) ?: return@withContext null
        synchronized(cache) { cache.put(path, decoded) }
        decoded
    }

    fun clear() {
        synchronized(cache) { cache.evictAll() }
    }

    private fun decode(path: String): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(path, options)
        } catch (_: Throwable) {
            null
        }
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (sample < MAX_SAMPLE) {
            val w = width / sample
            val h = height / sample
            if (w in 1..MAX_EDGE && h in 1..MAX_EDGE &&
                w.toLong() * h.toLong() <= MAX_PIXELS
            ) return sample
            sample *= 2
        }
        return sample
    }
}

data class PixelRect(val left: Int, val top: Int, val width: Int, val height: Int)

object MediaLayerGeometry {
    /** Aspect-fit source size inside the project canvas (pixel units). */
    fun fitInto(
        sourceWidth: Double,
        sourceHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double,
    ): Pair<Double, Double> {
        if (sourceWidth <= 0.0 || sourceHeight <= 0.0 ||
            canvasWidth <= 0.0 || canvasHeight <= 0.0
        ) return 0.0 to 0.0
        val scale = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
        return (sourceWidth * scale) to (sourceHeight * scale)
    }

    /**
     * Source pixel crop. The stored crop is normalized to the source frame,
     * so it is applied before the aspect-fit natural placement.
     */
    fun cropRect(crop: NormalizedRect?, sourceWidth: Int, sourceHeight: Int): PixelRect {
        if (sourceWidth <= 0 || sourceHeight <= 0) return PixelRect(0, 0, 1, 1)
        val rect = crop ?: NormalizedRect.UNIT
        val left = (rect.x * sourceWidth).toInt().coerceIn(0, max(0, sourceWidth - 1))
        val top = (rect.y * sourceHeight).toInt().coerceIn(0, max(0, sourceHeight - 1))
        val width = (rect.width * sourceWidth).toInt()
            .coerceIn(1, max(1, sourceWidth - left))
        val height = (rect.height * sourceHeight).toInt()
            .coerceIn(1, max(1, sourceHeight - top))
        return PixelRect(left, top, width, height)
    }

    /** Centered crop maximizing area for [aspect] (width/height); null = full. */
    fun centeredCrop(aspect: Double?, sourceWidth: Int, sourceHeight: Int): NormalizedRect {
        if (aspect == null || aspect <= 0.0 || sourceWidth <= 0 || sourceHeight <= 0) {
            return NormalizedRect.UNIT
        }
        val sourceAspect = sourceWidth.toDouble() / sourceHeight.toDouble()
        val crop = if (sourceAspect > aspect) {
            NormalizedRect(
                x = (1.0 - aspect / sourceAspect) / 2,
                y = 0.0,
                width = aspect / sourceAspect,
                height = 1.0,
            )
        } else {
            NormalizedRect(
                x = 0.0,
                y = (1.0 - sourceAspect / aspect) / 2,
                width = 1.0,
                height = sourceAspect / aspect,
            )
        }
        return crop
    }

    /** Natural (untransformed) rendered size of a layer in canvas pixels. */
    fun naturalSize(
        layer: ImageLayer,
        asset: MediaAssetReference?,
        bitmap: Bitmap?,
        canvas: MediaCanvas?,
    ): Pair<Double, Double> {
        val width = canvas?.width?.toDouble() ?: 0.0
        val height = canvas?.height?.toDouble() ?: 0.0
        return when (layer.kind) {
            "image" -> {
                val bitmapWidth = bitmap?.width ?: asset?.metadata?.width ?: 0
                val bitmapHeight = bitmap?.height ?: asset?.metadata?.height ?: 0
                if (bitmapWidth <= 0 || bitmapHeight <= 0) {
                    width * 0.6 to height * 0.6
                } else {
                    val crop = cropRect(layer.crop, bitmapWidth, bitmapHeight)
                    fitInto(crop.width.toDouble(), crop.height.toDouble(), width, height)
                }
            }
            else -> width to height
        }
    }

    /**
     * Effective on-canvas center/size for drawing. Transform is a normalized
     * center anchor plus a uniform scale, matching the shared iOS renderer.
     */
    fun placedBounds(
        layer: ImageLayer,
        asset: MediaAssetReference?,
        bitmap: Bitmap?,
        canvas: MediaCanvas?,
    ): PlacedLayerBounds {
        val (naturalWidth, naturalHeight) = naturalSize(layer, asset, bitmap, canvas)
        val canvasWidth = canvas?.width?.toDouble() ?: 1.0
        val canvasHeight = canvas?.height?.toDouble() ?: 1.0
        val scale = layer.transform.scale.takeIf { it.isFinite() && it > 0 } ?: 1.0
        return PlacedLayerBounds(
            centerX = layer.transform.centerX.coerceIn(0.0, 2.0) * canvasWidth,
            centerY = layer.transform.centerY.coerceIn(0.0, 2.0) * canvasHeight,
            width = naturalWidth * scale,
            height = naturalHeight * scale,
            rotationDegrees = layer.transform.rotationDegrees,
        )
    }
}

data class PlacedLayerBounds(
    val centerX: Double,
    val centerY: Double,
    val width: Double,
    val height: Double,
    val rotationDegrees: Double,
)

object MediaColor {
    fun parseCompose(hex: String?, fallback: Color): Color {
        val argb = parseArgb(hex) ?: return fallback
        return Color(argb)
    }

    fun parseArgb(hex: String?): Int? {
        if (hex == null) return null
        return try {
            val value = hex.removePrefix("#")
            when (value.length) {
                6 -> (0xFF000000L or value.toLong(16)).toInt()
                8 -> value.toLong(16).toInt()
                else -> null
            }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Basic preview matrix for the persisted per-layer adjustment. Unsupported
     * advanced effects (blur/mosaic/levels/temperature) stay persisted and are
     * applied by the export renderer; the preview never pretends to show them.
     */
    fun previewMatrix(adjustment: ImageLayerAdjustment): ColorMatrix? {
        val brightness = adjustment.brightness?.toFloat()
        val contrast = adjustment.contrast?.toFloat()
        val saturation = adjustment.saturation?.toFloat()
        if (brightness == null && contrast == null && saturation == null) return null
        val c = (contrast ?: 0f).coerceIn(-4f, 4f).let { 1f + it }
        val s = (saturation ?: 1f).coerceIn(0f, 4f)
        val offset = (1f - c) * 127.5f + (brightness ?: 0f).coerceIn(-4f, 4f) * 127.5f
        val lumR = 0.213f
        val lumG = 0.715f
        val lumB = 0.072f
        val sr = (1f - s) * lumR
        val sg = (1f - s) * lumG
        val sb = (1f - s) * lumB
        val values = floatArrayOf(
            c * (sr + s), c * sg, c * sb, 0f, offset,
            c * sr, c * (sg + s), c * sb, 0f, offset,
            c * sr, c * sg, c * (sb + s), 0f, offset,
            0f, 0f, 0f, 1f, 0f,
        )
        return ColorMatrix(values)
    }
}

/** Human-readable media kind labels are resolved by the Compose layer. */
fun MediaProject.layerCount(): Int = imageLayers.size

fun MediaProject.assetForLayer(layer: ImageLayer): MediaAssetReference? =
    layer.assetID?.let { id -> assets.firstOrNull { it.id == id } }
