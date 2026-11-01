// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.feature.workbench.ImageLayerAdjustment
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Deterministic bitmap adjustment pipeline. It is a real pixel pipeline, not
 * a declaration: Core Image filters are not portable, so the six supported
 * `filterID` names get explicit matrix equivalents and an unknown name is a
 * typed refusal. The iOS pipeline order is preserved (temperature, hue,
 * levels, saturation/contrast/brightness, exposure, blur, sharpen, mosaic,
 * filter).
 */
internal object ImageAdjustments {
    private val SUPPORTED_FILTERS = setOf(
        "CIPhotoEffectMono", "CIPhotoEffectNoir", "CIPhotoEffectChrome",
        "CIPhotoEffectFade", "CIPhotoEffectInstant", "CISepiaTone",
    )

    fun isIdentity(adjustment: ImageLayerAdjustment): Boolean =
        adjustment.saturation == null && adjustment.contrast == null &&
            adjustment.brightness == null && adjustment.exposureEV == null &&
            adjustment.blurRadius == null && adjustment.sharpenRadius == null &&
            adjustment.mosaicBlockSize == null && adjustment.filterID == null &&
            adjustment.temperature == null && adjustment.hueDegrees == null &&
            adjustment.levels == null

    fun apply(source: Bitmap, adjustment: ImageLayerAdjustment, scale: Double = 1.0): Bitmap {
        if (isIdentity(adjustment)) return source
        var current = source
        try {
            var matrix = ColorMatrix()
            var hasMatrix = false
            adjustment.temperature?.takeIf { it.isFinite() }?.let {
                matrix.postConcat(temperatureMatrix(it))
                hasMatrix = true
            }
            adjustment.hueDegrees?.takeIf { it.isFinite() && abs(it) > 0.001 }?.let {
                matrix.postConcat(hueMatrix(it))
                hasMatrix = true
            }
            if (adjustment.saturation != null || adjustment.contrast != null || adjustment.brightness != null) {
                matrix.postConcat(colorControlsMatrix(adjustment))
                hasMatrix = true
            }
            adjustment.exposureEV?.takeIf { it.isFinite() && abs(it) > 0.001 }?.let {
                matrix.postConcat(exposureMatrix(it))
                hasMatrix = true
            }
            val levels = adjustment.levels
            val hasGamma = levels != null && (levels.double("gamma") ?: 1.0) != 1.0
            if (levels != null && !hasGamma) {
                matrix.postConcat(levelsMatrix(levels))
                hasMatrix = true
            }
            adjustment.filterID?.let { id ->
                if (id !in SUPPORTED_FILTERS) {
                    throw refusal(RENDER_UNSUPPORTED, "Unknown active image filter $id")
                }
                matrix.postConcat(filterMatrix(id))
                hasMatrix = true
            }
            if (hasMatrix) current = applyMatrix(current, matrix)
            if (hasGamma) current = applyLevelsLut(current, levels!!)
            adjustment.blurRadius?.takeIf { it.isFinite() && it > 0.0 }?.let { radius ->
                val scaled = radius * scale
                if (scaled > 128.0) {
                    throw refusal(RENDER_UNSUPPORTED, "Active blur radius exceeds the bounded renderer")
                }
                current = BoxBlur.blur(current, max(1, scaled.toInt()))
            }
            adjustment.sharpenRadius?.takeIf { it.isFinite() && it > 0.0 }?.let { radius ->
                val scaled = radius * scale
                if (scaled > 128.0) {
                    throw refusal(RENDER_UNSUPPORTED, "Active sharpen radius exceeds the bounded renderer")
                }
                current = sharpen(current, max(1, scaled.toInt()))
            }
            adjustment.mosaicBlockSize?.takeIf { it > 0 }?.let { block ->
                current = mosaic(current, max(2, (block * scale).toInt()))
            }
            return current
        } catch (failure: Throwable) {
            if (current !== source) current.recycle()
            throw failure
        }
    }

