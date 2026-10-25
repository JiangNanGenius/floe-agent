// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.SwiftCore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Application-owned v3 command client and bounded effect/event pumps.
 *
 * This is the single App-side authority that turns feature-component
 * callbacks into canonical `floe.command-envelope/3` operations and turns the
 * async `floe.effect-cursor/3` / `floe.event-cursor/3` channels back into
 * immutable typed projections. It owns NO business state of its own: it
 * correlates, decodes, budgets and fences; the domain host controllers own
 * projections and admission.
 *
 * Wire authority: `BridgeV3Contracts.kt` (frozen 84-entry matrix after the
 * accepted rev3 settings extension), `BridgeEnvelopeV2.kt`,
 * `SettingsDomainV1.kt`, `RuntimeContracts.kt`, plus the Main RB1 typed
 * page/value carrier decision
 * (`RB1_TYPED_RESULT_CARRIER_MAIN_DECISION_20261019.json`). The typed
 * carrier is consumed here as OPTIONAL typed fields on the existing effect /
 * result model — see [HostTypedFrame] and the HANDOFF "typed adaptation
 * delta". Detail maps stay identifier/reason-only; no page is ever smuggled
 * through string detail, and no secret, raw path or raw exception text ever
 * enters a diagnostic.
 *
 * Threading contract (RB1 + gateway rev4 startup rules):
 *  * the client is constructed on the Application owner and only ever calls
 *    [SwiftCore.exchange] from the supplied background dispatcher — never
 *    from the main thread and never from a Composable;
 *  * all public projection surfaces are immutable snapshots carried by
 *    [StateFlow]; Composables only observe;
 *  * collectors are generation-fenced: when the owning host generation
 *    changes (owner stop/rebind), matching pumps dispose themselves and
 *    ignore foreign replies.
 *
 * Delivery/ack rule (RB1 decision 3): a frame is ACKed (cursor advanced)
 * only after it fully decoded within the measured budgets; a failed decode
 * or an over-budget frame never advances the cursor and surfaces a typed
 * recoverable error instead.
 */
