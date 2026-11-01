// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

import com.floe.android.core.workbenchmedia.AuthorityDecision
import com.floe.android.core.workbenchmedia.MAX_RECOVERED_EXPORT_LIST
import com.floe.android.core.workbenchmedia.MediaLifecycleKind
import com.floe.android.core.workbenchmedia.MediaLifecyclePin
import com.floe.android.core.workbenchmedia.MediaLifecyclePinRequest
import com.floe.android.core.workbenchmedia.RecoveryOwnerGrant
import com.floe.android.core.workbenchmedia.RecoveryRootDecision
import com.floe.android.core.workbenchmedia.WorkbenchEpochOwner
import com.floe.android.core.workbenchmedia.WorkbenchLeaseAuthority
import com.floe.android.core.workbenchmedia.WorkbenchMediaPlatformConfig
import com.floe.android.core.workbenchmedia.capability.MediaCapabilityProbe
import com.floe.android.core.workbenchmedia.lifecycle.LifecyclePinTracker
import com.floe.android.core.workbenchmedia.snapshot.SnapshotExpectation
import com.floe.android.core.workbenchmedia.snapshot.SnapshotVerifier
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.MediaRefusal
import com.floe.android.core.workbenchmedia.util.RENDERER_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.SessionDrainFence
import com.floe.android.core.workbenchmedia.util.SystemMediaClock
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.video.RenderControl
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportBinding
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.WorkbenchR2Errors
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

internal class ExportJob(
    val jobID: String,
    val context: CreativeProjectContext,
    val binding: MediaExportBinding,
    val request: MediaExportRequest,
    val root: File,
    val owner: RecoveryOwner,
    val epoch: Long,
    val pin: MediaLifecyclePin,
    val queuedAt: String,
    val sequence: Long,
) {
    val kind: MediaExportKind =
        if (request is MediaExportRequest.Video) MediaExportKind.VIDEO else MediaExportKind.IMAGE
    val attemptID: String get() = binding.attemptID
    val control = RenderControl()
    val cancelRequested = AtomicBoolean(false)
    val timeoutRequested = AtomicBoolean(false)
    val started = AtomicBoolean(false)
    @Volatile var terminal: Boolean = false
    @Volatile var interrupted: Boolean = false
    @Volatile var status: MediaExportStatus = MediaExportStatus(
        jobID = jobID,
        kind = kind,
        state = MediaExportState.QUEUED,
        updatedAt = queuedAt,
    )
    val listeners = CopyOnWriteArrayList<(MediaExportStatus) -> Unit>()

    private val drainedFlag = AtomicBoolean(false)
    val drained: Boolean get() = drainedFlag.get()

    /** True only once; the owner must release exactly one admission slot. */
    fun markDrained(): Boolean = drainedFlag.compareAndSet(false, true)
}

/**
 * Process-scoped export registry. It holds operation state and immutable
 * request/lease facts only; the native project/job stores remain the truth.
 * The mediaProcessing service owns actual worker lifetime; this registry is
 * what lets status/cancel/observer calls survive editor-close and what the
 * service consults to stop itself when the last job is terminal.
 *
 * Acceptance is bounded by [ExportAdmission] (live jobs, not just the two
 * encoder permits). Terminal entries are pruned only after their worker/queued
 * path actually drained, and the durable recovery journal is never pruned.
 */