    private fun applyMatrix(source: Bitmap, matrix: ColorMatrix): Bitmap {
        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawBitmap(source, 0f, 0f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            colorFilter = ColorMatrixColorFilter(matrix)
        })
        source.recycle()
        return output
    }

    private fun colorControlsMatrix(adjustment: ImageLayerAdjustment): ColorMatrix {
        val contrast = adjustment.contrast?.coerceIn(-1.0, 1.0) ?: 0.0
        val saturation = adjustment.saturation?.coerceIn(0.0, 2.0) ?: 1.0
        val brightness = adjustment.brightness?.coerceIn(-1.0, 1.0) ?: 0.0
        val c = (1.0 + contrast).coerceAtLeast(0.0)
        val t = (1.0 - c) * 127.5 + brightness * 255.0
        val sat = ColorMatrix().apply { setSaturation(saturation.toFloat()) }
        val contrastMatrix = ColorMatrix(floatArrayOf(
            c.toFloat(), 0f, 0f, 0f, t.toFloat(),
            0f, c.toFloat(), 0f, 0f, t.toFloat(),
            0f, 0f, c.toFloat(), 0f, t.toFloat(),
            0f, 0f, 0f, 1f, 0f,
        ))
        return ColorMatrix().also { it.postConcat(contrastMatrix); it.postConcat(sat) }
    }

    private fun exposureMatrix(ev: Double): ColorMatrix {
        val scale = 2.0.pow(ev.coerceIn(-4.0, 4.0)).toFloat()
        return ColorMatrix(floatArrayOf(
            scale, 0f, 0f, 0f, 0f,
            0f, scale, 0f, 0f, 0f,
            0f, 0f, scale, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        ))
    }

    private fun temperatureMatrix(kelvin: Double): ColorMatrix {
        val delta = ((kelvin.coerceIn(1000.0, 40_000.0) - 6500.0) / 5500.0).coerceIn(-1.0, 1.0)
        val r = (1.0 + 0.18 * delta).toFloat()
        val b = (1.0 - 0.18 * delta).toFloat()
        return ColorMatrix(floatArrayOf(
            r, 0f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f, 0f,
            0f, 0f, b, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        ))
    }

    private fun hueMatrix(degrees: Double): ColorMatrix {
        val radians = Math.toRadians(degrees)
        val c = cos(radians)
        val s = sin(radians)
        val m = floatArrayOf(
            (0.213 + c * 0.787 - s * 0.213).toFloat(),
            (0.715 - c * 0.715 - s * 0.715).toFloat(),
            (0.072 - c * 0.072 + s * 0.928).toFloat(), 0f, 0f,
            (0.213 - c * 0.213 + s * 0.143).toFloat(),
            (0.715 + c * 0.285 + s * 0.140).toFloat(),
            (0.072 - c * 0.072 - s * 0.283).toFloat(), 0f, 0f,
            (0.213 - c * 0.213 - s * 0.787).toFloat(),
            (0.715 - c * 0.715 + s * 0.715).toFloat(),
            (0.072 + c * 0.928 + s * 0.072).toFloat(), 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        )
        return ColorMatrix(m)
    }

    private fun levelsMatrix(levels: JsonObject): ColorMatrix {
        val black = (levels.double("black") ?: 0.0).coerceIn(0.0, 0.99)
        val white = (levels.double("white") ?: 1.0).coerceIn(black + 0.01, 1.0)
        val span = white - black
        val scale = (1.0 / span).toFloat()
        val offset = (-black / span * 255.0).toFloat()
        return ColorMatrix(floatArrayOf(
            scale, 0f, 0f, 0f, offset,
            0f, scale, 0f, 0f, offset,
            0f, 0f, scale, 0f, offset,
            0f, 0f, 0f, 1f, 0f,
        ))
    }

    private fun applyLevelsLut(source: Bitmap, levels: JsonObject): Bitmap {
        val black = (levels.double("black") ?: 0.0).coerceIn(0.0, 0.99)
        val white = (levels.double("white") ?: 1.0).coerceIn(black + 0.01, 1.0)
        val gamma = (levels.double("gamma") ?: 1.0).coerceIn(0.01, 10.0)
        val lut = IntArray(256)
        val span = white - black
        for (i in 0..255) {
            val normalized = ((i / 255.0 - black) / span).coerceIn(0.0, 1.0)
            val gammaCorrected = normalized.pow(1.0 / gamma)
            lut[i] = (gammaCorrected * 255.0).toInt().coerceIn(0, 255)
        }
        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(source.width * source.height)
        source.getPixels(pixels, 0, source.width, 0, 0, source.width, source.height)
        for (index in pixels.indices) {
            val value = pixels[index]
            val a = value ushr 24
            val r = lut[(value ushr 16) and 0xff]
            val g = lut[(value ushr 8) and 0xff]
            val b = lut[value and 0xff]
            pixels[index] = (a shl 24) or (r shl 16) or (g shl 8) or b
        }
        output.setPixels(pixels, 0, source.width, 0, 0, source.width, source.height)
        source.recycle()
        return output
    }

    private fun filterMatrix(id: String): ColorMatrix = when (id) {
        "CIPhotoEffectMono" -> ColorMatrix().apply { setSaturation(0f) }
        "CIPhotoEffectNoir" -> ColorMatrix().also {
            it.postConcat(ColorMatrix().apply { setSaturation(0f) })
            it.postConcat(ColorMatrix(floatArrayOf(
                1.2f, 0f, 0f, 0f, -20f,
                0f, 1.2f, 0f, 0f, -20f,
                0f, 0f, 1.2f, 0f, -20f,
                0f, 0f, 0f, 1f, 0f,
            )))
        }
        "CIPhotoEffectChrome" -> ColorMatrix().also {
            it.postConcat(ColorMatrix().apply { setSaturation(1.3f) })
            it.postConcat(ColorMatrix(floatArrayOf(
                1.1f, 0f, 0f, 0f, -8f,
                0f, 1.1f, 0f, 0f, -8f,
                0f, 0f, 1.1f, 0f, -8f,
                0f, 0f, 0f, 1f, 0f,
            )))
        }
        "CIPhotoEffectFade" -> ColorMatrix(floatArrayOf(
            0.9f, 0f, 0f, 0f, 22f,
            0f, 0.9f, 0f, 0f, 22f,
            0f, 0f, 0.9f, 0f, 22f,
            0f, 0f, 0f, 1f, 0f,
        ))
        "CIPhotoEffectInstant" -> ColorMatrix().also {
            it.postConcat(ColorMatrix().apply { setSaturation(1.1f) })
            it.postConcat(ColorMatrix(floatArrayOf(
                1.05f, 0f, 0f, 0f, 4f,
                0f, 1.0f, 0f, 0f, 0f,
                0f, 0f, 0.95f, 0f, 2f,
                0f, 0f, 0f, 1f, 0f,
            )))
        }
        "CISepiaTone" -> ColorMatrix(floatArrayOf(
            0.393f, 0.769f, 0.189f, 0f, 0f,
            0.349f, 0.686f, 0.168f, 0f, 0f,
            0.272f, 0.534f, 0.131f, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        ))
        else -> throw refusal(RENDER_UNSUPPORTED, "Unknown active image filter $id")
    }

    private fun sharpen(source: Bitmap, radius: Int): Bitmap {
        val blurred = BoxBlur.blur(source, radius, recycleSource = false)
        val width = source.width
        val height = source.height
        val src = IntArray(width * height)
        val soft = IntArray(width * height)
        source.getPixels(src, 0, width, 0, 0, width, height)
        blurred.getPixels(soft, 0, width, 0, 0, width, height)
        val amount = 0.8
        for (i in src.indices) {
            val a = src[i] ushr 24
            val r = sharpChannel((src[i] ushr 16) and 0xff, (soft[i] ushr 16) and 0xff, amount)
            val g = sharpChannel((src[i] ushr 8) and 0xff, (soft[i] ushr 8) and 0xff, amount)
            val b = sharpChannel(src[i] and 0xff, soft[i] and 0xff, amount)
            src[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
        }
        blurred.recycle()
        source.recycle()
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            setPixels(src, 0, width, 0, 0, width, height)
        }
    }

    private fun sharpChannel(original: Int, soft: Int, amount: Double): Int =
        (original + amount * (original - soft)).toInt().coerceIn(0, 255)

    private fun mosaic(source: Bitmap, block: Int): Bitmap {
        val width = max(1, ceil(source.width.toDouble() / block).toInt())
        val height = max(1, ceil(source.height.toDouble() / block).toInt())
        val small = Bitmap.createScaledBitmap(source, width, height, false)
        val output = Bitmap.createScaledBitmap(small, source.width, source.height, false)
        small.recycle()
        source.recycle()
        return output
    }

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.content?.toDoubleOrNull()
}