class RuntimeHostCommandClient internal constructor(
    private val exchange: HostBridgeExchange,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val clock: () -> Long = { System.nanoTime() },
    private val diagnostics: (String) -> Unit = {},
    internal val budgets: HostWireBudgets = HostWireBudgets(),
    private val correlationSource: AtomicLong = AtomicLong(0),
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = false }

    /** Current host generation; pumps and pending correlations fence on it. */
    private val generation = MutableStateFlow(0L)
    private val stateLock = Any()
    private var currentGeneration: Long = 0

    private val pendingCorrelations = ConcurrentHashMap<String, PendingCorrelation>()

    /** One pump per polled operation receipt (effects) or run (events). */
    private val effectPumps = ConcurrentHashMap<String, EffectPumpHandle>()
    private val eventPumps = ConcurrentHashMap<String, EventPumpHandle>()

    fun bumpGeneration() {
        synchronized(stateLock) {
            currentGeneration += 1
            generation.value = currentGeneration
        }
        // Dispose matching collectors only; foreign replies were never ours.
        effectPumps.values.forEach { it.disposeIfGeneration(currentGeneration) }
        eventPumps.values.forEach { it.disposeIfGeneration(currentGeneration) }
    }

    fun generation(): Long = generation.value

    // ---------------------------------------------------------------- submit

    /**
     * Submit one matrix-closed command envelope. Returns the typed queue
     * receipt on admission; the caller learns outcomes exclusively through
     * the async effect channel (see [openEffectStream]).
     */
    suspend fun submit(request: HostCommandRequest): HostSubmitResult {
        HostCommandValidator.validate(request)?.let { return HostSubmitResult.Rejected(it) }
        val envelope = buildCommandEnvelope(request)
        val utf8 = envelope.toByteArray(Charsets.UTF_8)
        if (utf8.size > budgets.maxFrameBytes) {
            return HostSubmitResult.Rejected("frameBudgetExceeded")
        }
        val raw = try {
            withDispatcher { exchange.exchange(envelope) }
        } catch (c: CancellationException) {
            return HostSubmitResult.Superseded
        } catch (t: Throwable) {
            return HostSubmitResult.Rejected("exchangeUnavailable")
        }
        val utf8Out = raw.toByteArray(Charsets.UTF_8)
        if (utf8Out.size > budgets.maxFrameBytes) {
            return HostSubmitResult.Rejected("responseBudgetExceeded")
        }
        return when (val parsed = parseQueueReceipt(raw, request.correlationID)) {
            is QueueReceipt.Accepted -> {
                pendingCorrelations[request.correlationID] = PendingCorrelation(
                    correlationID = request.correlationID,
                    operationReceiptID = parsed.operationReceiptID,
                    command = request.command,
                    configurationScope = request.configurationScope,
                    submittedAtNanos = clock(),
                )
                HostSubmitResult.Accepted(parsed.operationReceiptID)
            }
            is QueueReceipt.Refused -> HostSubmitResult.Rejected(parsed.code)
            QueueReceipt.Malformed -> HostSubmitResult.Rejected("queueReceiptMalformed")
            QueueReceipt.Superseded -> HostSubmitResult.Superseded
        }
    }

    /** Forget a correlation when its terminal arrived or it was canceled. */
    fun closeCorrelation(correlationID: String) {
        pendingCorrelations.remove(correlationID)
    }

    /** True when this client admitted the correlation (foreign replies no-op). */
    fun ownsCorrelation(correlationID: String): Boolean =
        pendingCorrelations.containsKey(correlationID)

    private suspend fun <T> withDispatcher(block: suspend () -> T): T =
        kotlinx.coroutines.withContext(ioDispatcher) { block() }

    /**
     * Builds the EXACT v3 `command.submit` request accepted by the frozen
     * native `BridgeEnvelopeV3`:
     *
     * ```
     * {"version":3,"operation":"command.submit","requestID":<correlation>,
     *  "envelope":{"schema":"floe.command-envelope/3",
     *              "scope":"<string label>",
     *              "configurationScope":"<label>" | "owner":{...},
     *              "command":..., "stateful":..., "revision":...,
     *              "createIntent":..., "payload":...,
     *              "correlationID":<correlation>}}
     * ```
     *
     * The INNER envelope is the frozen `floe.command-envelope/3` document;
     * the outer object is the v3 operation envelope. The native validator
     * reads `scope` as a STRING and the semantic roles (`taskID`/`runID`/
     * `environmentID`/`jobID`) under `owner`; it rejects `version` inside the
     * inner envelope as an unknown field. Sending the bare inner object (the
     * pre-fix shape) reaches `BridgeV3.handle` with no `operation` and answers
     * `unsupportedOperation` — the exact defect this function repairs.
     */
    private fun buildCommandEnvelope(request: HostCommandRequest): String {
        val inner = linkedMapOf<String, JsonElement>()
        inner["schema"] = JsonPrimitive(HOST_COMMAND_SCHEMA)
        val scopeLabel: String
        when (val scope = request.scope) {
            is HostScope.ApplicationConfiguration -> {
                scopeLabel = "applicationConfiguration"
                inner["configurationScope"] = JsonPrimitive(scope.configurationScope)
            }
            is HostScope.ConversationLifecycle -> {
                scopeLabel = "conversationLifecycle"
                inner["owner"] = JsonObject(mapOf(
                    "taskID" to JsonPrimitive(scope.taskID),
                ))
            }
            is HostScope.LaunchExisting -> {
                scopeLabel = "launch"
                inner["owner"] = JsonObject(mapOf(
                    "taskID" to JsonPrimitive(scope.taskID),
                ))
            }
            HostScope.LaunchNewIdentity -> {
                // A new identity carries NO owner; the explicit create intent
                // is the only way the frozen validator accepts it.
                scopeLabel = "launch"
            }
            is HostScope.TaskExecution -> {
                scopeLabel = "taskExecution"
                val owner = linkedMapOf<String, JsonElement>(
                    "taskID" to JsonPrimitive(scope.taskID),
                    "runID" to JsonPrimitive(scope.runID),
                )
                scope.environmentID?.let { owner["environmentID"] = JsonPrimitive(it) }
                scope.jobID?.let { owner["jobID"] = JsonPrimitive(it) }
                inner["owner"] = JsonObject(owner)
            }
        }
        inner["scope"] = JsonPrimitive(scopeLabel)
        inner["command"] = JsonPrimitive(request.command)
        inner["stateful"] = JsonPrimitive(request.stateful)
        inner["correlationID"] = JsonPrimitive(request.correlationID)
        if (request.revision != null) {
            inner["revision"] = JsonObject(mapOf(
                "resourceID" to JsonPrimitive(request.revision.resourceID),
                "version" to JsonPrimitive(request.revision.version),
            ))
        }
        if (request.createIntent) {
            inner["createIntent"] = JsonPrimitive(true)
        }
        if (request.payload != null) {
            inner["payload"] = request.payload
        }
        return JsonObject(linkedMapOf(
            "version" to JsonPrimitive(3),
            "operation" to JsonPrimitive(HOST_COMMAND_OPERATION),
            "requestID" to JsonPrimitive(request.correlationID),
            "envelope" to JsonObject(inner),
        )).toString()
    }

    /** Exposed for pump handles; same background dispatcher contract. */
    internal fun ioDispatcherForTests(): CoroutineDispatcher = ioDispatcher

    /** Synchronous exchange on the pump's background context. */
    internal fun exchangeForPump(request: String): String = exchange.exchange(request)

    private sealed interface QueueReceipt {
        data class Accepted(val operationReceiptID: String) : QueueReceipt
        data class Refused(val code: String, val reason: String?) : QueueReceipt
        data object Malformed : QueueReceipt
        data object Superseded : QueueReceipt
    }

    private fun parseQueueReceipt(raw: String, expectedCorrelation: String): QueueReceipt {
        val root = parseObject(raw) ?: return QueueReceipt.Malformed
        if (root.stringStrict("correlationID") != expectedCorrelation) return QueueReceipt.Malformed
        if (root.longStrict("version") != 3L) return QueueReceipt.Malformed
        val ok = root.boolStrict("ok") ?: return QueueReceipt.Malformed
        if (!ok) {
            // A structurally valid TYPED refusal (runtimeUnavailable /
            // bootstrapNotInstalled / invalidEnvelope / ...) is NOT a
            // malformed receipt: surface its typed code so the caller can
            // gate/retry honestly instead of reporting a wire defect.
            val code = root.stringStrict("error") ?: return QueueReceipt.Malformed
            val reason = root.stringStrict("reason")
            return QueueReceipt.Refused(code, reason)
        }
        if (root.boolStrict("queued") != true) return QueueReceipt.Malformed
        val receipt = root.stringStrict("operationReceiptID") ?: return QueueReceipt.Malformed
        if (!isOpaqueReceipt(receipt)) return QueueReceipt.Malformed
        return QueueReceipt.Accepted(receipt)
    }

    // ------------------------------------------------------------ effect pump

    /**
     * Open a bounded effect stream for [operationReceiptID]. [onFrame] is
     * invoked for every ACKed frame; [onTerminal] exactly once for the
     * operation terminal; [onFailure] for typed recoverable failures.
     * The pump self-disposes on terminal, on generation change, or when
     * [EffectPumpHandle.close] is called.
     */
    fun openEffectStream(
        operationReceiptID: String,
        configurationScope: String,
        onFrame: (HostEffectFrame) -> Unit,
        onTerminal: (HostEffectTerminal) -> Unit,
        onFailure: (HostPumpFailure) -> Unit,
    ): EffectPumpHandle {
        val gen = generation()
        val handle = EffectPumpHandle(
            client = this,
            operationReceiptID = operationReceiptID,
            configurationScope = configurationScope,
            generationAtOpen = gen,
            onFrame = onFrame,
            onTerminal = onTerminal,
            onFailure = onFailure,
        )
        effectPumps[operationReceiptID] = handle
        handle.job = scope.launch(ioDispatcher) { handle.run() }
        return handle
    }

    internal fun removeEffectPump(receipt: String, handle: EffectPumpHandle) {
        effectPumps.remove(receipt, handle)
    }

    internal fun removeEventPump(runID: String, handle: EventPumpHandle) {
        eventPumps.remove(runID, handle)
    }

    // ------------------------------------------------------------- event pump

    /**
     * Open a bounded run-event stream. Events are durable run facts
     * (`floe.event-cursor/3`); they are distinct from operation effects and
     * never ack an operation cursor.
     */
    fun openRunEventStream(
        taskID: String,
        runID: String,
        environmentID: String?,
        jobID: String?,
        onEvent: (HostRunEventFrame) -> Unit,
        onLiveHint: () -> Unit,
        onFailure: (HostPumpFailure) -> Unit,
        startSequence: Long = 0L,
        /** Typed durable-resync signal (C09 QREV-03): the native window could
         *  NOT verify its durable tail against the journal (a degraded
         *  queue-settle publication, carried on the EXISTING frozen
         *  `resyncRequired` member — no schema change). The owner reconciles
         *  from authoritative pages; the pump keeps delivering the frames of
         *  the same page FIRST, then signals once per page.
         *
         *  MAIN_ADDENDUM B — queue-watcher-only notAttached opt-out: opening a
         *  durable-resync consumer is what marks this stream as a QUEUE
         *  OBSERVER (the only consumer of the member today; the ordinary run
         *  pump passes no callback). A queue observer legitimately watches a
         *  EVICTED or never-refreshed retired window, so the legacy
         *  `notAttached` COUNT cutoff (~10 s) is skipped FOR THIS STREAM ONLY
         *  and must never be presented as observation failure. Ordinary pumps
         *  keep the baseline limit byte-identically (HostEventPumpTest
         *  timeout expectations unchanged), and lifecycle (Superseded),
         *  `runGone`, exchange-throw and decode-failure streaks still
         *  terminate observation exactly as before.
         *
         *  Default null ⇒ every existing call site and positional test call
         *  compiles and behaves byte-for-byte as before. */
        onDurableResync: (() -> Unit)? = null,
    ): EventPumpHandle {
        val gen = generation()
        val handle = EventPumpHandle(
            client = this,
            taskID = taskID,
            runID = runID,
            environmentID = environmentID,
            jobID = jobID,
            generationAtOpen = gen,
            onEvent = onEvent,
            onLiveHint = onLiveHint,
            onFailure = onFailure,
            initialSequence = startSequence,
            onDurableResync = onDurableResync,
        )
        eventPumps[runID] = handle
        handle.job = scope.launch(ioDispatcher) { handle.run() }
        return handle
    }

    /** Test/owner visibility; production code must not fan out on this. */
    internal fun activePumpCounts(): Pair<Int, Int> =
        effectPumps.size to eventPumps.size

    // --------------------------------------------------------- shared decode

    internal fun parseObject(raw: String): JsonObject? = parseJsonObject(json, raw)

    internal fun isOpaqueReceipt(value: String): Boolean =
        value.isNotBlank() && value.length <= budgets.maxReceiptCharacters &&
            value.none { it.isISOControl() }

    internal fun correlationID(prefix: String): String {
        val n = correlationSource.incrementAndGet()
        return "$prefix-$n"
    }

    companion object {
        const val HOST_COMMAND_OPERATION = "command.submit"
        const val HOST_EFFECT_OPERATION = "effect.poll"
        const val HOST_EVENT_OPERATION = "event.poll"
        const val HOST_COMMAND_SCHEMA = "floe.command-envelope/3"
        const val HOST_EFFECT_SCHEMA = "floe.effect-cursor/3"
        const val HOST_RUN_EVENT_SCHEMA = "floe.event-cursor/3"

        fun system(): RuntimeHostCommandClient = RuntimeHostCommandClient(
            exchange = object : HostBridgeExchange {
                override fun exchange(request: String): String = SwiftCore.exchange(request)
            },
            scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + DispatchersCompat.default()),
            ioDispatcher = DispatchersCompat.io(),
            diagnostics = { code -> android.util.Log.e("FloeRuntimeHost", code) },
        )
    }
}

