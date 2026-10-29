// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot

/**
 * Text-search results for one verified PDF source.
 *
 * Honesty rules (G06 media contract):
 *  - an EMPTY result is only ever produced by a backend that actually read a
 *    text layer; otherwise the caller gets [NeedsOcr] or [Unavailable];
 *  - every result is bound to the source SHA-256. After the source changes,
 *    [PdfTextIndex] returns [StaleSource] instead of quietly matching old
 *    text against a new document;
 *  - bounds are optional because a native text layer may not expose them;
 *    OCR-supplied regions can carry real paper-space boxes.
 */
sealed class PdfTextSearchOutcome {
    data class Matches(
        val query: String,
        val matches: List<PdfTextMatch>,
        val truncated: Boolean,
    ) : PdfTextSearchOutcome()

    data class NoMatches(
        val query: String,
        val pagesSearched: Int,
        val backendId: String,
        /**
         * True when the backend stopped at its bounded page/window limit, so
         * "no match" is NOT a whole-document claim. Added 2026-10-30 with the
         * isolated text path; default false keeps existing constructors valid.
         */
        val truncated: Boolean = false,
    ) : PdfTextSearchOutcome()

    /** A backend exists but this source has no text layer (typical for scans). Run OCR. */
    data class NeedsOcr(
        val query: String,
        val pagesWithoutText: Int,
    ) : PdfTextSearchOutcome()

    data class Unavailable(
        val reason: PdfTextUnavailableReason,
        val backendId: String,
    ) : PdfTextSearchOutcome()

    data class StaleSource(
        val expectedSha256: String,
        val actualSha256: String,
    ) : PdfTextSearchOutcome()
}

enum class PdfTextUnavailableReason {
    /** The shared Office PDF renderer exposes no text transaction. */
    NATIVE_TEXT_NOT_EXPOSED,

    /** Platform text search exists (API 35+) but is not enabled by policy. */
    IN_PROCESS_SEARCH_DISABLED,

    /** Platform text search requires API 35+. */
    API_LEVEL_TOO_LOW,

    /** The document is encrypted; renderers refuse before text can be read. */
    ENCRYPTED,

    /** The backend ran and failed (transport/parse). */
    BACKEND_FAILED,

    /** Operation cancelled by the caller. */
    CANCELLED,

    /** No backend configured at all. */
    NO_BACKEND,

    /** The isolated text backend is asynchronous; use the await/suspend entry point. */
    NATIVE_TEXT_ASYNC_REQUIRED,

    /** A supplied password was refused by the platform renderer. */
    PASSWORD_REJECTED,

    /** This device has no password-capable platform renderer. */
    PASSWORD_UNSUPPORTED,

    /** The reply identified a different source length than the verified snapshot. */
    SOURCE_CHANGED,
}

/** One match, with paper-space highlight boxes when the backend supplied them. */
data class PdfTextMatch(
    val page: PdfPageId,
    val startChar: Int,
    val endChar: Int,
    val snippet: String,
    val rects: List<PdfRect> = emptyList(),
)

/** Caller/OCR-supplied text region inside one page. */
data class PdfTextRegion(
    val startChar: Int,
    val endChar: Int,
    val rects: List<PdfRect>,
)

/**
 * A source-bound text/OCR index.
 *
 * Legitimate producers:
 *  1. the DEFAULT isolated-renderer text backend (`IsolatedPdfTextBackend`),
 *     which extracts real platform text inside the `:floe_pdf` process;
 *  2. the opt-in in-process platform backend (`PlatformPdfTextBackend`);
 *  3. the Notes assistant's configured cloud OCR, which runs elsewhere and
 *     hands its text + paper-space regions to [addPage]. This module never
 *     downloads a model or calls a cloud provider.
 *
 * The index holds the last bound source digest and refuses to answer for a
 * different one. Text is stored verbatim (bounded), matching is
 * case-insensitive with collapsed whitespace, and snippets are clipped.
 */
