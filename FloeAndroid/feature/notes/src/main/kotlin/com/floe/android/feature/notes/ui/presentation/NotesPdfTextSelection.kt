// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.ui.api.NotesNormalizedRect
import com.floe.android.feature.notes.ui.api.NotesPdfTextRegion
import java.text.BreakIterator
import java.util.Locale

/**
 * Identity that a page-text selection is allowed to represent.
 *
 * It binds the exact verified PDF snapshot (SHA-256 and byte length), the PDF
 * page identity/index/count, and the Notes document/page/revision that were
 * current when the text was read. A selection with any other identity is stale
 * and must never reach the clipboard.
 */
public data class NotesPdfTextIdentity(
    public val documentID: String,
    public val documentRevision: Int,
    public val pageID: String,
    public val resourceID: String,
    public val sourceSha256: String,
    public val sourceByteCount: Long,
    public val pageIndex: Int,
    public val pageCount: Int,
) {
    public val isValid: Boolean
        get() = documentID.isNotBlank() &&
            documentRevision >= 0 &&
            pageID.isNotBlank() &&
            resourceID.isNotBlank() &&
            sourceSha256.length == SHA256_CHARS &&
            sourceSha256.all { it in HEX_DIGITS } &&
            sourceByteCount in 1L..MAX_SOURCE_BYTES &&
            pageCount in 1..MAX_PAGE_COUNT &&
            pageIndex in 0 until pageCount

    public companion object {
        public const val SHA256_CHARS: Int = 64
        public const val MAX_PAGE_COUNT: Int = 20_000
        public const val MAX_SOURCE_BYTES: Long = 256L * 1024L * 1024L

        private const val HEX_DIGITS: String = "0123456789abcdef"
    }
}

/** One bounded page-text snapshot ready for selection. */
public data class NotesPdfTextPage(
    public val identity: NotesPdfTextIdentity,
    public val pageWidthPt: Float,
    public val pageHeightPt: Float,
    public val text: String,
    public val regions: List<NotesPdfTextRegion>,
    public val truncated: Boolean,
    /**
     * False when the extracted page box did not match the Notes page box. The
     * text remains readable in the full-text sheet, but viewport selection is
     * refused because its geometry cannot be trusted.
     */
    public val geometryMatchesPage: Boolean,
)

/**
 * A selected UTF-16 range plus the exact text that may be copied. [rects] are
 * normalized page rectangles for the region boxes that are FULLY inside the
 * range; a partial region is never assigned an invented glyph box.
 */
public data class NotesPdfTextSelection(
    public val identity: NotesPdfTextIdentity,
    public val startChar: Int,
    public val endChar: Int,
    public val text: String,
    public val rects: List<NotesNormalizedRect>,
    public val truncated: Boolean,
)

/** Typed reason shown by the PDF text bar; user-visible strings live in the UI. */
public enum class NotesPdfTextNotice {
    NO_TEXT,
    NATIVE_TEXT_UNSUPPORTED,
    PROTECTED,
    SOURCE_CHANGED,
    PAGE_OUT_OF_RANGE,
    GEOMETRY_MISMATCH,
    BACKEND_FAILED,
    CANCELLED,
}

/**
 * Pure selection algebra for extracted PDF page text.
 *
 * Geometry rule: the platform producer supplies region/line boxes, not
 * per-glyph boxes. The viewport therefore selects whole regions by hit-testing
 * those real boxes, while character-level selection is offered by the platform
 * text sheet. We never estimate a glyph's x position from a character index.
 *
 * Unicode rule: every user range is snapped outward to grapheme-cluster
 * boundaries with [BreakIterator] so a copied string never splits a surrogate
 * pair or a combining sequence. CJK/RTL/multiline text is copied verbatim from
 * the extracted source.
 */
public object NotesPdfTextSelectionRules {

    public const val MAX_TEXT_CHARS_PER_PAGE: Int = 32_000
    public const val MAX_REGIONS: Int = 256
    public const val MAX_RECTS_PER_REGION: Int = 32
    public const val MAX_SELECTION_CHARS: Int = 32_000
    public const val DEFAULT_HIT_TOLERANCE: Float = 0.01f

