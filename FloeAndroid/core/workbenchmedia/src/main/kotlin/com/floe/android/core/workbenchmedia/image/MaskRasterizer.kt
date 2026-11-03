// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED
import com.floe.android.core.workbenchmedia.util.refusal
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.max
import kotlin.math.min

internal data class MaskPoint(val x: Double, val y: Double)

internal data class SelectionShape(
    val kind: String,
    val operation: String,
    val points: List<MaskPoint>,
)

internal data class SelectionModel(
    val shapes: List<SelectionShape>,
    val feather: Double,
    val inverted: Boolean,
)

internal data class MaskStroke(
    val points: List<MaskPoint>,
    val width: Double,
    val hardness: Double?,
    val restore: Boolean,
    val region: SelectionModel?,
)

/**
 * Real vector mask rasterization for the frozen R1 `ImageSelection` and
 * `ImageLayerMask` JSON subtrees. Selection coordinates are normalized to the
 * canvas; mask strokes are applied in order (erase hides, restore reveals) and
 * never mutate source pixels.
 */
internal object MaskRasterizer {
    fun applySelection(
        contribution: Bitmap,
        raw: JsonObject?,
        width: Int,
        height: Int,
    ) {
        val model = parseSelection(raw) ?: return
        val mask = renderSelection(model, width, height) ?: return
        applyMask(contribution, mask)
        mask.recycle()
    }

