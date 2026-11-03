// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import com.floe.android.core.workbenchmedia.snapshot.ProjectedLayer
import com.floe.android.core.workbenchmedia.snapshot.SnapshotProjection
import com.floe.android.core.workbenchmedia.snapshot.VerifiedSnapshot
import com.floe.android.core.workbenchmedia.util.INVALID_PAYLOAD
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.video.fitInto
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.asset
import java.io.File
import kotlin.math.max
import kotlinx.serialization.json.JsonObject

internal data class ImageRenderTarget(
    val width: Int,
    val height: Int,
    val preview: Boolean,
)

/**
 * Real, non-destructive Android image-project renderer. It renders the actual
 * schema-1 project image layers (source crop, EXIF orientation, aspect-fit,
 * transform/rotation/flip/opacity/order, text, freehand, fill, masks and the
 * adjustment pipeline) into a fresh bitmap. Source assets are never modified.
 *
 * iOS uses CoreImage; this is an explicit Bitmap/Canvas implementation with
 * the same documented semantics, not a CoreImage parity claim. Unknown active
 * layer/effect keys are refused before any pixel is committed.
 */
internal class ImageProjectRenderer(private val snapshot: VerifiedSnapshot) {
    private val projection: SnapshotProjection = snapshot.projection
    private val project = projection.project

