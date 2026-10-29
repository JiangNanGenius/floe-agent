// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

/**
 * The typed, bounded page-text payload returned by the isolated PDF renderer
 * (transaction [OfficePdfRendererContract.T_PAGE_TEXT]).
 *
 * Platform facts this contract is built on (verified against the installed
 * API-37 `android.jar`, `android-stubs-src.jar` and
 * `data/api-versions.xml` on 2026-10-30 — NOT assumed from the earlier
 * handoff):
 *  - `PdfRenderer.Page.getTextContents()` / `searchText(String)` are public
 *    since API 35 and return real PDF text content with point-space bounds
 *    ([android.graphics.pdf.content.PdfPageTextContent]);
 *  - `PdfRendererPreV` (and its `Page`) exposes the same content APIs as a
 *    Mainline `framework-pdf` module class on API 31/33/34 (module version
 *    13), so the backport is detectable at runtime by class presence;
 *  - the text path lives in the SAME `isolatedProcess` renderer as pixels:
 *    untrusted PDF bytes are never parsed in the app process.
 *
 * Bounds exist on BOTH sides of the binder:
 *  - the service truncates to [MAX_TEXT_CHARS_PER_PAGE] and never emits more
 *    than [MAX_TEXT_REGIONS] regions or [MAX_REGION_RECTS] rectangles per
 *    region, so one reply stays far below the binder transaction budget;
 *  - the host re-validates every count BEFORE reading it and sanitizes the
 *    payload again before delivery, so a hostile/buggy service reply cannot
 *    drive unbounded allocation in the app process.
 *
 * Identity: a payload carries the page index, the total page count and the
 * exact source byte length read from the received descriptor. The consumer
 * (Notes media) additionally checks its own SHA-256-bound snapshot length;
 * a payload that does not match is refused, never treated as "no text".
 */
data class OfficePdfPageText(
    val pageIndex: Int,
    val pageCount: Int,
    val sourceBytes: Long,
    val pageWidthPt: Float,
    val pageHeightPt: Float,
    val text: String,
    val regions: List<OfficePdfTextRegion>,
    val truncated: Boolean,
)

/** One text region [startChar, endChar) inside [OfficePdfPageText.text]. */
data class OfficePdfTextRegion(
    val startChar: Int,
    val endChar: Int,
    val rects: List<OfficePdfTextRect>,
)

/** Paper-space highlight rectangle in PDF points (top-left origin). */
data class OfficePdfTextRect(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
)

/**
 * Pure shape/bounds rules for the text transaction. No Android types: every
 * rule here is exercised by the module's JVM regression tests and is applied
 * identically by the isolated writer and the app-side reader.
 */
object OfficePdfTextContract {

    /** Per-page character cap (UTF-16 units). 32k chars ≈ 64 KiB on the wire. */
    const val MAX_TEXT_CHARS_PER_PAGE: Int = 32_000

    /** Regions (lines/blocks) accepted for one page. */
    const val MAX_TEXT_REGIONS: Int = 256

    /** Bounds rectangles accepted for one region. */
    const val MAX_REGION_RECTS: Int = 32

    /** A page box must be finite and inside the same sanity range the renderer uses. */
    const val MAX_PAGE_POINTS: Float = 100_000f

    /** Password channel shape: null means "no password"; non-empty and bounded otherwise. */
    const val MAX_PASSWORD_CHARS: Int = 512

    /** Typed flags carried on the wire (bit 0 = the service truncated the page text). */
    const val FLAG_TRUNCATED: Int = 1

    /** Transaction timeout for one page-text extraction. */
    const val TEXT_TIMEOUT_MS: Long = 45_000L

    /** Wire marker for "no password supplied" (never a valid array length). */
    const val NO_PASSWORD: Int = -1

    fun validPassword(password: CharArray?): Boolean =
        password == null || password.size in 1..MAX_PASSWORD_CHARS

    fun validRequestPageIndex(pageIndex: Int): Boolean =
        OfficePdfRendererContract.validPageIndex(pageIndex)

    fun validTextStatus(status: Int): Boolean = status == OfficePdfRendererContract.S_OK ||
        status == OfficePdfRendererContract.S_BAD_REQUEST ||
        status == OfficePdfRendererContract.S_INVALID_PDF ||
        status == OfficePdfRendererContract.S_PASSWORD ||
        status == OfficePdfRendererContract.S_PASSWORD_REJECTED ||
        status == OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED ||
        status == OfficePdfRendererContract.S_TEXT_UNSUPPORTED ||
        status == OfficePdfRendererContract.S_BUSY ||
        status == OfficePdfRendererContract.S_INTERNAL

