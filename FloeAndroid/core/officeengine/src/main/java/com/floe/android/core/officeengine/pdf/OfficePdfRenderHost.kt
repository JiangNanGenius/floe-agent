// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * The REAL release/delivery lifetime coordinator of one [OfficePdfRenderHost]
 * (lane 17 repair of the accepted lane-14 host). The delivered host fenced a
 * result only BEFORE `main.post`: a [OfficePdfRenderHost.release] landing
 * between the post and its main-thread delivery could still call a dead UI
 * and drop a bitmap nobody would ever recycle. This coordinator owns the two
 * decisions the production host actually consults — exactly like
 * [OfficePdfPrintQuiescence] does for the print worker, and unit-testable
 * with a real executor because it uses no Android types:
 *  1. [mayDeliver] — the fence a POSTED result re-checks on the main thread
 *     at DELIVERY time (false ⇒ recycle the late bitmap, never invoke the
 *     retired callback);
 *  2. [scheduleQuiescentRelease] — the optional lease-join: the first
 *     releasing caller submits [quiescent] as a finalizer to the SAME single
 *     worker that owns every renderer transaction, so it runs only AFTER the
 *     running/queued jobs have returned from their own `finally` (each closes
 *     its per-request descriptor there). FIFO + single worker guarantees the
 *     order; the caller thread never blocks joining the worker; a rejected
 *     finalizer (executor already gone) runs inline so a caller lease is
 *     NEVER stranded; the callback runs EXACTLY ONCE per host even if the
 *     drain is scheduled more than once.
 * It grants nothing and parses nothing: the host keeps owning its binder,
 * jobs and recycling — only the lifetime decisions move here, so no caller
 * has to mirror (and can silently diverge from) the fence rules.
 */
internal class OfficePdfRenderHostLifetime(
    private val submitDrainTask: (Runnable) -> Unit,
) {
    private val releasedFlag = AtomicBoolean(false)
    private val drainGate = OfficePdfOnceCallback("render-drain")

    fun isReleased(): Boolean = releasedFlag.get()

    /** True only for the FIRST release attempt (the fence that flips it). */
    fun beginRelease(): Boolean = releasedFlag.compareAndSet(false, true)

    /**
     * Main-thread delivery decision a posted result must make when it
     * actually runs — after [beginRelease] this is false forever, so a result
     * that raced between post and delivery never reaches a retired owner.
     */
    fun mayDeliver(): Boolean = !releasedFlag.get()

    /**
     * Serializes [quiescent] behind every already-submitted host job on the
     * owned worker (see class docs). At most one effective execution per
     * host; rejection settles inline; later calls are ignored.
     */
    fun scheduleQuiescentRelease(quiescent: () -> Unit) {
        val finalizer = Runnable {
            drainGate.fire(OfficePdfOnceCallback.Terminal.FINISHED) {
                runCatching { quiescent() }
            }
        }
        try {
            submitDrainTask(finalizer)
        } catch (_: RejectedExecutionException) {
            finalizer.run()
        }
    }
}

/**
 * Per-owner client facade for the isolated PDF renderer. One host instance
 * belongs to exactly one screen (the preview Activity, or the print-prep
 * session in the editor Activity); every PdfRenderer touch runs on this
 * host's single worker thread (constructor + page work off main, serialized
 * one-at-a-time), and results hop back to the main thread.
 *
 * Fencing rules (Main contract 2026-10-27; delivery fence corrected by
 * lane 17 on 2026-10-27):
 *  - [release] is final: after it NO callback fires — the fence is re-checked
 *    at main-thread DELIVERY time, not only before the post —, a late or
 *    undeliverable bitmap is recycled instead of dropped, and the binding is
 *    gone; an optional [release] `onQuiescent` lease-join fires exactly once
 *    only after the owned worker has drained every running/queued
 *    transaction (each closed its own descriptor in its `finally`), never
 *    blocking the releasing thread;
 *  - the caller passes an [OfficePdfVerifiedSource] (the Office viewer hands
 *    its receipt-proved [VerifiedPdfSnapshot]; a sealed output owner hands
 *    its own verified source); the host shape-guards it, opens its OWN
 *    pinned read-only NO-FOLLOW FD per request through the REAL public SDK
 *    path ([OfficePdfSourceAccess]: plain-regular + exact-size proven under
 *    the descriptor — `MODE_RDONLY` referenced before does not exist on the
 *    platform), closes it after the transaction returns —
 *    it never shares the source and never takes a writable FD;
 *  - a newer request supersedes a still-queued previous job (page flips
 *    must not accumulate backlogs); an already-running job finishes and its
 *    result is honestly dropped;
 *  - bind failures/timeouts are honest [PdfFailure.Transport] — a dead or
 *    slow service process is NEVER presented as a document error.
 */