    /**
     * Validates and bounds one page snapshot. Returns null rather than
     * constructing a page the UI could misrepresent.
     */
    public fun page(
        identity: NotesPdfTextIdentity,
        pageWidthPt: Float,
        pageHeightPt: Float,
        text: String,
        regions: List<NotesPdfTextRegion>,
        truncated: Boolean,
        geometryMatchesPage: Boolean,
    ): NotesPdfTextPage? {
        if (!identity.isValid) return null
        if (!validPageSize(pageWidthPt, pageHeightPt)) return null
        if (text.length > MAX_TEXT_CHARS_PER_PAGE) return null
        val bounded = regions
            .take(MAX_REGIONS)
            .mapNotNull { region ->
                if (region.startChar < 0 || region.endChar < region.startChar ||
                    region.endChar > text.length
                ) {
                    return@mapNotNull null
                }
                val rects = region.rects
                    .take(MAX_RECTS_PER_REGION)
                    .mapNotNull(::normalizedRect)
                    .sortedWith(compareBy({ it.top }, { it.left }))
                NotesPdfTextRegion(
                    startChar = region.startChar,
                    endChar = region.endChar,
                    rects = rects,
                )
            }
            .sortedBy { it.startChar }
        return NotesPdfTextPage(
            identity = identity,
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
            text = text,
            regions = bounded,
            truncated = truncated,
            geometryMatchesPage = geometryMatchesPage,
        )
    }

    /**
     * Pixel point inside one displayed page box -> normalized page point.
     * The caller passes the CURRENT page box size, so zoom and any page
     * rotation already applied by the renderer are the only transform; the
     * selection model never re-applies a second scale/rotation.
     */
    public fun normalizedPoint(
        xPx: Float,
        yPx: Float,
        widthPx: Float,
        heightPx: Float,
    ): Pair<Float, Float>? {
        if (!xPx.isFinite() || !yPx.isFinite() ||
            !widthPx.isFinite() || !heightPx.isFinite() ||
            widthPx <= 0f || heightPx <= 0f
        ) {
            return null
        }
        return (xPx / widthPx).coerceIn(0f, 1f) to (yPx / heightPx).coerceIn(0f, 1f)
    }

    /**
     * Region under a normalized page point, or null. Tolerance makes thin text
     * lines easier to touch; among overlapping boxes the nearest center wins.
     */
    public fun regionAt(
        page: NotesPdfTextPage,
        normalizedX: Float,
        normalizedY: Float,
        tolerance: Float = DEFAULT_HIT_TOLERANCE,
    ): Int? {
        if (!normalizedX.isFinite() || !normalizedY.isFinite()) return null
        val x = normalizedX.coerceIn(0f, 1f)
        val y = normalizedY.coerceIn(0f, 1f)
        val slack = tolerance.coerceIn(0f, 0.05f)
        var bestIndex = -1
        var bestDistance = Float.MAX_VALUE
        page.regions.forEachIndexed { index, region ->
            for (rect in region.rects) {
                if (x < rect.left - slack || x > rect.right + slack ||
                    y < rect.top - slack || y > rect.bottom + slack
                ) {
                    continue
                }
                val centerX = (rect.left + rect.right) / 2f
                val centerY = (rect.top + rect.bottom) / 2f
                val distance = (x - centerX) * (x - centerX) + (y - centerY) * (y - centerY)
                if (distance < bestDistance) {
                    bestDistance = distance
                    bestIndex = index
                }
            }
        }
        return bestIndex.takeIf { it >= 0 }
    }

    /**
     * Selection spanning whole regions [firstRegion]..[lastRegion]. This is the
     * viewport gesture: arbitrary line/region runs, never a fabricated
     * character-to-glyph position.
     */
    public fun regionSpan(
        page: NotesPdfTextPage,
        identity: NotesPdfTextIdentity,
        firstRegion: Int,
        lastRegion: Int,
    ): NotesPdfTextSelection? {
        if (!pageIsCurrent(page, identity) || !page.geometryMatchesPage) return null
        if (page.regions.isEmpty()) return null
        val a = firstRegion.coerceIn(0, page.regions.lastIndex)
        val b = lastRegion.coerceIn(0, page.regions.lastIndex)
        val from = minOf(a, b)
        val to = maxOf(a, b)
        val covered = page.regions.subList(from, to + 1)
        val start = covered.minOf { it.startChar }
        val end = covered.maxOf { it.endChar }
        if (end <= start) return null
        return selection(page, identity, start, end, covered.flatMap { it.rects })
    }

