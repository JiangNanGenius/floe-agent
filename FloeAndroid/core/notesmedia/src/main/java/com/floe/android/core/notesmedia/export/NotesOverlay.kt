// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import android.graphics.Bitmap
import com.floe.android.core.notesmedia.ink.InkBox
import com.floe.android.core.notesmedia.ink.InkSnapshot
import com.floe.android.core.notesmedia.pdf.PdfPageBox
import com.floe.android.core.notesmedia.pdf.PdfPageId

/** Text alignment inside an overlay box. */
enum class NotesTextAlign { LEFT, CENTER, RIGHT }

enum class NotesShapeKind { RECT, ELLIPSE, LINE, ARROW }

/**
 * One caller-owned annotation overlay, expressed in DISPLAYED page points
 * (top-left origin, y down) — the same paper space as ink and the page box.
 *
 * Ownership: the caller supplies immutable content and keeps it alive for the
 * duration of the export. [ImageOverlay] wraps a Bitmap the exporter will only
 * READ (never recycle it); the caller must not mutate it concurrently.
 */
sealed class NotesOverlay {
    abstract val page: PdfPageId
    abstract val bounds: InkBox

    data class Text(
        override val page: PdfPageId,
        override val bounds: InkBox,
        val text: String,
        val fontSizePt: Float,
        val colorArgb: Int,
        val align: NotesTextAlign = NotesTextAlign.LEFT,
        val backgroundColorArgb: Int? = null,
    ) : NotesOverlay() {
        init {
            require(text.isNotEmpty() && text.length <= MAX_TEXT_CHARS) { "Overlay text out of bounds" }
            require(fontSizePt.isFinite() && fontSizePt in 1f..400f) { "Overlay font size out of range" }
        }

        companion object {
            const val MAX_TEXT_CHARS: Int = 4_000
        }
    }

    data class Image(
        override val page: PdfPageId,
        override val bounds: InkBox,
        val bitmap: Bitmap,
        /** 0..1; 1 = fully opaque. */
        val opacity: Float = 1f,
    ) : NotesOverlay() {
        init {
            require(!bitmap.isRecycled) { "Overlay bitmap was recycled" }
            require(bitmap.width > 0 && bitmap.height > 0) { "Overlay bitmap has no pixels" }
            require(opacity.isFinite() && opacity in 0f..1f) { "Overlay opacity out of range" }
        }
    }

    data class Shape(
        override val page: PdfPageId,
        override val bounds: InkBox,
        val kind: NotesShapeKind,
        val strokeWidthPt: Float,
        val colorArgb: Int,
    ) : NotesOverlay() {
        init {
            require(strokeWidthPt.isFinite() && strokeWidthPt in 0.25f..64f) { "Overlay stroke width out of range" }
        }
    }

    /** Ink authored on the SAME page; coordinates are scaled from its page space to the export page. */
    data class InkMark(
        override val page: PdfPageId,
        override val bounds: InkBox,
        val snapshot: InkSnapshot,
    ) : NotesOverlay() {
        init {
            require(bounds.isValid) { "Ink overlay bounds must be finite" }
        }
    }

    companion object {
        /** Paint order: images at the back, then shapes, then text, ink on top. */
        fun paintOrder(overlays: List<NotesOverlay>): List<NotesOverlay> =
            overlays.sortedBy { order(it) }

        fun order(overlay: NotesOverlay): Int = when (overlay) {
            is Image -> 0
            is Shape -> 1
            is Text -> 2
            is InkMark -> 3
        }
    }
}

/**
 * Pure export planner: turns page boxes + overlays into an exact per-page plan
 * (output size in points, renderer zoom, overlay order, clipping) BEFORE any
 * rendering happens. Refusing here is cheap and keeps the writer from
 * producing a page with guessed dimensions.
 */
data class NotesExportPagePlan(
    val page: PdfPageId,
    val box: PdfPageBox,
    val outputWidthPt: Int,
    val outputHeightPt: Int,
    val renderZoomPercent: Int,
    val renderedWidthPx: Int,
    val renderedHeightPx: Int,
    val overlays: List<NotesOverlay>,
)

data class NotesExportPlan(
    val sourceSha256: String,
    val pages: List<NotesExportPagePlan>,
)

enum class NotesExportQuality(val targetPixelsPerPoint: Float) {
    /** ~96 DPI-ish source raster (1 px per point). */
    STANDARD(1f),

    /** ~144 DPI source raster (2 px per point); default for annotation export. */
    HIGH(2f),
}