/** Budgets mirror the frozen bridge bound and the RB1 typed-carrier decision. */
data class HostWireBudgets(
    val maxFrameBytes: Int = 65_536,
    val maxPageBytes: Int = 48 * 1024,
    val maxChunkBytes: Int = 32 * 768,
    val maxEffectItemsPerPage: Int = 64,
    val maxRunEventsPerPage: Int = 200,
    val maxReceiptCharacters: Int = 256,
    val effectPollIntervalMillis: Long = 50,
    /** Global per-pump-tick byte ceiling across all receipts (no GB ring). */
    val globalPumpBudgetBytes: Int = 256 * 1024,
    val resyncStreakLimit: Int = 3,
)

object DispatchersCompat {
    fun io(): CoroutineDispatcher = kotlinx.coroutines.Dispatchers.IO
    fun default(): CoroutineDispatcher = kotlinx.coroutines.Dispatchers.Default
}

interface HostBridgeExchange {
    fun exchange(request: String): String
}

/**
 * Structural validation of a host command against the frozen
 * [com.floe.android.contracts.BridgeV3CommandMatrix]. The Kotlin contract
 * projection is the shared authority; the host never widens authority by
 * presenting a command under another scope or label. This validator mirrors
 * the rules of `BridgeV3CommandEnvelope` but reports typed failures instead
 * of throwing, so a UI callback can honestly decline.
 */
object HostCommandValidator {
    fun validate(request: HostCommandRequest): String? {
        val scopeKind = when (request.scope) {
            is HostScope.ApplicationConfiguration ->
                com.floe.android.contracts.BridgeV3Scope.Kind.APPLICATION_CONFIGURATION
            is HostScope.ConversationLifecycle ->
                com.floe.android.contracts.BridgeV3Scope.Kind.CONVERSATION_LIFECYCLE
            is HostScope.LaunchExisting, HostScope.LaunchNewIdentity ->
                com.floe.android.contracts.BridgeV3Scope.Kind.LAUNCH
            is HostScope.TaskExecution ->
                com.floe.android.contracts.BridgeV3Scope.Kind.TASK_EXECUTION
        }
        val configurationScope = request.configurationScope
        val entry = com.floe.android.contracts.BridgeV3CommandMatrix
            .ENTRIES.firstOrNull {
                it.command == request.command && it.scope == scopeKind &&
                    (scopeKind != com.floe.android.contracts.BridgeV3Scope.Kind.APPLICATION_CONFIGURATION ||
                        it.configurationScope == configurationScope)
            }
            ?: return "unknownCommandInScope"
        if (entry.isRunEventPoll) return "eventPollUsesEventChannel"
        val statefulExpected = request.createIntent || entry.revisionRequired
        if (request.stateful != statefulExpected) return "statefulMismatch"
        if (request.createIntent && !entry.allowsCreateIntent) return "createIntentNotAllowed"
        // Scope identity is checked BEFORE the revision matrix: a launch-new-
        // identity envelope without createIntent is fundamentally invalid, so
        // the precise typed reason wins over the generic revision rule.
        when (request.scope) {
            HostScope.LaunchNewIdentity -> if (!request.createIntent) return "newIdentityRequiresCreateIntent"
            is HostScope.LaunchExisting -> if (request.createIntent) return "existingLaunchHasCreateIntent"
            else -> Unit
        }
        if (entry.revisionRequired && !request.createIntent && request.revision == null) {
            return "revisionRequired"
        }
        if (!entry.revisionRequired && request.revision != null) return "revisionNotAllowed"
        if (request.createIntent && request.revision != null) return "revisionForNewIdentity"
        return null
    }
}

// --------------------------------------------------------------- request DTO

sealed interface HostScope {
    data class ApplicationConfiguration(val configurationScope: String) : HostScope
    data class ConversationLifecycle(val taskID: String) : HostScope
    data class LaunchExisting(val taskID: String) : HostScope
    data object LaunchNewIdentity : HostScope
    data class TaskExecution(
        val taskID: String,
        val runID: String,
        val environmentID: String? = null,
        val jobID: String? = null,
    ) : HostScope
}

data class HostRevision(val resourceID: String, val version: String) {
    init {
        require(resourceID.isNotBlank() && resourceID.length <= 256)
        require(version.isNotBlank() && version.length <= 256)
    }
}

data class HostCommandRequest(
    val command: String,
    val scope: HostScope,
    val stateful: Boolean,
    val correlationID: String,
    val revision: HostRevision? = null,
    val createIntent: Boolean = false,
    val payload: JsonObject? = null,
) {
    val configurationScope: String?
        get() = (scope as? HostScope.ApplicationConfiguration)?.configurationScope
}

