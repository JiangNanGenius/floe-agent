// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportJobHandle
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportRequest
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Exact project owner identity for an exported journal record. A saved export
 * outlives the editor session/token that started it, so jobs are matched by
 * project + real storage + origin (never by a stale session token).
 *
 * `null` and an explicit standalone origin are the same owner; every other
 * origin keeps its owner/environment identity. This is provenance only, never
 * storage authority.
 */
data class WorkbenchExportOwner(
    val projectID: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
) {
    val key: String
        get() = listOf(projectID, storageKey(storage), originKey(origin))
            .joinToString("|")

    fun matches(context: CreativeProjectContext): Boolean =
        projectID == context.projectID &&
            storageKey(storage) == storageKey(context.storage) &&
            originKey(origin) == originKey(context.origin)

    companion object {
        fun from(context: CreativeProjectContext): WorkbenchExportOwner =
            WorkbenchExportOwner(
                projectID = context.projectID,
                storage = context.storage,
                origin = context.origin,
            )

        private fun storageKey(storage: CreativeStorageLayer): String = when (storage) {
            CreativeStorageLayer.AppOwned -> "app"
            is CreativeStorageLayer.Workspace -> "workspace:${storage.workspaceID}"
        }

        private fun originKey(origin: CreativeOriginContext?): String {
            if (origin == null) return "standalone"
            if (origin.kind == CreativeOriginContext.STANDALONE &&
                origin.ownerID == null &&
                origin.environmentID == null
            ) {
                return "standalone"
            }
            return listOf(
                origin.kind,
                origin.ownerID.orEmpty(),
                origin.environmentID.orEmpty(),
            ).joinToString("|")
        }
    }
}

/** One retained export attempt as presented to the workbench UI. */
data class WorkbenchExportJob(
    val jobID: String,
    val projectID: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
    val kind: MediaExportKind,
    val attemptID: String,
    /**
     * The captured immutable request/binding for a job started by THIS
     * process. Null for a journal-recovered record: there is no live lease to
     * release and no retry settings to reuse.
     */
    internal val request: MediaExportRequest?,
    val recovered: Boolean,
    val createdAt: String,
    val status: MediaExportStatus,
    val delivery: WorkbenchExportDeliveryResult? = null,
) {
    val terminal: Boolean get() = status.state.terminal

    /** Only a completed job with a host-issued receipt is a verified output. */
    val verifiedReceipt: MediaExportReceipt?
        get() = status.receipt?.takeIf { status.state == MediaExportState.COMPLETED }

    /** A recovered journal record has no captured snapshot/request to retry. */
    val canRetry: Boolean
        get() = request != null && terminal && status.state != MediaExportState.COMPLETED

    val owner: WorkbenchExportOwner
        get() = WorkbenchExportOwner(projectID, storage, origin)
}

val MediaExportState.terminal: Boolean
    get() = this == MediaExportState.COMPLETED ||
        this == MediaExportState.CANCELLED ||
        this == MediaExportState.FAILED ||
        this == MediaExportState.INTERRUPTED ||
        this == MediaExportState.TIMEOUT

/**
 * Session-scoped export tracking.
 *
 * The platform service owns the actual export worker, so closing the editor
 * does not cancel it. This coordinator keeps the captured owner identity and
 * the immutable binding, updates the real queued/running/verifying/terminal
 * state and calls the required release callback only after the host reports a
 * true terminal state.
 *
 * A new editor reauthorizes with a NEW session token. [reattach] replaces the
 * stored context for matching project/storage/origin records and re-observes
 * them; it never retargets another owner. A process restart is recovered
 * through the injected [WorkbenchRecoveredExportLister]: those records are
 * explicitly marked recovered and carry no live lease or retry request, while
 * a verified receipt can still be saved/shared.
 */
