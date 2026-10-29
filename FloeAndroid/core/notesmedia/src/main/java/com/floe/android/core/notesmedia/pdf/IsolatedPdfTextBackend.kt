// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import kotlinx.coroutines.CancellationException

/**
 * The DEFAULT Notes PDF text backend: real platform text extracted by the
 * already-qualified Office isolated renderer (`core/officeengine/pdf`), one
 * bounded page transaction at a time.
 *
 * Why this shape:
 *  - untrusted PDF bytes are parsed only in the `:floe_pdf` isolated process;
 *    the app process never opens `PdfRenderer` for text;
 *  - every reply is identity-checked against the SHA-bound snapshot's exact
 *    byte length and page count before a single character is trusted, so a
 *    foreign/stale reply can never be presented as this document's text;
 *  - older devices without a platform text API answer
 *    [PdfMediaFailure.TEXT_UNSUPPORTED] and the caller gets an explicit
 *    `NeedsOcr` result — never a false "no matches";
 *  - the scan is bounded by page count and polled for cancellation; a
 *    truncated scan is reported (`NoMatches.truncated` / `Matches.truncated`)
 *    instead of pretending whole-document coverage;
 *  - it is asynchronous: [search] answers
 *    [PdfTextUnavailableReason.NATIVE_TEXT_ASYNC_REQUIRED] so a caller that
 *    accidentally uses the blocking entry point gets a typed refusal instead
 *    of a binder call on the wrong thread.
 */
class IsolatedPdfTextBackend(
    private val transport: PdfPageTextTransport,
    private val password: PdfPassword? = null,
    private val maxPagesPerSearch: Int = DEFAULT_MAX_PAGES,
) : PdfTextBackend {

    override val id: String = BACKEND_ID

    override fun search(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome =
        PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NATIVE_TEXT_ASYNC_REQUIRED, id)

    override suspend fun searchAsync(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        limit: Int,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome {
        val maxMatches = limit.coerceIn(1, PdfTextIndex.MAX_LIMIT)
        val normalized = PdfTextIndex.normalizeQuery(query)
            ?: return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NO_BACKEND, id)
        if (pageCount < 1) {
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
        }
        val boundedPages = maxPagesPerSearch.coerceIn(1, PdfPageId.MAX_PAGE_INDEX)
        val scanPages = minOf(pageCount, boundedPages)
        val matches = ArrayList<PdfTextMatch>(maxMatches)
        var scanned = 0
        var pagesWithoutText = 0
        var pagesWithText = 0
        var hitLimit = false
        var anyPageTruncated = false
        for (index0 in 0 until scanPages) {
            if (isCancelled()) {
                return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.CANCELLED, id)
            }
            val page = PdfPageId(index0)
            val secret = try {
                password?.borrowSecret()
            } catch (_: IllegalStateException) {
                // Session/credential lifecycle closed under the scan: typed
                // failure, never a silent "no matches".
                return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
            }
            val result = try {
                transport.pageText(source, page, secret)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
            }
            when (result) {
                is PdfPageTextResult.Failed -> return mapFailure(normalized, pageCount, result.failure)
                is PdfPageTextResult.Page -> {
                    val payload = result.page
                    // Identity fences: the page, the document length and the
                    // total page count must all agree with the verified
                    // snapshot before the text is trusted.
                    if (payload.pageIndex != index0 || payload.pageCount != pageCount) {
                        return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
                    }
                    if (payload.sourceBytes != source.byteCount) {
                        return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.SOURCE_CHANGED, id)
                    }
                    scanned++
                    if (payload.truncated) anyPageTruncated = true
                    if (payload.text.isBlank()) {
                        pagesWithoutText++
                        continue
                    }
                    pagesWithText++
                    // Search ONE page at a time: matches/offsets/rects are
                    // page-local by definition, and this keeps memory and work
                    // bounded even for a 10k-page scan.
                    val pageIndex = PdfTextIndex(maxPages = 1)
                    val indexed = pageIndex.addPage(
                        source = source,
                        page = page,
                        text = payload.text,
                        regions = payload.regions.map { region ->
                            PdfTextRegion(
                                startChar = region.startChar,
                                endChar = region.endChar,
                                rects = region.rects.map { PdfRect(it.left, it.top, it.right, it.bottom) },
                            )
                        },
                    )
                    if (!indexed) {
                        // Bounded index refused this page: never report a false
                        // "no matches" for text we could not search.
                        return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
                    }
                    val remaining = maxMatches - matches.size
                    if (remaining <= 0) {
                        hitLimit = true
                        break
                    }
                    when (val pageOutcome = pageIndex.search(
                        source = source,
                        query = normalized,
                        limit = remaining,
                        expectedPageCount = 1,
                        isCancelled = isCancelled,
                    )) {
                        is PdfTextSearchOutcome.Matches -> {
                            matches.addAll(pageOutcome.matches)
                            if (pageOutcome.truncated || matches.size >= maxMatches) {
                                hitLimit = true
                                break
                            }
                        }
                        is PdfTextSearchOutcome.Unavailable -> {
                            if (pageOutcome.reason == PdfTextUnavailableReason.CANCELLED) return pageOutcome
                            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
                        }
                        is PdfTextSearchOutcome.StaleSource ->
                            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.SOURCE_CHANGED, id)
                        // NoMatches / NeedsOcr for this single page mean no
                        // match here; the document-level aggregation below
                        // decides between "no matches" and "needs OCR".
                        is PdfTextSearchOutcome.NoMatches -> Unit
                        is PdfTextSearchOutcome.NeedsOcr -> Unit
                    }
                }
            }
        }
        val unscanned = pageCount - scanned
        return when {
            matches.isNotEmpty() -> PdfTextSearchOutcome.Matches(
                query = normalized,
                matches = matches,
                truncated = hitLimit || unscanned > 0 || anyPageTruncated,
            )
            pagesWithText == 0 -> PdfTextSearchOutcome.NeedsOcr(
                query = normalized,
                pagesWithoutText = (pagesWithoutText + unscanned).coerceAtMost(pageCount),
            )
            pagesWithoutText > 0 -> PdfTextSearchOutcome.NeedsOcr(
                query = normalized,
                pagesWithoutText = (pagesWithoutText + unscanned).coerceAtMost(pageCount),
            )
            else -> PdfTextSearchOutcome.NoMatches(
                query = normalized,
                pagesSearched = scanned,
                backendId = id,
                truncated = unscanned > 0 || anyPageTruncated,
            )
        }
    }

    private fun mapFailure(
        query: String,
        pageCount: Int,
        failure: PdfMediaFailure,
    ): PdfTextSearchOutcome = when (failure) {
        // No platform text API on this device: OCR is the honest next step.
        PdfMediaFailure.TEXT_UNSUPPORTED -> PdfTextSearchOutcome.NeedsOcr(query, pageCount)
        PdfMediaFailure.CANCELLED ->
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.CANCELLED, id)
        PdfMediaFailure.PASSWORD_PROTECTED ->
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.ENCRYPTED, id)
        PdfMediaFailure.PASSWORD_REJECTED ->
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.PASSWORD_REJECTED, id)
        PdfMediaFailure.PASSWORD_UNSUPPORTED ->
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.PASSWORD_UNSUPPORTED, id)
        PdfMediaFailure.SOURCE_CHANGED ->
            PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.SOURCE_CHANGED, id)
        else -> PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
    }

    companion object {
        const val BACKEND_ID: String = "office-pdf-renderer-text"

        /** One document open per page; 200 pages keeps a search bounded in time and binder calls. */
        const val DEFAULT_MAX_PAGES: Int = 200
    }
}