sealed interface HostSubmitResult {
    data class Accepted(val operationReceiptID: String) : HostSubmitResult
    data class Rejected(val reason: String) : HostSubmitResult
    data object Superseded : HostSubmitResult
}

// ------------------------------------------------------------------ effects

/**
 * One ACKed effect frame. [page] is the OPTIONAL typed page payload and
 * [value] the OPTIONAL typed value/result payload per the RB1 typed-carrier
 * decision (each a JSON object; `pageBytes` measures only the page). They are
 * null for identifier-only frames. [detail] stays a bounded typed map of
 * IDs/reasons. [bytes] counts the complete encoded frame contribution.
 *
 * The temporary navigation acknowledgement is consumed ONLY from
 * `value.navigationFence`; a `page` object with a similar member is never an
 * admission (see `TemporaryNavigationFence`).
 */
data class HostEffectFrame(
    val sequence: Long,
    val kind: String,
    val code: String?,
    val detail: Map<String, String>,
    val page: JsonObject?,
    val pageBytes: Int,
    val bytes: Int,
    /**
     * Typed completed value/result document. The frozen native carrier
     * declares this as a JSON document; list commands
     * (`config.providers.list`, `conversation.list`, ...) legitimately return
     * a JSON ARRAY, so the App keeps the exact element instead of narrowing
     * to an object and rejecting a real success. The temporary-navigation
     * acknowledgement still reads only an OBJECT `navigationFence` member.
     */
    val value: JsonElement? = null,
)

sealed interface HostEffectTerminal {
    data class Completed(val value: JsonElement?, val detail: Map<String, String>) : HostEffectTerminal
    data class Rejected(val code: String, val reason: String, val detail: Map<String, String>) : HostEffectTerminal
    data class Failed(val code: String, val reason: String, val detail: Map<String, String>) : HostEffectTerminal
    data class Cancelled(val detail: Map<String, String>) : HostEffectTerminal
    data class Closed(val detail: Map<String, String>) : HostEffectTerminal
    data class Replaced(val detail: Map<String, String>) : HostEffectTerminal
}

data class HostRunEventFrame(
    val runID: String,
    val sequence: Long,
    val kind: String,
    val payload: JsonObject?,
    val bytes: Int,
)

sealed interface HostPumpFailure {
    data class Recoverable(val code: String, val reason: String) : HostPumpFailure
    data object Superseded : HostPumpFailure
}

internal data class PendingCorrelation(
    val correlationID: String,
    val operationReceiptID: String,
    val command: String,
    val configurationScope: String?,
    val submittedAtNanos: Long,
)