    /** Clamped character range selection used by the text sheet/select-all. */
    public fun range(
        page: NotesPdfTextPage,
        identity: NotesPdfTextIdentity,
        startChar: Int,
        endChar: Int,
    ): NotesPdfTextSelection? {
        if (!pageIsCurrent(page, identity)) return null
        val (start, end) = graphemeRange(page.text, startChar, endChar)
        if (start == end) return null
        val rects = page.regions
            .filter { it.startChar >= start && it.endChar <= end }
            .flatMap { it.rects }
        return selection(page, identity, start, end, rects)
    }

    public fun selectAll(
        page: NotesPdfTextPage,
        identity: NotesPdfTextIdentity,
    ): NotesPdfTextSelection? = range(page, identity, 0, page.text.length)

    public fun pageIsCurrent(
        page: NotesPdfTextPage,
        identity: NotesPdfTextIdentity,
    ): Boolean = identity.isValid && page.identity == identity

    public fun selectionIsCurrent(
        selection: NotesPdfTextSelection,
        identity: NotesPdfTextIdentity,
    ): Boolean =
        identity.isValid &&
            selection.identity == identity &&
            selection.startChar >= 0 &&
            selection.endChar >= selection.startChar &&
            selection.endChar - selection.startChar == selection.text.length &&
            selection.text.isNotEmpty() &&
            selection.text.length <= MAX_SELECTION_CHARS

    /**
     * The only copy boundary: text leaves this function only when the
     * selection still represents the caller's current document/page/source.
     */
    public fun copyText(
        selection: NotesPdfTextSelection,
        currentIdentity: NotesPdfTextIdentity,
    ): String? = if (selectionIsCurrent(selection, currentIdentity)) selection.text else null

    /**
     * Snaps [start]..[end] outward to grapheme-cluster boundaries and clamps
     * them to [text]. A collapsed range stays empty. Surrogate pairs and
     * combining sequences are never split.
     */
    public fun graphemeRange(text: String, startChar: Int, endChar: Int): Pair<Int, Int> {
        if (text.isEmpty()) return 0 to 0
        var start = startChar.coerceIn(0, text.length)
        var end = endChar.coerceIn(0, text.length)
        if (start > end) {
            val swap = start
            start = end
            end = swap
        }
        if (start == end) return start to start
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(text)
        if (start > 0 && !iterator.isBoundary(start)) {
            val previous = iterator.preceding(start)
            if (previous != BreakIterator.DONE) start = previous
        }
        if (end < text.length && !iterator.isBoundary(end)) {
            val next = iterator.following(end)
            if (next != BreakIterator.DONE) end = next
        }
        if (start > end) {
            val swap = start
            start = end
            end = swap
        }
        return start to end
    }

    private fun selection(
        page: NotesPdfTextPage,
        identity: NotesPdfTextIdentity,
        startChar: Int,
        endChar: Int,
        rects: List<NotesNormalizedRect>,
    ): NotesPdfTextSelection? {
        if (!pageIsCurrent(page, identity)) return null
        val (start, end) = graphemeRange(page.text, startChar, endChar)
        if (start == end) return null
        if (end - start > MAX_SELECTION_CHARS) return null
        val boundedRects = rects
            .mapNotNull(::normalizedRect)
            .distinct()
        return NotesPdfTextSelection(
            identity = identity,
            startChar = start,
            endChar = end,
            text = page.text.substring(start, end),
            rects = boundedRects,
            truncated = page.truncated,
        )
    }

    private fun normalizedRect(rect: NotesNormalizedRect): NotesNormalizedRect? {
        if (!rect.left.isFinite() || !rect.top.isFinite() ||
            !rect.right.isFinite() || !rect.bottom.isFinite()
        ) {
            return null
        }
        val left = rect.left.coerceIn(0f, 1f)
        val top = rect.top.coerceIn(0f, 1f)
        val right = rect.right.coerceIn(0f, 1f)
        val bottom = rect.bottom.coerceIn(0f, 1f)
        if (right <= left || bottom <= top) return null
        return NotesNormalizedRect(left = left, top = top, right = right, bottom = bottom)
    }

    private fun validPageSize(widthPt: Float, heightPt: Float): Boolean =
        widthPt.isFinite() && heightPt.isFinite() &&
            widthPt > 0f && heightPt > 0f &&
            widthPt <= MAX_PAGE_POINTS && heightPt <= MAX_PAGE_POINTS

    private const val MAX_PAGE_POINTS: Float = 100_000f
}
