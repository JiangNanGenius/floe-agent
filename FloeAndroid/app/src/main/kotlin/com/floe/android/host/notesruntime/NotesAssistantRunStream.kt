// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesruntime

import com.floe.android.host.EventPumpHandle
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostEffectTerminal
import com.floe.android.host.HostPumpFailure
import com.floe.android.host.HostRunEventFrame
import com.floe.android.host.HostScope
import com.floe.android.host.HostSubmitResult
import com.floe.android.host.RuntimeHostCommandClient
import com.floe.android.host.notes.NotesHostController
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * The ONE real App-owned Notes assistant run stream.
 *
 * It is built over the SAME [RuntimeHostCommandClient] the Application already
 * owns ([com.floe.android.host.RuntimeHost.commandClient]) — never a second
 * client, observer service, conversation controller or provider loop:
 *
 * * `openRunEventStream` is the EXISTING durable `floe.event-cursor/3` pump.
 *   Every typed [HostRunEventFrame] is mapped to a bounded JSON object that
 *   keeps `runID`, `sequence`, `kind`, `payload` and `bytes` losslessly.
 * * live content is NEVER projected from the unsequenced `live` mirror. The
 *   native `onLiveHint` (and the typed durable-resync signal) coalesce into at
 *   most ONE in-flight canonical `run.snapshot` read per run, with one bounded
 *   dirty follow-up. The snapshot page is delivered as a synthetic
 *   [FRAME_SNAPSHOT] frame and is the authoritative text source.
 * * `awaitTerminal` completes exactly once for a durable terminal frame, an
 *   authoritative terminal snapshot, or a typed pump failure / Superseded.
 *   A local detach only closes this subscription; it never cancels the run and
 *   never completes a turn by itself.
 * * every callback is fenced on the exact (taskID, runID, opened root epoch);
 *   a stale generation drops the callback and settles the UI honestly.
 *
 * No call to `run.cancel`/`assistant.cancel` exists here: a dead pump or a
 * root generation change is a settled OBSERVATION, never a fabricated native
 * cancellation.
 */