/** Owns one receipt's effect cursor. Advances only on ACKed frames. */
class EffectPumpHandle internal constructor(
    private val client: RuntimeHostCommandClient,
    internal val operationReceiptID: String,
    private val configurationScope: String,
    private val generationAtOpen: Long,
    private val onFrame: (HostEffectFrame) -> Unit,
    private val onTerminal: (HostEffectTerminal) -> Unit,
    private val onFailure: (HostPumpFailure) -> Unit,
) {
    internal var job: Job? = null
    private val disposed = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Exactly ONE terminal/failure notification per pump (a generation bump
     *  reports the typed Superseded signal instead of a silent cancel). */
    private val finished = java.util.concurrent.atomic.AtomicBoolean(false)
    private val cursorMutex = Mutex()
    private var nextSequence = 0L

    fun close() {
        if (disposed.compareAndSet(false, true)) {
            job?.cancel()
            client.removeEffectPump(operationReceiptID, this)
        }
    }

    internal fun disposeIfGeneration(current: Long) {
        if (current != generationAtOpen) {
            if (finished.compareAndSet(false, true)) {
                onFailure(HostPumpFailure.Superseded)
            }
            close()
        }
    }

    internal suspend fun run() {
        var resyncStreak = 0
        try {
            while (!disposed.get()) {
                if (client.generation() != generationAtOpen) {
                    onFailure(HostPumpFailure.Superseded)
                    return
                }
                val correlation = client.correlationID("fx")
                val request = effectPollEnvelope(correlation, operationReceiptID, nextSequence)
                val raw = try {
                    kotlinx.coroutines.withContext(client.ioDispatcherForTests()) {
                        client.exchangeForPump(request)
                    }
                } catch (c: CancellationException) {
                    return
                } catch (t: Throwable) {
                    onFailure(HostPumpFailure.Recoverable("exchangeUnavailable", "exchange"))
                    delay(client.budgets.effectPollIntervalMillis)
                    continue
                }
                val page = decodeEffectPage(raw, correlation, operationReceiptID, nextSequence)
                when (page) {
                    is EffectDecode.FrameBatch -> {
                        var newCursor = nextSequence
                        for (frame in page.frames) {
                            // ACK only after the frame fully decoded in-budget.
                            onFrame(frame)
                            newCursor = frame.sequence
                        }
                        cursorMutex.withLock { nextSequence = page.nextSequence }
                        when (val terminal = page.terminal) {
                            null -> Unit
                            else -> {
                                if (finished.compareAndSet(false, true)) {
                                    onTerminal(terminal)
                                }
                                close()
                                return
                            }
                        }
                        resyncStreak = if (page.resyncRequired) resyncStreak + 1 else 0
                        if (resyncStreak > client.budgets.resyncStreakLimit) {
                            onFailure(HostPumpFailure.Recoverable("effectResync", "resync"))
                            return
                        }
                        if (!page.hasMore || page.frames.isEmpty()) {
                            delay(client.budgets.effectPollIntervalMillis)
                        }
                    }
                    is EffectDecode.Failure -> {
                        when (page.reason) {
                            "effectReceiptNotFound", "effectReceiptExpired" -> {
                                onFailure(HostPumpFailure.Recoverable(page.reason, page.reason))
                                return
                            }
                            else -> {
                                onFailure(HostPumpFailure.Recoverable(sanitize(page.reason), page.reason))
                                delay(client.budgets.effectPollIntervalMillis)
                            }
                        }
                    }
                    EffectDecode.ProtocolMismatch -> {
                        onFailure(HostPumpFailure.Recoverable("effectProtocolMismatch", "protocol"))
                        return
                    }
                    is EffectDecode.OverBudget -> {
                        // Typed recoverable; the cursor does NOT advance past
                        // the offending item — consumer may resync/retry.
                        onFailure(HostPumpFailure.Recoverable("frameBudgetExceeded", page.item))
                        return
                    }
                }
            }
        } finally {
            close()
        }
    }

    private fun effectPollEnvelope(correlation: String, receipt: String, sequence: Long): String {
        val correlationJSON = JsonPrimitive(correlation).toString()
        val receiptJSON = JsonPrimitive(receipt).toString()
        return """{"version":3,"operation":"effect.poll","requestID":$correlationJSON,""" +
            """"envelope":{"schema":"floe.effect-cursor/3","scope":"applicationConfiguration",""" +
            """"configurationScope":${JsonPrimitive(configurationScope)},""" +
            """"command":"effect.poll","stateful":false,""" +
            """"correlationID":$correlationJSON,""" +
            """"effect":{"operationReceiptID":$receiptJSON,"sequence":$sequence}}}"""
    }

    private sealed interface EffectDecode {
        data class FrameBatch(
            val frames: List<HostEffectFrame>,
            val nextSequence: Long,
            val hasMore: Boolean,
            val resyncRequired: Boolean,
            val terminal: HostEffectTerminal?,
        ) : EffectDecode
        data class Failure(val reason: String) : EffectDecode
        data object ProtocolMismatch : EffectDecode
        data class OverBudget(val item: String) : EffectDecode
    }

    private fun decodeEffectPage(
        raw: String,
        expectedCorrelation: String,
        expectedReceipt: String,
        afterSequence: Long,
    ): EffectDecode {
        if (raw.toByteArray(Charsets.UTF_8).size > client.budgets.maxFrameBytes) {
            return EffectDecode.ProtocolMismatch
        }
        val root = client.parseObject(raw) ?: return EffectDecode.ProtocolMismatch
        if (root.longStrict("version") != 3L) return EffectDecode.ProtocolMismatch
        if (root.stringStrict("requestID") != expectedCorrelation) return EffectDecode.ProtocolMismatch
        if (root.boolStrict("ok") == false) {
            val error = root.stringStrict("error") ?: return EffectDecode.ProtocolMismatch
            if (error == "invalidEnvelope") return EffectDecode.ProtocolMismatch
            if (error != "runtimeUnavailable") return EffectDecode.ProtocolMismatch
            return EffectDecode.Failure(root.stringStrict("reason") ?: "runtimeUnavailable")
        }
        if (root.boolStrict("ok") != true) return EffectDecode.ProtocolMismatch
        if (root.stringStrict("schema") != RuntimeHostCommandClient.HOST_EFFECT_SCHEMA) {
            return EffectDecode.ProtocolMismatch
        }
        if (root.stringStrict("correlationID") != expectedCorrelation) return EffectDecode.ProtocolMismatch
        val cursor = root["cursor"] as? JsonObject ?: return EffectDecode.ProtocolMismatch
        if (cursor.stringStrict("operationReceiptID") != expectedReceipt) return EffectDecode.ProtocolMismatch
        val nextSequence = cursor.longStrict("sequence") ?: return EffectDecode.ProtocolMismatch
        if (nextSequence < afterSequence) return EffectDecode.ProtocolMismatch
        val hasMore = root.boolStrict("hasMore") ?: return EffectDecode.ProtocolMismatch
        val resync = root.boolStrict("resyncRequired") ?: return EffectDecode.ProtocolMismatch
        val effects = root["effects"] as? JsonArray ?: return EffectDecode.ProtocolMismatch
        if (effects.size > client.budgets.maxEffectItemsPerPage) return EffectDecode.ProtocolMismatch

        val frames = ArrayList<HostEffectFrame>(effects.size)
        var retainedPageBytes = 0
        var retainedFrameBytes = 0
        var previous = afterSequence
        var terminal: HostEffectTerminal? = null
        var terminalSequence: Long? = null
        for (element in effects) {
            val obj = element as? JsonObject ?: return EffectDecode.ProtocolMismatch
            val sequence = obj.longStrict("sequence") ?: return EffectDecode.ProtocolMismatch
            if (sequence <= previous) return EffectDecode.ProtocolMismatch
            val kind = obj.stringStrict("kind") ?: return EffectDecode.ProtocolMismatch
            if (kind !in EFFECT_KINDS) return EffectDecode.ProtocolMismatch
            val code = if (obj.containsKey("code")) {
                obj.stringStrict("code") ?: return EffectDecode.ProtocolMismatch
            } else null
            val detail = LinkedHashMap<String, String>()
            if (obj.containsKey("detail")) {
                val detailArray = obj["detail"] as? JsonArray ?: return EffectDecode.ProtocolMismatch
                for (entry in detailArray) {
                    val entryObject = entry as? JsonObject ?: return EffectDecode.ProtocolMismatch
                    val key = entryObject.stringStrict("key") ?: return EffectDecode.ProtocolMismatch
                    val value = entryObject.stringStrict("value") ?: return EffectDecode.ProtocolMismatch
                    detail[key] = value
                }
            }
            // Typed carrier: optional page + measured pageBytes. When present,
            // pageBytes must equal the actual encoded size of `page`.
            var page: JsonObject? = null
            var pageBytes = 0
            if (obj.containsKey("page")) {
                val pageElement = obj["page"]
                page = pageElement as? JsonObject ?: return EffectDecode.ProtocolMismatch
                pageBytes = pageElement.toString().toByteArray(Charsets.UTF_8).size
                val declared = obj.longStrict("pageBytes")
                if (declared != null && declared != pageBytes.toLong()) {
                    return EffectDecode.ProtocolMismatch
                }
            } else if (obj.containsKey("pageBytes")) {
                return EffectDecode.ProtocolMismatch
            }
            // Typed value/result payload (RB1 option 2). The temp fence
            // consumes ONLY this member; a generic detail map or page can
            // never prove a navigation fence. The frozen carrier's value is a
            // JSON document: list reads return arrays, mutations return
            // objects. JsonNull is not a value (the native encoder only emits
            // it when its own encoding failed), so it stays a protocol break.
            var value: JsonElement? = null
            if (obj.containsKey("value")) {
                val valueElement = obj["value"]
                if (valueElement is JsonNull) return EffectDecode.ProtocolMismatch
                value = valueElement
                if (obj.containsKey("valueBytes")) {
                    val declaredValueBytes = obj.longStrict("valueBytes")
                        ?: return EffectDecode.ProtocolMismatch
                    if (declaredValueBytes !=
                        valueElement.toString().toByteArray(Charsets.UTF_8).size.toLong()
                    ) {
                        return EffectDecode.ProtocolMismatch
                    }
                }
            } else if (obj.containsKey("valueBytes")) {
                return EffectDecode.ProtocolMismatch
            }
            val bytes = element.toString().toByteArray(Charsets.UTF_8).size
            retainedFrameBytes += bytes
            retainedPageBytes += pageBytes
            previous = sequence
            val frame = HostEffectFrame(
                sequence, kind, code, detail, page, pageBytes, bytes, value)
            frames.add(frame)
            if (kind in TERMINAL_KINDS && terminal == null) {
                terminal = frame.toTerminal()
                // The ACTUAL sequence of the terminal frame: the frozen
                // "no frames after terminal" guard compares against this,
                // never a constant that disables it.
                terminalSequence = sequence
            }
        }
        if (retainedFrameBytes > client.budgets.maxFrameBytes) return EffectDecode.OverBudget("frame")
        if (retainedPageBytes > client.budgets.maxPageBytes) return EffectDecode.OverBudget("page")
        val boundary = terminalSequence
        if (boundary != null &&
            frames.any { it.kind != "resyncRequired" && it.sequence > boundary }
        ) {
            return EffectDecode.ProtocolMismatch
        }
        return EffectDecode.FrameBatch(frames, nextSequence, hasMore, resync, terminal)
    }

    private fun HostEffectFrame.toTerminal(): HostEffectTerminal = when (kind) {
        // The typed value/result payload wins when present; `page` remains
        // the backward-compatible carrier for paged reads.
        "accepted" -> HostEffectTerminal.Completed(value ?: page, detail)
        "rejected" -> HostEffectTerminal.Rejected(domainCode("rejected"), domainReason("rejected"), detail)
        "failed" -> HostEffectTerminal.Failed(domainCode("failed"), domainReason("failed"), detail)
        "cancelled" -> HostEffectTerminal.Cancelled(detail)
        "closed" -> HostEffectTerminal.Closed(detail)
        "replaced" -> HostEffectTerminal.Replaced(detail)
        else -> HostEffectTerminal.Failed("unknown", kind, detail)
    }

    // G02's native binder carries its domain error in detail.wire under the
    // frozen admission code. Preserve that identifier for field errors and
    // recovery; a genuine admission failure without a wire code stays intact.
    private fun HostEffectFrame.domainCode(fallback: String): String {
        val outer = code ?: fallback
        if (outer != "ordinaryRuntimeBlocked") return outer
        return detail["wire"]?.takeIf {
            it.length in 1..128 && it.first().isLetter() &&
                it.all { ch -> ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "_.-" }
        } ?: outer
    }

    // Native domain reasons are identifiers, never provider payloads. Keep
    // them available for recovery without accepting arbitrary diagnostic text.
    private fun HostEffectFrame.domainReason(fallback: String): String {
        val reason = if (code == "ordinaryRuntimeBlocked" && detail["wire"] != null) {
            ((value as? JsonObject)?.get("reason") as? JsonPrimitive)?.contentOrNull
        } else detail["reason"]
        return reason?.takeIf {
            (it.length in 1..128 && it.all { ch ->
                ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "_.-"
            }) || (it.length <= 2048 && it.startsWith("providerValidation[") &&
                it.endsWith("]") && it.all { ch ->
                    ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch in "_.-[]:;"
                })
        } ?: fallback
    }

    private fun sanitize(value: String): String {
        val builder = StringBuilder(minOf(value.length, 48))
        for (char in value) {
            if (builder.length >= 48) break
            if (char.isLetterOrDigit() || char == '_') builder.append(char)
        }
        return if (builder.isEmpty()) "unknown" else builder.toString()
    }

    companion object {
        internal val EFFECT_KINDS = setOf(
            "accepted", "rejected", "failed", "cancelled", "replaced",
            "closed", "resyncRequired", "prepared", "started",
        )
        internal val TERMINAL_KINDS = setOf(
            "accepted", "rejected", "failed", "cancelled", "replaced", "closed",
        )
    }
}