internal class ExportRuntime(
    private val config: WorkbenchMediaPlatformConfig,
    private val authority: WorkbenchLeaseAuthority,
    private val epochOwner: WorkbenchEpochOwner,
    private val capabilities: MediaCapabilityProbe,
    private val pins: LifecyclePinTracker,
    private val fence: SessionDrainFence,
    private val clock: MediaClock = SystemMediaClock(),
) {
    private val jobs = ConcurrentHashMap<String, ExportJob>()
    private val concurrency = Semaphore(2)
    private val store = ExportRecoveryStore(clock)
    private val engine = MediaExportEngine(config, authority, capabilities, clock)
    private val admission = ExportAdmission()
    private val sequence = AtomicLong(0L)
    private val scope = CoroutineScope(SupervisorJob() + config.ioDispatcher)
    @Volatile private var serviceListener: ((MediaExportStatus) -> Unit)? = null

    fun setServiceListener(listener: ((MediaExportStatus) -> Unit)?) {
        serviceListener = listener
    }

    suspend fun submit(request: MediaExportRequest): MediaExportJobHandle {
        val binding = request.binding
        validateContext(binding.context)
        if (fence.isFenced()) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The media session is draining; wait for a new accepted epoch and session",
                retryable = true,
            )
        }
        if (!CreativeSessionTokens.isValid(binding.context.sessionToken)) {
            throw refusal("invalidSession", "A valid editor session token is required")
        }
        if (!MediaPaths.safeComponent(binding.attemptID)) {
            throw refusal("invalidPayload", "The export attempt id is not a safe component")
        }
        if (binding.timelineDigest.isBlank() || binding.timelineDigest.length > 128) {
            throw refusal("invalidPayload", "A native timeline digest is required")
        }
        if (binding.projectRevision < 0L) {
            throw refusal("invalidPayload", "A non-negative project revision is required")
        }
        if (binding.mediaRootPath != binding.snapshot.mediaRootPath ||
            binding.snapshot.leaseID.isBlank()
        ) {
            throw refusal("invalidPayload", "The binding and immutable snapshot lease do not match")
        }
        val decision = authority.validateRenderBinding(binding)
        val grant = when (decision) {
            is AuthorityDecision.Accepted -> decision.grant
            is AuthorityDecision.Refused -> throw refusal(decision.code, decision.reason, decision.retryable)
        }
        val root = MediaPaths.canonicalRoot(binding.mediaRootPath)
            ?: throw refusal(STORAGE_UNAVAILABLE, "The accepted media root is not available")
        val recoveryGrant = resolveRecoveryGrant(binding.context)
        if (recoveryGrant.epoch != grant.epoch) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The native epoch changed while accepting the export",
                retryable = true,
            )
        }
        if (recoveryGrant.mediaRootPath != root.path) {
            throw refusal(
                STORAGE_UNAVAILABLE,
                "The accepted project recovery root is not the immutable export root",
            )
        }
        val owner = RecoveryOwner(
            projectID = binding.context.projectID,
            storageKey = recoveryGrant.storageKey,
            originKey = recoveryGrant.originKey,
            ownerKey = recoveryGrant.ownerKey,
        )
        val jobID = "export-" + UUID.randomUUID().toString()
        if (!admission.reserve()) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The media export queue is full (${admission.liveLimit} accepted); " +
                    "wait for an export to finish or cancel one",
                retryable = true,
            )
        }
        var admitted = false
        var wroteRecord = false
        var pin: MediaLifecyclePin? = null
        try {
            val acquired = pins.acquire(
                MediaLifecyclePinRequest(
                    context = binding.context,
                    kind = MediaLifecycleKind.EXPORT,
                    epoch = grant.epoch,
                    mediaRootPath = root.path,
                    attemptID = binding.attemptID,
                    jobID = jobID,
                ),
            )
            pin = acquired
            if (fence.isFenced()) {
                throw refusal(
                    RENDERER_UNAVAILABLE,
                    "The media session began draining while the export was being accepted",
                    retryable = true,
                )
            }
            val verified = SnapshotVerifier.verify(
                SnapshotExpectation(
                    epoch = grant.epoch,
                    projectID = binding.context.projectID,
                    revision = binding.projectRevision,
                    timelineDigest = binding.timelineDigest,
                    mediaRootPath = binding.mediaRootPath,
                    attemptID = binding.attemptID,
                    lease = binding.snapshot,
                ),
                grant,
                clock,
            )
            // Validate settings/formats before accepting the job. Video asset
            // probing/encoder planning happens again at render time; a refusal
            // there still occurs before any output is opened.
            if (request is MediaExportRequest.Image) {
                com.floe.android.core.workbenchmedia.image.ImageExporter.validate(verified, request.settings)
            }
            val record = store.initial(
                jobID = jobID,
                owner = owner,
                attemptID = binding.attemptID,
                kind = if (request is MediaExportRequest.Video) MediaExportKind.VIDEO else MediaExportKind.IMAGE,
                revision = binding.projectRevision,
                timelineDigest = binding.timelineDigest,
                mediaRootPath = root.path,
                writtenEpoch = grant.epoch,
            )
            store.write(root, record)
            wroteRecord = true
            val job = ExportJob(
                jobID = jobID,
                context = binding.context,
                binding = binding,
                request = request,
                root = root,
                owner = owner,
                epoch = grant.epoch,
                pin = acquired,
                queuedAt = clock.nowIso(),
                sequence = sequence.incrementAndGet(),
            )
            synchronized(jobs) {
                // A drain fences before it takes this lock and cancels a
                // snapshot of the table. Re-check under the same lock so a
                // submission cannot slip in after that snapshot and be missed.
                if (fence.isFenced()) {
                    throw refusal(
                        RENDERER_UNAVAILABLE,
                        "The media session began draining while the export was being accepted",
                        retryable = true,
                    )
                }
                pruneTerminalLocked()
                jobs[jobID] = job
                // Commit the live slot while holding the same table lock used
                // by drain. Otherwise drain could observe zero live jobs in
                // the window between insertion and commit, report success,
                // and let a worker start against a retired Root.
                admission.commitReservation()
                admitted = true
            }
            return MediaExportJobHandle(jobID, job.kind, MediaExportState.QUEUED, job.queuedAt)
        } catch (failure: Throwable) {
            if (!admitted) {
                if (wroteRecord) {
                    runCatching { store.delete(root, jobID) }
                }
                pin?.let { acquired ->
                    try {
                        withContext(NonCancellable) { pins.release(acquired) }
                    } catch (_: Throwable) {
                        // The tracker retains an unconfirmed pin; the failed
                        // submission must not mask the original refusal.
                    }
                }
            }
            throw failure
        } finally {
            if (!admitted) admission.cancelReservation()
        }
    }

    fun execute(jobID: String, scope: CoroutineScope) {
        val job = jobs[jobID] ?: return
        if (!job.started.compareAndSet(false, true)) return
        val worker = scope.launch {
            try {
                try {
                    concurrency.withPermit {
                        engine.execute(job, this@ExportRuntime)
                    }
                } catch (failure: kotlinx.coroutines.CancellationException) {
                    if (!job.terminal) {
                        if (job.interrupted) {
                            finish(
                                job,
                                MediaExportState.INTERRUPTED,
                                errorCode = "serviceDestroyed",
                            )
                        } else {
                            finish(
                                job,
                                MediaExportState.CANCELLED,
                                errorCode = WorkbenchR2Errors.RENDER_CANCELLED,
                            )
                        }
                    }
                    throw failure
                } catch (failure: Throwable) {
                    if (!job.terminal) {
                        finish(
                            job,
                            if (job.interrupted) MediaExportState.INTERRUPTED else MediaExportState.FAILED,
                            errorCode = (failure as? MediaRefusal)?.code
                                ?: if (job.interrupted) "serviceDestroyed"
                                else WorkbenchR2Errors.RENDERER_UNAVAILABLE,
                            retryable = (failure as? MediaRefusal)?.retryable == true,
                        )
                    }
                }
            } finally {
                // The engine, codec and file writers have returned before this
                // finally. Release the native pin only here, never on a UI
                // terminal status (onTimeout may publish TIMEOUT earlier).
                withContext(NonCancellable) { pins.release(job.pin) }
            }
        }
        worker.invokeOnCompletion {
            if (!job.terminal) {
                finish(
                    job,
                    if (job.interrupted) MediaExportState.INTERRUPTED else MediaExportState.CANCELLED,
                    errorCode = if (job.interrupted) "serviceDestroyed" else WorkbenchR2Errors.RENDER_CANCELLED,
                )
            }
            markDrained(job)
            // If the worker coroutine was cancelled before its body entered
            // the try/finally, the pin must still be released after the
            // worker is actually gone. The tracker makes this race idempotent.
            this@ExportRuntime.scope.launch {
                withContext(NonCancellable) { pins.release(job.pin) }
            }
            pruneTerminal()
        }
    }

    fun publish(job: ExportJob, status: MediaExportStatus, persist: Boolean = true) {
        synchronized(job) {
            if (job.terminal) return
            if (status.state == MediaExportState.COMPLETED ||
                status.state == MediaExportState.CANCELLED ||
                status.state == MediaExportState.FAILED ||
                status.state == MediaExportState.TIMEOUT ||
                status.state == MediaExportState.INTERRUPTED
            ) {
                job.terminal = true
            }
            job.status = status
        }
        if (persist) {
            runCatching {
                store.write(
                    job.root,
                    RecoveryRecord(
                        jobID = job.jobID,
                        projectID = job.context.projectID,
                        attemptID = job.attemptID,
                        kind = job.kind,
                        state = status.state,
                        updatedAt = status.updatedAt,
                        ownerFingerprint = job.owner.fingerprint,
                        revision = job.binding.projectRevision,
                        timelineDigest = job.binding.timelineDigest,
                        ownerVersion = RECOVERY_OWNER_VERSION,
                        ownerKey = job.owner.ownerKey,
                        storageKey = job.owner.storageKey,
                        originKey = job.owner.originKey,
                        mediaRootPath = job.root.path,
                        writtenEpoch = job.epoch,
                        progress = status.progress,
                        outputRelativePath = status.receipt?.outputRelativePath,
                        mimeType = status.receipt?.mimeType,
                        byteCount = status.receipt?.byteCount,
                        sha256 = status.receipt?.sha256,
                        verification = status.receipt?.verification,
                        errorCode = status.errorCode,
                        retryable = status.retryable,
                    ),
                )
            }
        }
        if (job.terminal && !job.started.get()) {
            // No worker will ever run for this queued job. It is the queued
            // path that owns the pin, so release it only now and keep the
            // release asynchronous so status delivery is not blocked.
            markDrained(job)
            pins.releaseAsync(job.pin)
        }
        job.listeners.forEach { listener -> runCatching { listener(status) } }
        runCatching { serviceListener?.invoke(status) }
        if (job.terminal) {
            // A terminal status is delivered once; retaining editor listeners
            // after it would keep UI/controller references alive with no
            // further event to deliver.
            job.listeners.clear()
        }
    }

    fun finish(
        job: ExportJob,
        state: MediaExportState,
        receipt: MediaExportReceipt? = null,
        errorCode: String? = null,
        retryable: Boolean = false,
        progress: Double? = null,
    ) {
        publish(
            job,
            MediaExportStatus(
                jobID = job.jobID,
                kind = job.kind,
                state = state,
                updatedAt = clock.nowIso(),
                progress = progress,
                receipt = receipt,
                errorCode = errorCode,
                retryable = retryable,
            ),
        )
    }

    suspend fun status(context: CreativeProjectContext, jobID: String): MediaExportStatus {
        validateContext(context)
        if (!MediaPaths.safeComponent(jobID, max = 200)) {
            throw refusal("jobNotFound", "The export job is not present")
        }
        val job = jobs[jobID]
        if (job != null) {
            requireAcceptedJob(job, context)
            return job.status
        }
        val grant = resolveRecoveryGrant(context)
        return store.statusFromRecovery(File(grant.mediaRootPath), expectation(grant), jobID)
            ?: throw refusal("jobNotFound", "The export job is not present")
    }

    /**
     * Bounded active+recovered export list. The native recovery grant is
     * resolved once for the current editor session; only jobs/records in that
     * exact project/storage/origin owner and epoch/root scope are considered.
     * Active statuses win exact de-dupe, and each recovered COMPLETED record
     * goes through the same streaming size+SHA proof as exportStatus.
     */
    suspend fun listRecoveredExports(
        context: CreativeProjectContext,
        limit: Int,
    ): List<MediaExportStatus> {
        validateContext(context)
        if (limit !in 1..MAX_RECOVERED_EXPORT_LIST) {
            throw refusal(
                "invalidPayload",
                "Recovered export limit must be 1..$MAX_RECOVERED_EXPORT_LIST",
            )
        }
        val grant = resolveRecoveryGrant(context)
        val grantOwner = RecoveryOwner(
            projectID = grant.projectID,
            storageKey = grant.storageKey,
            originKey = grant.originKey,
            ownerKey = grant.ownerKey,
        )
        val activeJobs = synchronized(jobs) { jobs.values.toList() }
            .filter { jobMatchesGrant(it, grant, context) }
            .sortedWith(compareByDescending<ExportJob> { it.status.updatedAt }.thenBy { it.jobID })
        val activeIds = activeJobs.map { it.jobID }.toSet()
        val activeStatuses = activeJobs.take(limit).map { it.status }
        if (activeStatuses.size >= limit) {
            return RecoveredExportList.merge(activeStatuses, emptyList(), limit)
        }

        val remaining = limit - activeStatuses.size
        val root = File(grant.mediaRootPath)
        val expectation = RecoveryExpectation(grantOwner, root.path)
        val recovered = ArrayList<MediaExportStatus>(remaining)
        val candidates = store
            .recoveryCandidates(root, ExportRecoveryStore.MAX_RECOVERY_SCAN, expectation)
            .filter { it.jobID !in activeIds }
            .sortedWith(compareByDescending<RecoveryCandidate> { it.updatedAt }.thenBy { it.jobID })
        for (candidate in candidates) {
            if (recovered.size >= remaining) break
            if (candidate.jobID in activeIds) continue
            val status = store.statusFromRecovery(root, expectation, candidate.jobID) ?: continue
            recovered += status
        }
        return RecoveredExportList.merge(activeStatuses, recovered, limit)
    }

    suspend fun cancel(context: CreativeProjectContext, jobID: String): MediaExportJobHandle {
        validateContext(context)
        if (!MediaPaths.safeComponent(jobID, max = 200)) {
            throw refusal("jobNotFound", "The export job is not present")
        }
        val job = jobs[jobID]
            ?: throw refusal("jobNotFound", "The export job is not present")
        requireAcceptedJob(job, context)
        if (job.terminal) {
            return MediaExportJobHandle(job.jobID, job.kind, job.status.state, job.queuedAt)
        }
        job.cancelRequested.set(true)
        job.control.requestCancel()
        if (job.status.state == MediaExportState.QUEUED && !job.started.get()) {
            finish(job, MediaExportState.CANCELLED, errorCode = WorkbenchR2Errors.RENDER_CANCELLED)
        }
        return MediaExportJobHandle(job.jobID, job.kind, job.status.state, job.queuedAt)
    }

    /**
     * Observes an active or durable job. Context/owner/root reauthorization is
     * a suspend native lookup, while the frozen platform callback is declared
     * non-suspend; resolution therefore runs on the runtime scope and invokes
     * the listener once it is safe. A refused/foreign lookup emits no event.
     */
    fun observe(
        context: CreativeProjectContext,
        jobID: String,
        listener: (MediaExportStatus) -> Unit,
    ): AutoCloseable {
        validateContext(context)
        if (!MediaPaths.safeComponent(jobID, max = 200)) {
            throw refusal("jobNotFound", "The export job is not present")
        }
        val open = AtomicBoolean(true)
        val registration = AtomicReference<AutoCloseable?>(null)
        val resolution = scope.launch {
            try {
                val registered = observeResolved(context, jobID) { status ->
                    if (open.get()) runCatching { listener(status) }
                }
                registration.set(registered)
                if (!open.get()) registered.close()
            } catch (_: MediaRefusal) {
                // Foreign owner, stale epoch/root or missing job: no event.
            } catch (_: Exception) {
                // A bounded observer must not crash the caller's process.
            }
        }
        return AutoCloseable {
            if (open.compareAndSet(true, false)) {
                resolution.cancel()
                registration.getAndSet(null)?.close()
            }
        }
    }

    fun activeCount(): Int = admission.liveCount()

    fun queuedOrRunning(): List<ExportJob> = jobs.values.filter { !it.drained }

    fun requestCancelAll() {
        val snapshot = synchronized(jobs) { jobs.values.toList() }
        for (job in snapshot) {
            if (job.terminal) continue
            job.cancelRequested.set(true)
            job.control.requestCancel()
            if (job.status.state == MediaExportState.QUEUED && !job.started.get()) {
                finish(job, MediaExportState.CANCELLED, errorCode = WorkbenchR2Errors.RENDER_CANCELLED)
            }
        }
    }

    fun timeoutAll() {
        val snapshot = synchronized(jobs) { jobs.values.toList() }
        for (job in snapshot) {
            if (job.terminal) continue
            job.timeoutRequested.set(true)
            job.cancelRequested.set(true)
            job.control.requestCancel()
            // Never delete a staging file here: the writer may still be
            // finishing. The engine removes its own .part after the actual
            // writer stops, so a timeout cannot race a new partial file into
            // existence behind a pre-emptive delete.
        }
    }

    fun markServiceDestroyed() {
        val snapshot = synchronized(jobs) { jobs.values.toList() }
        for (job in snapshot) {
            if (job.terminal) continue
            job.interrupted = true
            job.cancelRequested.set(true)
            job.control.requestCancel()
            if (job.status.state == MediaExportState.QUEUED && !job.started.get()) {
                finish(
                    job,
                    MediaExportState.INTERRUPTED,
                    errorCode = "serviceDestroyed",
                )
            }
        }
    }

    suspend fun drain(timeoutMillis: Long): Pair<Boolean, Int> {
        requestCancelAll()
        val deadline = System.currentTimeMillis() + timeoutMillis.coerceIn(0L, 60_000L)
        while (System.currentTimeMillis() < deadline) {
            val active = activeCount()
            if (active == 0) return true to 0
            delay(50L)
        }
        val active = activeCount()
        return (active == 0) to active
    }

    fun job(jobID: String): ExportJob? = jobs[jobID]

    fun requestCancel(jobID: String) {
        val job = jobs[jobID] ?: return
        if (job.terminal) return
        job.cancelRequested.set(true)
        job.control.requestCancel()
        if (job.status.state == MediaExportState.QUEUED && !job.started.get()) {
            finish(job, MediaExportState.CANCELLED, errorCode = WorkbenchR2Errors.RENDER_CANCELLED)
        }
    }

    fun failStart(jobID: String, code: String, reason: String) {
        val job = jobs[jobID] ?: return
        if (job.terminal) return
        job.cancelRequested.set(true)
        job.control.requestCancel()
        finish(job, MediaExportState.FAILED, errorCode = code, retryable = true)
    }

    /** Stops the runtime helper scope only after the session has actually drained. */
    fun shutdown() {
        scope.cancel()
        serviceListener = null
        for (job in jobs.values) {
            job.listeners.clear()
        }
        jobs.clear()
    }

    private suspend fun observeResolved(
        context: CreativeProjectContext,
        jobID: String,
        listener: (MediaExportStatus) -> Unit,
    ): AutoCloseable {
        val job = jobs[jobID]
        if (job != null) {
            requireAcceptedJob(job, context)
            runCatching { listener(job.status) }
            if (job.terminal) return AutoCloseable { }
            job.listeners += listener
            // Re-check after registration so a terminal publish racing this
            // subscription cannot be missed; the callback is idempotent enough
            // for a duplicate terminal status but must never be lost.
            if (job.terminal) {
                job.listeners.remove(listener)
                runCatching { listener(job.status) }
                return AutoCloseable { }
            }
            return AutoCloseable { job.listeners.remove(listener) }
        }
        val grant = resolveRecoveryGrant(context)
        val recovered = store.statusFromRecovery(File(grant.mediaRootPath), expectation(grant), jobID)
            ?: return AutoCloseable { }
        runCatching { listener(recovered) }
        return AutoCloseable { }
    }

    private suspend fun requireAcceptedJob(
        job: ExportJob,
        context: CreativeProjectContext,
    ): RecoveryOwnerGrant {
        // The editor session token is re-proved by the native callback below,
        // not compared as an in-memory credential. A new authorized editor
        // session for the same project/storage/origin may read/cancel the
        // durable export; a different project/storage/origin may not.
        if (job.context.projectID != context.projectID ||
            job.context.storage != context.storage ||
            job.context.origin != context.origin
        ) {
            throw refusal("jobNotFound", "The export job is not present in this project scope")
        }
        val grant = resolveRecoveryGrant(context)
        if (grant.epoch != job.epoch ||
            grant.mediaRootPath != job.root.path ||
            grant.storageKey != job.owner.storageKey ||
            grant.originKey != job.owner.originKey ||
            grant.ownerKey != job.owner.ownerKey
        ) {
            throw refusal("jobNotFound", "The export job does not belong to the accepted epoch/root owner")
        }
        return grant
    }

    private suspend fun resolveRecoveryGrant(context: CreativeProjectContext): RecoveryOwnerGrant {
        val decision = try {
            config.recoveryAuthority.resolveRecoveryRoot(context)
        } catch (failure: MediaRefusal) {
            throw failure
        } catch (failure: Exception) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The native recovery root could not be resolved: ${failure.message}",
                retryable = true,
            )
        }
        val grant = when (decision) {
            is RecoveryRootDecision.Accepted -> decision.grant
            is RecoveryRootDecision.Refused -> throw refusal(
                decision.code.ifBlank { RENDERER_UNAVAILABLE },
                decision.reason,
                decision.retryable,
            )
        }
        if (grant.projectID != context.projectID) {
            throw refusal("jobNotFound", "The recovery grant belongs to another project")
        }
        if (grant.ownerKey.isBlank() || grant.ownerKey.length > 512) {
            throw refusal(STORAGE_UNAVAILABLE, "The native recovery owner key is not a bounded value")
        }
        if (grant.storageKey.isBlank() || grant.storageKey.length > 512) {
            throw refusal(STORAGE_UNAVAILABLE, "The native recovery storage scope is not a bounded value")
        }
        if (grant.originKey != null && grant.originKey.length > 512) {
            throw refusal(STORAGE_UNAVAILABLE, "The native recovery origin scope is not a bounded value")
        }
        val root = MediaPaths.canonicalRoot(grant.mediaRootPath)
            ?: throw refusal(STORAGE_UNAVAILABLE, "The native project recovery root is not available")
        if (!epochOwner.isEpochLive(grant.epoch) || epochOwner.currentEpoch() != grant.epoch) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The native recovery epoch is not the accepted live epoch",
                retryable = true,
            )
        }
        return grant.copy(mediaRootPath = root.path)
    }

    private fun expectation(grant: RecoveryOwnerGrant): RecoveryExpectation = RecoveryExpectation(
        owner = RecoveryOwner(
            projectID = grant.projectID,
            storageKey = grant.storageKey,
            originKey = grant.originKey,
            ownerKey = grant.ownerKey,
        ),
        mediaRootPath = grant.mediaRootPath,
    )

    private fun jobMatchesGrant(
        job: ExportJob,
        grant: RecoveryOwnerGrant,
        context: CreativeProjectContext,
    ): Boolean =
        job.context.projectID == context.projectID &&
            job.context.storage == context.storage &&
            job.context.origin == context.origin &&
            job.epoch == grant.epoch &&
            job.root.path == grant.mediaRootPath &&
            job.owner.storageKey == grant.storageKey &&
            job.owner.originKey == grant.originKey &&
            job.owner.ownerKey == grant.ownerKey

    private fun markDrained(job: ExportJob) {
        if (job.markDrained()) admission.releaseLive()
    }

    private fun pruneTerminal() {
        synchronized(jobs) { pruneTerminalLocked() }
    }

    private fun pruneTerminalLocked() {
        val terminal = jobs.values
            .filter { it.terminal && it.drained }
            .sortedBy { it.sequence }
        val excess = admission.terminalExcess(terminal.size)
        if (excess <= 0) return
        for (index in 0 until excess) {
            val removed = jobs.remove(terminal[index].jobID)
            if (removed != null) removed.listeners.clear()
        }
    }

    private fun validateContext(context: CreativeProjectContext) {
        if (context.projectID.isBlank()) throw refusal("invalidPayload", "A project id is required")
        if (!CreativeSessionTokens.isValid(context.sessionToken)) {
            throw refusal("invalidSession", "A valid editor session token is required")
        }
    }
}
