// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import android.content.Context
import android.graphics.Bitmap
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.source.MediaSnapshotVerifier
import com.floe.android.core.notesmedia.source.SnapshotRefusal
import com.floe.android.core.notesmedia.source.SnapshotResult
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSourceContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One open, verified PDF document.
 *
 * Responsibilities kept here (and nowhere else):
 *  - one owned verified snapshot, one page count, one optional page geometry;
 *  - the bounded render/thumbnail/tile caches for THAT document;
 *  - cancellable page/tile/thumbnail requests fenced by the gateway;
 *  - the source-bound text/OCR index facade and typed search outcomes;
 *  - reading-state/viewport value construction (state is stored by the
 *    caller's Notes authority — this class never persists anything).
 *
 * It does NOT render: every pixel comes from [PdfRenderGateway] (the shared
 * Office isolated renderer in production). It does NOT own the Notes document,
 * the editor state or a database.
 *
 * Bitmap ownership:
 *  - results with `fromCache = true` are owned by the session cache; the caller
 *    must only DRAW them and must never recycle them;
 *  - uncached results (`renderForExport`) are owned by the caller, who MUST
 *    recycle them; [releaseBitmap] performs the right action for either.
 */
class PdfDocumentSession internal constructor(
    val source: VerifiedMediaSnapshot,
    val pageCount: Int,
    /** Null when the page tree could not be proven; reading/rendering still works, export refuses. */
    val geometry: PdfPageGeometry?,
    private val gateway: PdfRenderGateway,
    private val ownsGateway: Boolean,
    private val textBackend: PdfTextBackend,
    /** RAM-only password supplied at open; owned by this session and cleared on close. */
    private val password: PdfPassword?,
    renderBudgetBytes: Long,
    thumbnailBudgetBytes: Long,
) : AutoCloseable {

    private val renderCache = ByteBudgetCache<String, Bitmap>(
        maxBytes = renderBudgetBytes,
        sizeOf = { bitmap -> bitmap.allocationByteCount.toLong().coerceAtLeast(1L) },
        onEvict = { bitmap -> if (!bitmap.isRecycled) runCatching { bitmap.recycle() } },
    )
    private val thumbnailCache = ByteBudgetCache<String, Bitmap>(
        maxBytes = thumbnailBudgetBytes,
        sizeOf = { bitmap -> bitmap.allocationByteCount.toLong().coerceAtLeast(1L) },
        onEvict = { bitmap -> if (!bitmap.isRecycled) runCatching { bitmap.recycle() } },
    )
    private val textIndex = PdfTextIndex()
    private val verifiedAspects = HashMap<Int, Boolean>()
    private val closed = AtomicBoolean(false)

    val isClosed: Boolean get() = closed.get()

    /** True once a rendered page proved the parsed page box aspect (null = not checked yet). */
    fun pageGeometryVerified(page: PdfPageId): Boolean? = synchronized(verifiedAspects) { verifiedAspects[page.pageIndex] }

    fun pageBox(page: PdfPageId): PdfPageBox? = geometry?.pages?.getOrNull(page.pageIndex)

    /** A fresh viewport for this page, or null when the page tree/box is unavailable. */
    fun viewport(page: PdfPageId, densityDpi: Int): PdfViewport? =
        pageBox(page)?.let { PdfViewport(it, densityDpi) }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    /**
     * Renders one page at a bounded zoom percent, reusing the bounded cache.
     * Cancels cooperatively: the gateway recycles a bitmap that arrives after
     * cancellation.
     */
    suspend fun renderPage(page: PdfPageId, zoomPercent: Int): PdfPageRenderResult {
        if (closed.get()) return PdfPageRenderResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        if (page.pageIndex !in 0 until pageCount) return PdfPageRenderResult.Failed(PdfMediaFailure.PAGE_OUT_OF_RANGE)
        val key = PdfCacheKeys.render(page.pageIndex, zoomPercent)
        renderCache.get(key)?.let { cached ->
            return PdfPageRenderResult.Ready(
                bitmap = cached,
                widthPx = cached.width,
                heightPx = cached.height,
                zoomPercent = zoomPercent,
                page = page,
                fromCache = true,
            )
        }
        val result = renderWithPassword(page, zoomPercent)
        if (result is PdfPageRenderResult.Ready) {
            recordAspect(page, result)
            if (!renderCache.put(key, result.bitmap)) {
                // Budget refused (single page > budget): hand it to the caller
                // uncached rather than dropping a valid render.
                return result
            }
        }
        return result
    }

    /**
     * Renders a page the caller owns, bypassing the cache. Intended for export
     * (the exporter recycles it). Cancellation still fences the gateway.
     */
    suspend fun renderForExport(page: PdfPageId, zoomPercent: Int): PdfPageRenderResult {
        if (closed.get()) return PdfPageRenderResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        if (page.pageIndex !in 0 until pageCount) return PdfPageRenderResult.Failed(PdfMediaFailure.PAGE_OUT_OF_RANGE)
        val result = renderWithPassword(page, zoomPercent)
        if (result is PdfPageRenderResult.Ready) recordAspect(page, result)
        return result
    }

    /**
     * Every pixel request goes through the password-aware gateway overload:
     * the secret is borrowed from this session's RAM-only holder for exactly
     * one transaction and never copied into a String in the app process.
     */
    private suspend fun renderWithPassword(page: PdfPageId, zoomPercent: Int): PdfPageRenderResult {
        val secret = password?.borrowSecret() ?: return gateway.renderPage(source, page, zoomPercent)
        return gateway.renderPageWithPassword(source, page, zoomPercent, secret)
    }

    /** Releases a bitmap according to its ownership (cached bitmaps are ignored). */
    fun releaseBitmap(result: PdfPageRenderResult) {
        if (result is PdfPageRenderResult.Ready && !result.fromCache && !result.bitmap.isRecycled) {
            runCatching { result.bitmap.recycle() }
        }
    }

    /**
     * One device-resolution tile, cropped from a cached page render. The crop
     * rect is derived from the tile's PAPER rect through the page box mapping,
     * so it is correct for rotated pages too.
     */
    suspend fun renderTile(page: PdfPageId, tile: PdfTile, viewport: PdfViewport): PdfTileResult {
        if (closed.get()) return PdfTileResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        val box = pageBox(page) ?: return PdfTileResult.Failed(PdfMediaFailure.SOURCE_CHANGED)
        val key = PdfCacheKeys.tile(page.pageIndex, tile.column, tile.row, viewport.zoom.times(100).toInt())
        renderCache.get(key)?.let { return PdfTileResult.Ready(it, fromCache = true) }
        val targetPageWidthPx = (box.displayedWidthPt * viewport.zoom * viewport.pxPerPoint)
            .toInt().coerceAtLeast(1)
        val zoom = PdfRenderPlanner.zoomPercentForWidth(box, targetPageWidthPx)
        val pageResult = renderPage(page, zoom)
        if (pageResult !is PdfPageRenderResult.Ready) {
            return PdfTileResult.Failed((pageResult as? PdfPageRenderResult.Failed)?.failure ?: PdfMediaFailure.TRANSPORT)
        }
        val bitmap = pageResult.bitmap
        if (bitmap.isRecycled) return PdfTileResult.Failed(PdfMediaFailure.TRANSPORT)
        val rect = tilePixelRect(box, tile.paperRect, bitmap.width, bitmap.height)
            ?: return PdfTileResult.Failed(PdfMediaFailure.PAGE_OUT_OF_RANGE)
        if (rect.x + rect.width > bitmap.width || rect.y + rect.height > bitmap.height ||
            rect.width <= 0 || rect.height <= 0
        ) {
            return PdfTileResult.Failed(PdfMediaFailure.PAGE_OUT_OF_RANGE)
        }
        val cropped = try {
            Bitmap.createBitmap(bitmap, rect.x, rect.y, rect.width, rect.height)
        } catch (_: IllegalArgumentException) {
            return PdfTileResult.Failed(PdfMediaFailure.PAGE_OUT_OF_RANGE)
        } catch (_: OutOfMemoryError) {
            return PdfTileResult.Failed(PdfMediaFailure.TRANSPORT)
        }
        if (!renderCache.put(key, cropped)) {
            return PdfTileResult.Ready(cropped, fromCache = false)
        }
        return PdfTileResult.Ready(cropped, fromCache = true)
    }

    suspend fun thumbnail(page: PdfPageId, maxEdgePx: Int): PdfThumbnailResult {
        if (closed.get()) return PdfThumbnailResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        val box = pageBox(page) ?: return PdfThumbnailResult.Failed(PdfMediaFailure.SOURCE_CHANGED)
        val plan = when (val planned = PdfThumbnailPlanner.plan(page, box, maxEdgePx)) {
            is PdfThumbnailPlanResult.Refused -> return PdfThumbnailResult.Failed(PdfMediaFailure.INVALID_PDF)
            is PdfThumbnailPlanResult.Ready -> planned.plan
        }
        thumbnailCache.get(plan.cacheKey)?.let {
            return PdfThumbnailResult.Ready(it, plan, fromCache = true)
        }
        val result = gateway.renderPage(source, page, plan.zoomPercent)
        if (result !is PdfPageRenderResult.Ready) {
            return PdfThumbnailResult.Failed((result as? PdfPageRenderResult.Failed)?.failure ?: PdfMediaFailure.TRANSPORT)
        }
        recordAspect(page, result)
        if (!thumbnailCache.put(plan.cacheKey, result.bitmap)) {
            return PdfThumbnailResult.Ready(result.bitmap, plan, fromCache = false)
        }
        return PdfThumbnailResult.Ready(result.bitmap, plan, fromCache = true)
    }

    fun releaseThumbnail(result: PdfThumbnailResult) {
        if (result is PdfThumbnailResult.Ready && !result.fromCache && !result.bitmap.isRecycled) {
            runCatching { result.bitmap.recycle() }
        }
    }

    // ------------------------------------------------------------------
    // Text / OCR index
    // ------------------------------------------------------------------

    /** Adds OCR/native text for one page, bound to this session's source. */
    fun indexText(
        page: PdfPageId,
        text: String,
        regions: List<PdfTextRegion> = emptyList(),
        nativeOcrSourceKey: String? = null,
    ): Boolean = textIndex.addPage(source, page, text, regions, nativeOcrSourceKey)

    fun markPageWithoutText(page: PdfPageId) = textIndex.markPageWithoutText(source, page)

    fun textIndexState(): PdfTextIndex = textIndex

    /**
     * Searches the session's index first; when the index has nothing for this
     * source, asks the configured backend. Encrypted documents report
     * ENCRYPTED before touching any backend.
     */
    fun searchText(
        query: String,
        limit: Int = PdfTextIndex.DEFAULT_LIMIT,
        isCancelled: () -> Boolean = { false },
    ): PdfTextSearchOutcome {
        if (closed.get()) return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, "session")
        val normalized = PdfTextIndex.normalizeQuery(query)
            ?: return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NO_BACKEND, "session")
        // An encrypted source is only unusable when no password unlocked this
        // session; a successfully opened protected document must still search.
        if (geometry?.encrypted == true && password == null) {
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.ENCRYPTED, "session")
        }
        if (textIndex.isBoundTo(source.sha256) && textIndex.pageCount() > 0) {
            return textIndex.search(source, normalized, limit, pageCount, isCancelled)
        }
        return textBackend.search(source, pageCount, normalized, isCancelled)
    }

    /**
     * Suspending search used by the UI/assistant. The default backend is the
     * isolated renderer text path ([IsolatedPdfTextBackend]), which performs
     * one bounded binder transaction per page; a pre-bound index or an
     * injected OCR/platform backend keeps working through the same outcome
     * types.
     */
    suspend fun searchTextAwait(
        query: String,
        limit: Int = PdfTextIndex.DEFAULT_LIMIT,
        isCancelled: () -> Boolean = { false },
    ): PdfTextSearchOutcome {
        if (closed.get()) {
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.BACKEND_FAILED, "session")
        }
        val normalized = PdfTextIndex.normalizeQuery(query)
            ?: return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.NO_BACKEND, "session")
        if (geometry?.encrypted == true && password == null) {
            return PdfTextSearchOutcome.Unavailable(PdfTextUnavailableReason.ENCRYPTED, "session")
        }
        if (textIndex.isBoundTo(source.sha256) && textIndex.pageCount() > 0) {
            return textIndex.search(source, normalized, limit, pageCount, isCancelled)
        }
        // Every backend (isolated binder or the opt-in in-process platform
        // parser) runs off the main thread; the isolated one never blocks a
        // dispatcher thread on binder I/O.
        return withContext(Dispatchers.IO) {
            textBackend.searchAsync(source, pageCount, normalized, limit, isCancelled)
        }
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        renderCache.clear()
        thumbnailCache.clear()
        password?.close()
        if (ownsGateway) {
            gateway.release { /* caches are already empty; nothing else is owned */ }
        }
    }

    private fun recordAspect(page: PdfPageId, result: PdfPageRenderResult.Ready) {
        val box = pageBox(page) ?: return
        synchronized(verifiedAspects) {
            verifiedAspects[page.pageIndex] = box.matchesRenderedAspect(result.widthPx, result.heightPx)
        }
    }

    companion object {
        const val DEFAULT_RENDER_BUDGET_BYTES: Long = 48L shl 20
        const val DEFAULT_THUMBNAIL_BUDGET_BYTES: Long = 12L shl 20

        /**
         * Crops a paper-space rect out of a displayed page bitmap:
         * (x, y, width, height) in bitmap pixels, or null when empty.
         */
        fun tilePixelRect(
            box: PdfPageBox,
            paperRect: PdfRect,
            bitmapWidth: Int,
            bitmapHeight: Int,
        ): TilePixelRect? {
            if (bitmapWidth <= 0 || bitmapHeight <= 0) return null
            val corners = listOf(
                box.toDisplayed(paperRect.left, paperRect.top),
                box.toDisplayed(paperRect.right, paperRect.top),
                box.toDisplayed(paperRect.left, paperRect.bottom),
                box.toDisplayed(paperRect.right, paperRect.bottom),
            )
            val left = corners.minOf { it.first }
            val top = corners.minOf { it.second }
            val right = corners.maxOf { it.first }
            val bottom = corners.maxOf { it.second }
            val sx = bitmapWidth / box.displayedWidthPt
            val sy = bitmapHeight / box.displayedHeightPt
            val x = (left * sx).toInt().coerceIn(0, bitmapWidth - 1)
            val y = (top * sy).toInt().coerceIn(0, bitmapHeight - 1)
            val w = ((right - left) * sx).toInt().coerceAtMost(bitmapWidth - x)
            val h = ((bottom - top) * sy).toInt().coerceAtMost(bitmapHeight - y)
            if (w <= 0 || h <= 0) return null
            return TilePixelRect(x, y, w, h)
        }
    }
}

