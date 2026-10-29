// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import android.content.Context
import android.graphics.Bitmap
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPageText
import com.floe.android.core.officeengine.pdf.OfficePdfPlatformCapabilities
import com.floe.android.core.officeengine.pdf.OfficePdfRenderFence
import com.floe.android.core.officeengine.pdf.OfficePdfRenderHost
import com.floe.android.core.officeengine.pdf.PdfDocResult
import com.floe.android.core.officeengine.pdf.PdfFailure
import com.floe.android.core.officeengine.pdf.PdfPageResult
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * Typed PDF media failure (path-free). Mirrors the shared renderer's honest
 * failure vocabulary and adds media-level identities. Transport/service faults
 * are never presented as document errors.
 */
enum class PdfMediaFailure {
    INVALID_PDF,

    /** Encrypted document and no password was supplied. */
    PASSWORD_PROTECTED,

    /** A password was supplied but the platform refused it (or the security scheme). */
    PASSWORD_REJECTED,

    /** This device has no public password-capable PDF renderer. */
    PASSWORD_UNSUPPORTED,

    /** This device's renderer has no text-content API; request OCR instead. */
    TEXT_UNSUPPORTED,

    BUSY,
    TRANSPORT,
    PAGE_OUT_OF_RANGE,
    CANCELLED,
    SOURCE_CHANGED,
    SESSION_CLOSED,
}

sealed class PdfDocumentInfoResult {
    data class Ready(val pageCount: Int) : PdfDocumentInfoResult()
    data class Failed(val failure: PdfMediaFailure) : PdfDocumentInfoResult()
}

/** One page's bounded text extracted by the isolated renderer. */
sealed class PdfPageTextResult {
    data class Page(val page: OfficePdfPageText) : PdfPageTextResult()
    data class Failed(val failure: PdfMediaFailure) : PdfPageTextResult()
}

sealed class PdfPageRenderResult {
    data class Ready(
        val bitmap: Bitmap,
        val widthPx: Int,
        val heightPx: Int,
        val zoomPercent: Int,
        val page: PdfPageId,
        /** True when the bitmap is owned by the session cache (never recycle it). */
        val fromCache: Boolean = false,
    ) : PdfPageRenderResult()

    data class Failed(val failure: PdfMediaFailure) : PdfPageRenderResult()
}

/**
 * The narrow render seam this module consumes.
 *
 * Production is [OfficePdfRenderGateway], which delegates to the already
 * qualified `:core:officeengine` isolated renderer (one shared renderer, one
 * source-validation path, no second parser). A fake gateway is used by JVM
 * tests for the session's caching/fencing logic.
 *
 * Contract for implementations:
 *  - [documentInfo]/[renderPage] return only for the source digest they were
 *    called with, and never throw (typed failure instead);
 *  - the returned bitmap is owned by the CALLER (the gateway hands off its
 *    only reference and will not recycle it);
 *  - [release] is final; late results are dropped (and recycled if they are a
 *    bitmap).
 */
interface PdfRenderGateway : PdfPageTextTransport {
    suspend fun documentInfo(source: VerifiedMediaSnapshot): PdfDocumentInfoResult

    suspend fun renderPage(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        zoomPercent: Int,
    ): PdfPageRenderResult

    /**
     * Optional password-aware overloads. Defaults preserve the previous
     * no-password behaviour for fakes and existing consumers; production
     * [OfficePdfRenderGateway] forwards the secret only for this call.
     */
    suspend fun documentInfoWithPassword(
        source: VerifiedMediaSnapshot,
        password: CharArray?,
    ): PdfDocumentInfoResult = documentInfo(source)

    suspend fun renderPageWithPassword(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        zoomPercent: Int,
        password: CharArray?,
    ): PdfPageRenderResult = renderPage(source, page, zoomPercent)

    /**
     * Isolated page-text extraction. Implementations that cannot provide it
     * MUST return a typed failure, never empty text.
     */
    override suspend fun pageText(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        password: CharArray?,
    ): PdfPageTextResult = PdfPageTextResult.Failed(PdfMediaFailure.TRANSPORT)

    /** Final release; [onQuiescent] runs once no owned render transaction can still run. */
    fun release(onQuiescent: (() -> Unit)? = null)
}

