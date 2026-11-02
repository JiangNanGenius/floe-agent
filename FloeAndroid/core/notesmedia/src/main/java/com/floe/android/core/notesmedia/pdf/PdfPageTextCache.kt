// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfTextContract

/**
 * Bounded, source-bound cache for extracted page text.
 *
 * Selection can re-enter the same page repeatedly (mode toggle, sheet open,
 * copy). Re-running the binder transaction every time is wasteful, but a
 * cached page must never be served for a different snapshot, page count or
 * page index. Every entry therefore repeats the full identity (SHA-256, byte
 * length, page count, page index) and [get] re-validates the payload against
 * the CURRENT snapshot before returning it.
 *
 * Bounds are per page count and total UTF-16 characters. Empty page text is
 * cached deliberately: a scanned page is an observed "no text layer" fact, not
 * a reason to ask the renderer again on every selection attempt.
 */
internal class PdfPageTextCache(
    private val maxPages: Int = DEFAULT_MAX_PAGES,
    private val maxChars: Int = DEFAULT_MAX_CHARS,
) {
    private data class Entry(
        val sourceSha256: String,
        val sourceByteCount: Long,
        val pageCount: Int,
        val pageIndex: Int,
        val payload: OfficePdfPageText,
    )

    private val entries = LinkedHashMap<Int, Entry>(0, 0.75f, true)
    private var totalChars: Int = 0

    val size: Int
        get() = entries.size

    fun get(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        pageCount: Int,
    ): OfficePdfPageText? {
        val entry = entries[page.pageIndex] ?: return null
        if (!matchesIdentity(entry, source, page, pageCount)) {
            remove(page.pageIndex)
            return null
        }
        return entry.payload
    }

    /**
     * Stores [payload] only when it is for exactly this source/page and still
     * inside the shared text contract. Returns false when the entry is
     * refused (it is then not readable later).
     */
    fun put(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        pageCount: Int,
        payload: OfficePdfPageText,
    ): Boolean {
        if (payload.pageIndex != page.pageIndex) return false
        if (payload.pageCount != pageCount) return false
        if (payload.sourceBytes != source.byteCount) return false
        if (!OfficePdfTextContract.accept(payload, page.pageIndex, source.byteCount)) return false
        if (payload.text.length > maxChars.coerceAtLeast(1)) return false

        val old = entries.remove(page.pageIndex)
        if (old != null) totalChars -= old.payload.text.length
        while (entries.size >= maxPages.coerceAtLeast(1) && entries.isNotEmpty()) {
            val eldest = entries.entries.first()
            entries.remove(eldest.key)
            totalChars -= eldest.value.payload.text.length
        }
        while (totalChars + payload.text.length > maxChars.coerceAtLeast(1) && entries.isNotEmpty()) {
            val eldest = entries.entries.first()
            entries.remove(eldest.key)
            totalChars -= eldest.value.payload.text.length
        }
        entries[page.pageIndex] = Entry(
            sourceSha256 = source.sha256,
            sourceByteCount = source.byteCount,
            pageCount = pageCount,
            pageIndex = page.pageIndex,
            payload = payload,
        )
        totalChars += payload.text.length
        return true
    }

    fun clear() {
        entries.clear()
        totalChars = 0
    }

    private fun matchesIdentity(
        entry: Entry,
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        pageCount: Int,
    ): Boolean =
        entry.sourceSha256 == source.sha256 &&
            entry.sourceByteCount == source.byteCount &&
            entry.pageCount == pageCount &&
            entry.pageIndex == page.pageIndex &&
            entry.payload.pageIndex == page.pageIndex &&
            entry.payload.pageCount == pageCount &&
            entry.payload.sourceBytes == source.byteCount &&
            OfficePdfTextContract.accept(entry.payload, page.pageIndex, source.byteCount)

    private fun remove(pageIndex: Int) {
        val old = entries.remove(pageIndex) ?: return
        totalChars -= old.payload.text.length
        if (totalChars < 0) totalChars = 0
    }

    companion object {
        /** Four pages keeps a user's recent selection targets warm without holding a whole document. */
        const val DEFAULT_MAX_PAGES: Int = 4

        /** Two average pages plus headroom; one page is capped at 32k UTF-16 units by contract. */
        const val DEFAULT_MAX_CHARS: Int = 96_000
    }
}
