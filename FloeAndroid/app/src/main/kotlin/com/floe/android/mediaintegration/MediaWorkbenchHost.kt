// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import android.content.Context
import com.floe.android.core.workbenchmedia.MAX_RECOVERED_EXPORT_LIST
import com.floe.android.core.workbenchmedia.WorkbenchMediaSession
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingPort
import com.floe.android.feature.workbench.CandidateMutationReceipt
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.DeliveredCandidate
import com.floe.android.feature.workbench.GenerationModelCatalog
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageRequestHandle
import com.floe.android.feature.workbench.ImageRequestStatus
import com.floe.android.feature.workbench.MediaCandidate
import com.floe.android.feature.workbench.MediaJobStatus
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.VideoEditCommand
import com.floe.android.feature.workbench.VideoGenerationRequest
import com.floe.android.feature.workbench.VideoJobHandle
import com.floe.android.feature.workbench.VideoProjectEnvelope
import com.floe.android.feature.workbench.WorkbenchGenerationHostApi
import com.floe.android.feature.workbench.WorkbenchMediaPlatform
import com.floe.android.feature.workbench.WorkbenchVideoHostApi
import com.floe.android.feature.workbench.ui.r2.WorkbenchR2Ports
import com.floe.android.feature.workbench.ui.r2.WorkbenchRecoveredExportLister
import com.floe.android.feature.workbench.ui.r2.WorkbenchRenderBindingPreparer
import com.floe.android.feature.workbench.ui.r2.WorkbenchRenderBindingReleaser
import com.floe.android.host.creative.CreativeHostController
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * ONE Application-owned G09-R2 media integration owner.
 *
 * It composes the process-scoped platform session, the native authority
 * adapters, the App Save/Share delivery and the reviewed large-import facade,
 * and supplies the REQUIRED `WorkbenchR2Ports` bundle to the retained
 * workbench UI sessions. It owns no project store, no renderer and no second
 * export/recovery journal.
 *
 * All host/session lookups are lazy: a feature/UI call always resolves the
 * CURRENT `CreativeHostController` and platform session, never a captured
 * root from before a root/epoch replacement.
 */
internal class MediaWorkbenchHost(
    context: Context,
    scope: CoroutineScope,
    private val hostProvider: () -> CreativeHostController,
    /** Explicit trusted Ask AI task/project binding owner; null keeps the
     * feature's Ask AI entry honestly unavailable (no fake grant). */
    private val agentBindingOwner: MediaAgentBindingOwner? = null,
) {
    /** Feature-facing explicit Ask AI seam; never a model/tool route. */
    val agentBinding: MediaAgentBindingPort? get() = agentBindingOwner

    /** Optional explicit-review grant issuer for the pinned association. */
    suspend fun issueMediaProposalGrant(
        projectID: String,
        proposalID: String,
        revision: Long,
    ): String = agentBindingOwner?.issueProposalGrant(
        projectID = projectID,
        proposalID = proposalID,
        revision = revision,
    ) ?: throw com.floe.android.feature.workbench.ui.api.MediaAgentBindingFailure(
        "ownerProofUnavailable")

    suspend fun revokeMediaTaskBinding(
        projectID: String,
        bindingID: String? = null,
        taskID: String? = null,
    ): Boolean = agentBindingOwner?.revokeBinding(
        projectID = projectID,
        bindingID = bindingID,
        taskID = taskID,
    ) ?: false

    /**
     * Application-owned Save/Share authority is constructed first so the
     * platform facade can capture the exact verified receipt/owner identity
     * on every status/observe reply.
     */
    val exportDelivery = MediaWorkbenchExportDelivery(
        context = context,
        hostProvider = hostProvider,
    )
    val platformOwner = MediaWorkbenchPlatformOwner(
        context = context,
        hostProvider = hostProvider,
        receiptRecorder = exportDelivery,
    )
    val workspacePrestage = MediaWorkbenchWorkspacePrestage(
        root = File(context.applicationContext.filesDir, "MediaWorkspaceSource"),
        scope = scope,
    )
    val largeImport = MediaWorkbenchLargeImport(hostProvider)

    val platform: WorkbenchMediaPlatform get() = platformOwner.platform

    fun pickerDelivery(): MediaWorkbenchExportDelivery = exportDelivery

    fun currentSession(): WorkbenchMediaSession? = platformOwner.currentSession()

    fun currentEpoch(): Long = platformOwner.currentBoundEpoch()

    fun platformState(): MediaWorkbenchPlatformState = platformOwner.state.value

    fun diagnosticSummary(): String = platformOwner.diagnosticSummary()

    /** Counts only; no path/content. Used for actionable Root-stop pending logs. */
    fun lastDrainSummary(): String? {
        val platform = platformOwner.lastDrainReport()?.let { report ->
            "drained=${report.drained};exports=${report.activeExports};" +
                "tickets=${report.activeTickets};players=${report.openPlayers};" +
                "pins=${report.outstandingPins};pinUnknown=${report.pinReleaseUnknown}"
        }
        val prestage = workspacePrestage.pendingCount().takeIf { it > 0 }
            ?.let { "workspacePrestage=$it" }
        return listOfNotNull(platform, prestage).takeIf { it.isNotEmpty() }?.joinToString(";")
    }

    suspend fun onNativeCreativeBound(epoch: Long): Boolean {
        val ready = platformOwner.onNativeCreativeBound(epoch)
        if (ready) {
            exportDelivery.onNativeCreativeBound(epoch)
            workspacePrestage.onNativeCreativeBound()
        } else {
            // Never re-open Save/Share or workspace staging against a
            // half-installed B platform.
            exportDelivery.fenceForRootStop()
            workspacePrestage.fenceForRootStop()
        }
        return ready
    }

    /** Root-stop step 1: refuse NEW App media work immediately. */
    fun fenceForRootStop() {
        platformOwner.fenceForRootStop()
        exportDelivery.fenceForRootStop()
        workspacePrestage.fenceForRootStop()
    }

    /**
     * Root-stop steps 2/3: await the App-owned Save/Share operation and then
     * the old platform workers/players/claims/pins. FALSE keeps every old
     * reference owned; the Root must stay bound.
     */
    suspend fun prepareForRootStop(
        timeoutMillis: Long = MediaWorkbenchPlatformOwner.DEFAULT_RETIRE_TIMEOUT_MS,
    ): Boolean {
        fenceForRootStop()
        // The workspace prestage holds a native egress ticket; its exact
        // worker must close before the platform/native root can be retired.
        if (!workspacePrestage.retireForRootStop(timeoutMillis)) return false
        if (!exportDelivery.retireForRootStop(timeoutMillis)) return false
        return platformOwner.retireForRootStop(timeoutMillis)
    }

    /** Feature-facing required bundle; built once, resolved dynamically. */
    val r2Ports: WorkbenchR2Ports by lazy {
        WorkbenchR2Ports(
            video = LiveWorkbenchVideo(hostProvider),
            generation = LiveWorkbenchGeneration(hostProvider),
            platform = platform,
            recoveredExports = WorkbenchRecoveredExportLister { context, limit ->
                val session = currentSession()
                    ?: throw CreativeException(
                        "rendererUnavailable", "mediaPlatformUnbound", retryable = true)
                // Platform bound is 1..24; UI's own list cap may be larger.
                // Bounded here so recovery is the host journal enumeration,
                // never an unbounded scan (no clamp of an authority decision).
                val bounded = limit.coerceIn(1, MAX_RECOVERED_EXPORT_LIST)
                withContext(Dispatchers.IO) {
                    val statuses = session.listRecoveredExports(context, bounded)
                    // Capture each verified receipt against the exact context
                    // that the native journal just authorized. Recovered
                    // receipts stay Save/Share-able after a project reopen.
                    exportDelivery.recordRecovered(context, statuses)
                    statuses
                }
            },
            renderBindings = WorkbenchRenderBindingPreparer { context, revision, attemptID ->
                val prepared = withContext(Dispatchers.IO) {
                    hostProvider().r2Authority.prepareRenderBinding(
                        context = context,
                        expectedRevision = revision,
                        attemptID = attemptID,
                    )
                }
                exportDelivery.recordPrepared(prepared)
                prepared.toExportBinding()
            },
            releaseRenderBinding = WorkbenchRenderBindingReleaser { binding ->
                // Exact native immutable-lease release; while a platform
                // worker still owns its lifecycle pin the native side defers
                // deletion until that pin settles.
                withContext(Dispatchers.IO) {
                    hostProvider().r2Snapshots.release(binding.snapshot)
                }
            },
            exportDelivery = exportDelivery,
        )
    }
}

