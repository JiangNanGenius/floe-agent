// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.content.Context
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafGatewayService
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The OPENED owned egress: a native ticket whose generation lease lives
 * until [close] is called exactly once by its consumer (Office snapshot
 * stager, Save Copy transfer, or an aborted attempt). */
internal class NativeEgressSource(
    private val channel: RunOutputEgressChannel,
    val ticket: Long,
    override val info: RunOutputEgressInfo,
) : RunOutputEgressSource {
    private var closed = false
    override fun read(offset: Long, buffer: ByteArray): Int = channel.read(ticket, offset, buffer)
    override fun close() {
        if (!closed) {
            closed = true
            channel.close(ticket)
        }
    }
}

internal data class RunOutputPendingPick(
    val incarnation: Long,
    val spec: PickRequestSpec,
    val identity: RunOutputSaveIdentity,
)

/** Application-owned trusted host service for the D04 owned run-output lane:
 * the bounded list used by the conversation cards, the open/egress sessions
 * used by Office snapshot staging, and the verified Save Copy pipeline.
 *
 * Every call carries the CURRENT native root epoch (App readback of the
 * ACCEPTED generation; the native side re-validates and never trusts the
 * claim). A dynamic absence of the lane (LinkageError on the loaded Core)
 * or a fenced generation maps to typed refusals — the UI shows honest
 * unavailable states and success is never fabricated.
 *
 * No Kotlin here chooses file roots, paths or digests: identity in, bounded
 * verified bytes out, everything else re-derived natively from the run's
 * own durable records.
 */
