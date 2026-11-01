// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import com.floe.android.feature.workbench.ImageFreehandContent
import com.floe.android.feature.workbench.ImageTextContent
import kotlin.math.max
import kotlin.math.min

internal object ImageLayerPainters {
    fun renderText(
        content: ImageTextContent,
        canvasWidth: Int,
        canvasHeight: Int,
        scale: Double,
    ): Bitmap {
        val fontSize = max(8.0, min(content.fontSize * scale, canvasHeight * 0.5))
        val typeface = Typeface.create(content.fontName ?: "sans-serif", Typeface.NORMAL)
        val fill = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = fontSize.toFloat()
            color = parseColor(content.colorHex, Color.BLACK)
            content.tracking?.takeIf { it.isFinite() }?.let { tracking ->
                letterSpacing = (tracking / fontSize).toFloat().coerceIn(-0.5f, 2f)
            }
            content.shadow?.let { shadow ->
                setShadowLayer(
                    shadow.blur.toFloat().coerceIn(0f, fontSize.toFloat()),
                    shadow.offsetX.toFloat(),
                    shadow.offsetY.toFloat(),
                    parseColor(shadow.colorHex, Color.BLACK),
                )
            }
        }
        val maxWidth = max(1, (canvasWidth * 0.9).toInt())
        val lines = content.text.split('\n')
        val measured = lines.maxOfOrNull { fill.measureText(it) } ?: 0f
        val layoutWidth = min(maxWidth, max(1, measured.toInt() + 2)).coerceAtLeast(1)
        val alignment = when (content.alignment) {
            null, "left" -> Layout.Alignment.ALIGN_NORMAL
            "center" -> Layout.Alignment.ALIGN_CENTER
            "right" -> Layout.Alignment.ALIGN_OPPOSITE
            else -> throw com.floe.android.core.workbenchmedia.util.refusal(
                com.floe.android.core.workbenchmedia.util.RENDER_UNSUPPORTED,
                "Unknown active text alignment",
            )
        }
        fun layout(paint: TextPaint): StaticLayout =
            StaticLayout.Builder
                .obtain(content.text, 0, content.text.length, paint, layoutWidth)
                .setAlignment(alignment)
                .setIncludePad(false)
                .setLineSpacing(
                    content.leading?.takeIf { it.isFinite() }
                        ?.let { it.coerceIn(0.0, fontSize * 2.0) }
                        ?.toFloat() ?: 0f,
                    1f,
                )
                .build()

        val fillLayout = layout(fill)
        val strokePaint = if (content.strokeColorHex != null && (content.strokeWidth ?: 0.0) > 0.0) {
            TextPaint(fill).apply {
                style = Paint.Style.STROKE
                strokeWidth = min(content.strokeWidth ?: 0.0, fontSize).toFloat()
                color = parseColor(content.strokeColorHex ?: "#000000", Color.BLACK)
                clearShadowLayer()
            }
        } else {
            null
        }
        val strokeLayout = strokePaint?.let(::layout)
        val width = max(1, fillLayout.width)
        val height = max(1, fillLayout.height)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        strokeLayout?.draw(canvas)
        fillLayout.draw(canvas)
        return bitmap
    }

    fun renderFreehand(
        content: ImageFreehandContent,
        canvasWidth: Int,
        canvasHeight: Int,
        scale: Double,
    ): Bitmap {
        val output = Bitmap.createBitmap(canvasWidth, canvasHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        for (stroke in content.strokes) {
            if (stroke.points.size < 2) continue
            val pressures = stroke.points.mapNotNull { it.pressure }
            val pressureScale = if (pressures.isEmpty()) {
                1.0
            } else {
                (pressures.sum() / pressures.size).coerceIn(0.15, 1.0)
            }
            val width = max(1.0, stroke.width * scale * pressureScale)
            val opacity = (stroke.opacity ?: 1.0).coerceIn(0.02, 1.0)
            val strokeBitmap = Bitmap.createBitmap(canvasWidth, canvasHeight, Bitmap.Config.ARGB_8888)
            val strokeCanvas = Canvas(strokeBitmap)
            val path = android.graphics.Path()
            stroke.points.forEachIndexed { index, point ->
                val x = (point.x * canvasWidth).toFloat()
                val y = (point.y * canvasHeight).toFloat()
                if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width.toFloat()
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
                color = parseColor(stroke.colorHex, Color.BLACK)
                alpha = (opacity * 255).toInt().coerceIn(0, 255)
            }
            strokeCanvas.drawPath(path, paint)
            val hardness = (stroke.hardness ?: 0.0).coerceIn(0.0, 1.0)
            val soft = if (hardness > 0.001) {
                BoxBlur.blur(strokeBitmap, max(1, (hardness * max(1.0, width) * 0.6).toInt()))
            } else {
                strokeBitmap
            }
            canvas.drawBitmap(soft, 0f, 0f, null)
            if (soft !== strokeBitmap) soft.recycle()
            strokeBitmap.recycle()
        }
        return output
    }

    fun parseColor(value: String, fallback: Int): Int {
        val text = value.trim().removePrefix("#")
        return try {
            when (text.length) {
                6 -> 0xff000000.toInt() or text.toInt(16)
                8 -> text.toLong(16).toInt()
                else -> fallback
            }
        } catch (_: NumberFormatException) {
            fallback
        }
    }
}
