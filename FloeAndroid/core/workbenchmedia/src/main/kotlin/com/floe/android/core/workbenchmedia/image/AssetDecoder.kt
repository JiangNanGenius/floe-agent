// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.refusal
import java.io.File
import kotlin.math.max
import kotlin.math.min

internal data class DecodedImage(
    val bitmap: Bitmap,
    val hasAlpha: Boolean,
)

/**
 * Bounded image decoder. Source pixels are never mutated; EXIF orientation is
 * applied where the platform exposes it. Preview decodes are down-sampled to
 * an explicit edge; full export decodes are guarded by pixel/edge budgets and
 * a bounded allocation error path.
 */
internal object AssetDecoder {
    const val MAX_SOURCE_PIXELS = 24_000_000L
    const val MAX_SOURCE_EDGE = 16_384
    const val MAX_DECODE_BYTES = 256L * 1024L * 1024L

    fun decode(file: File, maxEdge: Int?): DecodedImage {
        if (!file.isFile) throw refusal(RENDER_UNSUPPORTED, "Image asset is missing")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) {
            throw refusal(RENDER_UNSUPPORTED, "Image dimensions could not be read")
        }
        if (maxEdge == null) {
            if (width > MAX_SOURCE_EDGE || height > MAX_SOURCE_EDGE ||
                width.toLong() * height.toLong() > MAX_SOURCE_PIXELS ||
                width.toLong() * height.toLong() * 4L > MAX_DECODE_BYTES
            ) {
                throw refusal(
                    RENDER_UNSUPPORTED,
                    "Source image exceeds the full-resolution decode guard; use a scaled copy",
                )
            }
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(width, height, maxEdge)
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
            inDither = false
        }
        val decoded = try {
            BitmapFactory.decodeFile(file.path, options)
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: Exception) {
            null
        } ?: throw refusal(RENDERER_UNAVAILABLE, "Image decode returned no bitmap")
        val oriented = applyOrientation(file, decoded)
        val result = if (maxEdge != null) {
            val longest = max(oriented.width, oriented.height)
            if (longest > maxEdge) {
                val scale = maxEdge.toDouble() / longest
                val scaled = Bitmap.createScaledBitmap(
                    oriented,
                    max(1, (oriented.width * scale).toInt()),
                    max(1, (oriented.height * scale).toInt()),
                    true,
                )
                if (scaled !== oriented) oriented.recycle()
                scaled
            } else {
                oriented
            }
        } else {
            oriented
        }
        return DecodedImage(result, result.hasAlpha())
    }

    private fun sampleSize(width: Int, height: Int, maxEdge: Int?): Int {
        var sample = 1
        while (sample < 64) {
            val w = width / sample
            val h = height / sample
            if (maxEdge != null) {
                if (max(w, h) <= maxEdge && w.toLong() * h.toLong() * 4L <= MAX_DECODE_BYTES) return sample
            } else {
                if (w.toLong() * h.toLong() * 4L <= MAX_DECODE_BYTES) return sample
            }
            sample *= 2
        }
        return sample
    }

    private fun applyOrientation(file: File, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(file.path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return try {
            val transformed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (transformed !== bitmap) bitmap.recycle()
            transformed
        } catch (_: Exception) {
            bitmap
        }
    }

    fun samplePreviewEdge(canvasWidth: Int, canvasHeight: Int): Int =
        min(2_048, max(1, max(canvasWidth, canvasHeight)))
}