/** Transport seam used by [IsolatedPdfTextBackend]; production is the render gateway. */
interface PdfPageTextTransport {
    suspend fun pageText(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        password: CharArray?,
    ): PdfPageTextResult
}

/**
 * Production gateway over the shared Office renderer host.
 *
 *  - uses [OfficePdfRenderHost] exactly as shipped (same isolated service,
 *    same read-only NO-FOLLOW per-request descriptor, same bounded zoom table
 *    through [PdfRenderPlanner]);
 *  - bridges the host's main-thread callbacks to coroutines;
 *  - fences late/duplicate results with [OfficePdfRenderFence]: a cancelled
 *    request's bitmap is recycled, never delivered;
 *  - caches the page COUNT per source digest so repeated open() calls do not
 *    re-parse the document (the renderer already counted it once).
 */
class OfficePdfRenderGateway(context: Context) : PdfRenderGateway, PdfPageTextTransport {

    private val host = OfficePdfRenderHost(context.applicationContext)
    private val fence = OfficePdfRenderFence()
    private val released = AtomicBoolean(false)
    private val infoLock = Any()
    private val infoCache = LinkedHashMap<String, Int>()
    private val mutex = Mutex()

    override suspend fun documentInfo(source: VerifiedMediaSnapshot): PdfDocumentInfoResult =
        documentInfoWithPassword(source, null)

    override suspend fun documentInfoWithPassword(
        source: VerifiedMediaSnapshot,
        password: CharArray?,
    ): PdfDocumentInfoResult = mutex.withLock {
        if (released.get()) return PdfDocumentInfoResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        // The cache is proof of a REAL successful open WITHOUT a password.
        // A password attempt must reach the platform: a cached count from an
        // earlier privileged open must never make a wrong password look open.
        if (password == null) {
            synchronized(infoLock) { infoCache[source.sha256] }?.let { return PdfDocumentInfoResult.Ready(it) }
        }
        val token = fence.bump()
        return suspendCancellableCoroutine { cont ->
            if (!cont.isActive) return@suspendCancellableCoroutine
            cont.invokeOnCancellation { fence.bump() }
            // A cache hit is safe even for an encrypted source: the cached
            // page count was proven by a real open of the same digest.
            host.documentInfo(source, password) { result ->
                val mapped = when (result) {
                    is PdfDocResult.Ready -> PdfDocumentInfoResult.Ready(result.pageCount)
                    is PdfDocResult.Failed -> PdfDocumentInfoResult.Failed(
                        mapSecurityFailure(result.failure, password != null),
                    )
                }
                if (mapped is PdfDocumentInfoResult.Ready && password == null) {
                    synchronized(infoLock) {
                        infoCache[source.sha256] = mapped.pageCount
                        while (infoCache.size > INFO_CACHE_MAX) {
                            infoCache.remove(infoCache.keys.first())
                        }
                    }
                }
                deliver(cont, token, mapped)
            }
        }
    }

    override suspend fun renderPage(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        zoomPercent: Int,
    ): PdfPageRenderResult = renderPageWithPassword(source, page, zoomPercent, null)

    override suspend fun renderPageWithPassword(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        zoomPercent: Int,
        password: CharArray?,
    ): PdfPageRenderResult = mutex.withLock {
        if (released.get()) return PdfPageRenderResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        val token = fence.bump()
        val bounded = zoomPercent.coerceIn(
            com.floe.android.core.officeengine.pdf.OfficePdfGeometry.MIN_ZOOM_PERCENT,
            com.floe.android.core.officeengine.pdf.OfficePdfGeometry.MAX_ZOOM_PERCENT,
        )
        return suspendCancellableCoroutine { cont ->
            if (!cont.isActive) return@suspendCancellableCoroutine
            cont.invokeOnCancellation { fence.bump() }
            host.renderPage(source, page.pageIndex, bounded, password) { result ->
                val mapped = when (result) {
                    is PdfPageResult.Rendered -> PdfPageRenderResult.Ready(
                        bitmap = result.bitmap,
                        widthPx = result.widthPx,
                        heightPx = result.heightPx,
                        zoomPercent = bounded,
                        page = page,
                    )
                    is PdfPageResult.Failed -> PdfPageRenderResult.Failed(
                        mapSecurityFailure(result.failure, password != null),
                    )
                }
                if (mapped is PdfPageRenderResult.Ready && (cont.isCancelled || !fence.isCurrent(token) || released.get())) {
                    runCatching { mapped.bitmap.recycle() }
                    return@renderPage
                }
                deliver(cont, token, mapped)
            }
        }
    }