    fun applyLayerMask(
        contribution: Bitmap,
        raw: JsonObject?,
        width: Int,
        height: Int,
    ) {
        val strokes = parseMaskStrokes(raw)
        if (strokes.isEmpty()) return
        val mask = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(mask)
        canvas.drawColor(Color.WHITE)
        for (stroke in strokes) {
            // Region strokes (selection cut/copy masks) carry a complete
            // vector selection and intentionally have no freehand points.
            // They must be rasterized through the SAME selection pipeline as
            // the displayed marching-ants selection before any point check.
            if (stroke.region != null) {
                val regionMask = renderSelection(stroke.region, width, height) ?: continue
                canvas.drawBitmap(
                    regionMask,
                    0f,
                    0f,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        xfermode = PorterDuffXfermode(
                            if (stroke.restore) PorterDuff.Mode.SRC_OVER else PorterDuff.Mode.DST_OUT,
                        )
                    },
                )
                regionMask.recycle()
                continue
            }
            if (stroke.points.size < 2) continue
            val strokeBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val strokeCanvas = Canvas(strokeBitmap)
            val path = Path()
            stroke.points.forEachIndexed { index, point ->
                val x = (point.x * width).toFloat()
                val y = (point.y * height).toFloat()
                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = max(1f, stroke.width.toFloat())
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
                color = Color.WHITE
            }
            strokeCanvas.drawPath(path, paint)
            val hardness = (stroke.hardness ?: 0.0).coerceIn(0.0, 1.0)
            val soft = if (hardness > 0.001) {
                BoxBlur.blur(strokeBitmap, max(1, (hardness * max(1.0, stroke.width) * 0.6).toInt()))
            } else {
                strokeBitmap
            }
            canvas.drawBitmap(
                soft,
                0f,
                0f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    xfermode = PorterDuffXfermode(
                        if (stroke.restore) PorterDuff.Mode.SRC_OVER else PorterDuff.Mode.DST_OUT,
                    )
                },
            )
            if (soft !== strokeBitmap) soft.recycle()
            strokeBitmap.recycle()
        }
        applyMask(contribution, mask)
        mask.recycle()
    }

    private fun applyMask(contribution: Bitmap, mask: Bitmap) {
        val canvas = Canvas(contribution)
        canvas.drawBitmap(
            mask,
            0f,
            0f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
            },
        )
    }

    private fun renderSelection(model: SelectionModel, width: Int, height: Int): Bitmap? {
        if (model.shapes.isEmpty() && !model.inverted) return null
        val mask = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(mask)
        val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        for (shape in model.shapes) {
            val shapeBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val shapeCanvas = Canvas(shapeBitmap)
            drawShape(shapeCanvas, shape, width, height)
            when (shape.operation) {
                "replace" -> {
                    canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
                    canvas.drawBitmap(shapeBitmap, 0f, 0f, white)
                }
                "add" -> canvas.drawBitmap(shapeBitmap, 0f, 0f, white)
                "subtract" -> canvas.drawBitmap(
                    shapeBitmap,
                    0f,
                    0f,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
                    },
                )
                else -> throw refusal(RENDER_UNSUPPORTED, "Unknown selection operation ${shape.operation}")
            }
            shapeBitmap.recycle()
        }
        if (model.inverted) {
            val inverted = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val invertedCanvas = Canvas(inverted)
            invertedCanvas.drawColor(Color.WHITE)
            invertedCanvas.drawBitmap(
                mask,
                0f,
                0f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
                },
            )
            mask.recycle()
            return feather(inverted, model.feather, width, height)
        }
        return feather(mask, model.feather, width, height)
    }

    private fun drawShape(canvas: Canvas, shape: SelectionShape, width: Int, height: Int) {
        if (shape.points.isEmpty()) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        when (shape.kind) {
            "rectangle" -> {
                if (shape.points.size < 2) return
                val x0 = shape.points.minOf { it.x }.coerceIn(0.0, 1.0) * width
                val x1 = shape.points.maxOf { it.x }.coerceIn(0.0, 1.0) * width
                val y0 = shape.points.minOf { it.y }.coerceIn(0.0, 1.0) * height
                val y1 = shape.points.maxOf { it.y }.coerceIn(0.0, 1.0) * height
                canvas.drawRect(
                    RectF(min(x0, x1).toFloat(), min(y0, y1).toFloat(), max(x0, x1).toFloat(), max(y0, y1).toFloat()),
                    paint,
                )
            }
            "ellipse" -> {
                if (shape.points.size < 2) return
                val x0 = shape.points.minOf { it.x }.coerceIn(0.0, 1.0) * width
                val x1 = shape.points.maxOf { it.x }.coerceIn(0.0, 1.0) * width
                val y0 = shape.points.minOf { it.y }.coerceIn(0.0, 1.0) * height
                val y1 = shape.points.maxOf { it.y }.coerceIn(0.0, 1.0) * height
                canvas.drawOval(
                    RectF(min(x0, x1).toFloat(), min(y0, y1).toFloat(), max(x0, x1).toFloat(), max(y0, y1).toFloat()),
                    paint,
                )
            }
            "lasso" -> {
                val path = Path()
                shape.points.forEachIndexed { index, point ->
                    val x = (point.x * width).toFloat()
                    val y = (point.y * height).toFloat()
                    if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                path.close()
                canvas.drawPath(path, paint)
            }
            else -> throw refusal(RENDER_UNSUPPORTED, "Unknown selection shape ${shape.kind}")
        }
    }

    private fun feather(mask: Bitmap, feather: Double, width: Int, height: Int): Bitmap {
        if (!feather.isFinite() || feather <= 0.0) return mask
        val requested = feather * min(width, height)
        if (requested > 128.0) {
            throw refusal(RENDER_UNSUPPORTED, "Selection feather exceeds the bounded renderer")
        }
        val radius = max(1, requested.toInt())
        val blurred = BoxBlur.blur(mask, radius)
        // Preserve a white RGB mask; only the blurred alpha is meaningful.
        val pixels = IntArray(width * height)
        blurred.getPixels(pixels, 0, width, 0, 0, width, height)
        for (index in pixels.indices) {
            val alpha = pixels[index] ushr 24
            pixels[index] = (alpha shl 24) or 0x00FFFFFF
        }
        blurred.setPixels(pixels, 0, width, 0, 0, width, height)
        return blurred
    }

    fun parseSelection(raw: JsonObject?): SelectionModel? {
        if (raw == null) return null
        val shapes = raw.array("shapes").map { element ->
            val obj = element as? JsonObject
                ?: throw refusal(RENDER_UNSUPPORTED, "Selection shape is not an object")
            SelectionShape(
                kind = obj.string("kind")
                    ?: throw refusal(RENDER_UNSUPPORTED, "Selection shape has no kind"),
                operation = obj.string("operation") ?: "replace",
                points = parsePoints(obj.array("points")),
            )
        }
        val feather = raw.double("feather") ?: 0.0
        val inverted = raw.boolean("inverted") ?: false
        if (shapes.isEmpty() && !inverted) return null
        return SelectionModel(shapes, feather, inverted)
    }

    fun parseMaskStrokes(raw: JsonObject?): List<MaskStroke> {
        if (raw == null) return emptyList()
        return raw.array("strokes").map { element ->
            val obj = element as? JsonObject
                ?: throw refusal(RENDER_UNSUPPORTED, "Mask stroke is not an object")
            val region = obj.obj("region")?.let(::parseSelection)
            MaskStroke(
                points = parsePoints(obj.array("points")),
                width = obj.double("width") ?: 24.0,
                hardness = obj.double("hardness"),
                restore = obj.boolean("restore") ?: false,
                region = region,
            )
        }
    }

    private fun parsePoints(array: List<JsonElement>): List<MaskPoint> = array.map { element ->
        val obj = element as? JsonObject
            ?: throw refusal(RENDER_UNSUPPORTED, "Mask point is not an object")
        MaskPoint(obj.double("x") ?: 0.0, obj.double("y") ?: 0.0)
    }

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.array(key: String): List<JsonElement> =
        (this[key] as? JsonArray)?.toList() ?: emptyList()
    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.content?.toDoubleOrNull()
    private fun JsonObject.boolean(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()
}