class PdfTextIndex(
    private val maxPages: Int = PdfPageId.MAX_PAGE_INDEX,
    private val maxCharsPerPage: Int = 200_000,
    private val maxTotalChars: Int = 4_000_000,
) {
    private class PageText(
        val text: String,
        val regions: List<PdfTextRegion>,
        /** Opaque native Notes `ocrSourceKey`; never derived or interpreted here. */
        val nativeOcrSourceKey: String?,
    )

    private val pages = HashMap<Int, PageText>()
    private val missingPages = HashSet<Int>()
    private var boundSha: String? = null
    private var totalChars: Int = 0

    val boundSourceSha256: String? get() = boundSha

    /** True when the index belongs to [sourceSha256] and can be queried. */
    fun isBoundTo(sourceSha256: String): Boolean = boundSha == sourceSha256

    fun pageCount(): Int = pages.size

    fun clear() {
        pages.clear()
        missingPages.clear()
        boundSha = null
        totalChars = 0
    }

    /**
     * Binds the index to one source the first time a page is added. A page
     * added for a different source clears the index first (an index can never
     * mix two documents).
     */
    fun addPage(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        text: String,
        regions: List<PdfTextRegion> = emptyList(),
        nativeOcrSourceKey: String? = null,
    ): Boolean {
        if (boundSha != null && boundSha != source.sha256) clear()
        if (pages.size >= maxPages) return false
        if (text.length > maxCharsPerPage) return false
        val newTotal = totalChars - (pages[page.pageIndex]?.text?.length ?: 0) + text.length
        if (newTotal > maxTotalChars) return false
        val ordered = regions
            .filter { it.startChar in 0..it.endChar && it.endChar <= text.length && it.rects.isNotEmpty() }
            .sortedBy { it.startChar }
        pages[page.pageIndex] = PageText(text, ordered, nativeOcrSourceKey?.takeIf { it.length <= MAX_OCR_KEY_CHARS })
        missingPages.remove(page.pageIndex)
        boundSha = source.sha256
        totalChars = newTotal
        return true
    }

    /** Registers an explicit "this page has no text" observation (a scan). */
    fun markPageWithoutText(source: VerifiedMediaSnapshot, page: PdfPageId) {
        if (boundSha != null && boundSha != source.sha256) clear()
        pages.remove(page.pageIndex)
        missingPages.add(page.pageIndex)
        boundSha = source.sha256
    }

    fun pagesWithoutText(): Int = missingPages.size

    /**
     * Returns the OPAQUE native `ocrSourceKey` recorded for [page], if any.
     * The key is produced by the Notes native authority; this module only
     * echoes it back so the App can invalidate/refresh OCR against the exact
     * source. It is never computed, hashed or guessed here.
     */
    fun nativeOcrSourceKey(page: PdfPageId): String? = pages[page.pageIndex]?.nativeOcrSourceKey

    /**
     * Searches the indexed text. Returns [PdfTextSearchOutcome.Matches],
     * [NoMatches] when the index really covers the document, or [NeedsOcr]
     * when no/partial text is available.
     */
    fun search(
        source: VerifiedMediaSnapshot,
        query: String,
        limit: Int = DEFAULT_LIMIT,
        expectedPageCount: Int = pages.size,
        isCancelled: () -> Boolean = { false },
    ): PdfTextSearchOutcome {
        val bound = boundSha
        if (bound != null && bound != source.sha256) {
            return PdfTextSearchOutcome.StaleSource(expectedSha256 = bound, actualSha256 = source.sha256)
        }
        val normalized = normalizeQuery(query) ?: return PdfTextSearchOutcome.Unavailable(
            PdfTextUnavailableReason.NO_BACKEND,
            "index",
        )
        if (bound == null || pages.isEmpty()) {
            return PdfTextSearchOutcome.NeedsOcr(
                query = normalized,
                pagesWithoutText = if (missingPages.isNotEmpty()) missingPages.size else expectedPageCount,
            )
        }
        val max = limit.coerceIn(1, MAX_LIMIT)
        val matches = ArrayList<PdfTextMatch>(minOf(max, 32))
        var truncated = false
        outer@ for ((pageIndex, pageText) in pages.toSortedMap()) {
            if (isCancelled()) {
                return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.CANCELLED, "index")
            }
            val needle = normalized
            val lowered = normalizeForSearch(pageText.text)
            // Case folding may change length for exotic characters; only use the
            // folded copy when offsets stay identical, otherwise search verbatim
            // (still correct, just case-sensitive for that page).
            val haystack = if (lowered.length == pageText.text.length) lowered else pageText.text
            var from = 0
            while (true) {
                val at = haystack.indexOf(needle, from)
                if (at < 0) break
                val end = at + needle.length
                val rects = pageText.regions.firstOrNull { it.startChar <= at && it.endChar >= end }?.rects.orEmpty()
                matches.add(
                    PdfTextMatch(
                        page = PdfPageId(pageIndex),
                        startChar = at,
                        endChar = end,
                        snippet = snippet(pageText.text, at, end),
                        rects = rects,
                    ),
                )
                if (matches.size >= max) {
                    truncated = true
                    break@outer
                }
                from = end.coerceAtLeast(at + 1)
            }
        }
        if (matches.isEmpty()) {
            return if (missingPages.isNotEmpty()) {
                PdfTextSearchOutcome.NeedsOcr(normalized, missingPages.size)
            } else {
                PdfTextSearchOutcome.NoMatches(normalized, pages.size, "index")
            }
        }
        return PdfTextSearchOutcome.Matches(normalized, matches, truncated)
    }

    companion object {
        const val DEFAULT_LIMIT: Int = 50
        const val MAX_LIMIT: Int = 200
        const val MAX_QUERY_CHARS: Int = 128
        const val SNIPPET_RADIUS: Int = 48
        const val MAX_OCR_KEY_CHARS: Int = 256

        fun normalizeQuery(raw: String): String? {
            val trimmed = raw.trim().replace(Regex("\\s+"), " ")
            if (trimmed.isEmpty() || trimmed.length > MAX_QUERY_CHARS) return null
            return trimmed.lowercase(java.util.Locale.ROOT)
        }

        fun normalizeForSearch(text: String): String = text.lowercase(java.util.Locale.ROOT)

        fun snippet(text: String, start: Int, end: Int): String {
            val from = (start - SNIPPET_RADIUS).coerceAtLeast(0)
            val to = (end + SNIPPET_RADIUS).coerceAtMost(text.length)
            val prefix = if (from > 0) "…" else ""
            val suffix = if (to < text.length) "…" else ""
            return prefix + text.substring(from, to).replace(Regex("\\s+"), " ") + suffix
        }
    }
}