    fun render(target: ImageRenderTarget): Bitmap {
        if (project.kind != "image") {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "The snapshot is not an image project")
        }
        val canvas = project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        if (canvas.width <= 0 || canvas.height <= 0) {
            throw refusal(RENDER_UNSUPPORTED, "Image project canvas is invalid")
        }
        if (projection.unknownCanvasAdjustmentKeys.isNotEmpty()) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Unknown active canvas adjustment: ${projection.unknownCanvasAdjustmentKeys.joinToString()}",
            )
        }
        val renderWidth: Int
        val renderHeight: Int
        val renderScale: Double
        if (target.preview) {
            val longest = max(canvas.width, canvas.height)
            renderScale = if (longest > PREVIEW_MAX_EDGE) PREVIEW_MAX_EDGE.toDouble() / longest else 1.0
            renderWidth = max(1, (canvas.width * renderScale).toInt())
            renderHeight = max(1, (canvas.height * renderScale).toInt())
        } else {
            renderScale = 1.0
            renderWidth = canvas.width
            renderHeight = canvas.height
        }
        guardRenderSize(renderWidth, renderHeight)
        val output = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888)
        try {
            val canvasBitmap = Canvas(output)
            val assetCache = HashMap<String, DecodedImage>()
            try {
                for (projected in projection.layers) {
                    drawProjectedLayer(
                        canvasBitmap = canvasBitmap,
                        projected = projected,
                        renderWidth = renderWidth,
                        renderHeight = renderHeight,
                        renderScale = renderScale,
                        assetCache = assetCache,
                    )
                }
            } finally {
                assetCache.values.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() }
            }
            val adjustedCanvas = ImageAdjustments.apply(output, project.canvasAdjustment, renderScale)
            val finalBitmap = if (adjustedCanvas.width == target.width && adjustedCanvas.height == target.height) {
                adjustedCanvas
            } else {
                val resized = Bitmap.createScaledBitmap(
                    adjustedCanvas,
                    max(1, target.width),
                    max(1, target.height),
                    true,
                )
                if (resized !== adjustedCanvas) adjustedCanvas.recycle()
                resized
            }
            return finalBitmap
        } catch (failure: Throwable) {
            if (!output.isRecycled) output.recycle()
            throw failure
        }
    }

    /**
     * C03 layer merge: composites ONLY the named layers (project stacking
     * order, hidden skipped) into a transparent full-canvas bitmap WITHOUT the
     * whole-canvas adjustment. This is the same per-layer pipeline used by the
     * preview/export renderer, so replacing the inputs with one identity-placed
     * image layer is render-preserving. Source assets are never modified.
     */
    internal fun renderMerge(layerIDs: Set<String>, target: ImageRenderTarget): Bitmap {
        requireImageTarget(target)
        val layerSet = layerIDs
        if (layerSet.size < 2) {
            throw refusal(RENDER_UNSUPPORTED, "Merge needs at least two distinct layers")
        }
        val canvas = project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        val output = Bitmap.createBitmap(target.width, target.height, Bitmap.Config.ARGB_8888)
        val assetCache = HashMap<String, DecodedImage>()
        var contributed = 0
        try {
            val canvasBitmap = Canvas(output)
            for (projected in projection.layers) {
                val layer = projected.layer
                if (layer.id !in layerSet || layer.isHidden || layer.opacity <= 0.0) continue
                drawProjectedLayer(
                    canvasBitmap = canvasBitmap,
                    projected = projected,
                    renderWidth = target.width,
                    renderHeight = target.height,
                    renderScale = if (canvas.width > 0) target.width.toDouble() / canvas.width else 1.0,
                    assetCache = assetCache,
                )
                contributed += 1
            }
        } catch (failure: Throwable) {
            if (!output.isRecycled) output.recycle()
            throw failure
        } finally {
            assetCache.values.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() }
        }
        if (contributed == 0) {
            output.recycle()
            throw refusal(RENDER_UNSUPPORTED, "None of the merge layers could be rendered")
        }
        return output
    }

    /**
     * C03 copy selection: renders ONE layer through the same pipeline, then
     * multiplies the result by the project selection mask (feather/invert and
     * add/subtract/replace included). The original layer and selection stay
     * untouched.
     */
    internal fun renderCopySelection(
        layerID: String,
        selection: JsonObject,
        target: ImageRenderTarget,
    ): Bitmap {
        requireImageTarget(target)
        val canvas = project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        val projected = projection.layers.firstOrNull { it.layer.id == layerID }
            ?: throw refusal(RENDER_UNSUPPORTED, "Copy source layer is missing")
        if (projected.layer.isHidden) {
            throw refusal(RENDER_UNSUPPORTED, "A hidden layer cannot be copied from the selection")
        }
        if (projected.layer.opacity <= 0.0) {
            throw refusal(RENDER_UNSUPPORTED, "A fully transparent layer cannot be copied")
        }
        val output = Bitmap.createBitmap(target.width, target.height, Bitmap.Config.ARGB_8888)
        val assetCache = HashMap<String, DecodedImage>()
        try {
            drawProjectedLayer(
                canvasBitmap = Canvas(output),
                projected = projected,
                renderWidth = target.width,
                renderHeight = target.height,
                renderScale = if (canvas.width > 0) target.width.toDouble() / canvas.width else 1.0,
                assetCache = assetCache,
            )
        } catch (failure: Throwable) {
            if (!output.isRecycled) output.recycle()
            throw failure
        } finally {
            assetCache.values.forEach { if (!it.bitmap.isRecycled) it.bitmap.recycle() }
        }
        // The fixed iOS copy path renders the single-layer projection with
        // `render(project:)`, which applies the whole-canvas adjustment before
        // the project selection mask. Mirror that order exactly.
        val adjusted = try {
            ImageAdjustments.apply(
                output,
                project.canvasAdjustment,
                if (canvas.width > 0) target.width.toDouble() / canvas.width else 1.0,
            )
        } catch (failure: Throwable) {
            if (!output.isRecycled) output.recycle()
            throw failure
        }
        try {
            MaskRasterizer.applySelection(adjusted, selection, target.width, target.height)
            return adjusted
        } catch (failure: Throwable) {
            if (!adjusted.isRecycled) adjusted.recycle()
            throw failure
        }
    }

    private fun requireImageTarget(target: ImageRenderTarget) {
        if (project.kind != "image") {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "The snapshot is not an image project")
        }
        val canvas = project.canvas
            ?: throw refusal(RENDER_UNSUPPORTED, "Image project has no canvas")
        if (canvas.width <= 0 || canvas.height <= 0) {
            throw refusal(RENDER_UNSUPPORTED, "Image project canvas is invalid")
        }
        if (target.preview) {
            throw refusal(RENDER_UNSUPPORTED, "A layer raster must use the full canvas")
        }
        if (target.width != canvas.width || target.height != canvas.height) {
            throw refusal(RENDER_UNSUPPORTED, "A layer raster must match the full canvas")
        }
        guardRenderSize(target.width, target.height)
        if (projection.unknownCanvasAdjustmentKeys.isNotEmpty()) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Unknown active canvas adjustment: ${projection.unknownCanvasAdjustmentKeys.joinToString()}",
            )
        }
    }

    private fun drawProjectedLayer(
        canvasBitmap: Canvas,
        projected: ProjectedLayer,
        renderWidth: Int,
        renderHeight: Int,
        renderScale: Double,
        assetCache: HashMap<String, DecodedImage>,
    ) {
        val layer = projected.layer
        if (layer.isHidden || layer.opacity <= 0.0) return
        if (projected.unknownLayerKeys.isNotEmpty() ||
            projected.unknownAdjustmentKeys.isNotEmpty() ||
            projected.unknownTextKeys.isNotEmpty() ||
            projected.unknownFreehandKeys.isNotEmpty() ||
            projected.unknownMaskKeys.isNotEmpty() ||
            projected.unknownSelectionKeys.isNotEmpty()
        ) {
            val keys = projected.unknownLayerKeys + projected.unknownAdjustmentKeys +
                projected.unknownTextKeys + projected.unknownFreehandKeys +
                projected.unknownMaskKeys + projected.unknownSelectionKeys
            throw refusal(
                RENDER_UNSUPPORTED,
                "Unknown active fields on layer ${layer.id}: ${keys.joinToString()}",
            )
        }
        if (layer.crop != null && layer.kind != "image") {
            throw refusal(RENDER_UNSUPPORTED, "Crop is only supported on image layers")
        }
        val layerBitmap = when (layer.kind) {
            "image" -> imageLayerBitmap(layer, renderWidth, renderHeight, renderScale, assetCache)
            "text" -> {
                val content = layer.text
                    ?: throw refusal(RENDER_UNSUPPORTED, "Text layer ${layer.id} has no text content")
                ImageLayerPainters.renderText(content, renderWidth, renderHeight, renderScale)
            }
            "freehand" -> {
                val content = layer.freehand
                    ?: throw refusal(RENDER_UNSUPPORTED, "Freehand layer ${layer.id} has no strokes")
                ImageLayerPainters.renderFreehand(content, renderWidth, renderHeight, renderScale)
            }
            "fill" -> {
                if (layer.crop != null) {
                    throw refusal(RENDER_UNSUPPORTED, "Crop is only supported on image layers")
                }
                Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888).apply {
                    Canvas(this).drawColor(
                        ImageLayerPainters.parseColor(layer.fillColorHex ?: "#FFFFFF", 0xFFFFFFFF.toInt()),
                    )
                }
            }
            else -> throw refusal(RENDER_UNSUPPORTED, "Unknown active layer kind ${layer.kind}")
        }
        val adjusted = try {
            ImageAdjustments.apply(layerBitmap, layer.adjustment, renderScale)
        } catch (failure: Throwable) {
            if (!layerBitmap.isRecycled) layerBitmap.recycle()
            throw failure
        }
        try {
            val contribution = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888)
            try {
                drawPlaced(contribution, adjusted, layer, renderWidth, renderHeight)
                MaskRasterizer.applySelection(contribution, layer.selectionMask, renderWidth, renderHeight)
                MaskRasterizer.applyLayerMask(contribution, layer.mask, renderWidth, renderHeight)
                canvasBitmap.drawBitmap(
                    contribution,
                    0f,
                    0f,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        alpha = (layer.opacity.coerceIn(0.0, 1.0) * 255).toInt()
                    },
                )
            } finally {
                contribution.recycle()
            }
        } finally {
            adjusted.recycle()
        }
    }

    private fun imageLayerBitmap(
        layer: ImageLayer,
        renderWidth: Int,
        renderHeight: Int,
        renderScale: Double,
        cache: HashMap<String, DecodedImage>,
    ): Bitmap {
        val assetID = layer.assetID
            ?: throw refusal(RENDER_UNSUPPORTED, "Image layer ${layer.id} has no asset")
        val asset = project.asset(assetID)
            ?: throw refusal(RENDER_UNSUPPORTED, "Image layer asset $assetID is missing")
        if (asset.kind != "image") throw refusal(RENDER_UNSUPPORTED, "Layer asset $assetID is not an image")
        val file = MediaPaths.resolveExistingUnder(snapshot.root, asset.relativePath)
            ?: throw refusal(RENDER_UNSUPPORTED, "Image asset path is missing or escapes the media root")
        val decoded = cache.getOrPut(assetID) {
            AssetDecoder.decode(file, if (renderScale < 1.0) max(renderWidth, renderHeight) else null)
        }
        var working = decoded.bitmap
        val crop = layer.crop
        if (crop != null) {
            val rect = cropRect(crop, working.width, working.height)
            val cropped = Bitmap.createBitmap(working, rect.left, rect.top, rect.width(), rect.height())
            if (cropped !== working) {
                // Do not recycle the cached source; the crop is a temporary.
            }
            working = cropped
        }
        val fitted = fitInto(
            working.width.toDouble(),
            working.height.toDouble(),
            renderWidth.toDouble(),
            renderHeight.toDouble(),
        )
        val fittedWidth = max(1, fitted.first.toInt())
        val fittedHeight = max(1, fitted.second.toInt())
        val output = if (working.width == fittedWidth && working.height == fittedHeight) {
            // A cached bitmap must not be mutated/recycled by the adjustment
            // pipeline; copy it when it is the cache entry.
            if (working === decoded.bitmap) Bitmap.createBitmap(working) else working
        } else {
            Bitmap.createScaledBitmap(working, fittedWidth, fittedHeight, true)
        }
        if (working !== decoded.bitmap) working.recycle()
        return output
    }

    private fun drawPlaced(
        contribution: Bitmap,
        layerBitmap: Bitmap,
        layer: ImageLayer,
        width: Int,
        height: Int,
    ) {
        val transform = layer.transform
        if (!transform.centerX.isFinite() || !transform.centerY.isFinite() ||
            !transform.scale.isFinite() || !transform.rotationDegrees.isFinite()
        ) {
            throw refusal(INVALID_PAYLOAD, "Layer transform values must be finite")
        }
        val canvas = Canvas(contribution)
        canvas.save()
        canvas.translate((transform.centerX * width).toFloat(), (transform.centerY * height).toFloat())
        canvas.rotate(transform.rotationDegrees.toFloat())
        canvas.scale(
            (transform.scale * if (transform.flipX == true) -1.0 else 1.0).toFloat(),
            (transform.scale * if (transform.flipY == true) -1.0 else 1.0).toFloat(),
        )
        canvas.drawBitmap(
            layerBitmap,
            -layerBitmap.width / 2f,
            -layerBitmap.height / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG),
        )
        canvas.restore()
    }

    private fun cropRect(crop: NormalizedRect, width: Int, height: Int): android.graphics.Rect {
        if (!crop.x.isFinite() || !crop.y.isFinite() || !crop.width.isFinite() || !crop.height.isFinite() ||
            crop.x < 0.0 || crop.y < 0.0 || crop.width <= 0.0 || crop.height <= 0.0 ||
            crop.x + crop.width > 1.0001 || crop.y + crop.height > 1.0001
        ) {
            throw refusal(INVALID_PAYLOAD, "Layer crop must be a valid normalized rect")
        }
        val left = (crop.x * width).toInt().coerceIn(0, max(0, width - 1))
        val top = (crop.y * height).toInt().coerceIn(0, max(0, height - 1))
        val right = ((crop.x + crop.width) * width).toInt().coerceIn(left + 1, width)
        val bottom = ((crop.y + crop.height) * height).toInt().coerceIn(top + 1, height)
        return android.graphics.Rect(left, top, right, bottom)
    }

    private fun guardRenderSize(width: Int, height: Int) {
        if (width < 1 || height < 1 || width > MAX_RENDER_EDGE || height > MAX_RENDER_EDGE ||
            width.toLong() * height.toLong() > MAX_RENDER_PIXELS
        ) {
            throw refusal(
                RENDER_UNSUPPORTED,
                "Image render target exceeds the bounded ${MAX_RENDER_PIXELS / 1_000_000} MP / ${MAX_RENDER_EDGE}px budget",
            )
        }
    }

    companion object {
        const val PREVIEW_MAX_EDGE = 2_048
        const val MAX_RENDER_PIXELS = 16_000_000L
        const val MAX_RENDER_EDGE = 8_192
    }
}