sealed class PdfFailure {
    /** Renderer says the bytes are not a parseable PDF. */
    object InvalidPdf : PdfFailure()

    /**
     * The renderer refused for a password/security reason. The host does not
     * guess whether the password was wrong or the device lacks a password
     * channel; the caller (Notes media) owns that distinction because it knows
     * whether it supplied a secret and what this device supports.
     */
    object PasswordProtected : PdfFailure()

    /** Renderer busy (bounded backlog) — the caller may retry once the current work drains. */
    object Busy : PdfFailure()

    /** Binder/transport/binding fault — not a statement about the document. */
    object Transport : PdfFailure()
}

sealed class PdfDocResult {
    data class Ready(val pageCount: Int) : PdfDocResult()
    data class Failed(val failure: PdfFailure) : PdfDocResult()
}

sealed class PdfPageResult {
    data class Rendered(val bitmap: Bitmap, val widthPx: Int, val heightPx: Int) : PdfPageResult()
    data class Failed(val failure: PdfFailure) : PdfPageResult()
}

sealed class PdfTextResult {
    /** Bounded, source/page-tagged text extracted in the isolated renderer. */
    data class Page(val page: OfficePdfPageText) : PdfTextResult()

    /** This device's platform renderer has no text-content API; use OCR. */
    object Unsupported : PdfTextResult()

    data class Failed(val failure: PdfFailure) : PdfTextResult()
}