enum class NotesExportRefusal {
    NO_PAGE_GEOMETRY,
    EMPTY_PAGE_SELECTION,
    PAGE_OUT_OF_RANGE,
    OVERLAY_OUT_OF_PAGE,
    OVERLAY_PAGE_MISMATCH,
    TOO_MANY_OVERLAYS,
    RENDERER_REFUSED_SIZE,
    INVALID_PAGE_BOX,
}

sealed class NotesExportPlanResult {
    data class Ready(val plan: NotesExportPlan) : NotesExportPlanResult()
    data class Refused(val refusal: NotesExportRefusal) : NotesExportPlanResult()
}

object NotesExportPlanner {

    const val MAX_PAGES_PER_EXPORT: Int = 500
    const val MAX_OVERLAYS_PER_PAGE: Int = 500
    const val MAX_OUTPUT_POINTS: Int = 20_000
    const val MAX_OUTPUT_PIXELS_PER_PAGE: Long = 30_000_000L

    fun plan(
        sourceSha256: String,
        geometry: com.floe.android.core.notesmedia.pdf.PdfPageGeometry?,
        pages: List<PdfPageId>,
        overlays: List<NotesOverlay>,
        quality: NotesExportQuality = NotesExportQuality.HIGH,
    ): NotesExportPlanResult {
        if (geometry == null) return NotesExportPlanResult.Refused(NotesExportRefusal.NO_PAGE_GEOMETRY)
        if (pages.isEmpty()) return NotesExportPlanResult.Refused(NotesExportRefusal.EMPTY_PAGE_SELECTION)
        if (pages.size > MAX_PAGES_PER_EXPORT) return NotesExportPlanResult.Refused(NotesExportRefusal.TOO_MANY_OVERLAYS)
        if (!geometry.isBoundTo(sourceSha256)) return NotesExportPlanResult.Refused(NotesExportRefusal.NO_PAGE_GEOMETRY)
        val byPage = overlays.groupBy { it.page.pageIndex }
        val plans = ArrayList<NotesExportPagePlan>(pages.size)
        val seen = HashSet<Int>()
        for (page in pages) {
            if (!seen.add(page.pageIndex)) continue
            if (page.pageIndex !in 0 until geometry.pageCount) {
                return NotesExportPlanResult.Refused(NotesExportRefusal.PAGE_OUT_OF_RANGE)
            }
            val box = geometry.boxFor(page)
            if (box.displayedWidthPt < 1f || box.displayedHeightPt < 1f) {
                return NotesExportPlanResult.Refused(NotesExportRefusal.INVALID_PAGE_BOX)
            }
            val outW = box.displayedWidthPt.toInt().coerceIn(1, MAX_OUTPUT_POINTS)
            val outH = box.displayedHeightPt.toInt().coerceIn(1, MAX_OUTPUT_POINTS)
            if (outW.toLong() * outH.toLong() > MAX_OUTPUT_PIXELS_PER_PAGE) {
                return NotesExportPlanResult.Refused(NotesExportRefusal.INVALID_PAGE_BOX)
            }
            val pageOverlays = byPage[page.pageIndex].orEmpty()
            if (pageOverlays.size > MAX_OVERLAYS_PER_PAGE) {
                return NotesExportPlanResult.Refused(NotesExportRefusal.TOO_MANY_OVERLAYS)
            }
            val pageRect = InkBox(0f, 0f, box.displayedWidthPt, box.displayedHeightPt)
            for (overlay in pageOverlays) {
                if (!overlay.bounds.isValid || !pageRect.intersects(overlay.bounds)) {
                    return NotesExportPlanResult.Refused(NotesExportRefusal.OVERLAY_OUT_OF_PAGE)
                }
            }
            val targetPx = (box.displayedWidthPt * quality.targetPixelsPerPoint).toInt().coerceAtLeast(1)
            val zoom = com.floe.android.core.notesmedia.pdf.PdfRenderPlanner.zoomPercentForWidth(box, targetPx)
            val rendered = com.floe.android.core.notesmedia.pdf.PdfRenderPlanner.expectedBitmap(box, zoom)
                ?: return NotesExportPlanResult.Refused(NotesExportRefusal.RENDERER_REFUSED_SIZE)
            plans.add(
                NotesExportPagePlan(
                    page = page,
                    box = box,
                    outputWidthPt = outW,
                    outputHeightPt = outH,
                    renderZoomPercent = zoom,
                    renderedWidthPx = rendered.first,
                    renderedHeightPx = rendered.second,
                    overlays = NotesOverlay.paintOrder(pageOverlays),
                ),
            )
        }
        if (plans.isEmpty()) return NotesExportPlanResult.Refused(NotesExportRefusal.EMPTY_PAGE_SELECTION)
        return NotesExportPlanResult.Ready(NotesExportPlan(sourceSha256, plans))
    }
}