internal class HostNotesAssistantRunStreamFactory(
    private val client: RuntimeHostCommandClient,
    private val scope: CoroutineScope,
    private val epochProvider: () -> Long,
    private val budgets: NotesRunStreamBudgets = NotesRunStreamBudgets(),
) : NotesAssistantRunStreamFactory {

    private val runs = ConcurrentHashMap<String, RunStreamRecord>()

    override fun open(
        taskID: String,
        runID: String,
        onFrame: (JsonObject) -> Unit,
        onFailure: (String) -> Unit,
    ): () -> Unit {
        val record = RunStreamRecord(
            taskID = taskID,
            runID = runID,
            openedEpoch = currentEpoch(),
            onFrame = onFrame,
            onFailure = onFailure,
        )
        // Bound the map from the owner side; a re-open of the same durable run
        // first settles the previous local observation.
        runs.put(runID, record)?.let { previous ->
            previous.settlementQueued.set(true)
            previous.settled.set(true)
            previous.channel.trySend(Delivery.Complete)
            previous.pump?.close()
        }
        trimTrackedRuns(keep = record)
        record.worker = scope.launch { consume(record) }
        if (record.openedEpoch <= 0L) {
            settleFailure(record, "runtimeUnavailable")
            return { detach(record) }
        }
        val handle = try {
            client.openRunEventStream(
                taskID = taskID,
                runID = runID,
                environmentID = null,
                jobID = null,
                onEvent = { frame -> onDurableFrame(record, frame) },
                onLiveHint = { onDirtyHint(record) },
                onFailure = { failure -> onPumpFailure(record, failure) },
                // The typed degraded-window signal is a read trigger, never
                // text and never a second poll loop. Passing it also marks
                // this stream as a queue observer for the documented
                // notAttached opt-out: a just-committed Notes run window is
                // tolerated instead of being declared an observation failure
                // after a count cutoff.
                onDurableResync = { onDurableResync(record) },
            )
        } catch (_: Throwable) {
            settleFailure(record, "streamUnavailable")
            return { detach(record) }
        }
        record.pump = handle
        // A synchronous fast callback may have settled before the handle was
        // stored; never leave that pump running.
        if (record.settlementQueued.get()) handle.close()
        return { detach(record) }
    }

    override suspend fun awaitTerminal(runID: String) {
        // An unknown/detached run is already past observation: returning is
        // the only honest answer (never fabricate a terminal).
        runs[runID]?.terminal?.await()
    }

    /** Test/owner visibility: no record may survive its detach. */
    internal fun trackedRunCount(): Int = runs.size

    // ------------------------------------------------------------ pump input

    private fun onDurableFrame(record: RunStreamRecord, frame: HostRunEventFrame) {
        if (!epochValid(record)) {
            settleFailure(record, "superseded")
            return
        }
        if (record.settled.get()) return
        record.channel.trySend(Delivery.Frame(frame.toNotesJson()))
        if (isTerminalFrame(frame)) settle(record)
    }

    private fun onDirtyHint(record: RunStreamRecord) {
        if (!epochValid(record)) {
            settleFailure(record, "superseded")
            return
        }
        if (record.settled.get()) return
        record.dirty.set(true)
        maybeStartSnapshot(record, force = false)
    }

    private fun onDurableResync(record: RunStreamRecord) {
        if (!epochValid(record)) {
            settleFailure(record, "superseded")
            return
        }
        if (record.settled.get()) return
        record.dirty.set(true)
        maybeStartSnapshot(record, force = true)
    }

    private fun onPumpFailure(record: RunStreamRecord, failure: HostPumpFailure) {
        if (!epochValid(record)) {
            settleFailure(record, "superseded")
            return
        }
        if (record.settled.get()) return
        when (failure) {
            HostPumpFailure.Superseded -> settleFailure(record, "superseded")
            is HostPumpFailure.Recoverable -> probeAfterPumpDeath(record, failure.code)
        }
    }

    /**
     * A dead pump is a settled observation, but the run itself is not
     * cancelled. One authoritative snapshot answers the real terminal (a fast
     * run can finish before its durable terminal frame is consumed); when it
     * is non-terminal or unreadable the UI settles with the typed pump code.
     */
    private fun probeAfterPumpDeath(record: RunStreamRecord, code: String) {
        if (!record.pumpDead.compareAndSet(false, true)) return
        if (!record.probeInFlight.compareAndSet(false, true)) return
        scope.launch {
            val result = readSnapshot(record)
            record.probeInFlight.set(false)
            if (record.settled.get()) return@launch
            when (result) {
                is SnapshotRead.Page -> {
                    deliverSnapshot(record, result.page)
                    if (!record.settled.get()) settleFailure(record, code)
                }
                is SnapshotRead.Refused, SnapshotRead.Timeout ->
                    settleFailure(record, code)
                SnapshotRead.Superseded -> settleFailure(record, "superseded")
            }
        }
    }

    // --------------------------------------------------------- live coalesce

    private fun maybeStartSnapshot(record: RunStreamRecord, force: Boolean) {
        if (record.settled.get() || !epochValid(record)) return
        if (record.snapshotInFlight.get()) return
        val interval = budgets.minSnapshotIntervalMillis
        if (!force) {
            val elapsed = System.currentTimeMillis() - record.lastStartedAtMillis.get()
            if (elapsed in 0L until interval) {
                scheduleFollowUp(record, interval - elapsed)
                return
            }
        }
        if (!record.snapshotInFlight.compareAndSet(false, true)) return
        // A concurrent consumer may have cleared the dirty flag; the read is
        // still authoritative for the current turn.
        record.dirty.compareAndSet(true, false)
        record.lastStartedAtMillis.set(System.currentTimeMillis())
        scope.launch {
            val result = readSnapshot(record)
            record.snapshotInFlight.set(false)
            if (record.settled.get()) return@launch
            when (result) {
                is SnapshotRead.Page -> {
                    deliverSnapshot(record, result.page)
                    if (record.dirty.get()) scheduleFollowUp(record, interval)
                }
                is SnapshotRead.Refused -> {
                    // Keep the hint dirty for the NEXT real hint. Never start
                    // an automatic retry loop here.
                    record.dirty.set(true)
                }
                SnapshotRead.Superseded -> settleFailure(record, "superseded")
                SnapshotRead.Timeout -> record.dirty.set(true)
            }
        }
    }

    private fun scheduleFollowUp(record: RunStreamRecord, waitMillis: Long) {
        if (!record.followUpScheduled.compareAndSet(false, true)) return
        scope.launch {
            try {
                delay(waitMillis.coerceAtLeast(1L))
            } finally {
                record.followUpScheduled.set(false)
            }
            if (record.dirty.get()) maybeStartSnapshot(record, force = false)
        }
    }

    // -------------------------------------------------- canonical snapshot

    private fun deliverSnapshot(record: RunStreamRecord, page: JsonObject) {
        if (!epochValid(record)) {
            settleFailure(record, "superseded")
            return
        }
        if (record.settled.get()) return
        val pageRunID = page.string("runID") ?: return
        if (!sameUUID(pageRunID, record.runID)) return
        val frame = buildJsonObject {
            put("runID", record.runID)
            put("sequence", page.long("durableWatermark") ?: 0L)
            put("kind", FRAME_SNAPSHOT)
            put("payload", page)
            put("bytes", page.toString().toByteArray(Charsets.UTF_8).size)
        }
        record.channel.trySend(Delivery.Frame(frame))
        if (page.isTerminalPage()) settle(record)
    }

    /**
     * One canonical `run.snapshot` read over the SAME client. The command is
     * the existing taskExecution `run.snapshot` (no new wire action, no
     * purpose relaxation): the native domain serves the run's OWN stores and
     * refuses a foreign/missing run before any text is returned.
     */
    private suspend fun readSnapshot(record: RunStreamRecord): SnapshotRead {
        val correlation = client.correlationID("notesnap")
        val request = HostCommandRequest(
            command = "run.snapshot",
            scope = HostScope.TaskExecution(record.taskID, record.runID),
            stateful = false,
            correlationID = correlation,
        )
        val receipt = when (val submitted = client.submit(request)) {
            is HostSubmitResult.Accepted -> submitted.operationReceiptID
            is HostSubmitResult.Rejected -> {
                client.closeCorrelation(correlation)
                return SnapshotRead.Refused(submitted.reason)
            }
            HostSubmitResult.Superseded -> {
                client.closeCorrelation(correlation)
                return SnapshotRead.Superseded
            }
        }
        val terminal = CompletableDeferred<SnapshotRead>()
        val handle = client.openEffectStream(
            operationReceiptID = receipt,
            configurationScope = "system",
            onFrame = {},
            onTerminal = { value -> terminal.complete(value.toSnapshotRead()) },
            onFailure = { failure ->
                terminal.complete(when (failure) {
                    is HostPumpFailure.Recoverable -> SnapshotRead.Refused(failure.code)
                    HostPumpFailure.Superseded -> SnapshotRead.Superseded
                })
            },
        )
        return try {
            withTimeoutOrNull(budgets.snapshotTimeoutMillis) { terminal.await() }
                ?: SnapshotRead.Timeout
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            handle.close()
            client.closeCorrelation(correlation)
        }
    }

    private fun HostEffectTerminal.toSnapshotRead(): SnapshotRead = when (this) {
        is HostEffectTerminal.Completed -> {
            val page = value as? JsonObject
            if (page == null) SnapshotRead.Refused("snapshotUnavailable")
            else SnapshotRead.Page(page)
        }
        is HostEffectTerminal.Rejected -> SnapshotRead.Refused(code.ifBlank { "snapshotRefused" })
        is HostEffectTerminal.Failed -> SnapshotRead.Refused(code.ifBlank { "snapshotFailed" })
        is HostEffectTerminal.Cancelled -> SnapshotRead.Refused("snapshotCancelled")
        is HostEffectTerminal.Closed -> SnapshotRead.Refused("snapshotClosed")
        is HostEffectTerminal.Replaced -> SnapshotRead.Superseded
    }

    // ------------------------------------------------------------- settle

    private fun settle(record: RunStreamRecord) {
        if (!record.settlementQueued.compareAndSet(false, true)) return
        record.settled.set(true)
        record.channel.trySend(Delivery.Complete)
        record.pump?.close()
    }

    private fun settleFailure(record: RunStreamRecord, code: String) {
        if (!record.settlementQueued.compareAndSet(false, true)) return
        record.settled.set(true)
        record.channel.trySend(Delivery.Failure(code))
        record.channel.trySend(Delivery.Complete)
        record.pump?.close()
    }

    /** Serial frame/failure delivery; the terminal completes after the frame. */
    private suspend fun consume(record: RunStreamRecord) {
        try {
            for (delivery in record.channel) {
                when (delivery) {
                    is Delivery.Frame -> runCatching { record.onFrame(delivery.json) }
                    is Delivery.Failure -> runCatching { record.onFailure(delivery.code) }
                    Delivery.Complete -> {
                        record.terminal.complete(Unit)
                        return
                    }
                }
            }
        } finally {
            // A cancelled/closed worker must not leave a host awaiting a
            // deferred forever when the owner already tore the scope down.
            if (record.settlementQueued.get()) record.terminal.complete(Unit)
        }
    }

    private fun detach(record: RunStreamRecord) {
        if (!record.detached.compareAndSet(false, true)) return
        // Detach only: the native run keeps running. Closing the channel lets
        // the worker drain already-delivered frames, then exit.
        record.pump?.close()
        record.channel.close()
        runs.remove(record.runID, record)
    }

    private fun trimTrackedRuns(keep: RunStreamRecord) {
        if (runs.size <= budgets.maxTrackedRuns) return
        val victims = runs.values
            .filter { it !== keep && it.settled.get() }
            .sortedBy { it.openedAtMillis }
            .take(runs.size - budgets.maxTrackedRuns)
        for (victim in victims) {
            victim.channel.close()
            victim.pump?.close()
            runs.remove(victim.runID, victim)
        }
    }

    // --------------------------------------------------------------- fence

    private fun currentEpoch(): Long =
        runCatching { epochProvider() }.getOrDefault(0L).let { if (it > 0L) it else 0L }

    private fun epochValid(record: RunStreamRecord): Boolean =
        record.openedEpoch > 0L && currentEpoch() == record.openedEpoch

    private fun isTerminalFrame(frame: HostRunEventFrame): Boolean =
        frame.kind == "terminal" ||
            (frame.kind == "status" &&
                frame.payload?.string("state")?.let { it in TERMINAL_STATES } == true)

    private fun HostRunEventFrame.toNotesJson(): JsonObject = buildJsonObject {
        put("runID", runID)
        put("sequence", sequence)
        put("kind", kind)
        put("payload", payload ?: JsonNull)
        put("bytes", bytes)
    }

    private fun JsonObject.isTerminalPage(): Boolean {
        if (bool("isTerminal") == true) return true
        val state = string("durableState") ?: return false
        return state in TERMINAL_STATES
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun sameUUID(left: String, right: String): Boolean {
        val a = runCatching { java.util.UUID.fromString(left) }.getOrNull() ?: return false
        val b = runCatching { java.util.UUID.fromString(right) }.getOrNull() ?: return false
        return a == b
    }

    private sealed interface Delivery {
        data class Frame(val json: JsonObject) : Delivery
        data class Failure(val code: String) : Delivery
        data object Complete : Delivery
    }

    private sealed interface SnapshotRead {
        data class Page(val page: JsonObject) : SnapshotRead
        data class Refused(val code: String) : SnapshotRead
        data object Superseded : SnapshotRead
        data object Timeout : SnapshotRead
    }

    private class RunStreamRecord(
        val taskID: String,
        val runID: String,
        val openedEpoch: Long,
        val onFrame: (JsonObject) -> Unit,
        val onFailure: (String) -> Unit,
        val openedAtMillis: Long = System.currentTimeMillis(),
    ) {
        val terminal = CompletableDeferred<Unit>()
        val settled = AtomicBoolean(false)
        val settlementQueued = AtomicBoolean(false)
        val detached = AtomicBoolean(false)
        val pumpDead = AtomicBoolean(false)
        val snapshotInFlight = AtomicBoolean(false)
        val probeInFlight = AtomicBoolean(false)
        val dirty = AtomicBoolean(false)
        val followUpScheduled = AtomicBoolean(false)
        val lastStartedAtMillis = AtomicLong(0L)
        val channel = Channel<Delivery>(Channel.UNLIMITED)
        @Volatile var worker: Job? = null
        @Volatile var pump: EventPumpHandle? = null
    }

    companion object {
        /** Synthetic frame kind carrying one canonical `run.snapshot` page. */
        internal const val FRAME_SNAPSHOT = "snapshot"

        private val TERMINAL_STATES = setOf(
            "completed", "failed", "checkpointed", "idle", "cancelled", "canceled",
        )
    }
}

/** Bounded timing/record caps for the App Notes stream adapter. */
internal data class NotesRunStreamBudgets(
    /** A dead pump's one authoritative terminal probe. */
    val snapshotTimeoutMillis: Long = 8_000L,
    /** Minimum spacing between live-hint snapshot reads (no token storm). */
    val minSnapshotIntervalMillis: Long = 40L,
    /** Retained local observation records (removed on detach anyway). */
    val maxTrackedRuns: Int = 32,
)

/**
 * The EXACT App assembly Main needs for the Notes assistant.
 *
 * It reuses the Application's existing [notesHost] (the real `NotesHostService`
 * v4 channel) and the existing `runtimeHost.commandClient` (the one run-event
 * pump). No second client, no fake command port, no `onLiveHint = {}`.
 *
 * ```kotlin
 * private val notesAssistant: NotesAssistantHost by lazy {
 *     notesAssistantHost(
 *         notesHost = notesHost,
 *         commandClient = runtimeHost.commandClient,
 *         hostScope = hostScope,
 *         epochProvider = { runtimeHost.nativeRootEpoch()?.takeIf { it > 0L } ?: 0L },
 *     )
 * }
 * ```
 */
fun notesAssistantHost(
    notesHost: NotesHostController,
    commandClient: RuntimeHostCommandClient,
    hostScope: CoroutineScope,
    epochProvider: () -> Long,
): NotesAssistantHost = NotesAssistantHost(
    commands = NotesAssistantCommandPort { action, payload ->
        notesHost.commandObject(action, payload)
    },
    runs = HostNotesAssistantRunStreamFactory(commandClient, hostScope, epochProvider),
    scope = hostScope,
    epochProvider = epochProvider,
)

/**
 * Test/alternate-owner overload: the same concrete stream factory over an
 * explicit closed command port. Production Apps use the overload above.
 */
fun notesAssistantHost(
    commands: NotesAssistantCommandPort,
    commandClient: RuntimeHostCommandClient,
    hostScope: CoroutineScope,
    epochProvider: () -> Long,
): NotesAssistantHost = NotesAssistantHost(
    commands = commands,
    runs = HostNotesAssistantRunStreamFactory(commandClient, hostScope, epochProvider),
    scope = hostScope,
    epochProvider = epochProvider,
)
