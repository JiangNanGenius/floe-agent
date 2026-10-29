// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import android.graphics.pdf.PdfRenderer
import android.os.Build
import androidx.annotation.RequiresApi
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfSourceAccess

/**
 * OPT-IN platform text backend (API 35+).
 *
 * Why opt-in and not the default: `android.graphics.pdf.PdfRenderer.Page`
 * gained `textContents`/`searchText` in API 35, which is a real native text
 * layer (no OCR). But the shared Office PDF renderer deliberately runs in an
 * isolated process; opening untrusted PDF bytes in the app process for text
 * extraction reintroduces the parser into the app's crash domain. Since
 * 2026-10-30 the DEFAULT is the isolated-renderer backend
 * ([IsolatedPdfTextBackend]); this in-process backend remains available only
 * when a caller explicitly opts in ([PdfTextBackends.platformOrUnavailable]).
 *
 * The backend:
 *  - reuses [OfficePdfSourceAccess] for a NO-FOLLOW, exact-size, read-only
 *    descriptor of the verified snapshot (no path reopening);
 *  - never renders pixels and never writes;
 *  - bounds the number of pages scanned and polls cancellation per page;
 *  - returns paper-space rectangles from the platform (displayed page space,
 *    origin top-left, points) clamped to the page;
 *  - reports a typed refusal (encrypted/API/failed) instead of empty text.
 */
@RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
class PlatformPdfTextBackend(
    private val maxPagesPerSearch: Int = DEFAULT_MAX_PAGES,
) : PdfTextBackend {

    override val id: String = "platform-pdf-text-api35"

    override fun search(
        source: VerifiedMediaSnapshot,
        pageCount: Int,
        query: String,
        isCancelled: () -> Boolean,
    ): PdfTextSearchOutcome {
        val normalized = PdfTextIndex.normalizeQuery(query)
            ?: return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
        val fd = OfficePdfSourceAccess.openPinnedReadOnly(source.readableFile, source.byteCount)
            ?: return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
        var pagesWithoutText = 0
        val matches = ArrayList<PdfTextMatch>()
        var truncated = false
        try {
            PdfRenderer(fd).use { renderer ->
                val total = minOf(renderer.pageCount, pageCount, maxPagesPerSearch.coerceIn(1, MAX_PAGES))
                var searched = 0
                for (index in 0 until total) {
                    if (isCancelled()) {
                        return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.CANCELLED, id)
                    }
                    renderer.openPage(index).use { page ->
                        searched++
                        val contents = try {
                            page.textContents
                        } catch (_: Exception) {
                            emptyList()
                        }
                        val pageText = contents.joinToString("") { it.text.orEmpty() }
                        if (pageText.isBlank()) {
                            pagesWithoutText++
                            return@use
                        }
                        val found = try {
                            page.searchText(normalized)
                        } catch (_: IllegalArgumentException) {
                            emptyList()
                        } catch (_: Exception) {
                            return PdfTextSearchOutcome.Unavailable(
                                PdfTextUnavailableReason.BACKEND_FAILED,
                                id,
                            )
                        }
                        val pageW = page.width.toFloat()
                        val pageH = page.height.toFloat()
                        for (m in found) {
                            if (matches.size >= PdfTextIndex.MAX_LIMIT) {
                                truncated = true
                                break
                            }
                            val start = m.textStartIndex
                            val end = (start + normalized.length).coerceAtMost(pageText.length)
                            if (start !in 0 until pageText.length || end <= start) continue
                            val rects = m.bounds.orEmpty().mapNotNull { r ->
                                val left = maxOf(0f, minOf(r.left, r.right))
                                val top = maxOf(0f, minOf(r.top, r.bottom))
                                val right = minOf(pageW, maxOf(r.left, r.right))
                                val bottom = minOf(pageH, maxOf(r.top, r.bottom))
                                if (right > left && bottom > top) PdfRect(left, top, right, bottom) else null
                            }
                            val pageId = PdfPageId.of(index) ?: continue
                            matches.add(
                                PdfTextMatch(
                                    page = pageId,
                                    startChar = start,
                                    endChar = end,
                                    snippet = PdfTextIndex.snippet(pageText, start, end),
                                    rects = rects,
                                ),
                            )
                        }
                    }
                    if (truncated) break
                }
                if (matches.isEmpty()) {
                    return if (pagesWithoutText > 0 && pagesWithoutText == total) {
                        PdfTextSearchOutcome.NeedsOcr(normalized, pagesWithoutText)
                    } else {
                        PdfTextSearchOutcome.NoMatches(normalized, searched, id)
                    }
                }
                return PdfTextSearchOutcome.Matches(normalized, matches, truncated)
            }
        } catch (_: SecurityException) {
            // Encrypted/unsupported security scheme: the platform refuses; there
            // is no public password channel (see PdfPasswordSupport).
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.ENCRYPTED, id)
        } catch (_: Exception) {
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, id)
        } finally {
            runCatching { fd.close() }
        }
    }

    companion object {
        const val MIN_API: Int = 35
        const val DEFAULT_MAX_PAGES: Int = 500
        const val MAX_PAGES: Int = 2_000
    }
}

/** Backend selection policy (the only place that decides whether in-process search is allowed). */
object PdfTextBackends {

    /**
     * In-process platform backend selector. It is NOT the default (the
     * isolated renderer is); it is returned only when the caller opts in AND
     * the device is API 35+; otherwise a typed unavailable backend explains
     * why.
     */
    fun platformOrUnavailable(
        allowInProcessPlatformText: Boolean,
        apiLevel: Int = Build.VERSION.SDK_INT,
    ): PdfTextBackend {
        if (!allowInProcessPlatformText) {
            return UnavailablePdfTextBackend(
                PdfTextUnavailableReason.IN_PROCESS_SEARCH_DISABLED,
                "policy",
            )
        }
        if (apiLevel < PlatformPdfTextBackend.MIN_API) {
            return UnavailablePdfTextBackend(PdfTextUnavailableReason.API_LEVEL_TOO_LOW, "policy")
        }
        return PlatformPdfTextBackend()
    }

    /**
     * The DEFAULT Notes text backend (2026-10-30): real text extracted by the
     * shared Office isolated renderer. A transport is required because the
     * backend is bound to one live session/gateway; when it is absent the
     * honest typed fallback is returned (never an empty-text claim).
     */
    fun officeRendererDefault(
        transport: PdfPageTextTransport? = null,
        password: PdfPassword? = null,
    ): PdfTextBackend =
        if (transport == null) {
            UnavailablePdfTextBackend(PdfTextUnavailableReason.NATIVE_TEXT_NOT_EXPOSED, "office-pdf-renderer")
        } else {
            IsolatedPdfTextBackend(transport, password)
        }
}
