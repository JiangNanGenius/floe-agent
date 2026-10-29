// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.officeengine.pdf.OfficePdfGeometry
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Small affine transform (x' = a*x + c*y + e, y' = b*x + d*y + f) kept here so
 * the PDF/viewport math is pure Kotlin and unit-testable on the JVM. The
 * component order matches [android.graphics.Matrix]'s 3x3 layout through
 * [toAndroidValues], which is the only bridge to Android types.
 */
data class PdfAffine(
    val a: Float = 1f,
    val b: Float = 0f,
    val c: Float = 0f,
    val d: Float = 1f,
    val e: Float = 0f,
    val f: Float = 0f,
) {
    fun mapX(x: Float, y: Float): Float = a * x + c * y + e
    fun mapY(x: Float, y: Float): Float = b * x + d * y + f

    /** `this` followed by [next] (i.e. next ∘ this). */
    fun then(next: PdfAffine): PdfAffine = PdfAffine(
        a = next.a * a + next.c * b,
        b = next.b * a + next.d * b,
        c = next.a * c + next.c * d,
        d = next.b * c + next.d * d,
        e = next.a * e + next.c * f + next.e,
        f = next.b * e + next.d * f + next.f,
    )

    fun invertOrNull(): PdfAffine? {
        val det = a * d - b * c
        if (!det.isFinite() || abs(det) < 1e-6f) return null
        val inv = 1f / det
        return PdfAffine(
            a = d * inv,
            b = -b * inv,
            c = -c * inv,
            d = a * inv,
            e = (c * f - d * e) * inv,
            f = (b * e - a * f) * inv,
        )
    }

    /** Android Matrix value order: [scaleX, skewX, transX, skewY, scaleY, transY, 0, 0, 1]. */
    fun toAndroidValues(): FloatArray =
        floatArrayOf(a, c, e, b, d, f, 0f, 0f, 1f)

    companion object {
        val IDENTITY = PdfAffine()

        fun translation(dx: Float, dy: Float): PdfAffine = PdfAffine(e = dx, f = dy)
        fun scale(sx: Float, sy: Float): PdfAffine = PdfAffine(a = sx, d = sy)

        /** Clockwise-positive rotation in a y-down coordinate space (screen/paper). */
        fun rotationDegrees(degrees: Float): PdfAffine {
            val rad = Math.toRadians(degrees.toDouble())
            val cs = cos(rad).toFloat()
            val sn = sin(rad).toFloat()
            return PdfAffine(a = cs, b = sn, c = -sn, d = cs)
        }
    }
}

/** Axis-aligned rectangle in paper points or view pixels (explicit by usage). */
data class PdfRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    val isEmpty: Boolean get() = width <= 0f || height <= 0f

    fun intersect(other: PdfRect): PdfRect? {
        val l = maxOf(left, other.left)
        val t = maxOf(top, other.top)
        val r = minOf(right, other.right)
        val b = minOf(bottom, other.bottom)
        return if (r > l && b > t) PdfRect(l, t, r, b) else null
    }

    fun contains(x: Float, y: Float): Boolean = x in left..right && y in top..bottom
}

/** One render tile request: a paper-space region plus its device pixel box. */
data class PdfTile(
    val column: Int,
    val row: Int,
    val paperRect: PdfRect,
    val widthPx: Int,
    val heightPx: Int,
)

/**
 * The viewport state machine for one open PDF page: zoom, user rotation,
 * panning and the paper↔view transforms, plus bounded tile planning.
 *
 * Conventions (the module's one coordinate contract):
 *  - "paper" coordinates are DISPLAYED page points: origin top-left, x right,
 *    y down, `PdfPageBox.displayedWidthPt` × `displayedHeightPt`;
 *  - ink strokes and annotation overlays are stored in paper coordinates, so
 *    they survive zoom/rotation/pan without re-encoding;
 *  - "view" coordinates are device pixels inside the page viewport.
 *
 * The class is intentionally mutable state only (no Android types, no
 * rendering); the UI owner drives it from gestures and the session asks it
 * for render plans. All clamps are explicit and tested.
 */