/** Owns one run's durable event cursor. Events are facts, never acked back. */
class EventPumpHandle internal constructor(
    private val client: RuntimeHostCommandClient,
    internal val taskID: String,
    internal val runID: String,
    private val environmentID: String?,
    private val jobID: String?,
    private val generationAtOpen: Long,
    private val onEvent: (HostRunEventFrame) -> Unit,
    /** One coalesced "live content may exist" signal per poll that carried
     *  live frames / an explicit resync. The owner reconciles it through the
     *  canonical `run.snapshot`; this pump never projects live text itself. */
    private val onLiveHint: () -> Unit,
    private val onFailure: (HostPumpFailure) -> Unit,
    initialSequence: Long = 0L,
    /** C09 QREV-03 typed durable-resync consumer (facts first, signal second,
     *  once per delivered page). Its presence is ALSO the MAIN_ADDENDUM B
     *  marker that this stream is a QUEUE OBSERVER: the legacy `notAttached`
     *  COUNT cutoff (~10 s) is skipped for this stream only (an evicted or
     *  never-refreshed retired window is legitimate slow observation, never
     *  an observation failure). Ordinary pumps pass nothing and keep the
     *  baseline cutoff byte-identically; lifecycle (Superseded), `runGone`,
     *  exchange-throw and decode-failure streaks still terminate exactly as
     *  before, and NO timer/idle machinery exists anywhere on either path. */
    private val onDurableResync: (() -> Unit)? = null,
) {
    internal var job: Job? = null
    private val disposed = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Exactly ONE terminal/failure notification per pump (a generation bump
     *  reports the typed Superseded signal instead of a silent cancel). */
    private val finished = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Resume cursor: callers may open after a known durable watermark. */
    private var nextSequence = initialSequence

    fun close() {
        if (disposed.compareAndSet(false, true)) {
            job?.cancel()
            client.removeEventPump(runID, this)
        }
    }

    internal fun disposeIfGeneration(current: Long) {
        if (current != generationAtOpen) {
            if (finished.compareAndSet(false, true)) {
                onFailure(HostPumpFailure.Superseded)
            }
            close()
        }
    }

    internal suspend fun run() {
        // Bounded honesty: a transient failure is retried, but a persistent
        // failure surfaces ONE typed terminal signal to the owner and stops
        // instead of polling forever. `notAttached`/`runGone` are native
        // window facts: `runGone` closes immediately, `notAttached` is
        // tolerated for a bounded number of polls while a just-committed run's
        // window registers, then reported so the owner reconciles by snapshot.
        var consecutiveFailures = 0
        var notAttachedPolls = 0
        try {
            while (!disposed.get()) {
                if (client.generation() != generationAtOpen) {
                    onFailure(HostPumpFailure.Superseded)
                    return
                }
                val correlation = client.correlationID("ev")
                val request = eventPollEnvelope(correlation, nextSequence)
                val raw = try {
                    kotlinx.coroutines.withContext(client.ioDispatcherForTests()) {
                        client.exchangeForPump(request)
                    }
                } catch (c: CancellationException) {
                    return
                } catch (t: Throwable) {
                    consecutiveFailures += 1
                    if (consecutiveFailures > FAILURE_STREAK_LIMIT) {
                        onFailure(HostPumpFailure.Recoverable("exchangeUnavailable", "exchange"))
                        return
                    }
                    delay(client.budgets.effectPollIntervalMillis)
                    continue
                }
                val page = decodeEventPage(raw, correlation, nextSequence)
                when (page) {
                    is EventDecode.FrameBatch -> {
                        if (page.windowState == "runGone") {
                            onFailure(HostPumpFailure.Recoverable("runGone", "runGone"))
                            return
                        }
                        if (page.windowState == "notAttached") {
                            notAttachedPolls += 1
                            // MAIN_ADDENDUM B: the COUNT cutoff belongs to
                            // ordinary pumps chasing a just-committed window.
                            // A queue observer (opened with the durable-resync
                            // consumer) legitimately watches an evicted or
                            // never-refreshed retired window: no count cutoff,
                            // no timer — only lifecycle/typed exits terminate
                            // it, and a late durable fact still arrives through
                            // the SAME binder poll path.
                            if (onDurableResync == null &&
                                notAttachedPolls > NOT_ATTACHED_POLL_LIMIT) {
                                onFailure(
                                    HostPumpFailure.Recoverable(
                                        "eventWindowUnavailable", "notAttached"),
                                )
                                return
                            }
                        } else {
                            notAttachedPolls = 0
                        }
                        consecutiveFailures = 0
                        // Live frames are an unsequenced, lossy HINT only: they
                        // are drained by this poll and never projected as
                        // durable facts. The owner coalesces this signal into
                        // ONE authoritative `run.snapshot` reconciliation.
                        if (page.liveHint.dirty) onLiveHint()
                        for (frame in page.frames) onEvent(frame)
                        nextSequence = page.nextSequence
                        // C09 QREV-03: facts first, typed resync signal second,
                        // in the SAME poll page — a degraded settle window is
                        // consumed once per watch by the queue observer. The
                        // member is the EXISTING decoded `resyncRequired`
                        // (`durableResync || outerResync`); ordinary pumps
                        // pass no consumer and behave byte-for-byte as before.
                        if (page.resyncRequired) onDurableResync?.invoke()
                        if (!page.hasMore || page.frames.isEmpty()) {
                            delay(client.budgets.effectPollIntervalMillis)
                        }
                    }
                    is EventDecode.Failure -> {
                        consecutiveFailures += 1
                        if (consecutiveFailures > FAILURE_STREAK_LIMIT) {
                            onFailure(HostPumpFailure.Recoverable(page.reason, page.reason))
                            return
                        }
                        delay(client.budgets.effectPollIntervalMillis)
                    }
                    EventDecode.ProtocolMismatch -> {
                        onFailure(HostPumpFailure.Recoverable("eventProtocolMismatch", "protocol"))
                        return
                    }
                }
            }
        } finally {
            close()
        }
    }

    /**
     * Canonical `event.poll` request: outer v3 operation envelope plus the
     * frozen `floe.event-cursor/3` inner document. The native validator reads
     * `scope` as the STRING `taskExecution`, the run identity from `owner`
     * (taskID + runID, optional environment/job roles), and the durable
     * cursor from `cursor` (runID + nonnegative sequence). A bare
     * `{"kind":...}` scope object or an `event` member is not part of the
     * frozen contract and is refused before dispatch.
     */
    private fun eventPollEnvelope(correlation: String, sequence: Long): String {
        val owner = linkedMapOf<String, JsonElement>(
            "taskID" to JsonPrimitive(taskID),
            "runID" to JsonPrimitive(runID),
        )
        environmentID?.let { owner["environmentID"] = JsonPrimitive(it) }
        jobID?.let { owner["jobID"] = JsonPrimitive(it) }
        val inner = linkedMapOf<String, JsonElement>(
            "schema" to JsonPrimitive(RuntimeHostCommandClient.HOST_RUN_EVENT_SCHEMA),
            "scope" to JsonPrimitive("taskExecution"),
            "owner" to JsonObject(owner),
            "command" to JsonPrimitive("event.poll"),
            "stateful" to JsonPrimitive(false),
            "cursor" to JsonObject(mapOf(
                "runID" to JsonPrimitive(runID),
                "sequence" to JsonPrimitive(sequence),
            )),
            "correlationID" to JsonPrimitive(correlation),
        )
        return JsonObject(linkedMapOf(
            "version" to JsonPrimitive(3),
            "operation" to JsonPrimitive(RuntimeHostCommandClient.HOST_EVENT_OPERATION),
            "requestID" to JsonPrimitive(correlation),
            "envelope" to JsonObject(inner),
        )).toString()
    }

    private sealed interface EventDecode {
        data class FrameBatch(
            val frames: List<HostRunEventFrame>,
            val nextSequence: Long,
            val hasMore: Boolean,
            val resyncRequired: Boolean,
            val windowState: String,
            val liveHint: LivePageHint.Hint,
        ) : EventDecode
        data class Failure(val reason: String) : EventDecode
        data object ProtocolMismatch : EventDecode
    }

    /**
     * Decodes the ACTUAL `floe.event-cursor/3` reply emitted by the native
     * event pump handler:
     *
     * ```
     * {"ok":true,"schema":"floe.event-cursor/3","correlationID":...,
     *  "cursor":{"runID":...,"sequence":<acknowledged position>},
     *  "durable":{"windowState":"attached|notAttached|runGone",
     *             "events":[{"sequence":N,"kind":"...",
     *                        "createdAt":<millis>,"payload":"<json string>"}],
     *             "hasMore":...,"nextSequence":N,"resyncRequired":...,
     *             "watermark":N},
     *  "live":{"liveState":"...","frames":[...]},
     *  "resyncRequired":...}
     * ```
     *
     * Durable events are the authoritative run facts. Their `payload` is a
     * JSON STRING (the original `RunStore.events.payload_json` column), never
     * a nested object, so it is parsed and rejected typed when malformed. The
     * live channel is a bounded, unsequenced mirror with a different
     * vocabulary; it is classified only as a dirty HINT (see [LivePageHint])
     * that drives one coalesced authoritative `run.snapshot` reconciliation —
     * never projected as durable facts and never used to synthesize a
     * sequence here.
     */
    private fun decodeEventPage(raw: String, expectedCorrelation: String, afterSequence: Long): EventDecode {
        if (raw.toByteArray(Charsets.UTF_8).size > client.budgets.maxFrameBytes) {
            return EventDecode.ProtocolMismatch
        }
        val root = client.parseObject(raw) ?: return EventDecode.ProtocolMismatch
        if (root.longStrict("version") != 3L) return EventDecode.ProtocolMismatch
        if (root.stringStrict("requestID") != expectedCorrelation) return EventDecode.ProtocolMismatch
        if (root.boolStrict("ok") == false) {
            val error = root.stringStrict("error") ?: return EventDecode.ProtocolMismatch
            if (error == "invalidEnvelope") return EventDecode.ProtocolMismatch
            if (error != "runtimeUnavailable") return EventDecode.ProtocolMismatch
            return EventDecode.Failure(sanitize(root.stringStrict("reason") ?: "runtimeUnavailable"))
        }
        if (root.boolStrict("ok") != true) return EventDecode.ProtocolMismatch
        if (root.stringStrict("schema") != RuntimeHostCommandClient.HOST_RUN_EVENT_SCHEMA) {
            return EventDecode.ProtocolMismatch
        }
        if (root.stringStrict("correlationID") != expectedCorrelation) {
            return EventDecode.ProtocolMismatch
        }
        val cursor = root["cursor"] as? JsonObject ?: return EventDecode.ProtocolMismatch
        if (!sameUUID(cursor.stringStrict("runID"), runID)) {
            return EventDecode.ProtocolMismatch
        }
        val cursorSequence = cursor.longStrict("sequence") ?: return EventDecode.ProtocolMismatch
        if (cursorSequence < afterSequence) return EventDecode.ProtocolMismatch
        val durable = root["durable"] as? JsonObject ?: return EventDecode.ProtocolMismatch
        val windowState = durable.stringStrict("windowState")
            ?: return EventDecode.ProtocolMismatch
        if (windowState !in EVENT_WINDOW_STATES) return EventDecode.ProtocolMismatch
        val durableResync = durable.boolStrict("resyncRequired")
            ?: return EventDecode.ProtocolMismatch
        val outerResync = root.boolStrict("resyncRequired") ?: false
        val events = durable["events"] as? JsonArray ?: return EventDecode.ProtocolMismatch
        if (events.size > client.budgets.maxRunEventsPerPage) return EventDecode.ProtocolMismatch
        val nextSequence = durable.longStrict("nextSequence") ?: cursorSequence
        if (nextSequence < afterSequence) return EventDecode.ProtocolMismatch
        val hasMore = durable.boolStrict("hasMore") ?: return EventDecode.ProtocolMismatch
        val frames = ArrayList<HostRunEventFrame>(events.size)
        var previous = afterSequence
        for (element in events) {
            val obj = element as? JsonObject ?: return EventDecode.ProtocolMismatch
            val sequence = obj.longStrict("sequence") ?: return EventDecode.ProtocolMismatch
            if (sequence <= previous) return EventDecode.ProtocolMismatch
            val kind = obj.stringStrict("kind") ?: return EventDecode.ProtocolMismatch
            if (kind.isBlank() || kind.length > 64) return EventDecode.ProtocolMismatch
            val payloadRaw = obj.stringStrict("payload")
                ?: return EventDecode.ProtocolMismatch
            val payload = client.parseObject(payloadRaw)
                ?: return EventDecode.ProtocolMismatch
            val bytes = element.toString().toByteArray(Charsets.UTF_8).size
            previous = sequence
            frames.add(HostRunEventFrame(runID, sequence, kind, payload, bytes))
        }
        return EventDecode.FrameBatch(
            frames = frames,
            nextSequence = nextSequence,
            hasMore = hasMore,
            resyncRequired = durableResync || outerResync,
            windowState = windowState,
            liveHint = LivePageHint.decode(root, client.budgets.maxFrameBytes),
        )
    }

    private fun sameUUID(left: String?, right: String): Boolean {
        if (left == null) return false
        val a = runCatching { java.util.UUID.fromString(left) }.getOrNull() ?: return false
        val b = runCatching { java.util.UUID.fromString(right) }.getOrNull() ?: return false
        return a == b
    }

    private fun sanitize(value: String): String {
        val builder = StringBuilder(minOf(value.length, 48))
        for (char in value) {
            if (builder.length >= 48) break
            if (char.isLetterOrDigit() || char == '_') builder.append(char)
        }
        return if (builder.isEmpty()) "unknown" else builder.toString()
    }

    companion object {
        internal val EVENT_WINDOW_STATES = setOf("attached", "notAttached", "runGone")

        /** Consecutive transient transport/decode failures before the pump
         * reports one typed terminal failure (50 ms poll ⇒ ~1 s). */
        internal const val FAILURE_STREAK_LIMIT = 5

        /** Consecutive `notAttached` windows tolerated for a just-committed
         * run (50 ms poll ⇒ ~10 s) before the owner reconciles by snapshot. */
        internal const val NOT_ATTACHED_POLL_LIMIT = 200
    }
}

