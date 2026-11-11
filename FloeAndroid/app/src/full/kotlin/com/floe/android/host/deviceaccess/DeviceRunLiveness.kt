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

    /** Null means this owner has never been observed here; false also fences a retired proof. */
    fun answer(owner: PhoneControlOwner, epoch: Long?): Boolean? {
        val observed = current.get()?.takeIf { it.owner == owner } ?: return null
        return epoch == observed.epoch && source.currentEpoch() == observed.epoch &&
            observed.state.get() == State.LIVE && observed.stream.get() != null &&
            current.get() === observed
    }

    suspend fun confirm(owner: PhoneControlOwner, epoch: Long): Boolean = admission.withLock {
        if (epoch <= 0 || source.currentEpoch() != epoch) return@withLock false
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
            proof == null || proof.terminal || !proof.liveOwner ||
            proof.watermark < 0 ||
            !owner.taskID.toString().equals(proof.taskID, ignoreCase = true) ||
            !owner.runID.toString().equals(proof.runID, ignoreCase = true)
        ) {
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
                onLost = { if (current.get() === observed) end(observed) },
            )
        } catch (cancelled: CancellationException) {
            end(observed)
            throw cancelled
        } catch (_: Exception) {
            end(observed)
            return@withLock false
        }
        observed.stream.set(handle)
        if (current.get() !== observed || stopFence.get() != fence || source.currentEpoch() != epoch ||
            !observed.state.compareAndSet(State.CHECKING, State.LIVE)
        ) {
            observed.stream.getAndSet(null)?.let { runCatching { it.close() } }
            end(observed)
            return@withLock false
        }
        onChanged()
        answer(owner, epoch) == true
    }

    /** Keep an ended proof until a fresh native confirmation, so stale UI state cannot revive it. */
    fun stop() {
        stopFence.incrementAndGet()
        current.get()?.let(::end)
    }

    private fun end(observed: Observation) {
        val previous = observed.state.getAndSet(State.ENDED)
        observed.stream.getAndSet(null)?.let { runCatching { it.close() } }
        if (previous == State.LIVE && current.get() === observed) onChanged()
    }
}

internal class HostDeviceRunReadPort(private val host: RuntimeHost) : DeviceRunReadPort {
    override fun currentEpoch(): Long? = host.nativeRootEpoch()

    override suspend fun snapshot(owner: PhoneControlOwner): DeviceRunProof? {
        val result = CompletableDeferred<ConversationWire.SnapshotPage?>()
        host.trackOperation(
            HostCommandRequest(
                command = "run.snapshot",
                scope = HostScope.TaskExecution(owner.taskID.toString(), owner.runID.toString()),
                stateful = false,
                correlationID = host.commandClient.correlationID("device-run"),
            ),
        ) { outcome ->
            result.complete((outcome as? HostOperationOutcome.Completed)?.value
                ?.let(ConversationWire::decodeSnapshotPage))
        }
        val page = withTimeoutOrNull(5_000L) { result.await() } ?: return null
        return DeviceRunProof(page.conversationID, page.runID, page.isTerminal,
            page.liveOwner, page.durableWatermark)
    }

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