    /**
     * Isolated page-text call bridged to a coroutine. Serialized with pixel
     * renders through the shared renderer host; cancellation fences the
     * callback. The payload is already bounded by the wire contract.
     */
    override suspend fun pageText(
        source: VerifiedMediaSnapshot,
        page: PdfPageId,
        password: CharArray?,
    ): PdfPageTextResult = mutex.withLock {
        if (released.get()) return PdfPageTextResult.Failed(PdfMediaFailure.SESSION_CLOSED)
        val token = fence.bump()
        try {
            // The host already joins the binder transaction with a bounded
            // timeout; this outer bound also covers a released host that can
            // no longer post a callback, so a search coroutine never hangs.
            withTimeout(com.floe.android.core.officeengine.pdf.OfficePdfTextContract.TEXT_TIMEOUT_MS + 5_000L) {
                suspendCancellableCoroutine<PdfPageTextResult> { cont ->
                    if (!cont.isActive) return@suspendCancellableCoroutine
                    cont.invokeOnCancellation { fence.bump() }
                    host.pageText(source, page.pageIndex, password) { result ->
                        val mapped = when (result) {
                            is com.floe.android.core.officeengine.pdf.PdfTextResult.Page ->
                                PdfPageTextResult.Page(result.page)
                            is com.floe.android.core.officeengine.pdf.PdfTextResult.Unsupported ->
                                PdfPageTextResult.Failed(PdfMediaFailure.TEXT_UNSUPPORTED)
                            is com.floe.android.core.officeengine.pdf.PdfTextResult.Failed ->
                                PdfPageTextResult.Failed(mapSecurityFailure(result.failure, password != null))
                        }
                        deliver(cont, token, mapped)
                    }
                }
            }
        } catch (_: TimeoutCancellationException) {
            fence.bump()
            PdfPageTextResult.Failed(PdfMediaFailure.TRANSPORT)
        }
    }

    override fun release(onQuiescent: (() -> Unit)?) {
        if (!released.compareAndSet(false, true)) return
        fence.bump()
        host.release(onQuiescent)
    }

    @OptIn(kotlinx.coroutines.InternalCoroutinesApi::class)
    private fun <T> deliver(cont: CancellableContinuation<T>, token: Long, value: T) {
        val resumable = cont.isActive && fence.isCurrent(token) && !released.get()
        if (resumable) {
            // tryResume/completeResume closes the cancel-vs-resume race: a
            // cancelled continuation returns null and we recycle instead of
            // leaking a bitmap the caller can never receive.
            val ticket = cont.tryResume(value)
            if (ticket != null) {
                cont.completeResume(ticket)
                return
            }
        }
        if (value is PdfPageRenderResult.Ready) runCatching { value.bitmap.recycle() }
    }

    private fun mapFailure(failure: PdfFailure): PdfMediaFailure = when (failure) {
        PdfFailure.InvalidPdf -> PdfMediaFailure.INVALID_PDF
        PdfFailure.PasswordProtected -> PdfMediaFailure.PASSWORD_PROTECTED
        PdfFailure.Busy -> PdfMediaFailure.BUSY
        PdfFailure.Transport -> PdfMediaFailure.TRANSPORT
    }

    /**
     * The host reports all password/security refusals as one identity; here we
     * know whether a secret was supplied and whether THIS device has a public
     * password channel, so the precise Notes identity is honest.
     */
    private fun mapSecurityFailure(failure: PdfFailure, passwordSupplied: Boolean): PdfMediaFailure =
        if (failure != PdfFailure.PasswordProtected) {
            mapFailure(failure)
        } else when {
            !passwordSupplied -> PdfMediaFailure.PASSWORD_PROTECTED
            !OfficePdfPlatformCapabilities.passwordSupported() -> PdfMediaFailure.PASSWORD_UNSUPPORTED
            else -> PdfMediaFailure.PASSWORD_REJECTED
        }

    companion object {
        private const val INFO_CACHE_MAX = 4

        /** Visible for diagnostics/tests: number of distinct sources this gateway has counted. */
        fun describeCacheSize(gateway: OfficePdfRenderGateway): Int =
            synchronized(gateway.infoLock) { gateway.infoCache.size }
    }
}