    /**
     * Truncates [text] to at most [maxChars] UTF-16 units without splitting a
     * surrogate pair. Returns the bounded text and whether anything was cut.
     */
    fun truncate(text: String, maxChars: Int = MAX_TEXT_CHARS_PER_PAGE): Pair<String, Boolean> {
        val cap = maxChars.coerceIn(1, MAX_TEXT_CHARS_PER_PAGE)
        if (text.length <= cap) return text to false
        var end = cap
        if (end > 0 && Character.isHighSurrogate(text[end - 1])) end--
        if (end <= 0) return "" to true
        return text.substring(0, end) to true
    }

    /**
     * Builds the service-side payload from raw platform lines. The result is
     * ALWAYS inside every contract bound; null means the page identity itself
     * is invalid (nothing is claimed). Rectangles are clamped to the page box
     * and empty ones are dropped.
     */
    fun build(
        pageIndex: Int,
        pageCount: Int,
        sourceBytes: Long,
        pageWidthPt: Float,
        pageHeightPt: Float,
        lines: List<OfficePdfTextLine>,
        maxChars: Int = MAX_TEXT_CHARS_PER_PAGE,
    ): OfficePdfPageText? {
        if (!validRequestPageIndex(pageIndex)) return null
        if (pageCount !in 1..OfficePdfRendererContract.MAX_PAGE_INDEX) return null
        if (pageIndex >= pageCount) return null
        if (sourceBytes !in 1L..OfficePdfVerifiedSourceContract.MAX_SOURCE_BYTES) return null
        if (!validPageBox(pageWidthPt, pageHeightPt)) return null
        val cap = maxChars.coerceIn(1, MAX_TEXT_CHARS_PER_PAGE)
        val builder = StringBuilder()
        val regions = ArrayList<OfficePdfTextRegion>(minOf(lines.size, MAX_TEXT_REGIONS))
        var truncated = false
        for (line in lines) {
            if (regions.size >= MAX_TEXT_REGIONS) {
                truncated = true
                break
            }
            val raw = line.text
            if (raw.isEmpty()) continue
            // Platform text contents are lines/blocks and may not carry a
            // trailing separator. Insert ONE SPACE only when both sides are
            // non-whitespace: words from adjacent lines never fuse, and a
            // normalized query with a space can match across a line boundary
            // (a newline would break the text index's contiguous match).
            val separator = if (builder.isNotEmpty() &&
                !builder.last().isWhitespace() &&
                !raw.first().isWhitespace()
            ) {
                1
            } else {
                0
            }
            val remaining = cap - builder.length - separator
            if (remaining <= 0) {
                truncated = true
                break
            }
            val piece: String
            if (raw.length > remaining) {
                piece = truncate(raw, remaining).first
                truncated = true
            } else {
                piece = raw
            }
            if (piece.isEmpty()) {
                truncated = true
                break
            }
            if (separator == 1) builder.append(' ')
            val start = builder.length
            builder.append(piece)
            val end = builder.length
            val rects = boundedRects(line.rects, pageWidthPt, pageHeightPt)
            regions.add(OfficePdfTextRegion(start, end, rects))
            if (piece.length < raw.length) break
        }
        val ordered = regions.sortedBy { it.startChar }
        return OfficePdfPageText(
            pageIndex = pageIndex,
            pageCount = pageCount,
            sourceBytes = sourceBytes,
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
            text = builder.toString(),
            regions = ordered,
            truncated = truncated,
        )
    }

