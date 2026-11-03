// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.video

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.CanvasOverlay
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.core.workbenchmedia.timeline.MediaTimeline
import kotlin.math.max
import kotlin.math.min

/**
 * Real burn-in caption overlay for the SAME Composition used by preview and
 * export. It follows the actual iOS `makeCaptionImage` semantics: bold system
 * font, font size capped at 12% of the canvas height, centered line, 60%
 * background, `positionY` measured from the top, and time-window selection
 * shared with `MediaTimeline.captionAt`.
 *
 * `respectsSafeArea`/`alignment` are preserved in the frozen model but the
 * actual iOS burn-in does not apply them; they are intentionally not invented
 * into a different export style here.
 */
@UnstableApi
internal class CaptionOverlay(
    private val captions: List<CaptionSegment>,
    private val style: CaptionStyle,
) : CanvasOverlay(true) {
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create("sans-serif", Typeface.BOLD)
        textAlign = Paint.Align.LEFT
    }
    private val background = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun onDraw(canvas: Canvas, presentationTimeUs: Long) {
        canvas.drawColor(Color.TRANSPARENT, android.graphics.PorterDuff.Mode.CLEAR)
        val seconds = presentationTimeUs / 1_000_000.0
        val caption = MediaTimeline.captionAt(seconds, captions) ?: return
        val width = canvas.width
        val height = canvas.height
        if (width <= 0 || height <= 0) return
        val fontSize = max(10f, min(style.fontSize.toFloat(), height * 0.12f))
        paint.textSize = fontSize
        paint.color = parseColor(style.colorHex, Color.WHITE)
        val maxWidth = (width * 0.88f).toInt().coerceAtLeast(1)
        val layout = StaticLayout.Builder
            .obtain(caption.text, 0, caption.text.length, paint, maxWidth)
            .setAlignment(Layout.Alignment.ALIGN_CENTER)
            .setIncludePad(false)
            .build()
        val padding = max(8f, fontSize * 0.25f)
        val boxWidth = min(width.toFloat(), layout.width + padding * 2f)
        val boxHeight = min(height.toFloat(), layout.height + padding * 2f)
        val left = (width - boxWidth) / 2f
        val top = (style.positionY.toFloat().coerceIn(0f, 1f) * height) - boxHeight / 2f
        val backgroundHex = style.backgroundHex
        if (backgroundHex != null) {
            background.color = parseColor(backgroundHex, Color.BLACK)
            background.alpha = 153 // 0.6 alpha, matching the iOS burn-in
            canvas.drawRect(left, top, left + boxWidth, top + boxHeight, background)
        }
        canvas.save()
        canvas.translate(left + (boxWidth - layout.width) / 2f, top + padding)
        layout.draw(canvas)
        canvas.restore()
    }

    private fun parseColor(value: String, fallback: Int): Int {
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
