// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.SharedMemory
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The narrow isolated PDF renderer (platform docs for `PdfRenderer`:
 * "If the file comes from an untrusted source, it is recommended to run the
 * renderer in a separate, isolated process with minimum permissions to limit
 * the impact of security vulnerabilities"). Declared in the module manifest
 * with `android:isolatedProcess="true"` + `android:exported="false"` in its
 * OWN process `:floe_pdf` — deliberately NOT the engine's `:floe_office`
 * process, which is same-UID crash separation and not a sandbox.
 *
 * Authority boundary (all fail-closed):
 *  - input is ONLY a kernel-duped read-only FD + page index + bounded zoom OR
 *    bounded page-text request + an optional RAM-only password char array
 *    (no paths, URIs, package/storage/network authority; an isolated process
 *    holds none by definition). The interface token is enforced on every
 *    transaction, and every transaction's `Binder.getCallingUid()` must
 *    EQUAL the owning app's UID read from this service's own trusted
 *    `ApplicationInfo.uid` — not a raw UID-range heuristic, not this
 *    isolated process's `Process.myUid()`, and never anything the parcel
 *    carries ([OfficePdfRendererBinder.callerIsOwner]). Foreign apps under
 *    any user, other isolated processes and invalid/sentinel UIDs are all
 *    refused fail-closed; the service is non-exported so only this app's
 *    own processes can ever hold the binder;
 *  - one serialized worker owns every renderer: constructor/getPageCount/
 *    openPage/render/text run OFF the main thread, exactly ONE page open at
 *    a time, and page + renderer + received FD are closed per job. No
 *    document state persists between jobs; an unbound isolated process is
 *    killed by the framework, which is the final backstop for any descriptor;
 *  - pixel results travel through ONE SharedMemory per successful render.
 *    The binder driver dups a reply fd only while the reply is written back
 *    (after onTransact returns), so the service must NOT close its handle
 *    early: a transferred handle stays registered until the host releases
 *    it via [OfficePdfRendererContract.T_RELEASE_SHM] — which by
 *    construction happens only after the host's transact returned — or until
 *    unbind/death. The registry is bounded to [MAX_ACK_PENDING]; a hostile
 *    host can pin at most that many buffers, the oldest is force-retired
 *    (its mapping then honestly fails host-side validation — never an
 *    unsafe render);
 *  - text replies are truncated/bounded BEFORE they are written
 *    ([OfficePdfTextContract]) so one page can never exceed the binder
 *    budget; the host re-validates every count;
 *  - passwords are never stored: a received char array is used once to build
 *    the platform `LoadParams` String inside this disposable isolated
 *    process and zero-filled immediately; a wrong password is a typed
 *    [OfficePdfRendererContract.S_PASSWORD_REJECTED], never a document error;
 *  - at most [OfficePdfRendererContract.MAX_INFLIGHT] queued/running jobs
 *    before replying S_BUSY; each job's own finally frees its slot, and a
 *    bounded join timeout answers S_INTERNAL while the worker still runs
 *    the job to its own cleanup (never cancelled mid-descriptor).
 */
class OfficePdfRendererService : Service() {

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "floe-pdf-renderer").apply { isDaemon = true }
    }
    private val inflight = AtomicInteger(0)
    private val shmIds = AtomicLong(0L)
    private val pendingAcks = ConcurrentHashMap<Long, SharedMemory>()
    private val ackOrder = ConcurrentLinkedQueue<Long>()

    override fun onBind(intent: Intent?): IBinder = Endpoint()

    override fun onUnbind(intent: Intent?): Boolean {
        releaseAllPending()
        return false
    }

    override fun onDestroy() {
        releaseAllPending()
        super.onDestroy()
    }

    private fun releaseAllPending() {
        // Drop OUR handles; kernel dups already delivered to hosts are their
        // own references. Queued jobs (if any) still close their received
        // FDs in their own finally, and process death closes everything.
        pendingAcks.keys.toList().forEach { id ->
            pendingAcks.remove(id)?.let { runCatching { it.close() } }
            ackOrder.remove(id)
        }
    }

    private fun releaseSharedMemory(id: Long) {
        if (id <= 0L) return
        pendingAcks.remove(id)?.let { runCatching { it.close() } }
        ackOrder.remove(id)
    }

    private fun registerSharedMemory(shared: SharedMemory): Long {
        val id = shmIds.incrementAndGet()
        // Bound the unacknowledged set.
        while (pendingAcks.size >= MAX_ACK_PENDING) {
            val oldest = ackOrder.poll() ?: break
            pendingAcks.remove(oldest)?.let { runCatching { it.close() } }
        }
        pendingAcks[id] = shared
        ackOrder.add(id)
        return id
    }

    private inner class Endpoint : Binder() {

        /**
         * Owner proof anchor: the app package UID for the user THIS service
         * instance runs under, read once from the Service's own trusted
         * context ([android.app.Service.applicationInfo] — never
         * `Process.myUid()`, which is the isolated runtime UID, and never a
         * parcel-carried claim). If the platform ever made the owner
         * unreadable we keep the -1 sentinel, which
         * [OfficePdfRendererBinder.callerIsOwner] treats as invalid: every
         * transaction then fails closed, never open.
         */
        private val ownerAppUid: Int = runCatching { applicationInfo.uid }.getOrDefault(INVALID_OWNER_UID)

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in setOf(
                    OfficePdfRendererContract.T_DOCUMENT_INFO,
                    OfficePdfRendererContract.T_RENDER_PAGE,
                    OfficePdfRendererContract.T_PAGE_TEXT,
                    OfficePdfRendererContract.T_RELEASE_SHM,
                )
            ) {
                return super.onTransact(code, data, reply, flags)
            }
            if (!OfficePdfRendererBinder.callerIsOwner(Binder.getCallingUid(), ownerAppUid) || reply == null) {
                return true
            }
            val parsed = try {
                OfficePdfRendererBinder.parse(data, code)
            } catch (_: Exception) {
                null
            } ?: return true
            when (parsed) {
                is OfficePdfRendererBinder.ParsedRequest.Release -> {
                    releaseSharedMemory(parsed.shmId)
                    OfficePdfRendererBinder.writeReleaseReply(reply, parsed.requestId)
                    return true
                }

                is OfficePdfRendererBinder.ParsedRequest.Info -> {
                    if (!tryAcquireSlot()) {
                        zeroPassword(parsed.password)
                        OfficePdfRendererBinder.writeInfoReply(
                            reply, parsed.requestId, OfficePdfRendererContract.S_BUSY, 0,
                        )
                        return true
                    }
                    val future: Future<JobOutcome> = worker.submit(Callable {
                        try {
                            runJob(parsed)
                        } finally {
                            inflight.decrementAndGet()
                        }
                    })
                    val outcome = join(future, OfficePdfRendererContract.INFO_TIMEOUT_MS)
                    OfficePdfRendererBinder.writeInfoReply(
                        reply, parsed.requestId, outcome.status, outcome.pageCount,
                    )
                    // An INFO job never transfers a buffer.
                    outcome.shared?.let { runCatching { it.close() } }
                    return true
                }

                is OfficePdfRendererBinder.ParsedRequest.Render -> {
                    if (!tryAcquireSlot()) {
                        zeroPassword(parsed.password)
                        OfficePdfRendererBinder.writePageReply(
                            reply, parsed.requestId, OfficePdfRendererContract.S_BUSY,
                            0, 0, 0L, 0L, null,
                        )
                        return true
                    }
                    val future: Future<JobOutcome> = worker.submit(Callable {
                        try {
                            runJob(parsed)
                        } finally {
                            inflight.decrementAndGet()
                        }
                    })
                    val outcome = join(future, OfficePdfRendererContract.RENDER_TIMEOUT_MS)
                    if (outcome.status == OfficePdfRendererContract.S_OK && outcome.shared != null) {
                        val shmId = registerSharedMemory(outcome.shared)
                        OfficePdfRendererBinder.writePageReply(
                            reply, parsed.requestId, OfficePdfRendererContract.S_OK,
                            outcome.width, outcome.height, outcome.bytes, shmId, outcome.shared,
                        )
                    } else {
                        OfficePdfRendererBinder.writePageReply(
                            reply, parsed.requestId, outcome.status,
                            0, 0, 0L, 0L, null,
                        )
                        // A non-delivered buffer belongs to THIS process only:
                        // close it now (the job's finally skips it precisely
                        // because it is S_OK).
                        outcome.shared?.let { runCatching { it.close() } }
                    }
                    return true
                }

                is OfficePdfRendererBinder.ParsedRequest.Text -> {
                    if (!tryAcquireSlot()) {
                        zeroPassword(parsed.password)
                        OfficePdfRendererBinder.writeTextReply(
                            reply, parsed.requestId, OfficePdfRendererContract.S_BUSY, null,
                        )
                        return true
                    }
                    val future: Future<JobOutcome> = worker.submit(Callable {
                        try {
                            runJob(parsed)
                        } finally {
                            inflight.decrementAndGet()
                        }
                    })
                    val outcome = join(future, OfficePdfTextContract.TEXT_TIMEOUT_MS)
                    OfficePdfRendererBinder.writeTextReply(
                        reply, parsed.requestId, outcome.status, outcome.text,
                    )
                    return true
                }
            }
        }
    }

    private fun zeroPassword(password: CharArray?) {
        password?.fill('\u0000')
    }

    /**
     * Pixel jobs keep the previously qualified legacy `PdfRenderer` path on
     * API 31–34 when no password is involved (the Mainline `PdfRendererPreV`
     * class is selected only when it is actually needed: a password or text).
     * API 35+ stays on the full framework path.
     */
    private fun engineKindForPixels(password: CharArray?): OfficePdfEngineKind {
        val kind = OfficePdfPlatformCapabilities.engineKind()
        return if (kind == OfficePdfEngineKind.PRE_V && password == null) {
            OfficePdfEngineKind.LEGACY
        } else {
            kind
        }
    }

    private fun tryAcquireSlot(): Boolean {
        if (inflight.incrementAndGet() > OfficePdfRendererContract.MAX_INFLIGHT) {
            inflight.decrementAndGet()
            return false
        }
        return true
    }

    /**
     * Bounded wait for the worker's value. NEVER cancels: the job must run
     * to its own descriptor cleanup. On timeout a synthetic S_INTERNAL
     * outcome is returned; the job's real result is dropped when it finally
     * completes (its slot frees in the job's own finally).
     */
    private fun join(future: Future<JobOutcome>, timeoutMs: Long): JobOutcome {
        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
            JobOutcome(OfficePdfRendererContract.S_INTERNAL)
        }
    }

    /**
     * Worker-thread result. `shared` is NON-NULL ONLY on S_OK, and in that
     * case ownership transfers to the endpoint (registered for host ack or
     * explicitly closed by the endpoint on a failed write). Every failure
     * path closes its own buffer inside the job. `text` is NON-NULL only on
     * a successful text job.
     */
    private class JobOutcome(
        val status: Int,
        val pageCount: Int = 0,
        val width: Int = 0,
        val height: Int = 0,
        val bytes: Long = 0L,
        val shared: SharedMemory? = null,
        val text: OfficePdfPageText? = null,
    )

    private fun runJob(request: OfficePdfRendererBinder.ParsedRequest): JobOutcome =
        when (request) {
            is OfficePdfRendererBinder.ParsedRequest.Info -> runInfo(request)
            is OfficePdfRendererBinder.ParsedRequest.Render -> runRender(request)
            is OfficePdfRendererBinder.ParsedRequest.Text -> runText(request)
            is OfficePdfRendererBinder.ParsedRequest.Release ->
                JobOutcome(OfficePdfRendererContract.S_BAD_REQUEST)
        }

    /**
     * Opens the real platform engine. The password array is the ONLY secret
     * input; it is zeroed here on every path after the platform constructor
     * copied it (the adapter zeroes it even earlier when it builds
     * LoadParams). No path/log/persistence ever sees it.
     */
    private fun openEngine(
        fd: ParcelFileDescriptor,
        password: CharArray?,
        kind: OfficePdfEngineKind,
    ): OfficePdfEngineOpenResult {
        val result = try {
            OfficePdfEngines.open(kind, fd, password)
        } catch (_: Exception) {
            runCatching { fd.close() }
            OfficePdfEngineOpenResult.Invalid
        } finally {
            zeroPassword(password)
        }
        return result
    }

    private fun runInfo(request: OfficePdfRendererBinder.ParsedRequest.Info): JobOutcome {
        val kind = engineKindForPixels(request.password)
        return when (val opened = openEngine(request.fd, request.password, kind)) {
            is OfficePdfEngineOpenResult.PasswordRequired ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD)
            is OfficePdfEngineOpenResult.PasswordRejected ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_REJECTED)
            is OfficePdfEngineOpenResult.PasswordUnsupported ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED)
            is OfficePdfEngineOpenResult.Invalid ->
                JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
            is OfficePdfEngineOpenResult.Ok -> {
                try {
                    val count = runCatching { opened.engine.pageCount }.getOrDefault(-1)
                    if (count < 1 || count > OfficePdfRendererContract.MAX_PAGE_INDEX) {
                        JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
                    } else {
                        JobOutcome(OfficePdfRendererContract.S_OK, pageCount = count)
                    }
                } catch (_: Exception) {
                    JobOutcome(OfficePdfRendererContract.S_INTERNAL)
                } finally {
                    runCatching { opened.engine.close() }
                }
            }
        }
    }

    private fun runRender(request: OfficePdfRendererBinder.ParsedRequest.Render): JobOutcome {
        val kind = engineKindForPixels(request.password)
        return when (val opened = openEngine(request.fd, request.password, kind)) {
            is OfficePdfEngineOpenResult.PasswordRequired ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD)
            is OfficePdfEngineOpenResult.PasswordRejected ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_REJECTED)
            is OfficePdfEngineOpenResult.PasswordUnsupported ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED)
            is OfficePdfEngineOpenResult.Invalid ->
                JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
            is OfficePdfEngineOpenResult.Ok -> renderWith(request, opened.engine)
        }
    }

    private fun renderWith(
        request: OfficePdfRendererBinder.ParsedRequest.Render,
        engine: OfficePdfEngine,
    ): JobOutcome {
        var page: OfficePdfEnginePage? = null
        var bitmap: Bitmap? = null
        var shared: SharedMemory? = null
        var mapped: java.nio.ByteBuffer? = null
        var engineClosed = false
        var outcome = JobOutcome(OfficePdfRendererContract.S_INTERNAL)
        try {
            val pageCount = runCatching { engine.pageCount }.getOrDefault(-1)
            if (pageCount <= 0 || request.pageIndex >= pageCount) {
                outcome = JobOutcome(OfficePdfRendererContract.S_BAD_REQUEST)
                return outcome
            }
            page = engine.openPage(request.pageIndex)
            val target = OfficePdfGeometry.renderSize(page.widthPt, page.heightPt, request.zoomPercent)
            if (target == null) {
                outcome = JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
                return outcome
            }
            val created = Bitmap.createBitmap(target.first, target.second, Bitmap.Config.ARGB_8888)
            bitmap = created
            page.render(created, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val byteCount = created.byteCount.toLong()
            if (!OfficePdfGeometry.validateReply(target.first, target.second, byteCount)) {
                outcome = JobOutcome(OfficePdfRendererContract.S_INTERNAL)
                return outcome
            }
            val shm = try {
                SharedMemory.create("floe-pdf-page", byteCount.toInt())
            } catch (_: Exception) {
                null
            }
            if (shm == null) {
                outcome = JobOutcome(OfficePdfRendererContract.S_INTERNAL)
                return outcome
            }
            shared = shm
            val buffer = try {
                shm.mapReadWrite()
            } catch (_: Exception) {
                null
            }
            if (buffer == null) {
                outcome = JobOutcome(OfficePdfRendererContract.S_INTERNAL)
                return outcome
            }
            mapped = buffer
            bitmap.copyPixelsToBuffer(buffer)
            SharedMemory.unmap(buffer)
            mapped = null
            // ONE page open at a time: close the page BEFORE the engine.
            page.close()
            page = null
            engine.close()
            engineClosed = true
            outcome = JobOutcome(
                OfficePdfRendererContract.S_OK,
                width = target.first,
                height = target.second,
                bytes = byteCount,
                shared = shm,
            )
            return outcome
        } catch (_: Exception) {
            outcome = JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
            return outcome
        } finally {
            runCatching { mapped?.let { SharedMemory.unmap(it) } }
            runCatching { page?.close() }
            if (!engineClosed) runCatching { engine.close() }
            bitmap?.takeUnless { it.isRecycled }?.recycle()
            // The buffer leaves this process ONLY on S_OK (the endpoint
            // registers it for the host ack). Every other exit closes it HERE
            // so a failed job never pins shared memory.
            if (outcome.status != OfficePdfRendererContract.S_OK) {
                runCatching { shared?.close() }
            }
        }
    }

    /**
     * One bounded page-text extraction. Text is extracted in the SAME
     * isolated process/engine as rendering; on devices without a text-capable
     * platform renderer the answer is the typed S_TEXT_UNSUPPORTED so the
     * caller requests OCR instead of receiving a false empty result.
     */
    private fun runText(request: OfficePdfRendererBinder.ParsedRequest.Text): JobOutcome {
        val kind = OfficePdfPlatformCapabilities.engineKind()
        if (!OfficePdfPlatformCapabilities.textExtractionSupported(kind = kind)) {
            zeroPassword(request.password)
            runCatching { request.fd.close() }
            return JobOutcome(OfficePdfRendererContract.S_TEXT_UNSUPPORTED)
        }
        val sourceBytes = runCatching { request.fd.statSize }.getOrDefault(-1L)
        if (sourceBytes < 1L) {
            zeroPassword(request.password)
            runCatching { request.fd.close() }
            return JobOutcome(OfficePdfRendererContract.S_BAD_REQUEST)
        }
        val opened = openEngine(request.fd, request.password, kind)
        return when (opened) {
            is OfficePdfEngineOpenResult.PasswordRequired ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD)
            is OfficePdfEngineOpenResult.PasswordRejected ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_REJECTED)
            is OfficePdfEngineOpenResult.PasswordUnsupported ->
                JobOutcome(OfficePdfRendererContract.S_PASSWORD_UNSUPPORTED)
            is OfficePdfEngineOpenResult.Invalid ->
                JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
            is OfficePdfEngineOpenResult.Ok -> {
                var page: OfficePdfEnginePage? = null
                var engineClosed = false
                try {
                    val pageCount = opened.engine.pageCount
                    if (pageCount < 1 || request.pageIndex >= pageCount) {
                        return JobOutcome(OfficePdfRendererContract.S_BAD_REQUEST)
                    }
                    page = opened.engine.openPage(request.pageIndex)
                    val (widthPt, heightPt) = page.widthPt to page.heightPt
                    val payload = OfficePdfTextContract.build(
                        pageIndex = request.pageIndex,
                        pageCount = pageCount,
                        sourceBytes = sourceBytes,
                        pageWidthPt = widthPt.toFloat(),
                        pageHeightPt = heightPt.toFloat(),
                        lines = page.textLines(),
                        maxChars = request.maxChars,
                    ) ?: return JobOutcome(OfficePdfRendererContract.S_INVALID_PDF)
                    page.close()
                    page = null
                    opened.engine.close()
                    engineClosed = true
                    JobOutcome(OfficePdfRendererContract.S_OK, text = payload)
                } catch (_: Exception) {
                    JobOutcome(OfficePdfRendererContract.S_INTERNAL)
                } finally {
                    runCatching { page?.close() }
                    if (!engineClosed) runCatching { opened.engine.close() }
                }
            }
        }
    }

    private companion object {
        /** Unreadable owner anchor: never plausible, so EVERY caller fails closed. */
        const val INVALID_OWNER_UID = -1

        /**
         * Bound on transferred SharedMemory handles a host may pin without
         * acknowledging (T_RELEASE_SHM); the oldest is force-retired.
         */
        const val MAX_ACK_PENDING = 8
    }
}