internal class RunOutputHostService(
    context: Context,
    private val scope: CoroutineScope,
    private val currentNativeEpoch: () -> Long?,
    private val channel: RunOutputEgressChannel = NativeRunOutputChannel,
) {
    private val appContext = context.applicationContext
    private val stagingRoot = File(appContext.applicationInfo.dataDir, "files/RunOutputSaveScratch")
    private val backend = AndroidSafBackend(appContext)
    private val gateway = SafGatewayService(backend)
    private val saveController = RunOutputSaveCopyController(gateway, backend, stagingRoot)

    /** Platform-launch identity namespace for the CREATE_DOCUMENT picker
     * (same ownership ledger discipline as the attachment/skills pickers). */
    val launchNamespace = PlatformLaunchOwnership.mintNamespace()

    private val mutablePickerRequest = MutableStateFlow<RunOutputPendingPick?>(null)
    val pickerRequest: StateFlow<RunOutputPendingPick?> = mutablePickerRequest

    private val lock = Any()
    private var incarnationCounter = 0L
    private var activeSave: ActiveSave? = null
    private var watchdog: Job? = null

    private class ActiveSave(
        val identity: RunOutputSaveIdentity,
        val source: RunOutputEgressSource,
        val onSettled: (RunOutputSaveOutcome) -> Unit,
    )

    companion object {
        /** Bounded wait for the system picker to come back. Expiry settles
         * the operation as Cancelled and releases the lease; the snapshot
         * stays untouched and recoverable. */
        const val PICK_WAIT_TIMEOUT_MS = 15 * 60 * 1000L
    }

    private fun liveEpoch(): Long? = currentNativeEpoch()?.takeIf { it > 0 }

    // MARK: - List (card availability)

    fun receipts(conversationID: String, runID: String): RunOutputListResult {
        val epoch = liveEpoch() ?: return RunOutputListResult.Refused(RunOutputStatus.NOT_INSTALLED)
        return RunOutputReply.list(
            RunOutputReply.call { buffer -> channel.list(epoch, conversationID, runID, buffer) },
            expectedConversationID = conversationID,
            expectedRunID = runID,
        )
    }

    // MARK: - Open (full verify + lease)

    /** Opens one owned egress session. Returns null with the typed status
     * on any refusal (the caller surfaces an honest unavailable state). */
    fun openEgress(conversationID: String, runID: String, outputID: String):
        Result<NativeEgressSource> {
        val epoch = liveEpoch()
            ?: return Result.failure(RunOutputLaneUnavailable(RunOutputStatus.NOT_INSTALLED))
        val ticket = try {
            channel.open(epoch, conversationID, runID, outputID)
        } catch (_: LinkageError) {
            return Result.failure(RunOutputLaneUnavailable(RunOutputStatus.NOT_INSTALLED))
        }
        if (ticket <= 0) {
            return Result.failure(RunOutputLaneUnavailable(ticket.toInt()))
        }
        val reply = RunOutputReply.call { buffer -> channel.info(ticket, buffer) }
        val info = RunOutputReply.egressInfo(reply, conversationID, runID, outputID)
        if (info == null) {
            // Shape violation after a successful open: close the EXACT
            // ticket (release, not a new admission).
            runCatching { channel.close(ticket) }
            return Result.failure(RunOutputLaneUnavailable(RunOutputStatus.INTERNAL))
        }
        return Result.success(NativeEgressSource(channel, ticket, info))
    }

    // MARK: - Save Copy

    /** Starts one Save Copy for one exact owned output. Must be called on a
     * background dispatcher (native open verifies the whole snapshot). True
     * means the platform pick was requested; the settled outcome arrives
     * exactly once via [onSettled], and the egress lease is released by this
     * service on every terminal path. */
    fun requestSaveCopy(conversationID: String, runID: String, outputID: String,
                        onSettled: (RunOutputSaveOutcome) -> Unit): Boolean {
        val source = openEgress(conversationID, runID, outputID).getOrNull() ?: return false
        // prepare() owns the single-slot admission: it refuses (null) while
        // another save is active, so no lease can be parked without an
        // owner.
        val prepared = saveController.prepare(source) ?: run {
            source.close()
            return false
        }
        val (identity, spec) = prepared
        val started = synchronized(lock) {
            if (activeSave != null) false
            else {
                activeSave = ActiveSave(identity, source, onSettled)
                mutablePickerRequest.value = RunOutputPendingPick(++incarnationCounter, spec, identity)
                watchdog?.cancel()
                watchdog = scope.launch(Dispatchers.Default) {
                    delay(PICK_WAIT_TIMEOUT_MS)
                    cancelPendingLocked("picker-wait-expired", identity)
                }
                true
            }
        }
        if (!started) {
            // Should be unreachable (prepare already holds the slot under the
            // controller lock); reconcile honestly: release the session we
            // just opened and refuse.
            source.close()
            return false
        }
        return true
    }

    /** Delivers the ACTUAL system result for the exact issued pick (URI +
     * real returned intent flags, verbatim; a null result is the user's
     * cancel, never a re-read of a replacement request). */
    fun deliverPickResult(incarnation: Long, resultUriString: String?,
                          returnedIntentFlags: Int) {
        val pending = synchronized(lock) {
            mutablePickerRequest.value?.takeIf { it.incarnation == incarnation }
                ?: return
        }
        val save = synchronized(lock) {
            activeSave?.takeIf { it.identity == pending.identity } ?: return
        }
        synchronized(lock) { mutablePickerRequest.value = null; watchdog?.cancel(); watchdog = null }
        when (val delivery = saveController.deliverPickResult(
            resultUriString, returnedIntentFlags, save.identity,
        )) {
            is RunOutputSaveDelivery.TargetAccepted -> {
                scope.launch(Dispatchers.IO) {
                    val operation = gateway.submit { cancel ->
                        com.floe.android.safgateway.SafOutcome.success(
                            saveController.transfer(save.identity, cancel))
                    }
                    val settled = withContext(NonCancellable) { operation.await() }
                    when (settled) {
                        is com.floe.android.safgateway.SafOutcome.Success ->
                            finishSave(save, settled.value)
                        is com.floe.android.safgateway.SafOutcome.Failure ->
                            finishSave(save, RunOutputSaveOutcome.Failed(
                                save.identity, "transfer-unavailable",
                                RunOutputSaveStage.TRANSFERRING, settled.detail, null,
                                partialWritePossible = true))
                    }
                }
            }
            is RunOutputSaveDelivery.NoTarget -> {
                // The controller already settled cancelled/refused internally;
                // surface the honest terminal to the caller.
                finishSave(save, RunOutputSaveOutcome.Cancelled(
                    save.identity, RunOutputSaveStage.AWAITING_TARGET, delivery.reason,
                    partialWritePossible = false))
            }
            is RunOutputSaveDelivery.Refused -> {
                finishSave(save, RunOutputSaveOutcome.Failed(
                    save.identity, delivery.code, RunOutputSaveStage.AWAITING_TARGET,
                    delivery.detail, null, partialWritePossible = false))
            }
        }
    }

    /** Cancel the pending/active save (surface unmount, explicit user
     * cancel, or runtime stop). The egress lease is released exactly once
     * and the snapshot is never modified or deleted. */
    fun cancelActiveSave(reason: String, runID: String? = null,
                        outputID: String? = null): Boolean {
        val save = synchronized(lock) {
            activeSave?.takeIf {
                (runID == null || it.identity.runID == runID) &&
                    (outputID == null || it.identity.outputID == outputID)
            } ?: return false
        }
        val controllerCancelled = saveController.cancel(save.identity, reason)
        if (controllerCancelled) {
            finishSave(save, RunOutputSaveOutcome.Cancelled(
                save.identity, RunOutputSaveStage.AWAITING_TARGET, reason,
                partialWritePossible = false))
        }
        return controllerCancelled
    }

    private fun cancelPendingLocked(reason: String, identity: RunOutputSaveIdentity) {
        val save = synchronized(lock) { activeSave?.takeIf { it.identity == identity } } ?: return
        if (saveController.cancel(identity, reason) || saveController.abandonActiveWith(
                identity, reason) != null) {
            finishSave(save, RunOutputSaveOutcome.Cancelled(
                identity, RunOutputSaveStage.AWAITING_TARGET, reason, partialWritePossible = false))
        }
    }

    /** Runtime teardown: settle whatever is pending. A transfer that
     * already reached the provider cannot be reversed; its honest outcome
     * still flows through finishSave when it lands. */
    fun onRuntimeStopped() {
        val save = synchronized(lock) { activeSave } ?: return
        saveController.abandonActiveWith(save.identity, "runtime-stopped")
        finishSave(save, RunOutputSaveOutcome.Cancelled(
            save.identity, RunOutputSaveStage.AWAITING_TARGET, "runtime-stopped",
            partialWritePossible = false))
    }

    private fun finishSave(save: ActiveSave, outcome: RunOutputSaveOutcome) {
        val wasCurrent = synchronized(lock) {
            if (activeSave === save) { activeSave = null; true } else false
        }
        // Close the EXACT lease token's session exactly once, even if a
        // late callback raced a replacement (idempotent close()).
        save.source.close()
        if (wasCurrent) save.onSettled(outcome)
    }

    /** Current save key ("runID/outputID") while an operation owns the
     * single save slot, for card state projection. */
    fun activeSaveKey(): String? = synchronized(lock) {
        activeSave?.let { "${it.identity.runID}/${it.identity.outputID}" }
    }
}

/** Typed lane refusal carrier (never a fake success surface). */
internal class RunOutputLaneUnavailable(val status: Int) : Exception("run-output lane status $status")

private fun RunOutputSaveCopyController.abandonActiveWith(
    identity: RunOutputSaveIdentity, reason: String,
): RunOutputSaveIdentity? {
    val abandoned = abandonActive(reason) ?: return null
    return if (abandoned == identity) abandoned else null
}

internal fun saveStateKey(runID: String, outputID: String): String = "$runID/$outputID"
