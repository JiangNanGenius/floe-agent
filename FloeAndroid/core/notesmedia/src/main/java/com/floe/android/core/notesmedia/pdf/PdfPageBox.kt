// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * One PDF page's effective page box in PDF points (1/72 inch).
 *
 * `widthPt`/`heightPt` are the **unrotated** box that a viewer displays after
 * applying [rotationQuarterTurns] clockwise (PDF `/Rotate` semantics). The
 * module works in DISPLAYED coordinates everywhere ink/overlays are stored:
 * origin top-left, x right, y down, units = points. [toDisplayed] and
 * [toUnrotated] are the only legal conversions; keeping them here (and
 * unit-testing them) is what makes "correct paper coordinates" provable
 * instead of a guess in the UI layer.
 *
 * The box is derived only from an actual PDF page tree read by
 * [PdfPageBoxReader]; it is never invented from a bitmap size.
 */
data class PdfPageBox(
    val widthPt: Float,
    val heightPt: Float,
    val rotationQuarterTurns: Int = 0,
    /** True when the page carried an explicit /Rotate (diagnostics only). */
    val explicitRotation: Boolean = false,
) {
    init {
        require(widthPt.isFinite() && heightPt.isFinite()) { "Page box must be finite" }
        require(widthPt in MIN_POINTS..MAX_POINTS && heightPt in MIN_POINTS..MAX_POINTS) {
            "Page box outside the module bounds"
        }
        require(rotationQuarterTurns in 0..3) { "Rotation must be 0..3 quarter turns" }
    }

    /** Size after applying /Rotate (what the reader shows). */
    val displayedWidthPt: Float get() = if (rotationQuarterTurns % 2 == 0) widthPt else heightPt
    val displayedHeightPt: Float get() = if (rotationQuarterTurns % 2 == 0) heightPt else widthPt

    val aspectRatio: Float get() = widthPt / heightPt

    /**
     * Maps a point in displayed paper coordinates (top-left origin, points) to
     * unrotated PDF page coordinates (top-left origin, points). Both spaces
     * have y growing downward; PDF user space (bottom-left origin) is only
     * used by low-level writers, and [unrotatedToPdfUser] performs that last
     * flip explicitly.
     */
    fun toUnrotated(x: Float, y: Float): Pair<Float, Float> = when (rotationQuarterTurns) {
        0 -> x to y
        1 -> y to (heightPt - x)          // displayed (w=h0,h=w0)
        2 -> (widthPt - x) to (heightPt - y)
        else -> (widthPt - y) to x
    }

    /** Inverse of [toUnrotated]: unrotated page point (top-left origin) → displayed paper point. */
    fun toDisplayed(u: Float, v: Float): Pair<Float, Float> = when (rotationQuarterTurns) {
        0 -> u to v
        1 -> (heightPt - v) to u
        2 -> (widthPt - u) to (heightPt - v)
        else -> v to (widthPt - u)
    }

    /** Unrotated top-left-origin point → PDF user-space point (bottom-left origin). */
    fun unrotatedToPdfUser(u: Float, v: Float): Pair<Float, Float> =
        u to (heightPt - v)

    /**
     * Whether a rendered bitmap is consistent with this box. The Office
     * renderer is aspect-preserving (it may uniformly down-scale to its caps),
     * so the ASPECT must match within a small tolerance. Used as a real
     * cross-check when the caller has both facts; a mismatch marks the box
     * unverified rather than silently using it for export.
     */
    fun matchesRenderedAspect(widthPx: Int, heightPx: Int, tolerance: Float = 0.02f): Boolean {
        if (widthPx <= 0 || heightPx <= 0) return false
        val rendered = widthPx.toFloat() / heightPx.toFloat()
        val expected = displayedWidthPt / displayedHeightPt
        if (!rendered.isFinite() || !expected.isFinite()) return false
        return abs(rendered - expected) / expected <= tolerance
    }

    companion object {
        const val MIN_POINTS: Float = 1f
        const val MAX_POINTS: Float = 100_000f

        fun of(
            widthPt: Float,
            heightPt: Float,
            rotationDegrees: Float,
        ): PdfPageBox? {
            if (!widthPt.isFinite() || !heightPt.isFinite()) return null
            if (widthPt < MIN_POINTS || heightPt < MIN_POINTS) return null
            if (widthPt > MAX_POINTS || heightPt > MAX_POINTS) return null
            val turns = normalizeRotation(rotationDegrees)
            return PdfPageBox(widthPt, heightPt, turns, explicitRotation = true)
        }

        /** Normalizes any finite degree value to 0..3 quarter turns (rounds to nearest 90°). */
        fun normalizeRotation(degrees: Float): Int {
            if (!degrees.isFinite()) return 0
            var mod = (degrees % 360f + 360f) % 360f
            if (mod >= 359.5f) mod = 0f
            return ((mod / 90f).roundToInt() % 4 + 4) % 4
        }
    }
}

/** Page identity inside one verified PDF source. Index is 0-based, matching PdfRenderer. */
data class PdfPageId(val pageIndex: Int) {
    init {
        require(pageIndex in 0 until MAX_PAGE_INDEX) { "Page index outside the module bound" }
    }

    companion object {
        const val MAX_PAGE_INDEX: Int = 20_000 // identical to OfficePdfRendererContract.MAX_PAGE_INDEX
        fun of(index: Int): PdfPageId? = if (index in 0 until MAX_PAGE_INDEX) PdfPageId(index) else null
    }
}

/**
 * Geometry of a whole verified source, bound to the source digest. The digest
 * binding is what lets the caller reject stale OCR/search/annotation results
 * after the underlying PDF was replaced.
 */
data class PdfPageGeometry(
    val sourceSha256: String,
    val pages: List<PdfPageBox>,
    val encrypted: Boolean,
) {
    init {
        require(pages.size in 1..PdfPageId.MAX_PAGE_INDEX) { "Page count outside the module bound" }
    }

    val pageCount: Int get() = pages.size

    fun boxFor(page: PdfPageId): PdfPageBox = pages[page.pageIndex]

    fun isBoundTo(sourceSha256: String): Boolean = this.sourceSha256 == sourceSha256

    fun staleAgainst(other: PdfPageGeometry?): Boolean = other == null || other.sourceSha256 != sourceSha256
}