class PdfViewport(
    val box: PdfPageBox,
    private val densityDpi: Int = 320,
) {
    var zoom: Float = 1f
        private set
    var userRotationQuarterTurns: Int = 0
        private set
    var panXPx: Float = 0f
        private set
    var panYPx: Float = 0f
        private set
    var viewWidthPx: Int = 0
        private set
    var viewHeightPx: Int = 0
        private set

    /** Pixels per PDF point at 100% zoom for the current device density. */
    val pxPerPoint: Float get() = densityDpi.toFloat() / 72f

    /** Displayed page size after the page's own /Rotate plus the user rotation. */
    val effectiveWidthPt: Float
        get() = if (userRotationQuarterTurns % 2 == 0) box.displayedWidthPt else box.displayedHeightPt
    val effectiveHeightPt: Float
        get() = if (userRotationQuarterTurns % 2 == 0) box.displayedHeightPt else box.displayedWidthPt

    fun resize(viewWidthPx: Int, viewHeightPx: Int) {
        this.viewWidthPx = viewWidthPx.coerceAtLeast(0)
        this.viewHeightPx = viewHeightPx.coerceAtLeast(0)
        clampPan()
    }

    fun setZoom(value: Float) {
        zoom = value.coerceIn(MIN_ZOOM, MAX_ZOOM)
        clampPan()
    }

    /** Sets zoom while keeping the paper point under ([focusX],[focusY]) fixed. */
    fun zoomAround(focusX: Float, focusY: Float, newZoom: Float) {
        val before = viewToPaper(focusX, focusY) ?: return
        zoom = newZoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
        val after = paperToView(before.first, before.second) ?: return
        panXPx += focusX - after.first
        panYPx += focusY - after.second
        clampPan()
    }

    fun panBy(dxPx: Float, dyPx: Float) {
        if (!dxPx.isFinite() || !dyPx.isFinite()) return
        panXPx += dxPx
        panYPx += dyPx
        clampPan()
    }

    /** Rotates the page by whole quarter turns; keeps the view center anchored. */
    fun rotateBy(deltaQuarterTurns: Int) {
        if (deltaQuarterTurns == 0) return
        val cx = viewWidthPx / 2f
        val cy = viewHeightPx / 2f
        val anchor = viewToPaper(cx, cy)
        userRotationQuarterTurns = ((userRotationQuarterTurns + deltaQuarterTurns) % 4 + 4) % 4
        val after = anchor?.let { paperToView(it.first, it.second) }
        if (after != null) {
            panXPx += cx - after.first
            panYPx += cy - after.second
        }
        clampPan()
    }

    fun reset() {
        zoom = 1f
        userRotationQuarterTurns = 0
        panXPx = 0f
        panYPx = 0f
    }

    fun fitWidthZoom(): Float {
        if (viewWidthPx <= 0 || effectiveWidthPt <= 0f) return zoom
        return (viewWidthPx / (effectiveWidthPt * pxPerPoint)).coerceIn(MIN_ZOOM, MAX_ZOOM)
    }

    fun fitPageZoom(): Float {
        if (viewWidthPx <= 0 || viewHeightPx <= 0) return zoom
        val sx = viewWidthPx / (effectiveWidthPt * pxPerPoint)
        val sy = viewHeightPx / (effectiveHeightPt * pxPerPoint)
        return minOf(sx, sy).coerceIn(MIN_ZOOM, MAX_ZOOM)
    }

    /** Paper → view transform for the current state (null when unusable). */
    fun paperToView(): PdfAffine? {
        if (viewWidthPx <= 0 || viewHeightPx <= 0) return null
        val s = zoom * pxPerPoint
        if (!s.isFinite() || s <= 0f) return null
        val w = box.displayedWidthPt
        val h = box.displayedHeightPt
        return PdfAffine.translation(-w / 2f, -h / 2f)
            .then(PdfAffine.rotationDegrees(90f * userRotationQuarterTurns))
            .then(PdfAffine.scale(s, s))
            .then(
                PdfAffine.translation(
                    viewWidthPx / 2f + panXPx,
                    viewHeightPx / 2f + panYPx,
                ),
            )
    }

    fun viewToPaper(): PdfAffine? = paperToView()?.invertOrNull()

    fun paperToView(x: Float, y: Float): Pair<Float, Float>? =
        paperToView()?.let { it.mapX(x, y) to it.mapY(x, y) }

    fun viewToPaper(x: Float, y: Float): Pair<Float, Float>? =
        viewToPaper()?.let { it.mapX(x, y) to it.mapY(x, y) }

    /** Bounding paper rect currently visible (clamped to the page), or null. */
    fun visiblePaperBounds(): PdfRect? {
        val inverse = viewToPaper() ?: return null
        val corners = listOf(
            0f to 0f,
            viewWidthPx.toFloat() to 0f,
            0f to viewHeightPx.toFloat(),
            viewWidthPx.toFloat() to viewHeightPx.toFloat(),
        ).map { (x, y) -> inverse.mapX(x, y) to inverse.mapY(x, y) }
        val left = corners.minOf { it.first }
        val top = corners.minOf { it.second }
        val right = corners.maxOf { it.first }
        val bottom = corners.maxOf { it.second }
        val clamped = PdfRect(left, top, right, bottom)
            .intersect(PdfRect(0f, 0f, box.displayedWidthPt, box.displayedHeightPt)) ?: return null
        return clamped
    }

    /**
     * Bounded tile plan for the visible region. Tiles are indexed in the
     * EFFECTIVE (rotated) page space so a rotated page reuses the same grid;
     * the paper rect of each tile is expressed in unrotated paper coordinates
     * via the page/rotation mapping. Never returns more than [MAX_TILES].
     */
    fun visibleTiles(tilePx: Int = DEFAULT_TILE_PX): List<PdfTile> {
        val visible = visiblePaperBounds() ?: return emptyList()
        val effective = tilePx.coerceIn(MIN_TILE_PX, MAX_TILE_PX)
        val pageLeft = 0f
        val pageTop = 0f
        var colStart = (visible.left / effective).toInt().coerceAtLeast(0)
        var rowStart = (visible.top / effective).toInt().coerceAtLeast(0)
        val colEnd = ((visible.right + effective - 1) / effective).toInt().coerceAtMost(MAX_TILE_DIMENSION)
        val rowEnd = ((visible.bottom + effective - 1) / effective).toInt().coerceAtMost(MAX_TILE_DIMENSION)
        if (colEnd <= colStart || rowEnd <= rowStart) return emptyList()
        var cols = colEnd - colStart
        var rows = rowEnd - rowStart
        while (cols * rows > MAX_TILES) {
            // Coarsen the plan instead of allocating unbounded tiles.
            colStart = (colStart / 2)
            rowStart = (rowStart / 2)
            cols = ((colEnd - colStart) + 1) / 2
            rows = ((rowEnd - rowStart) + 1) / 2
            if (cols <= 1 && rows <= 1) break
        }
        val tiles = ArrayList<PdfTile>(minOf(cols * rows, MAX_TILES))
        for (row in rowStart until minOf(rowStart + rows, MAX_TILE_DIMENSION)) {
            for (col in colStart until minOf(colStart + cols, MAX_TILE_DIMENSION)) {
                val tLeft = pageLeft + col * effective
                val tTop = pageTop + row * effective
                val tRight = minOf(tLeft + effective, effectiveWidthPt)
                val tBottom = minOf(tTop + effective, effectiveHeightPt)
                if (tRight <= tLeft || tBottom <= tTop) continue
                val paperRect = if (userRotationQuarterTurns == 0) {
                    PdfRect(tLeft, tTop, tRight, tBottom)
                } else {
                    // Map the four corners of the effective tile back to paper space.
                    val corners = listOf(
                        effectiveToPaper(tLeft, tTop),
                        effectiveToPaper(tRight, tTop),
                        effectiveToPaper(tLeft, tBottom),
                        effectiveToPaper(tRight, tBottom),
                    )
                    PdfRect(
                        corners.minOf { it.first },
                        corners.minOf { it.second },
                        corners.maxOf { it.first },
                        corners.maxOf { it.second },
                    )
                }
                tiles.add(
                    PdfTile(
                        column = col,
                        row = row,
                        paperRect = paperRect,
                        widthPx = ((tRight - tLeft) * (zoom * pxPerPoint)).roundToInt().coerceAtLeast(1),
                        heightPx = ((tBottom - tTop) * (zoom * pxPerPoint)).roundToInt().coerceAtLeast(1),
                    ),
                )
                if (tiles.size >= MAX_TILES) return tiles
            }
        }
        return tiles
    }

    /** Effective (user-rotated) page coordinates → unrotated paper coordinates. */
    fun effectiveToPaper(x: Float, y: Float): Pair<Float, Float> = when (userRotationQuarterTurns) {
        0 -> x to y
        1 -> y to (box.displayedHeightPt - x)
        2 -> (box.displayedWidthPt - x) to (box.displayedHeightPt - y)
        else -> (box.displayedWidthPt - y) to x
    }

    private fun clampPan() {
        if (viewWidthPx <= 0 || viewHeightPx <= 0) return
        val scale = zoom * pxPerPoint
        val contentW = effectiveWidthPt * scale
        val contentH = effectiveHeightPt * scale
        // Keep at least a quarter of the page inside the viewport so the page
        // can never be panned completely off-screen; small pages stay centred.
        val maxX = (maxOf(contentW, viewWidthPx.toFloat()) / 2f)
        val maxY = (maxOf(contentH, viewHeightPx.toFloat()) / 2f)
        panXPx = panXPx.coerceIn(-maxX, maxX)
        panYPx = panYPx.coerceIn(-maxY, maxY)
    }

    companion object {
        const val MIN_ZOOM: Float = 0.25f
        const val MAX_ZOOM: Float = 8f
        const val DEFAULT_TILE_PX: Int = 512
        const val MIN_TILE_PX: Int = 128
        const val MAX_TILE_PX: Int = 1024
        const val MAX_TILES: Int = 48
        const val MAX_TILE_DIMENSION: Int = 4096
    }
}