/** Pixel crop of one paper-space tile inside a displayed page bitmap. */
data class TilePixelRect(val x: Int, val y: Int, val width: Int, val height: Int)

sealed class PdfTileResult {
    data class Ready(val bitmap: Bitmap, val fromCache: Boolean) : PdfTileResult()
    data class Failed(val failure: PdfMediaFailure) : PdfTileResult()
}

sealed class PdfThumbnailResult {
    data class Ready(
        val bitmap: Bitmap,
        val plan: PdfThumbnailPlan,
        val fromCache: Boolean,
    ) : PdfThumbnailResult()

    data class Failed(val failure: PdfMediaFailure) : PdfThumbnailResult()
}

sealed class PdfOpenResult {
    data class Opened(val session: PdfDocumentSession) : PdfOpenResult()
    data class Failed(
        val failure: PdfMediaFailure,
        val geometryRefusal: PdfGeometryRefusal? = null,
    ) : PdfOpenResult()
}

/** Construction options. All budgets are byte caps; no option changes trust. */
data class PdfSessionOptions(
    val textBackend: PdfTextBackend? = null,
    val allowInProcessPlatformText: Boolean = false,
    val renderBudgetBytes: Long = PdfDocumentSession.DEFAULT_RENDER_BUDGET_BYTES,
    val thumbnailBudgetBytes: Long = PdfDocumentSession.DEFAULT_THUMBNAIL_BUDGET_BYTES,
    val reverifySourceBytes: Boolean = false,
    val gateway: PdfRenderGateway? = null,
    /**
     * RAM-only password for a protected PDF. Ownership transfers to
     * [PdfDocumentSessions.open]: the session clears it on close (or on a
     * failed open) and never logs/persists it. Null keeps the previous
     * no-password behaviour. Trailing default keeps old positional
     * construction source-compatible.
     */
    val password: PdfPassword? = null,
)

