// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

/**
 * Pure render bounds for the isolated PDF renderer. PdfRenderer page
 * dimensions are in PDF points (72/inch); the host asks for a zoom PERCENT
 * and both sides independently clamp through these rules, so a hostile or
 * buggy request can never drive an unbounded bitmap allocation in the
 * renderer process or an unbounded pixel buffer in the host process.
 */
object OfficePdfGeometry {

    /** Longest render edge in pixels (ARGB_8888) — generous for on-screen pages, far below any texture limit. */
    const val MAX_RENDER_DIMENSION_PX = 2048

    /** Total pixels per page render (≈ 8.3 MB as ARGB_8888). */
    const val MAX_RENDER_PIXELS = 2_073_600L

    /** Pixel bytes the host will ever read for one page: MAX_RENDER_PIXELS * 4. */
    const val MAX_RENDER_BYTES: Long = MAX_RENDER_PIXELS * 4L

    const val MIN_ZOOM_PERCENT = 25
    const val MAX_ZOOM_PERCENT = 400

    /** Base raster density at 100% zoom (≈96/72 ≈ 1.333 px per point — a crisp on-screen page). */
    private const val BASE_PX_PER_POINT = 1.333f

    /** Sanitised zoom: always inside the bounded table below the caps. */
    fun clampZoomPercent(zoomPercent: Int): Int =
        zoomPercent.coerceIn(MIN_ZOOM_PERCENT, MAX_ZOOM_PERCENT)

    /**
     * Target bitmap size for one page. Non-positive or NaN page dimensions
     * (a corrupt/forged claim) return null — the caller must refuse honestly.
     * The result is ALWAYS within MAX_RENDER_DIMENSION_PX per edge AND
     * MAX_RENDER_PIXELS total (uniform aspect-preserving scale-down when
     * needed — never a crop, never a distortion).
     */
    fun renderSize(pageWidthPoints: Int, pageHeightPoints: Int, zoomPercent: Int): Pair<Int, Int>? {
        if (pageWidthPoints <= 0 || pageWidthPoints > 100_000 ||
            pageHeightPoints <= 0 || pageHeightPoints > 100_000
        ) {
            return null
        }
        val zoom = clampZoomPercent(zoomPercent) / 100f
        var width = pageWidthPoints * BASE_PX_PER_POINT * zoom
        var height = pageHeightPoints * BASE_PX_PER_POINT * zoom
        // Edge caps first.
        val edge = MAX_RENDER_DIMENSION_PX.toFloat()
        val edgeScale = minOf(edge / width, edge / height, 1f)
        width *= edgeScale
        height *= edgeScale
        // Total-pixel cap (uniform, aspect-preserving).
        if (width.toLong() * height.toLong() > MAX_RENDER_PIXELS) {
            val areaScale = kotlin.math.sqrt(MAX_RENDER_PIXELS / (width * height))
            width *= areaScale.toFloat()
            height *= areaScale.toFloat()
        }
        val w = width.toInt().coerceAtLeast(1)
        val h = height.toInt().coerceAtLeast(1)
        if (w.toLong() * h.toLong() > MAX_RENDER_PIXELS) {
            // Integer rounding can only overshoot by <2 px²; a final 1-px
            // shrink keeps the invariant exact.
            val hFixed = (MAX_RENDER_PIXELS / w).toInt().coerceAtLeast(1)
            return w to minOf(h, hFixed)
        }
        return w to h
    }

    /**
     * Host-side guard for one renderer reply BEFORE any allocation: the
     * claimed dimensions and byte count must be internally consistent and
     * inside the same caps the service enforced. A reply that fails this is
     * dropped (nothing is read, no memory is reserved).
     */
    fun validateReply(width: Int, height: Int, byteCount: Long): Boolean {
        if (width < 1 || height < 1) return false
        if (width > MAX_RENDER_DIMENSION_PX || height > MAX_RENDER_DIMENSION_PX) return false
        val pixels = width.toLong() * height.toLong()
        if (pixels > MAX_RENDER_PIXELS) return false
        return byteCount == pixels * 4L
    }
}
