// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import android.content.Context
import android.os.SystemClock
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import com.floe.android.host.OfficePreviewController
import com.floe.android.host.OfficePrecisionClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import com.floe.android.host.WorkspaceSourceResult
import java.io.File
import java.util.concurrent.Executor
import kotlinx.coroutines.delay

/**
 * The production [OfficeAiDocumentPorts] join. Every capability routes to
 * the EXISTING application-owned objects — the single
 * [OfficePreviewController] (owned operation + owner-safe workspace open +
 * the one application-owned Save-Copy host instance behind its narrow
 * additive AI seam), the delivered typed [OfficePrecisionClient] (its own
 * bind; it never registers a host save channel), and the existing
 * [com.floe.android.host.WorkspaceSourceHostController] headless
 * runtime-owned lane on the SAME WorkspaceSourcePump gateway/backend. No
 * parallel controller, no second Save-Copy host, no new gateway, no raw
 * UNO/path surface and no model-facing entry exists here.
 */
internal class AppOfficeAiDocumentPorts(
    private val host: RuntimeHost,
    private val controller: OfficePreviewController,
) : OfficeAiDocumentPorts {
    private val appContext: Context = host.appContext
    private val saveHost = controller.officeAiSaveHost()
    private val io = host.ioDispatcher

    /** One client for the whole lane. `hostChannel = null`: the transaction-28
     * registration ownership stays exactly where it is (the Save-Copy host);
     * the client's own bind never refreshes the channel. */
    private val precisionClient = OfficePrecisionClient(
        appContext,
        Executor { command -> command.run() },
        hostChannel = null,
    )

    override fun ownedSnapshot(
        taskID: String,
        workspaceID: String?,
        nativeEpoch: String,
    ): OfficePreviewController.OwnedOperationSnapshot? = try {
        controller.ownedOperationSnapshot(taskID, workspaceID, nativeEpoch)
    } catch (_: Exception) {
        null
    }

    override fun viewerDisplayName(): String? =
        controller.state.value.viewer?.request?.displayName

    override fun isDocumentSlotBusy(): Boolean = controller.isBusy

    override fun openWorkspace(
        owner: WorkspaceOfficeSnapshotStager.Owner,
        logicalPath: String,
        ownerCurrent: () -> Boolean,
    ) = controller.openWorkspaceForAi(owner, logicalPath, ownerCurrent)

    override fun openAdmissionError(): String? = controller.state.value.error

    // ---- transient launch admission joins (Main host20 final review) ----
    // All three read REAL production state maintained for existing flows —
    // the MainActivity resume/pause projection, the controller's own picker
    // slot and the shell-reported visible-conversation binding. They gate
    // ONLY a NEW viewer launch (see OfficeAiHostService.open); the durable
    // owner fence deliberately excludes all three so the viewer taking over
    // the foreground never revokes an owned VIEWING document.

    override fun isApplicationForeground(): Boolean = runCatching {
        (appContext as? com.floe.android.FloeApplication)?.isActivityInForeground() == true
    }.getOrDefault(false)

    override fun isPlatformPickerPending(): Boolean =
        controller.state.value.picker != null

    override fun isConversationCurrentlyVisible(taskID: String): Boolean = runCatching {
        host.conversations.currentVisibleConversationId() == taskID
    }.getOrDefault(false)

    // The shell's observation-only modal projection (Settings/preview Dialog,
    // drawer): the privacy visible-holder stays bound underneath the Dialog,
    // so this separate real fact closes the settings-over-chat gap.
    override fun isModalSurfaceOwned(): Boolean = host.uiModalSurfaceOwned

    override fun isOwnedOperationViewing(
        taskID: String,
        workspaceID: String,
        nativeEpoch: String,
    ): Boolean = runCatching {
        controller.isOwnedOperationViewing(taskID, workspaceID, nativeEpoch)
    }.getOrDefault(false)

    /** The controller's EXISTING explicit-cancel lane through the owner-
     * checked join: retires only THIS exact owner's still-unclaimed launch;
     * a VIEWING operation or another surface's operation returns untouched,
     * which is exactly the stop-consulting boundary. */
    override fun cancelUnclaimedLaunch(taskID: String, workspaceID: String, nativeEpoch: String) {
        runCatching { controller.cancelUnclaimedOwnedLaunch(taskID, workspaceID, nativeEpoch) }
    }

    override fun engineGeneration(sessionToken: String): Long = try {
        saveHost.aiReadGeneration(sessionToken)
    } catch (_: Exception) {
        0L
    }

    override fun engineEditState(sessionToken: String, generation: Long): OfficeAiEngineEditFacts? = try {
        saveHost.aiReadState(sessionToken, generation)
            ?.let { OfficeAiEngineEditFacts(it.stateName, it.editPermissionEstablished) }
    } catch (_: Exception) {
        null
    }

    override fun saveSubmit(
        request: com.floe.android.core.officeengine.OfficeSaveRequest,
    ): OfficeAiSaveSubmit = try {
        saveHost.aiSubmitSave(request)
    } catch (_: Exception) {
        // Conservative: an unexpected frame failure around the seam cannot
        // prove "nothing was sent" — treat it as attempted-without-reply so
        // the receipt waiter / UNKNOWN-retained path decides, never a resend.
        OfficeAiSaveSubmit.AttemptedWithoutReply
    }

    override fun attachSaveReceiptObserver(observer: (com.floe.android.core.officeengine.OfficeSaveReceipt) -> Unit) {
        saveHost.attachAiReceiptObserver(observer)
    }

    override fun detachSaveReceiptObserver() {
        saveHost.attachAiReceiptObserver(null)
    }

    /**
     * Dispatch-proof precision execution (Main production review 2026-10-27).
     * The delivered [OfficePrecisionClient] emits REJECTED+TRANSPORT for two
     * STRUCTURALLY different moments and only ONE of them proves "nothing
     * was sent":
     *  - detail `engine-command-binding-unavailable` — the client never even
     *    had a command binder, so no postPrecisionCommand transaction was
     *    attempted: a bounded pre-dispatch admission retry is safe;
     *  - detail `binder-transport-failed` (postPrecisionCommand WAS attempted
     *    and its reply was lost) or `poll-interrupted` — an effect may have
     *    reached the kit. Those must NEVER be re-dispatched and must never
     *    be claimed as a clean rejected/nothing-sent: the adapter first
     *    re-reads the SAME op identity through the client's existing
     *    readAnswer seam (the real engine terminal), and without terminal
     *    proof relays an honest UNKNOWN/retained result (no auto-replay, no
     *    auto-undo; the engine ledger keeps the possible effect and the
     *    later reconcile/collect path decides).
     */
    override suspend fun precision(
        request: OfficePrecisionRequest,
        deadlineMs: Long,
    ): OfficePrecisionResult = kotlinx.coroutines.withContext(io) {
        var attempt = dispatchOnce(request, deadlineMs)
        var bindAttempts = 0
        while (classifyPrecisionResult(attempt) == PrecisionTransportDisposition.PRE_DISPATCH_RETRYABLE &&
            bindAttempts < PRECISION_BIND_ATTEMPTS
        ) {
            delay(PRECISION_BIND_BACKOFF_MILLIS)
            bindAttempts++
            attempt = dispatchOnce(request, deadlineMs)
        }
        if (classifyPrecisionResult(attempt) == PrecisionTransportDisposition.AMBIGUOUS_RETAINED) {
            // Same op identity, real terminal re-read before the relay.
            val reRead = reReadTerminal(request)
            if (reRead != null) return@withContext reRead
            return@withContext ambiguousRetainedResult(request)
        }
        attempt ?: ambiguousRetainedResult(request)
    }

    /** Bounded consumption of the engine's own terminal answer for the exact
     * op/token/generation after an ambiguous transport moment. A read is
     * never a re-dispatch; a still-pending window relays honestly. */
    private suspend fun reReadTerminal(request: OfficePrecisionRequest): OfficePrecisionResult? {
        repeat(READANSWER_ATTEMPTS) {
            val terminal = runCatching {
                precisionClient.readAnswer(request.opId, request.sessionToken, request.generation)
            }.getOrNull()
            if (terminal != null) return terminal
            delay(READANSWER_BACKOFF_MILLIS)
        }
        return null
    }

    private fun dispatchOnce(
        request: OfficePrecisionRequest,
        deadlineMs: Long,
    ): OfficePrecisionResult? {
        var outcome: OfficePrecisionResult? = null
        // The client runs on the supplied DIRECT executor: its callback is
        // invoked before execute() returns, so the terminal result can never
        // be lost or deferred past this frame.
        val dispatched = runCatching {
            precisionClient.execute(request, deadlineMs) { result -> outcome = result }
        }.isSuccess
        return if (dispatched) outcome else null
    }

    /** Honest UNKNOWN/retained relay for a post-attempt ambiguous transport
     * moment: identity preserved, NEVER presented as "nothing was sent". */
    private fun ambiguousRetainedResult(request: OfficePrecisionRequest): OfficePrecisionResult {
        val now = SystemClock.elapsedRealtime()
        return OfficePrecisionResult(
            opId = request.opId,
            sessionToken = request.sessionToken,
            generation = request.generation,
            action = request.action,
            state = OfficePrecisionState.UNKNOWN,
            failure = OfficePrecisionFailure.TRANSPORT,
            detail = "transport-ambiguous-post-send-retained",
            answer = null,
            attestation = "host-ambiguous-retained",
            submittedAtElapsedMs = now,
            completedAtElapsedMs = now,
        )
    }

    override suspend fun pushOriginalViaHeadlessLane(
        taskID: String,
        workspaceID: String,
        nativeEpoch: Long,
        hostGeneration: Long,
        logicalPath: String,
        ownerFence: () -> Boolean,
    ): WorkspaceSourceResult? = kotlinx.coroutines.withContext(io) {
        val lane = host.workspaceSourceHost?.headlessLaneFor(
            taskID = taskID, workspaceID = workspaceID, nativeEpoch = nativeEpoch,
            hostGeneration = hostGeneration, isCurrentOwner = ownerFence,
        ) ?: return@withContext null
        lane.savePathToProvider(logicalPath)
    }

    override fun currentNativeEpoch(): Long? = host.nativeRootEpoch()

    override fun commandGeneration(): Long = host.commandClient.generation()

    override fun isOwnedOrdinaryTask(taskID: String): Boolean = try {
        host.conversations.entryFor(taskID)?.isTemporary == false
    } catch (_: Exception) {
        false
    }

    override fun appDataRoot(): File? = runCatching {
        File(appContext.applicationInfo.dataDir).canonicalFile
    }.getOrNull()

    override fun outputsRoot(): File = File(appContext.noBackupFilesDir, "floe-office-outputs")

    override fun baselineRoot(): File = File(appContext.noBackupFilesDir, "floe-office-ai-capture")

    override fun elapsedMs(): Long = SystemClock.elapsedRealtime()

    /** Lane teardown: release only this client's own connection (never the
     * Save-Copy host's independent engine binding). */
    override fun releaseTransports() {
        runCatching { precisionClient.release() }
    }

    companion object {
        private const val PRECISION_BIND_ATTEMPTS = 10
        private const val PRECISION_BIND_BACKOFF_MILLIS = 150L
        private const val READANSWER_ATTEMPTS = 8
        private const val READANSWER_BACKOFF_MILLIS = 250L
    }
}