    /**
     * Host-side acceptance: the payload must be for exactly the requested page
     * of a plausible document whose byte length matches the verified snapshot.
     * Page-count equality is checked by the consumer that owns the session.
     */
    fun accept(payload: OfficePdfPageText?, expectedPageIndex: Int, expectedBytes: Long): Boolean {
        if (payload == null) return false
        if (payload.pageIndex != expectedPageIndex) return false
        if (payload.pageCount !in 1..OfficePdfRendererContract.MAX_PAGE_INDEX) return false
        if (payload.pageIndex >= payload.pageCount) return false
        if (expectedBytes < 1L || payload.sourceBytes != expectedBytes) return false
        if (!validPageBox(payload.pageWidthPt, payload.pageHeightPt)) return false
        if (payload.text.length > MAX_TEXT_CHARS_PER_PAGE) return false
        if (payload.regions.size > MAX_TEXT_REGIONS) return false
        var lastStart = -1
        for (region in payload.regions) {
            if (region.startChar < 0 || region.endChar < region.startChar ||
                region.endChar > payload.text.length
            ) {
                return false
            }
            if (region.startChar < lastStart) return false
            lastStart = region.startChar
            if (region.rects.size > MAX_REGION_RECTS) return false
            for (rect in region.rects) {
                if (!validRect(rect, payload.pageWidthPt, payload.pageHeightPt)) return false
            }
        }
        return true
    }

    /**
     * Re-bounds a payload after reading it from the wire (defense in depth):
     * text is truncated again, regions/rects are dropped once over a cap, and
     * any non-finite/out-of-page rectangle is omitted. Returns null only when
     * the identity itself is invalid.
     */
    fun sanitize(payload: OfficePdfPageText): OfficePdfPageText? {
        if (payload.pageCount !in 1..OfficePdfRendererContract.MAX_PAGE_INDEX) return null
        if (payload.pageIndex !in 0 until payload.pageCount) return null
        if (payload.sourceBytes !in 1L..OfficePdfVerifiedSourceContract.MAX_SOURCE_BYTES) return null
        if (!validPageBox(payload.pageWidthPt, payload.pageHeightPt)) return null
        val (text, cut) = truncate(payload.text)
        val regions = ArrayList<OfficePdfTextRegion>(minOf(payload.regions.size, MAX_TEXT_REGIONS))
        for (region in payload.regions) {
            if (regions.size >= MAX_TEXT_REGIONS) break
            if (region.startChar < 0 || region.endChar < region.startChar || region.endChar > text.length) continue
            val rects = region.rects
                .filter { validRect(it, payload.pageWidthPt, payload.pageHeightPt) }
                .take(MAX_REGION_RECTS)
            regions.add(region.copy(rects = rects))
        }
        return payload.copy(
            text = text,
            regions = regions.sortedBy { it.startChar },
            truncated = payload.truncated || cut,
        )
    }

    fun validPageBox(widthPt: Float, heightPt: Float): Boolean =
        widthPt.isFinite() && heightPt.isFinite() &&
            widthPt > 0f && heightPt > 0f &&
            widthPt <= MAX_PAGE_POINTS && heightPt <= MAX_PAGE_POINTS

    fun validRect(rect: OfficePdfTextRect, widthPt: Float, heightPt: Float): Boolean =
        rect.left.isFinite() && rect.top.isFinite() &&
            rect.right.isFinite() && rect.bottom.isFinite() &&
            rect.left >= 0f && rect.top >= 0f &&
            rect.right <= widthPt + RECT_TOLERANCE_PT &&
            rect.bottom <= heightPt + RECT_TOLERANCE_PT &&
            rect.right > rect.left && rect.bottom > rect.top

    private fun boundedRects(
        rects: List<OfficePdfTextLineRect>,
        pageWidthPt: Float,
        pageHeightPt: Float,
    ): List<OfficePdfTextRect> {
        val out = ArrayList<OfficePdfTextRect>(minOf(rects.size, MAX_REGION_RECTS))
        for (rect in rects) {
            if (out.size >= MAX_REGION_RECTS) break
            val left = rect.left.coerceIn(0f, pageWidthPt)
            val top = rect.top.coerceIn(0f, pageHeightPt)
            val right = rect.right.coerceIn(0f, pageWidthPt)
            val bottom = rect.bottom.coerceIn(0f, pageHeightPt)
            if (!left.isFinite() || !top.isFinite() || !right.isFinite() || !bottom.isFinite()) continue
            if (right <= left || bottom <= top) continue
            out.add(OfficePdfTextRect(left, top, right, bottom))
        }
        return out
    }

    /** Sub-point slack for platform rounding at the page edge. */
    private const val RECT_TOLERANCE_PT: Float = 0.5f
}

/** One platform text line before bounding (service-side only; no Android types). */
data class OfficePdfTextLine(
    val text: String,
    val rects: List<OfficePdfTextLineRect> = emptyList(),
)

/** One raw point-space rectangle from the platform text content. */
data class OfficePdfTextLineRect(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
)