class OfficePdfRenderHost(context: Context) {

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-pdf-host").apply { isDaemon = true }
    }
    /** The production lifetime coordinator (docs above): every fence and
     * the optional quiescent lease-join run through this REAL object — the
     * focused lifecycle regression drives the same class. */
    private val lifetime = OfficePdfRenderHostLifetime(worker::execute)
    private val requestIds = AtomicLong(0L)
    private val lock = Object()

    private var binder: IBinder? = null
    private var boundOnce = false
    private var currentJob: Future<*>? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            synchronized(lock) {
                binder = service
                lock.notifyAll()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            synchronized(lock) { binder = null }
        }
    }

    // ------------------------------------------------------------------
    // Public API (main-thread callbacks; safe to call from any thread)
    // ------------------------------------------------------------------

    /** Real page count from the renderer itself (never guessed from file size). */
    fun documentInfo(source: OfficePdfVerifiedSource, onResult: (PdfDocResult) -> Unit) {
        documentInfo(source, null, onResult)
    }

    /**
     * documentInfo with an OPTIONAL RAM-only password (same host/worker/
     * delivery fence). The caller owns the char array and must keep it valid
     * until the callback returns; the host never retains or logs it.
     */
    fun documentInfo(
        source: OfficePdfVerifiedSource,
        password: CharArray?,
        onResult: (PdfDocResult) -> Unit,
    ) {
        if (lifetime.isReleased()) return
        val job = runCatching { worker.submit {
            val result: PdfDocResult = try {
                val b = ensureBinderBlocking()
                withFd(source) { fd ->
                    when (val reply = OfficePdfRendererChannel.documentInfo(b, nextId(), fd, password)) {
                        is PdfRenderReply.Info -> PdfDocResult.Ready(reply.pageCount)
                        is PdfRenderReply.Refusal -> PdfDocResult.Failed(mapFailure(reply.status))
                        else -> PdfDocResult.Failed(PdfFailure.Transport)
                    }
                } ?: PdfDocResult.Failed(PdfFailure.Transport)
            } catch (t: Throwable) {
                PdfDocResult.Failed(PdfFailure.Transport)
            }
            // The posted delivery re-checks the fence at delivery time
            // (lane 17 fix): a release landing between this post and the
            // main-thread run retires the callback here, never a dead UI.
            main.post { if (lifetime.mayDeliver()) onResult(result) }
        } }.getOrNull()
        if (job != null) currentJob = job
    }

    /**
     * Renders one page at the bounded zoom percent. A still-queued previous
     * host job is superseded; the CURRENT page's older render (same call
     * site) must be fenced by the caller against its own request identity —
     * the host guarantees at most one running job and serialised delivery.
     */
    fun renderPage(
        source: OfficePdfVerifiedSource,
        pageIndex: Int,
        zoomPercent: Int,
        onResult: (PdfPageResult) -> Unit,
    ) {
        renderPage(source, pageIndex, zoomPercent, null, onResult)
    }

    /**
     * Renders one page of a password-protected document. Same worker,
     * descriptor, bounding and delivery fences as [renderPage].
     */
    fun renderPage(
        source: OfficePdfVerifiedSource,
        pageIndex: Int,
        zoomPercent: Int,
        password: CharArray?,
        onResult: (PdfPageResult) -> Unit,
    ) {
        if (lifetime.isReleased()) return
        val job = runCatching { worker.submit {
            val result: PdfPageResult = try {
                val b = ensureBinderBlocking()
                withFd(source) { fd ->
                    when (val reply = OfficePdfRendererChannel.renderPage(b, nextId(), fd, pageIndex, zoomPercent, password)) {
                        is PdfRenderReply.Page -> PdfPageResult.Rendered(reply.bitmap, reply.widthPx, reply.heightPx)
                        is PdfRenderReply.Refusal -> PdfPageResult.Failed(mapFailure(reply.status))
                        else -> PdfPageResult.Failed(PdfFailure.Transport)
                    }
                } ?: PdfPageResult.Failed(PdfFailure.Transport)
            } catch (t: Throwable) {
                PdfPageResult.Failed(PdfFailure.Transport)
            }
            if (lifetime.isReleased()) {
                // Late bitmap must not be dropped un-freed.
                if (result is PdfPageResult.Rendered && !result.bitmap.isRecycled) {
                    runCatching { result.bitmap.recycle() }
                }
                return@submit
            }
            // Lane 17 delivery fence: the released flag is re-checked when
            // the posted runnable RUNS. A release between this post and main
            // delivery therefore recycles the undeliverable bitmap instead of
            // calling a retired callback (the delivered shape leaked a dead
            // UI call plus an unrecycled bitmap exactly in that window).
            main.post {
                if (lifetime.mayDeliver()) {
                    onResult(result)
                } else if (result is PdfPageResult.Rendered && !result.bitmap.isRecycled) {
                    runCatching { result.bitmap.recycle() }
                }
            }
        } }.getOrNull()
        // Supersede a job that has NOT started yet; never interrupt a running
        // transaction (its descriptors clean up in the service's own pass).
        val previous = currentJob
        if (previous != null && !previous.isDone && !previous.isCancelled) {
            previous.cancel(false)
        }
        if (job != null) currentJob = job
    }

    /**
     * Extracts one page's bounded text + point-space regions from the SAME
     * isolated parser. The source shape and the payload identity (page index
     * + exact snapshot byte length) are re-validated here; a malformed reply
     * is a transport failure, never an empty text claim.
     */
    fun pageText(
        source: OfficePdfVerifiedSource,
        pageIndex: Int,
        password: CharArray?,
        onResult: (PdfTextResult) -> Unit,
    ) {
        if (lifetime.isReleased()) {
            // Always answer: a suspended caller must not wait forever for a
            // host that has already been released.
            onResult(PdfTextResult.Failed(PdfFailure.Transport))
            return
        }
        if (!OfficePdfRendererContract.validPageIndex(pageIndex)) {
            onResult(PdfTextResult.Failed(PdfFailure.Transport))
            return
        }
        val job = runCatching { worker.submit {
            val result: PdfTextResult = try {
                val b = ensureBinderBlocking()
                withFd(source) { fd ->
                    when (val reply = OfficePdfRendererChannel.pageText(
                        b,
                        nextId(),
                        fd,
                        pageIndex,
                        OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE,
                        password,
                    )) {
                        is PdfRenderReply.Text -> {
                            val page = reply.page
                            if (OfficePdfTextContract.accept(page, pageIndex, source.expectedBytes)) {
                                PdfTextResult.Page(page)
                            } else {
                                PdfTextResult.Failed(PdfFailure.Transport)
                            }
                        }
                        is PdfRenderReply.Refusal -> when (reply.status) {
                            OfficePdfRendererContract.S_TEXT_UNSUPPORTED -> PdfTextResult.Unsupported
                            else -> PdfTextResult.Failed(mapFailure(reply.status))
                        }
                        else -> PdfTextResult.Failed(PdfFailure.Transport)
                    }
                } ?: PdfTextResult.Failed(PdfFailure.Transport)
            } catch (_: Throwable) {
                PdfTextResult.Failed(PdfFailure.Transport)
            }
            if (lifetime.isReleased()) return@submit
            main.post { if (lifetime.mayDeliver()) onResult(result) }
        } }.getOrNull()
        if (job != null) currentJob = job
    }

    /** Final. Drops every pending/future result; recycles late bitmaps; unbinds. */
    fun release() = release(onQuiescent = null)

    /**
     * Final release plus an OPTIONAL quiescent lease-join (lane 17, added
     * for the durable run-output consumer; every existing zero-arg module
     * caller keeps the exact previous behaviour). [onQuiescent] — when given
     * — runs EXACTLY ONCE, on the owned worker, only after the running and
     * still-queued renderer transactions have each returned from their own
     * `finally` (closing their per-request descriptors there), so the caller
     * may only then unlink the immutable snapshot the host pinned nothing
     * but descriptors for. The releasing thread never blocks joining the
     * worker; a rejected drain finalizer settles inline (the lease is never
     * stranded). A still-queued-but-cancelled job opened nothing, so the
     * drain ordering stays descriptor-honest either way.
     */
    fun release(onQuiescent: (() -> Unit)?) {
        if (!lifetime.beginRelease()) return
        val wasBound = synchronized(lock) {
            val b = boundOnce
            boundOnce = false
            binder = null
            b
        }
        if (wasBound) runCatching { appContext.unbindService(connection) }
        currentJob?.cancel(false)
        currentJob = null
        if (onQuiescent != null) {
            // Submitted BEFORE shutdown so the single-worker FIFO runs it
            // after every job already queued by earlier submit() calls.
            lifetime.scheduleQuiescentRelease(onQuiescent)
        }
        worker.shutdown()
    }

    fun isReleased(): Boolean = lifetime.isReleased()

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private fun nextId(): Long = requestIds.incrementAndGet()

    private fun <R> withFd(source: OfficePdfVerifiedSource, block: (ParcelFileDescriptor) -> R): R? {
        if (lifetime.isReleased()) return null
        if (!OfficePdfVerifiedSourceContract.shapeOk(source)) return null
        // Real public SDK open (lane 14): read-only + O_CLOEXEC + O_NOFOLLOW,
        // plain-regular + exact size proven UNDER the descriptor. A refused
        // or failed open keeps the existing null → honest failure identity.
        val fd = OfficePdfSourceAccess.openPinnedReadOnly(source.readableFile, source.expectedBytes)
            ?: return null
        try {
            return block(fd)
        } finally {
            runCatching { fd.close() }
        }
    }

    private fun ensureBinderBlocking(): IBinder? {
        if (lifetime.isReleased()) return null
        synchronized(lock) {
            if (binder != null) return binder
            if (!boundOnce) {
                val intent = Intent(appContext, OfficePdfRendererService::class.java)
                boundOnce = runCatching {
                    appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                }.getOrDefault(false)
                if (!boundOnce) return null
            }
            var waited = 0L
            // The released fence breaks the wait promptly: release() unbinds
            // and flips the flag before shutting the worker down, so a
            // blocked transaction returns and the quiescent drain can run.
            while (binder == null && !lifetime.isReleased() && waited < BIND_WAIT_MS) {
                val t0 = System.currentTimeMillis()
                runCatching { lock.wait(BIND_WAIT_MS - waited) }
                waited += System.currentTimeMillis() - t0
            }
            return binder
        }
    }

    private fun mapFailure(status: Int): PdfFailure = when (status) {
        OfficePdfRendererContract.S_INVALID_PDF -> PdfFailure.InvalidPdf
        // Wrong password and "no password channel" are deliberately reported
        // as one host-level security refusal; Notes media knows whether it
        // supplied a secret and what this device supports, and returns the
        // precise typed identity (REJECTED vs UNSUPPORTED).
        OfficePdfRendererContract.S_PASSWORD -> PdfFailure.PasswordProtected
        OfficePdfRendererContract.S_PASSWORD_REJECTED -> PdfFailure.PasswordProtected
        OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED -> PdfFailure.PasswordProtected
        OfficePdfRendererContract.S_BUSY -> PdfFailure.Busy
        else -> PdfFailure.Transport
    }

    private companion object {
        const val BIND_WAIT_MS = 10_000L
    }
}