/**
 * Opens a verified PDF snapshot. The heavy work (byte re-proof when requested,
 * page-tree read, renderer page count) runs on [Dispatchers.IO]; the shared
 * renderer's callbacks are main-thread and are bridged by the gateway.
 */
object PdfDocumentSessions {

    suspend fun open(
        context: Context,
        source: VerifiedMediaSnapshot,
        options: PdfSessionOptions = PdfSessionOptions(),
    ): PdfOpenResult = withContext(Dispatchers.IO) {
        if (source.mediaType != NotesMediaType.PDF) {
            options.password?.close()
            return@withContext PdfOpenResult.Failed(PdfMediaFailure.INVALID_PDF)
        }
        if (!OfficePdfVerifiedSourceContract.shapeOk(source)) {
            options.password?.close()
            return@withContext PdfOpenResult.Failed(PdfMediaFailure.INVALID_PDF)
        }
        if (options.reverifySourceBytes) {
            when (val verified = MediaSnapshotVerifier.verify(source.file, NotesMediaType.PDF, source.displayName)) {
                is SnapshotResult.Refused -> {
                    options.password?.close()
                    return@withContext PdfOpenResult.Failed(
                        when (verified.reason) {
                            SnapshotRefusal.TOO_LARGE -> PdfMediaFailure.INVALID_PDF
                            else -> PdfMediaFailure.SOURCE_CHANGED
                        },
                    )
                }
                is SnapshotResult.Verified ->
                    if (verified.snapshot.sha256 != source.sha256 || verified.snapshot.byteCount != source.byteCount) {
                        options.password?.close()
                        return@withContext PdfOpenResult.Failed(PdfMediaFailure.SOURCE_CHANGED)
                    }
            }
        }
        val geometryResult = PdfPageBoxReader().read(source.file, source.sha256)
        val gateway = options.gateway ?: OfficePdfRenderGateway(context.applicationContext)
        val ownsGateway = options.gateway == null
        val password = options.password
        val info = if (password == null) {
            gateway.documentInfo(source)
        } else {
            try {
                gateway.documentInfoWithPassword(source, password.borrowSecret())
            } catch (_: IllegalStateException) {
                // The caller passed an already-cleared holder: refuse
                // without crashing and keep the source untouched.
                password.close()
                if (ownsGateway) gateway.release()
                return@withContext PdfOpenResult.Failed(PdfMediaFailure.PASSWORD_REJECTED)
            }
        }
        if (info is PdfDocumentInfoResult.Failed) {
            password?.close()
            if (ownsGateway) gateway.release()
            return@withContext PdfOpenResult.Failed(info.failure)
        }
        val pageCount = (info as PdfDocumentInfoResult.Ready).pageCount
        val geometry = when (geometryResult) {
            is PdfGeometryResult.Ok ->
                // A page count disagreement means the metadata reader did not see
                // the same page tree the renderer did: do not use it for export.
                if (geometryResult.geometry.pageCount == pageCount) geometryResult.geometry else null
            is PdfGeometryResult.Refused -> null
        }
        val backend = options.textBackend
            ?: if (options.allowInProcessPlatformText) {
                PdfTextBackends.platformOrUnavailable(true)
            } else {
                // 2026-10-30: the DEFAULT is the source-bound isolated text
                // transaction on the shared Office renderer (never an
                // in-process parse of untrusted PDF bytes).
                PdfTextBackends.officeRendererDefault(gateway, password)
            }
        PdfOpenResult.Opened(
            PdfDocumentSession(
                source = source,
                pageCount = pageCount,
                geometry = geometry,
                gateway = gateway,
                ownsGateway = ownsGateway,
                textBackend = backend,
                password = password,
                renderBudgetBytes = options.renderBudgetBytes,
                thumbnailBudgetBytes = options.thumbnailBudgetBytes,
            ),
        )
    }
}