/**
 * The exact client local-refusal moments (from the delivered
 * [com.floe.android.host.OfficePrecisionClient] source): only
 * `engine-command-binding-unavailable` PROVES no postPrecisionCommand
 * transaction was ever attempted. `binder-transport-failed` means the
 * transaction WAS attempted and the reply was lost; `poll-interrupted` means
 * the op was accepted and the client stopped watching. A null result means
 * even the client frame failed to run — conservatively ambiguous.
 */
internal enum class PrecisionTransportDisposition { PRE_DISPATCH_RETRYABLE, AMBIGUOUS_RETAINED, SETTLED }

internal fun classifyPrecisionResult(result: OfficePrecisionResult?): PrecisionTransportDisposition {
    if (result == null) return PrecisionTransportDisposition.AMBIGUOUS_RETAINED
    if (result.state == OfficePrecisionState.REJECTED &&
        result.failure == OfficePrecisionFailure.TRANSPORT
    ) {
        return when (result.detail) {
            "engine-command-binding-unavailable" -> PrecisionTransportDisposition.PRE_DISPATCH_RETRYABLE
            "binder-transport-failed", "poll-interrupted" ->
                PrecisionTransportDisposition.AMBIGUOUS_RETAINED
            else -> PrecisionTransportDisposition.AMBIGUOUS_RETAINED
        }
    }
    return PrecisionTransportDisposition.SETTLED
}