/**
 * Converts viewport intent into the Office renderer's bounded zoom PERCENT.
 * Reuses [OfficePdfGeometry.renderSize] (the renderer's own clamp authority),
 * so the host never asks for a bitmap the isolated renderer would scale
 * differently than expected.
 */
object PdfRenderPlanner {

    /** The renderer's base raster density (must match OfficePdfGeometry). */
    const val BASE_PX_PER_POINT: Float = 1.333f

    /** Zoom percent for a desired bitmap width, clamped to the renderer's table. */
    fun zoomPercentForWidth(box: PdfPageBox, targetWidthPx: Int): Int {
        if (targetWidthPx <= 0) return OfficePdfGeometry.MIN_ZOOM_PERCENT
        val displayedWidth = box.displayedWidthPt
        if (displayedWidth <= 0f) return OfficePdfGeometry.MIN_ZOOM_PERCENT
        val percent = (targetWidthPx / (displayedWidth * BASE_PX_PER_POINT) * 100f).roundToInt()
        return percent.coerceIn(OfficePdfGeometry.MIN_ZOOM_PERCENT, OfficePdfGeometry.MAX_ZOOM_PERCENT)
    }

    /** Exact bitmap the renderer will produce for that page/zoom (same clamp rules). */
    fun expectedBitmap(box: PdfPageBox, zoomPercent: Int): Pair<Int, Int>? =
        OfficePdfGeometry.renderSize(
            box.displayedWidthPt.roundToInt(),
            box.displayedHeightPt.roundToInt(),
            zoomPercent,
        )

    /** Thumbnail zoom keeping the longest edge at/below [maxEdgePx] and inside the caps. */
    fun thumbnailZoomPercent(box: PdfPageBox, maxEdgePx: Int): Int {
        val edge = maxEdgePx.coerceIn(48, OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        val longEdgePt = maxOf(box.displayedWidthPt, box.displayedHeightPt)
        if (longEdgePt <= 0f) return OfficePdfGeometry.MIN_ZOOM_PERCENT
        val percent = (edge / (longEdgePt * BASE_PX_PER_POINT) * 100f).roundToInt()
        return percent.coerceIn(OfficePdfGeometry.MIN_ZOOM_PERCENT, OfficePdfGeometry.MAX_ZOOM_PERCENT)
    }

    /** Target bitmap size for a viewport tile of [widthPx]×[heightPx] device pixels. */
    fun tileTargetPx(viewport: PdfViewport, paperRect: PdfRect): Pair<Int, Int> {
        val scale = viewport.zoom * viewport.pxPerPoint
        val w = (paperRect.width * scale).roundToInt().coerceIn(1, OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        val h = (paperRect.height * scale).roundToInt().coerceIn(1, OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        return w to h
    }
}
