// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot
import com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.RENDER_CANCELLED
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.atomicReplace
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.util.writeFullySync
import com.floe.android.core.workbenchmedia.video.ImageVerifier
import com.floe.android.core.workbenchmedia.video.VerifiedOutput
import com.floe.android.feature.workbench.ImageExportSettings
import com.floe.android.feature.workbench.asset
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max

internal data class EncodedImage(
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
    val format: String,
)

/**
 * Real PNG/JPEG image export and preview. HEIC is not offered: the source
 * stage has no qualified platform HEIF writer path, and a fake
 * `Bitmap.CompressFormat` value is not invented. Every output is encoded,
 * decoded back, dimension/format checked, fsynced to a task-owned staging file
 * and only then atomically published.
 */
internal object ImageExporter {
    const val MAX_OUTPUT_PIXELS = 16_000_000L
    const val MAX_OUTPUT_EDGE = 8_192
    const val MAX_OUTPUT_BYTES = 512L * 1024L * 1024L

    fun validate(snapshot: VerifiedSnapshot, settings: ImageExportSettings): Pair<Int, Int> {
        if (snapshot.projection.project.kind != "image") {
            throw refusal(UNSUPPORTED_FORMAT_IMAGE, "The snapshot is not an image project")
        }
        val canvas = snapshot.projection.project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        val format = settings.format.lowercase()
        if (format != "png" && format != "jpeg") {
            throw refusal(
                RENDER_UNSUPPORTED,
                if (format == "heic") {
                    "HEIC export is unavailable because no qualified platform HEIF writer is implemented"
                } else {
                    "Unsupported image format ${settings.format}"
                },
            )
        }
        if (!settings.quality.isFinite() || settings.quality < 0.01 || settings.quality > 1.0) {
            throw refusal(INVALID_PAYLOAD, "Export quality must be 0.01...1")
        }
        val hasWidth = settings.width != null
        val hasHeight = settings.height != null
        if (hasWidth != hasHeight) {
            throw refusal(INVALID_PAYLOAD, "Provide both export dimensions or neither")
        }
        val width = settings.width ?: canvas.width
        val height = settings.height ?: canvas.height
        if (width < 2 || height < 2 || width > MAX_OUTPUT_EDGE || height > MAX_OUTPUT_EDGE ||
            width.toLong() * height.toLong() > MAX_OUTPUT_PIXELS
        ) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Image output exceeds the bounded ${MAX_OUTPUT_PIXELS / 1_000_000} MP / ${MAX_OUTPUT_EDGE}px budget",
            )
        }
        if (format == "jpeg" && settings.preserveTransparency && projectHasTransparency(snapshot)) {
            throw refusal(
                INVALID_PAYLOAD,
                "JPEG cannot preserve transparency; choose PNG or turn off transparency to flatten",
            )
        }
        return width to height
    }

    fun encode(snapshot: VerifiedSnapshot, settings: ImageExportSettings): EncodedImage {
        val (width, height) = validate(snapshot, settings)
        val renderer = ImageProjectRenderer(snapshot)
        val bitmap = renderer.render(ImageRenderTarget(width, height, preview = false))
        try {
            val format = settings.format.lowercase()
            val bytes = compress(bitmap, format, settings.quality, settings.preserveTransparency)
            return EncodedImage(bytes, width, height, format)
        } finally {
            bitmap.recycle()
        }
    }

    fun preview(snapshot: VerifiedSnapshot): EncodedImage {
        if (snapshot.projection.project.kind != "image") {
            throw refusal(UNSUPPORTED_FORMAT_IMAGE, "The snapshot is not an image project")
        }
        val canvas = snapshot.projection.project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        val longest = max(canvas.width, canvas.height)
        val scale = if (longest > ImageProjectRenderer.PREVIEW_MAX_EDGE) {
            ImageProjectRenderer.PREVIEW_MAX_EDGE.toDouble() / longest
        } else {
            1.0
        }
        val width = max(2, (canvas.width * scale).toInt())
        val height = max(2, (canvas.height * scale).toInt())
        val renderer = ImageProjectRenderer(snapshot)
        val bitmap = renderer.render(ImageRenderTarget(width, height, preview = true))
        try {
            return EncodedImage(
                bytes = compress(bitmap, "png", 1.0, preserveTransparency = true),
                width = bitmap.width,
                height = bitmap.height,
                format = "png",
            )
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Encodes and verifies before atomic publication. The output path is
     * derived by the service under `Workbench/Exports`; an existing destination
     * is never overwritten.
     */
    fun writeVerified(
        snapshot: VerifiedSnapshot,
        settings: ImageExportSettings,
        output: File,
        attemptID: String,
        cancelled: () -> Boolean = { false },
    ): VerifiedOutput {
        if (cancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        val encoded = encode(snapshot, settings)
        if (cancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
        if (output.exists()) throw refusal(WRITE_FAILED, "The output attempt path already exists")
        val parent = output.parentFile
            ?: throw refusal(STORAGE_UNAVAILABLE, "Output directory is unavailable")
        if (!parent.isDirectory && !parent.mkdirs()) {
            throw refusal(STORAGE_UNAVAILABLE, "Output directory could not be created")
        }
        val staging = File(parent, ".$attemptID.${output.extension}.part")
        if (staging.exists()) staging.delete()
        try {
            writeFullySync(staging, encoded.bytes)
            val detected = ImageVerifier.detectFormat(staging)
            if (detected != encoded.format) {
                throw refusal(RENDERER_UNAVAILABLE, "Encoded image format could not be re-detected")
            }
            val verified = ImageVerifier.verify(
                staging,
                encoded.width,
                encoded.height,
                encoded.format,
                MAX_OUTPUT_BYTES,
            )
            if (cancelled()) throw refusal(RENDER_CANCELLED, "Export was cancelled")
            atomicReplace(staging, output)
            return verified
        } catch (failure: Throwable) {
            if (staging.exists()) staging.delete()
            throw failure
        }
    }

    private fun compress(
        bitmap: Bitmap,
        format: String,
        quality: Double,
        preserveTransparency: Boolean,
    ): ByteArray {
        val output = ByteArrayOutputStream()
        when (format) {
            "png" -> {
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    throw refusal(RENDERER_UNAVAILABLE, "PNG encoder failed")
                }
            }
            "jpeg" -> {
                val encoded = if (preserveTransparency) {
                    bitmap
                } else {
                    flattenOverWhite(bitmap)
                }
                try {
                    val q = (quality * 100.0).toInt().coerceIn(1, 100)
                    if (!encoded.compress(Bitmap.CompressFormat.JPEG, q, output)) {
                        throw refusal(RENDERER_UNAVAILABLE, "JPEG encoder failed")
                    }
                } finally {
                    if (encoded !== bitmap) encoded.recycle()
                }
            }
            else -> throw refusal(RENDER_UNSUPPORTED, "Unsupported image format $format")
        }
        return output.toByteArray()
    }

    private fun flattenOverWhite(source: Bitmap): Bitmap {
        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(source, 0f, 0f, Paint(Paint.ANTI_ALIAS_FLAG))
        return output
    }

    private fun projectHasTransparency(snapshot: VerifiedSnapshot): Boolean {
        val project = snapshot.projection.project
        for (layer in project.imageLayers) {
            if (layer.isHidden) continue
            when (layer.kind) {
                "text", "freehand" -> return true
                "fill" -> {
                    val color = ImageLayerPainters.parseColor(layer.fillColorHex ?: "#FFFFFF", -1)
                    if ((color ushr 24) < 255) return true
                }
                "image" -> {
                    val assetID = layer.assetID ?: continue
                    val asset = project.asset(assetID) ?: continue
                    val file = com.floe.android.core.workbenchmedia.util.MediaPaths.resolveExistingUnder(
                        snapshot.root, asset.relativePath)
                        ?: continue
                    val decoded = try {
                        AssetDecoder.decode(file, maxEdge = 64)
                    } catch (_: Exception) {
                        return true
                    }
                    try {
                        if (decoded.hasAlpha) return true
                    } finally {
                        decoded.bitmap.recycle()
                    }
                }
            }
        }
        // A transparent canvas is possible even with no layers; treat it as
        // alpha-bearing so a JPEG request is never silently flattened.
        return project.imageLayers.none { !it.isHidden }
    }

    private val UNSUPPORTED_FORMAT_IMAGE = com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
}