/** Re-resolves the current controller's real video host on every call. */
private class LiveWorkbenchVideo(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchVideoHostApi {
    override suspend fun loadVideo(
        context: CreativeProjectContext,
    ): VideoProjectEnvelope = hostProvider().r2Video.loadVideo(context)

    override suspend fun applyVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        commands: List<VideoEditCommand>,
    ) = hostProvider().r2Video.applyVideo(context, expectedRevision, opID, commands)
}

/**
 * Forwarding facade over the native generation host accessor supplied by the
 * generation lane. Every method stays lazy so an epoch/rebind resolves the
 * current implementation; no catalog, job or candidate is fabricated here.
 */
private class LiveWorkbenchGeneration(
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchGenerationHostApi {
    private val api get() = hostProvider().generationHost

    override suspend fun models(): GenerationModelCatalog = api.models()

    override suspend fun submitImage(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: ImageGenerationRequest,
    ): ImageRequestHandle = api.submitImage(context, expectedRevision, opID, request)

    override suspend fun imageStatus(
        context: CreativeProjectContext,
        requestID: String,
    ): ImageRequestStatus = api.imageStatus(context, requestID)

    override suspend fun dismissImageRequest(
        context: CreativeProjectContext,
        requestID: String,
        opID: String,
    ) = api.dismissImageRequest(context, requestID, opID)

    override suspend fun submitVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: VideoGenerationRequest,
    ): VideoJobHandle = api.submitVideo(context, expectedRevision, opID, request)

    override suspend fun jobs(
        context: CreativeProjectContext,
        limit: Int,
    ): List<MediaJobStatus> = api.jobs(context, limit)

    override suspend fun refreshJob(
        context: CreativeProjectContext,
        jobID: String,
    ): MediaJobStatus = api.refreshJob(context, jobID)

    override suspend fun cancelJob(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): MediaJobStatus = api.cancelJob(context, jobID, opID)

    override suspend fun deliverResult(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): DeliveredCandidate = api.deliverResult(context, jobID, opID)

    override suspend fun candidates(
        context: CreativeProjectContext,
    ): List<MediaCandidate> = api.candidates(context)

    override suspend fun acceptCandidate(
        context: CreativeProjectContext,
        expectedRevision: Long,
        candidateID: String,
        opID: String,
    ): MediaProjectReceipt = api.acceptCandidate(
        context, expectedRevision, candidateID, opID)

    override suspend fun rejectCandidate(
        context: CreativeProjectContext,
        candidateID: String,
        opID: String,
    ): CandidateMutationReceipt = api.rejectCandidate(context, candidateID, opID)
}