/**
 * One text backend. Implementations must be source-bound and cancellable; the
 * only shipped implementation in this module is the opt-in API 35+ platform
 * backend plus a typed "unavailable" instance used by default.
 */
interface PdfTextBackend {
    val id: String

    /**
     * Synchronous search for in-process/index/OCR backends. Called by
     * [PdfDocumentSession.searchText]; callers must not invoke it on the main
     * thread when the backend can block on I/O.
     */
    fun search(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome

    /**
     * Suspend variant. The default delegates to [search] (preserving every
     * existing backend); the isolated renderer backend overrides it so its
     * binder transactions never block a coroutine dispatcher thread.
     */
    suspend fun searchAsync(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome = searchAsync(
        source,
        pageCount,
        query,
        PdfTextIndex.DEFAULT_LIMIT,
        isCancelled,
    )

    /**
     * Limit-aware suspend variant (the isolated backend honours [limit]).
     * The default delegates to the synchronous backend.
     */
    suspend fun searchAsync(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        limit: Int,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome = search(source, pageCount, query, isCancelled)
}

/** Typed unavailability instance (never fabricates a text layer). */
class UnavailablePdfTextBackend(
    private val reason: PdfTextUnavailableReason,
    private val backendId: String = "unavailable",
) : PdfTextBackend {
    override val id: String get() = backendId

    override fun search(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome = PdfTextSearchOutcome.Unavailable(reason, backendId)
}