@Stable
class MediaExportCoordinator(
    private val platform: WorkbenchMediaPlatform,
    private val recoveredExports: WorkbenchRecoveredExportLister,
    private val releaseBinding: WorkbenchRenderBindingReleaser,
    private val scope: CoroutineScope,
    private val clock: () -> String = { Instant.now().toString() },
) {
    val jobs = mutableStateListOf<WorkbenchExportJob>()
    var recoveryFailure: MediaFailure? by mutableStateOf(null)
        private set

    private val contexts = HashMap<String, CreativeProjectContext>()
    private val observers = HashMap<String, AutoCloseable>()
    private val released = HashSet<String>()

    fun jobsFor(context: CreativeProjectContext): List<WorkbenchExportJob> =
        jobs.filter { it.owner.matches(context) }.sortedByDescending { it.createdAt }

    fun job(jobID: String): WorkbenchExportJob? = jobs.firstOrNull { it.jobID == jobID }

    /**
     * Reauthorizes this session's view of exports for the current editor.
     *
     * Matching records keep their job identity but use the CURRENT context
     * (new session token, same project/storage/origin). Non-matching owners
     * are left untouched. Then the bounded host journal is merged, without
     * inventing IDs or opening a second store; a job already known in this
     * process is never replaced by a recovered projection.
     */
    suspend fun reattach(context: CreativeProjectContext) {
        recoveryFailure = null
        val matching = jobs.filter { it.owner.matches(context) }
        for (record in matching) {
            contexts[record.jobID] = context
            updateJob(record.jobID) {
                it.copy(storage = context.storage, origin = context.origin)
            }
            runCatching { observe(context, record.jobID) }
            runCatching { platform.exportStatus(context, record.jobID) }
                .getOrNull()
                ?.let { applyStatusNow(it) }
        }

        val recovered: List<MediaExportStatus> = try {
            recoveredExports.listRecoveredExports(context, RECOVERY_LIMIT)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            recoveryFailure = MediaFailures.from(error)
            emptyList()
        }
        for (status in recovered) {
            val receiptOwner = status.receipt?.binding?.projectID
            if (receiptOwner != null && receiptOwner != context.projectID) {
                // A receipt names its project; never attach another owner's
                // verified output to this editor.
                continue
            }
            if (jobs.any { it.jobID == status.jobID }) {
                // This process already owns the exact record; do not replace
                // it with a journal projection.
                continue
            }
            contexts[status.jobID] = context
            val record = WorkbenchExportJob(
                jobID = status.jobID,
                projectID = context.projectID,
                storage = context.storage,
                origin = context.origin,
                kind = status.kind,
                attemptID = status.receipt?.binding?.attemptID.orEmpty(),
                request = null,
                recovered = true,
                createdAt = status.updatedAt,
                status = status,
            )
            jobs.add(0, record)
            if (!status.state.terminal) {
                runCatching { observe(context, status.jobID) }
            }
        }
    }

    /**
     * Submits an export. [request] already carries the immutable binding; the
     * caller prepared it through the required host callback.
     */
    suspend fun submit(
        context: CreativeProjectContext,
        attemptID: String,
        request: MediaExportRequest,
    ): WorkbenchExportJob {
        val handle: MediaExportJobHandle = platform.submitExport(request)
        val record = WorkbenchExportJob(
            jobID = handle.jobID,
            projectID = context.projectID,
            storage = context.storage,
            origin = context.origin,
            kind = handle.kind,
            attemptID = attemptID,
            request = request,
            recovered = false,
            createdAt = clock(),
            status = MediaExportStatus(
                jobID = handle.jobID,
                kind = handle.kind,
                state = handle.state,
                updatedAt = handle.acceptedAt,
            ),
        )
        contexts[handle.jobID] = context
        jobs.removeAll { it.jobID == handle.jobID }
        jobs.add(0, record)
        runCatching { observe(context, handle.jobID) }
        runCatching { platform.exportStatus(context, handle.jobID) }
            .getOrNull()
            ?.let { applyStatus(it) }
        return record
    }

    fun refresh(jobID: String) {
        val context = contexts[jobID] ?: return
        scope.launch {
            runCatching { platform.exportStatus(context, jobID) }
                .getOrNull()
                ?.let { applyStatus(it) }
        }
    }

    fun cancel(jobID: String) {
        val context = contexts[jobID] ?: return
        scope.launch {
            runCatching {
                val handle = platform.cancelExport(context, jobID)
                updateJob(jobID) { record ->
                    record.copy(
                        status = record.status.copy(
                            state = handle.state,
                            updatedAt = clock(),
                        ),
                    )
                }
            }
        }
    }

    fun markDelivered(jobID: String, result: WorkbenchExportDeliveryResult) {
        updateJob(jobID) { it.copy(delivery = result) }
    }

    private fun observe(context: CreativeProjectContext, jobID: String) {
        observers.remove(jobID)?.let { runCatching { it.close() } }
        val observer = platform.observeExport(context, jobID) { status ->
            applyStatus(status)
        }
        observers[jobID] = observer
    }

    private fun applyStatus(status: MediaExportStatus) {
        // Platform callbacks may arrive on a worker thread; serialize list
        // mutation on the session scope (the App's main scope).
        scope.launch { applyStatusNow(status) }
    }

    private fun applyStatusNow(status: MediaExportStatus) {
        val current = jobs.firstOrNull { it.jobID == status.jobID } ?: return
        val next = current.copy(status = status)
        replace(next)
        if (status.state.terminal) {
            observers.remove(status.jobID)?.let { runCatching { it.close() } }
            releaseIfNeeded(next)
        }
    }

    private fun releaseIfNeeded(record: WorkbenchExportJob) {
        if (!record.terminal) return
        // A journal-recovered record has no captured request/binding/lease.
        val request = record.request ?: return
        if (!released.add(record.jobID)) return
        scope.launch {
            runCatching { releaseBinding.releaseRenderBinding(request.binding) }
        }
    }

    private fun updateJob(jobID: String, transform: (WorkbenchExportJob) -> WorkbenchExportJob) {
        val index = jobs.indexOfFirst { it.jobID == jobID }
        if (index < 0) return
        replace(transform(jobs[index]))
    }

    private fun replace(next: WorkbenchExportJob) {
        val index = jobs.indexOfFirst { it.jobID == next.jobID }
        if (index < 0) {
            jobs.add(0, next)
        } else {
            jobs[index] = next
        }
        if (next.terminal) releaseIfNeeded(next)
    }

    private companion object {
        /** Bounded journal read; the host enforces its own cap too. */
        const val RECOVERY_LIMIT = 100
    }
}