/**
 * Truthful classification of the native `live` mirror carried by
 * `floe.event-cursor/3` replies.
 *
 * The live channel is an unsequenced, lossy mirror of the run's harness
 * events: frames may be dropped without notice, `liveSeq` is a per-consumer
 * ring position (never the durable sequence) and the native page does not
 * expose a stable live epoch. It is therefore validated HERE only as a DIRTY
 * HINT: any drained frame, an explicit `detached`/`resyncRequired` state, a
 * malformed/unrecognised document or an over-budget frame all mean "live
 * content may exist that the durable pages have not carried yet — reconcile
 * through the canonical `run.snapshot`". No text is projected, no durable
 * sequence is invented from `liveSeq`, and a malformed live document never
 * fails the authoritative durable section of the same page.
 */
internal object LivePageHint {
    /** Native live ring capacity (`FacadeEventPump.Limits.liveRingEvents`). */
    internal const val MAXIMUM_FRAMES = 512

    internal val STATES = setOf("attached", "noConsumer", "detached", "resyncRequired")

    data class Hint(
        /** True when an authoritative snapshot reconciliation is warranted. */
        val dirty: Boolean,
        /** Honest classification label for diagnostics/tests. */
        val state: String,
    )

    fun decode(root: JsonObject?, maxFrameBytes: Int): Hint {
        if (root == null) return Hint(false, "absent")
        val live = root["live"] as? JsonObject
            ?: return Hint(false, "absent")
        val state = live.stringStrict("liveState") ?: return Hint(true, "malformed")
        if (state !in STATES) return Hint(true, "malformed")
        val frames = live["frames"] as? JsonArray ?: return Hint(true, "malformed")
        if (frames.size > MAXIMUM_FRAMES) return Hint(true, "overBudget")
        val liveResync = live.boolStrict("resyncRequired") ?: false
        var dirty = liveResync || state == "detached" || state == "resyncRequired"
        for (element in frames) {
            val frame = element as? JsonObject ?: return Hint(true, "malformed")
            // The ring position is validated as a non-negative integer and
            // then INTENTIONALLY unused: it is not a durable sequence.
            val liveSeq = frame.longStrict("liveSeq") ?: return Hint(true, "malformed")
            if (liveSeq < 0) return Hint(true, "malformed")
            if (frame.boolStrict("priority") == null) return Hint(true, "malformed")
            val payload = frame.stringStrict("payload") ?: return Hint(true, "malformed")
            if (payload.toByteArray(Charsets.UTF_8).size > maxFrameBytes) {
                return Hint(true, "overBudget")
            }
            dirty = true
        }
        return Hint(dirty, state)
    }
}

// ---------------------------------------------------- shared JSON helpers

private fun parseJsonObject(json: Json, raw: String): JsonObject? = try {
    json.parseToJsonElement(raw) as? JsonObject
} catch (t: Throwable) {
    null
}

internal fun JsonObject.stringStrict(key: String): String? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (!value.isString) return null
    return value.contentOrNull
}

internal fun JsonObject.boolStrict(key: String): Boolean? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value.isString) return null
    return value.booleanOrNull
}

internal fun JsonObject.longStrict(key: String): Long? {
    val value = this[key] as? JsonPrimitive ?: return null
    if (value.isString) return null
    if (value is JsonNull) return null
    return value.longOrNull
}
