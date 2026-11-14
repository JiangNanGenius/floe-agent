// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.ConversationWire
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal data class DeviceRunProof(
    val taskID: String?,
    val runID: String,
    val terminal: Boolean,
    val liveOwner: Boolean,
    val watermark: Long,
)

/** Read-side projection of the existing native run service; grants stay with the device host. */
internal interface DeviceRunReadPort {
    fun currentEpoch(): Long?
    fun snapshotFailureCode(): String? = null
    suspend fun snapshot(owner: PhoneControlOwner): DeviceRunProof?
    fun observe(
        owner: PhoneControlOwner,
        afterSequence: Long,
        onTerminal: (Long) -> Unit,
        onLost: () -> Unit,
    ): AutoCloseable
}

/**
 * Observe only the run currently using device automation. A scheduled run has no UI holder.
 * Native snapshot ownership proves admission; durable terminal events end that same proof.
 * A lost stream or root epoch fails closed, without reconnecting or retrying device actions.
 */
internal class DeviceRunLiveness(
    private val source: DeviceRunReadPort,
    /**
     * The host's exact-owner stop fence. It is checked after the asynchronous
     * native snapshot and before an observation is installed, so a Stop that
     * lands while [confirm] is awaiting cannot revive that owner. A different
     * owner is never affected.
     */
    private val ownerStopped: (PhoneControlOwner) -> Boolean = { false },
    private val onChanged: () -> Unit,
) {
    private enum class State { CHECKING, LIVE, ENDED }
    private class Observation(val owner: PhoneControlOwner, val epoch: Long, val watermark: Long) {
        val state = AtomicReference(State.CHECKING)
        val stream = AtomicReference<AutoCloseable?>(null)
    }

    private val admission = Mutex()
    private val current = AtomicReference<Observation?>(null)
    private val stopFence = AtomicLong()
    @Volatile var refusalCode: String? = null
        private set

    /** Null means this owner has never been observed here; false also fences a retired proof. */
    fun answer(owner: PhoneControlOwner, epoch: Long?): Boolean? {
        val observed = current.get()?.takeIf { it.owner == owner } ?: return null
        return epoch == observed.epoch && source.currentEpoch() == observed.epoch &&
            observed.state.get() == State.LIVE && observed.stream.get() != null &&
            current.get() === observed
    }

    suspend fun confirm(
        owner: PhoneControlOwner,
        epoch: Long,
        /**
         * True ONLY for the explicit user re-allow/Continue gesture already
         * validated by the host's stop-settle rule. Automatic admission never
         * sets this, so a stop remains fail-closed outside that gesture.
         */
        allowStopped: Boolean = false,
    ): Boolean = admission.withLock {
        if (epoch <= 0 || source.currentEpoch() != epoch) {
            refusalCode = "epoch_changed"
            return@withLock false
        }
        if (!allowStopped && ownerStopped(owner)) {
            refusalCode = "control_stopped"
            current.get()?.takeIf { it.owner == owner }?.let(::end)
            return@withLock false
        }
        if (answer(owner, epoch) == true) return@withLock true
        val fence = stopFence.get()
        val proof = try {
            source.snapshot(owner)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        if (stopFence.get() != fence || source.currentEpoch() != epoch ||
            (!allowStopped && ownerStopped(owner)) ||
            proof == null || proof.terminal || !proof.liveOwner ||
            proof.watermark < 0 ||
            !owner.taskID.toString().equals(proof.taskID, ignoreCase = true) ||
            !owner.runID.toString().equals(proof.runID, ignoreCase = true)
        ) {
            refusalCode = when {
                stopFence.get() != fence || (!allowStopped && ownerStopped(owner)) ->
                    "control_stopped"
                source.currentEpoch() != epoch -> "epoch_changed"
                proof == null -> source.snapshotFailureCode() ?: "snapshot_unavailable"
                proof.terminal -> "run_terminal"
                !proof.liveOwner -> "owner_unavailable"
                proof.watermark < 0 -> "snapshot_invalid"
                else -> "owner_mismatch"
            }
            current.get()?.takeIf { it.owner == owner }?.let(::end)
            return@withLock false
        }
        val observed = Observation(owner, epoch, proof.watermark)
        val previous = current.getAndSet(observed)
        previous?.let(::end)
        val handle = try {
            source.observe(owner, proof.watermark,
                onTerminal = { sequence ->
                    // A retried run keeps its id; its old terminal is below the new snapshot.
                    if (sequence > observed.watermark && current.get() === observed) end(observed)
                },
                onLost = {
                    if (current.get() === observed) {
                        refusalCode = "observation_lost"
                        end(observed)
                    }
                },
            )
        } catch (cancelled: CancellationException) {
            end(observed)
            throw cancelled
        } catch (_: Exception) {
            refusalCode = "observation_unavailable"
            end(observed)
            return@withLock false
        }
        observed.stream.set(handle)
        if (current.get() !== observed || stopFence.get() != fence || source.currentEpoch() != epoch ||
            (!allowStopped && ownerStopped(owner)) ||
            !observed.state.compareAndSet(State.CHECKING, State.LIVE)
        ) {
            refusalCode = refusalCode ?: "observation_lost"
            observed.stream.getAndSet(null)?.let { runCatching { it.close() } }
            end(observed)
            return@withLock false
        }
        refusalCode = null
        onChanged()
        answer(owner, epoch) == true
    }

    /** Keep an ended proof until a fresh native confirmation, so stale UI state cannot revive it. */
    fun stop() {
        stopFence.incrementAndGet()
        current.get()?.let(::end)
    }

    /**
     * End ONLY this exact owner's proof. Old asynchronous stop/takeover
     * cleanup must not tear down a different owner's newer observation.
     */
    fun stop(owner: PhoneControlOwner) {
        val observed = current.get() ?: return
        if (observed.owner != owner) return
        end(observed)
        // Retain the ended proof: null would let the host fall back to an
        // older UI holder and mistake this stopped owner for a live run.
    }

    private fun end(observed: Observation) {
        val previous = observed.state.getAndSet(State.ENDED)
        observed.stream.getAndSet(null)?.let { runCatching { it.close() } }
        if (previous == State.LIVE && current.get() === observed) onChanged()
    }
}

internal class HostDeviceRunReadPort(private val host: RuntimeHost) : DeviceRunReadPort {
    private val failure = AtomicReference<String?>(null)
    override fun currentEpoch(): Long? = host.nativeRootEpoch()
    override fun snapshotFailureCode(): String? = failure.get()

    override suspend fun snapshot(owner: PhoneControlOwner): DeviceRunProof? {
        failure.set(null)
        val result = CompletableDeferred<Pair<ConversationWire.SnapshotPage?, String?>>()
        host.trackOperation(
            HostCommandRequest(
                command = "run.snapshot",
                scope = HostScope.TaskExecution(owner.taskID.toString(), owner.runID.toString()),
                stateful = false,
                correlationID = host.commandClient.correlationID("device-run"),
                // Input authority needs live identity/state, not a large
                // display snapshot or a continuation-content allocation.
                payload = JsonObject(mapOf("metadataOnly" to JsonPrimitive(true))),
            ),
        ) { outcome ->
            val page = (outcome as? HostOperationOutcome.Completed)?.value
                ?.let(ConversationWire::decodeSnapshotPage)
            val code = when (outcome) {
                is HostOperationOutcome.Completed -> if (page == null) "snapshot_invalid" else null
                is HostOperationOutcome.Failed -> "snapshot_failed_" + safeCode(outcome.code)
                is HostOperationOutcome.Rejected -> "snapshot_rejected_" + safeCode(outcome.code)
                HostOperationOutcome.Cancelled -> "snapshot_cancelled"
                HostOperationOutcome.Superseded -> "epoch_changed"
            }
            result.complete(page to code)
        }
        val reply = withTimeoutOrNull(5_000L) { result.await() }
        failure.set(reply?.second ?: if (reply == null) "snapshot_timeout" else null)
        val page = reply?.first ?: return null
        return DeviceRunProof(page.conversationID, page.runID, page.isTerminal,
            page.liveOwner, page.durableWatermark)
    }

    private fun safeCode(value: String): String = value
        .take(64).takeIf { it.isNotEmpty() && it.all { c -> c in 'a'..'z' ||
            c in 'A'..'Z' || c in '0'..'9' || c == '_' || c == '-' } } ?: "unknown"

    override fun observe(
        owner: PhoneControlOwner,
        afterSequence: Long,
        onTerminal: (Long) -> Unit,
        onLost: () -> Unit,
    ): AutoCloseable {
        val handle = host.commandClient.openRunEventStream(
            taskID = owner.taskID.toString(), runID = owner.runID.toString(),
            environmentID = null, jobID = null, startSequence = afterSequence,
            onEvent = { frame ->
                if (owner.runID.toString().equals(frame.runID, ignoreCase = true) &&
                    ConversationWire.isTerminalFrame(frame)) onTerminal(frame.sequence)
            },
            onLiveHint = { },
            onFailure = { onLost() },
        )
        return AutoCloseable { handle.close() }
    }
}