/** Separable, bounded box blur used by adjustments and mask feathering. */
internal object BoxBlur {
    fun blur(source: Bitmap, radius: Int, recycleSource: Boolean = true): Bitmap {
        val clamped = radius.coerceIn(1, 128)
        val width = source.width
        val height = source.height
        val pixels = IntArray(width * height)
        source.getPixels(pixels, 0, width, 0, 0, width, height)
        val horizontal = IntArray(width * height)
        val window = clamped * 2 + 1
        for (y in 0 until height) {
            var a = 0L; var r = 0L; var g = 0L; var b = 0L
            for (offset in -clamped..clamped) {
                val x = offset.coerceIn(0, width - 1)
                val value = pixels[y * width + x]
                a += value ushr 24; r += (value ushr 16) and 0xff
                g += (value ushr 8) and 0xff; b += value and 0xff
            }
            for (x in 0 until width) {
                horizontal[y * width + x] =
                    ((a / window).toInt() shl 24) or
                    ((r / window).toInt() shl 16) or
                    ((g / window).toInt() shl 8) or (b / window).toInt()
                val removeX = (x - clamped).coerceIn(0, width - 1)
                val addX = (x + clamped + 1).coerceIn(0, width - 1)
                val remove = pixels[y * width + removeX]
                val add = pixels[y * width + addX]
                a += (add ushr 24) - (remove ushr 24)
                r += ((add ushr 16) and 0xff) - ((remove ushr 16) and 0xff)
                g += ((add ushr 8) and 0xff) - ((remove ushr 8) and 0xff)
                b += (add and 0xff) - (remove and 0xff)
            }
        }
        val output = IntArray(width * height)
        for (x in 0 until width) {
            var a = 0L; var r = 0L; var g = 0L; var b = 0L
            for (offset in -clamped..clamped) {
                val y = offset.coerceIn(0, height - 1)
                val value = horizontal[y * width + x]
                a += value ushr 24; r += (value ushr 16) and 0xff
                g += (value ushr 8) and 0xff; b += value and 0xff
            }
            for (y in 0 until height) {
                output[y * width + x] =
                    ((a / window).toInt() shl 24) or
                    ((r / window).toInt() shl 16) or
                    ((g / window).toInt() shl 8) or (b / window).toInt()
                val removeY = (y - clamped).coerceIn(0, height - 1)
                val addY = (y + clamped + 1).coerceIn(0, height - 1)
                val remove = horizontal[removeY * width + x]
                val add = horizontal[addY * width + x]
                a += (add ushr 24) - (remove ushr 24)
                r += ((add ushr 16) and 0xff) - ((remove ushr 16) and 0xff)
                g += ((add ushr 8) and 0xff) - ((remove ushr 8) and 0xff)
                b += (add and 0xff) - (remove and 0xff)
            }
        }
        if (recycleSource) source.recycle()
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            setPixels(output, 0, width, 0, 0, width, height)
        }
    }
}
