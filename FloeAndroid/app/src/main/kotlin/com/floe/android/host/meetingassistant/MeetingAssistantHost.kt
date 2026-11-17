// SPDX-License-Identifier: MPL-2.0
//
// The one App-owned meeting assistant host.
//
// It reuses the EXISTING frozen v3 run/effect/event surface that already
// powers ordinary chat:
//
//   * the first ask creates ONE real ordinary conversation with
//     `run.startTask` (create intent) and records the conversation identity
//     returned by the native `prepared` commit;
//   * later asks reuse that conversation through `run.start` with the exact
//     `conversation.get` revision read at action time;
//   * every launch is text-only (`toolCeiling: []`), so the meeting pages,
//     files, shell and other meetings are never reachable tools;
//   * the answer is read back from `run.snapshot` plus the durable assistant
//     row of that exact run. Nothing is fabricated when the read fails.
//
// No provider client, prompt loop, workspace, task or project identity is
// created here. A deleted/broken task binding is cleared and replaced with a
// new real task only after the native `notFound` proof.
package com.floe.android.host.meetingassistant

import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.host.ConversationWire
import com.floe.android.host.EventPumpHandle
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostPumpFailure
import com.floe.android.host.HostRevision
import com.floe.android.host.HostRunEventFrame
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SettingsRoleModelController
import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class MeetingAssistantHost(
    private val host: RuntimeHost,
    private val store: MeetingAssistantStore,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private class ActiveTurn(
        val meetingId: String,
        val entryId: String,
        val action: MeetingAssistantAction,
        val question: String,
        val createdAtMillis: Long,
        var notesRevision: Long = 0L,
        var transcriptRevision: Long = 0L,
        var phase: MeetingAssistantTurnPhase = MeetingAssistantTurnPhase.PREPARING,
        var conversationId: String? = null,
        var runId: String? = null,
        var stream: EventPumpHandle? = null,
        var pendingSettleReason: String? = null,
        val settling: AtomicBoolean = AtomicBoolean(false),
        val finished: AtomicBoolean = AtomicBoolean(false),
    ) {
        fun view(): MeetingAssistantTurnView = MeetingAssistantTurnView(action, phase)

        fun entry(
            status: MeetingAssistantEntryStatus,
            answer: String?,
            assistantMessageId: String?,
            failure: MeetingAssistantFailureCode?,
            truncated: Boolean,
        ): MeetingAssistantEntry = MeetingAssistantEntry(
            id = entryId,
            action = action,
            question = question,
            status = status,
            answer = answer,
            createdAtMillis = createdAtMillis,
            notesRevision = notesRevision,
            transcriptRevision = transcriptRevision,
            conversationId = conversationId,
            runId = runId,
            failure = failure,
            assistantMessageId = assistantMessageId,
            answerTruncated = truncated,
        )
    }

    private sealed interface ConversationRead {
        data class Found(val revision: Revision) : ConversationRead
        data object NotFound : ConversationRead
        data object Failed : ConversationRead
    }

    private data class ResolvedRun(
        val readable: Boolean,
        val terminal: Boolean,
        val state: String?,
        val answer: String?,
        val assistantMessageId: String?,
        val truncated: Boolean,
    )

    private val lock = Any()
    private val stateFlow = MutableStateFlow(MeetingAssistantState())
    val state: StateFlow<MeetingAssistantState> = stateFlow.asStateFlow()

    private val turns = HashMap<String, ActiveTurn>()
    private var selectedMeetingId: String? = null
    private var selectionEpoch = 0L
    private var meetingModelId: String? = null
    private var preferredModelId: String? = null
    private var latestModels: List<ModelOptionUi> = emptyList()
    private var modelsLoaded = false
    private var providerAdmitted = false
    private var closed = false
    private var availabilityJob: Job? = null

    init {
        availabilityJob = scope.launch {
            combine(
                host.readiness,
                host.conversations.modelProjectionFlow,
                host.settings.roles.state,
            ) { readiness, projection, roles ->
                Triple(readiness.providerConfigurationAdmitted, projection, roles)
            }.collect { (admitted, projection, roles) ->
                synchronized(lock) {
                    providerAdmitted = admitted
                    latestModels = projection.models
                    modelsLoaded = projection.loaded
                    preferredModelId = roles.saved[
                        SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM
                    ] ?: roles.saved[SettingsRoleModelController.RoleSlot.DEFAULT_AGENT]
                }
                publishAvailability()
            }
        }
        scope.launch(ioDispatcher) {
            runCatching { host.conversations.refreshModels() }
        }
        scope.launch(ioDispatcher) {
            val roles = host.settings.roles.state.value
            if (roles.revision == null && !roles.loading) {
                runCatching { host.settings.roles.refresh() }
            }
        }
    }

    // ------------------------------------------------------------- selection

    /** Fences the whole page on one persisted meeting id. */
    fun selectMeeting(meetingId: String?) {
        val epoch: Long
        synchronized(lock) {
            selectionEpoch += 1
            epoch = selectionEpoch
            selectedMeetingId = meetingId
            meetingModelId = null
            updateLocked { current ->
                current.copy(
                    meetingId = meetingId,
                    entries = emptyList(),
                    active = meetingId?.let { turns[it]?.view() },
                    checkingEntryIds = emptySet(),
                    error = null,
                    historyUnreadable = false,
                )
            }
        }
        publishAvailability()
        if (meetingId == null) return
        scope.launch {
            val binding = runCatching {
                withContext(ioDispatcher) { store.load(meetingId) }
            }.getOrNull() ?: return@launch
            val applies = synchronized(lock) {
                if (selectionEpoch == epoch && selectedMeetingId == meetingId) {
                    meetingModelId = binding.modelId
                    updateLocked { current ->
                        current.copy(
                            entries = binding.entries,
                            historyUnreadable = binding.unreadable,
                            active = turns[meetingId]?.view(),
                        )
                    }
                    true
                } else {
                    false
                }
            }
            if (!applies) return@launch
            publishAvailability()
            if (!binding.unreadable) reconcilePending(meetingId, epoch)
        }
    }

    /** Explicitly re-reads the real model/provider projections. */
    fun refresh() {
        scope.launch(ioDispatcher) { runCatching { host.conversations.refreshModels() } }
        scope.launch(ioDispatcher) {
            val roles = host.settings.roles.state.value
            if (roles.revision == null && !roles.loading) {
                runCatching { host.settings.roles.refresh() }
            }
        }
        publishAvailability()
    }

    /** Changes only this meeting's assistant model; never a global setting. */
    fun selectModel(modelId: String) {
        val meetingId = synchronized(lock) { selectedMeetingId } ?: return
        val ready = stateFlow.value.availability as? MeetingAssistantAvailability.Ready
            ?: return
        if (ready.models.none { it.modelId == modelId }) return
        synchronized(lock) { meetingModelId = modelId }
        publishAvailability()
        scope.launch(ioDispatcher) { runCatching { store.selectModel(meetingId, modelId) } }
    }

    // ------------------------------------------------------------------ send

    /**
     * Starts one real text-only assistant turn for [meetingId].
     *
     * [loadDetail] must be the real repository read (MeetingManager.meeting);
     * the host uses exactly that persisted revision as the turn provenance.
     */
    fun send(
        meetingId: String,
        action: MeetingAssistantAction,
        question: String,
        loadDetail: suspend (String) -> MeetingDetail,
    ) {
        if (!isIdentifier(meetingId)) {
            publishErrorFor(meetingId, MeetingAssistantFailure(MeetingAssistantFailureCode.CONTEXT_UNAVAILABLE))
            return
        }
        // A late UI callback for a meeting that is no longer selected must not
        // launch a paid run; switching is a hard fence.
        if (synchronized(lock) { selectedMeetingId } != meetingId) return
        val ready = stateFlow.value.availability as? MeetingAssistantAvailability.Ready
        if (ready == null) {
            publishErrorFor(
                meetingId,
                MeetingAssistantFailure(MeetingAssistantFailureCode.MODEL_UNAVAILABLE),
            )
            return
        }
        val normalizedQuestion = when (action) {
            MeetingAssistantAction.ASK -> MeetingAssistantWire.normalizeQuestion(question)
                ?: run {
                    publishErrorFor(
                        meetingId,
                        MeetingAssistantFailure(MeetingAssistantFailureCode.INVALID_QUESTION),
                    )
                    return
                }
            MeetingAssistantAction.MINUTES,
            MeetingAssistantAction.TODOS,
            -> ""
        }
        val model = synchronized(lock) {
            latestModels.firstOrNull { it.isUsable && it.modelId == ready.modelId }
        }
        if (model == null ||
            !isIdentifier(model.providerId) ||
            !isIdentifier(model.modelId)
        ) {
            publishErrorFor(
                meetingId,
                MeetingAssistantFailure(MeetingAssistantFailureCode.MODEL_UNAVAILABLE),
            )
            return
        }
        val turn = ActiveTurn(
            meetingId = meetingId,
            entryId = newMeetingAssistantEntryId(meetingId),
            action = action,
            question = normalizedQuestion,
            createdAtMillis = clock(),
        )
        val accepted = synchronized(lock) {
            if (turns[meetingId] != null) {
                updateLocked { current ->
                    current.copy(
                        error = MeetingAssistantFailure(MeetingAssistantFailureCode.BUSY),
                    )
                }
                false
            } else {
                turns[meetingId] = turn
                if (selectedMeetingId == meetingId) {
                    updateLocked { current ->
                        current.copy(active = turn.view(), error = null)
                    }
                }
                true
            }
        }
        if (!accepted) return
        scope.launch {
            prepareAndLaunch(turn, model, loadDetail)
        }
    }

    private suspend fun prepareAndLaunch(
        turn: ActiveTurn,
        model: ModelOptionUi,
        loadDetail: suspend (String) -> MeetingDetail,
    ) {
        try {
            val detail = loadDetail(turn.meetingId)
            if (detail.id != turn.meetingId) {
                failTurn(turn, MeetingAssistantFailure(MeetingAssistantFailureCode.CONTEXT_UNAVAILABLE))
                return
            }
            val prompt = when (val built = MeetingAssistantPromptBuilder.build(
                detail = detail,
                action = turn.action,
                question = turn.question,
            )) {
                is MeetingAssistantPromptResult.Built -> built.prompt
                MeetingAssistantPromptResult.NoContext -> {
                    failTurn(turn, MeetingAssistantFailure(MeetingAssistantFailureCode.NO_CONTEXT))
                    return
                }
                MeetingAssistantPromptResult.InvalidQuestion -> {
                    failTurn(turn, MeetingAssistantFailure(MeetingAssistantFailureCode.INVALID_QUESTION))
                    return
                }
                MeetingAssistantPromptResult.TooLarge -> {
                    failTurn(turn, MeetingAssistantFailure(MeetingAssistantFailureCode.PROMPT_TOO_LARGE))
                    return
                }
            }
            synchronized(lock) {
                turn.notesRevision = prompt.notesRevision
                turn.transcriptRevision = prompt.transcriptRevision
            }
            val conversationId = withContext(ioDispatcher) {
                store.conversationId(turn.meetingId)
            }
            if (conversationId == null) {
                submitCreate(turn, prompt, model, detail.title)
                return
            }
            when (val read = readConversationRevision(conversationId)) {
                is ConversationRead.Found ->
                    submitExisting(turn, prompt, model, conversationId, read.revision)
                ConversationRead.NotFound -> {
                    withContext(ioDispatcher) { runCatching { store.clearConversation(turn.meetingId) } }
                    submitCreate(turn, prompt, model, detail.title)
                }
                ConversationRead.Failed ->
                    failTurn(turn, MeetingAssistantFailure(MeetingAssistantFailureCode.LAUNCH_FAILED))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: MeetingException) {
            failTurn(
                turn,
                MeetingAssistantFailure(
                    MeetingAssistantFailureCode.CONTEXT_UNAVAILABLE,
                    MeetingAssistantWire.boundedDetail(error.code.name),
                ),
            )
        } catch (error: Throwable) {
            failTurn(
                turn,
                MeetingAssistantFailure(
                    MeetingAssistantFailureCode.LAUNCH_FAILED,
                    MeetingAssistantWire.boundedDetail(error.message),
                ),
            )
        }
    }

    private fun submitCreate(
        turn: ActiveTurn,
        prompt: MeetingAssistantPrompt,
        model: ModelOptionUi,
        meetingTitle: String,
    ) {
        val payload = MeetingAssistantWire.runPayload(
            goal = prompt.goal,
            providerId = model.providerId,
            modelId = model.modelId,
            title = MeetingAssistantPromptBuilder.conversationTitle(meetingTitle),
        )
        dispatchLaunch(
            turn = turn,
            request = HostCommandRequest(
                command = "run.startTask",
                scope = HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = host.commandClient.correlationID("marun"),
                createIntent = true,
                payload = payload,
            ),
            providerId = model.providerId,
        )
    }

    private fun submitExisting(
        turn: ActiveTurn,
        prompt: MeetingAssistantPrompt,
        model: ModelOptionUi,
        conversationId: String,
        revision: Revision,
    ) {
        val payload = MeetingAssistantWire.runPayload(
            goal = prompt.goal,
            providerId = model.providerId,
            modelId = model.modelId,
            title = null,
        )
        dispatchLaunch(
            turn = turn,
            request = HostCommandRequest(
                command = "run.start",
                scope = HostScope.LaunchExisting(conversationId),
                stateful = true,
                correlationID = host.commandClient.correlationID("marun"),
                revision = HostRevision(revision.resourceID, revision.version),
                payload = payload,
            ),
            providerId = model.providerId,
        )
    }

    private fun dispatchLaunch(
        turn: ActiveTurn,
        request: HostCommandRequest,
        providerId: String,
    ) {
        val prepared = AtomicBoolean(false)
        fun dispatch() {
            if (!isCurrentTurn(turn)) return
            host.trackOperation(
                request = request,
                onFrame = { frame ->
                    if (frame.kind == "prepared" && !prepared.get()) {
                        ConversationWire.preparedFromEffect(frame.detail)?.let { value ->
                            if (prepared.compareAndSet(false, true)) onPrepared(turn, value)
                        }
                    }
                },
            ) { outcome ->
                if (prepared.get()) return@trackOperation
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        val value = outcome.value?.let { ConversationWire.decodePrepared(it) }
                        if (value != null) {
                            if (prepared.compareAndSet(false, true)) onPrepared(turn, value)
                        } else {
                            failTurn(
                                turn,
                                MeetingAssistantFailure(MeetingAssistantFailureCode.LAUNCH_FAILED),
                            )
                        }
                    }
                    is HostOperationOutcome.Rejected -> failTurn(
                        turn,
                        MeetingAssistantWire.failureForLaunch(outcome.code, outcome.reason),
                    )
                    is HostOperationOutcome.Failed -> failTurn(
                        turn,
                        MeetingAssistantWire.failureForLaunch(outcome.code, outcome.reason),
                    )
                    HostOperationOutcome.Cancelled -> failTurn(
                        turn,
                        MeetingAssistantFailure(
                            MeetingAssistantFailureCode.LAUNCH_FAILED,
                            "cancelled",
                        ),
                    )
                    HostOperationOutcome.Superseded -> failTurn(
                        turn,
                        MeetingAssistantFailure(
                            MeetingAssistantFailureCode.LAUNCH_FAILED,
                            "superseded",
                        ),
                    )
                }
            }
        }
        val started = host.providers.withLocalNetworkForProvider(
            providerID = providerId,
            isCurrent = { isCurrentTurn(turn) },
            onDenied = { code ->
                failTurn(
                    turn,
                    MeetingAssistantFailure(
                        MeetingAssistantFailureCode.PROVIDERS_NOT_READY,
                        MeetingAssistantWire.boundedDetail(code),
                    ),
                )
            },
            dispatch = ::dispatch,
        )
        if (!started) {
            failTurn(
                turn,
                MeetingAssistantFailure(
                    MeetingAssistantFailureCode.PROVIDERS_NOT_READY,
                    "providerUnavailable",
                ),
            )
        }
    }

    private fun onPrepared(turn: ActiveTurn, prepared: ConversationWire.Prepared) {
        if (turn.finished.get()) return
        val applies = synchronized(lock) {
            if (turns[turn.meetingId] !== turn) {
                false
            } else {
                turn.conversationId = prepared.conversationID
                turn.runId = prepared.runID
                turn.phase = MeetingAssistantTurnPhase.RUNNING
                if (selectedMeetingId == turn.meetingId) {
                    updateLocked { current ->
                        current.copy(active = turn.view(), error = null)
                    }
                }
                true
            }
        }
        if (!applies) return
        scope.launch {
            withContext(ioDispatcher) {
                runCatching { store.bindConversation(turn.meetingId, prepared.conversationID) }
                runCatching {
                    store.recordPending(
                        turn.meetingId,
                        turn.entry(
                            status = MeetingAssistantEntryStatus.PENDING,
                            answer = null,
                            assistantMessageId = null,
                            failure = null,
                            truncated = false,
                        ),
                    )
                }
            }
            reloadEntriesIfSelected(turn.meetingId)
        }
        openStream(turn)
    }

    private fun openStream(turn: ActiveTurn) {
        val conversationId = turn.conversationId ?: return
        val runId = turn.runId ?: return
        val handle = try {
            host.commandClient.openRunEventStream(
                taskID = conversationId,
                runID = runId,
                environmentID = null,
                jobID = null,
                onEvent = { frame -> onRunFrame(turn, frame) },
                onLiveHint = { },
                onFailure = { failure -> onStreamFailure(turn, failure) },
            )
        } catch (_: Throwable) {
            onStreamFailure(turn, null)
            return
        }
        val stored = synchronized(lock) {
            if (turns[turn.meetingId] === turn) {
                turn.stream = handle
                true
            } else {
                false
            }
        }
        if (!stored) {
            handle.close()
            return
        }
        // A very short run may have completed before this attach. One
        // authoritative read resolves that case without inventing a terminal.
        requestSettle(turn, "attach")
    }

    private fun onRunFrame(turn: ActiveTurn, frame: HostRunEventFrame) {
        if (MeetingAssistantWire.isTerminalFrame(frame.kind, frame.payload)) {
            requestSettle(turn, "terminal")
        }
    }

    private fun onStreamFailure(turn: ActiveTurn, failure: HostPumpFailure?) {
        if (turn.finished.get()) return
        val code = when (failure) {
            is HostPumpFailure.Recoverable -> failure.code
            HostPumpFailure.Superseded -> "superseded"
            null -> "streamUnavailable"
        }
        publishErrorFor(
            turn.meetingId,
            MeetingAssistantFailure(
                MeetingAssistantFailureCode.STREAM_LOST,
                MeetingAssistantWire.boundedDetail(code),
            ),
        )
        requestSettle(turn, "streamFailure")
    }

    // --------------------------------------------------------------- settling

    private fun requestSettle(turn: ActiveTurn, reason: String) {
        if (turn.finished.get()) return
        synchronized(lock) {
            // The newest signal wins; settleInternal always re-reads the
            // authoritative page, so a stronger signal cannot be lost to a
            // read that was already in flight.
            turn.pendingSettleReason = reason
        }
        if (!turn.settling.compareAndSet(false, true)) return
        scope.launch {
            try {
                while (true) {
                    val next = synchronized(lock) {
                        turn.pendingSettleReason.also { turn.pendingSettleReason = null }
                    } ?: break
                    settleInternal(turn, next)
                    if (turn.finished.get()) break
                }
            } finally {
                turn.settling.set(false)
                val pending = synchronized(lock) { turn.pendingSettleReason }
                if (!turn.finished.get() && pending != null) {
                    requestSettle(turn, pending)
                }
            }
        }
    }

    private suspend fun settleInternal(turn: ActiveTurn, reason: String) {
        val conversationId = turn.conversationId ?: return
        val runId = turn.runId ?: return
        var resolved = resolveRun(conversationId, runId)
        if (!resolved.terminal && reason == "terminal") {
            // The durable terminal frame and the snapshot are normally atomic;
            // one bounded re-read absorbs a just-committed row without a loop.
            delay(500)
            resolved = resolveRun(conversationId, runId)
        }
        if (!resolved.readable) {
            finishTurn(
                turn,
                status = MeetingAssistantEntryStatus.UNRESOLVED,
                answer = null,
                failure = MeetingAssistantFailureCode.RESULT_UNREADABLE,
                assistantMessageId = null,
                truncated = false,
            )
            return
        }
        if (resolved.terminal && resolved.answer == null && resolved.state == "completed") {
            // The terminal status and the durable assistant row are normally
            // committed together. One bounded re-read absorbs a just-committed
            // row; a still-missing answer is reported honestly, never filled.
            delay(500)
            resolved = resolveRun(conversationId, runId)
        }
        if (!resolved.readable) {
            finishTurn(
                turn,
                status = MeetingAssistantEntryStatus.UNRESOLVED,
                answer = null,
                failure = MeetingAssistantFailureCode.RESULT_UNREADABLE,
                assistantMessageId = null,
                truncated = false,
            )
            return
        }
        if (!resolved.terminal) {
            if (reason == "terminal") {
                finishTurn(
                    turn,
                    status = MeetingAssistantEntryStatus.UNRESOLVED,
                    answer = null,
                    failure = MeetingAssistantFailureCode.RESULT_UNREADABLE,
                    assistantMessageId = null,
                    truncated = false,
                )
            } else {
                setPhase(turn, MeetingAssistantTurnPhase.RUNNING)
            }
            return
        }
        val status = MeetingAssistantWire.classifyOutcome(resolved.state, resolved.answer)
        val failure = when (status) {
            MeetingAssistantEntryStatus.FAILED ->
                if (resolved.state == "failed") {
                    MeetingAssistantFailureCode.RUN_FAILED
                } else {
                    MeetingAssistantFailureCode.NO_ANSWER
                }
            MeetingAssistantEntryStatus.CANCELLED -> MeetingAssistantFailureCode.RUN_CANCELLED
            MeetingAssistantEntryStatus.UNRESOLVED ->
                MeetingAssistantFailureCode.RESULT_UNREADABLE
            else -> null
        }
        finishTurn(
            turn,
            status = status,
            answer = resolved.answer,
            failure = failure,
            assistantMessageId = resolved.assistantMessageId,
            truncated = resolved.truncated,
        )
    }

    private suspend fun finishTurn(
        turn: ActiveTurn,
        status: MeetingAssistantEntryStatus,
        answer: String?,
        failure: MeetingAssistantFailureCode?,
        assistantMessageId: String?,
        truncated: Boolean,
    ) {
        if (!turn.finished.compareAndSet(false, true)) return
        turn.stream?.close()
        turn.stream = null
        synchronized(lock) {
            turns.remove(turn.meetingId)
            if (selectedMeetingId == turn.meetingId) {
                updateLocked { current -> current.copy(active = null) }
            }
        }
        val entry = turn.entry(
            status = status,
            answer = answer,
            assistantMessageId = assistantMessageId,
            failure = failure,
            truncated = truncated,
        )
        val persisted = withContext(ioDispatcher) {
            runCatching { store.complete(turn.meetingId, entry) }.getOrDefault(false)
        }
        if (persisted) {
            reloadEntriesIfSelected(turn.meetingId)
        } else {
            synchronized(lock) {
                if (selectedMeetingId == turn.meetingId) {
                    updateLocked { current ->
                        current.copy(
                            entries = (listOf(entry) + current.entries)
                                .distinctBy { it.id }
                                .sortedByDescending { it.createdAtMillis },
                            error = MeetingAssistantFailure(
                                MeetingAssistantFailureCode.STORE_FAILED,
                            ),
                        )
                    }
                }
            }
        }
    }

    private suspend fun resolveRun(conversationId: String, runId: String): ResolvedRun {
        val snapshot = readSnapshot(conversationId, runId)
        val page = readMessagePage(conversationId)
        val row = page?.let { MeetingAssistantWire.selectAnswer(it.rows, runId) }
        val answerFromRow = row?.text?.trim()?.takeIf { it.isNotEmpty() }
        val completeSnapshot = snapshot?.takeIf {
            it.answerComplete && it.answerContinuationHandle == null
        }
        val answerFromSnapshot = completeSnapshot?.answerText
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val answer = answerFromRow ?: answerFromSnapshot
        val readable = snapshot != null || page != null
        val terminal = snapshot?.isTerminal == true ||
            (snapshot == null && answerFromRow != null)
        return ResolvedRun(
            readable = readable,
            terminal = terminal,
            state = snapshot?.durableState,
            answer = answer,
            assistantMessageId = row?.id,
            truncated = snapshot?.answerContinuationHandle != null,
        )
    }

    private suspend fun readSnapshot(
        conversationId: String,
        runId: String,
    ): ConversationWire.SnapshotPage? {
        val outcome = request(
            HostCommandRequest(
                command = "run.snapshot",
                scope = HostScope.TaskExecution(conversationId, runId),
                stateful = false,
                correlationID = host.commandClient.correlationID("masnap"),
            ),
        ) ?: return null
        if (outcome !is HostOperationOutcome.Completed) return null
        return ConversationWire.decodeSnapshotPage(outcome.value)
    }

    private suspend fun readMessagePage(
        conversationId: String,
    ): ConversationWire.MessagePage? {
        val outcome = request(
            HostCommandRequest(
                command = "conversation.messagePage",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = host.commandClient.correlationID("mapage"),
                payload = buildJsonObject { put("limit", 20) },
            ),
        ) ?: return null
        if (outcome !is HostOperationOutcome.Completed) return null
        return ConversationWire.decodeMessagePage(
            outcome.value ?: return null,
            conversationId,
        )
    }

    private suspend fun readConversationRevision(
        conversationId: String,
    ): ConversationRead {
        val outcome = request(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationId),
                stateful = false,
                correlationID = host.commandClient.correlationID("maconv"),
            ),
        ) ?: return ConversationRead.Failed
        return when (outcome) {
            is HostOperationOutcome.Completed -> {
                val revision = outcome.value
                    ?.let { ConversationWire.decodeSessionReply(it) }
                    ?.revision
                if (revision == null) ConversationRead.Failed
                else ConversationRead.Found(revision)
            }
            is HostOperationOutcome.Rejected ->
                if (outcome.code == "notFound") ConversationRead.NotFound
                else ConversationRead.Failed
            else -> ConversationRead.Failed
        }
    }

    private suspend fun request(request: HostCommandRequest): HostOperationOutcome? {
        val terminal = CompletableDeferred<HostOperationOutcome>()
        host.trackOperation(request) { outcome -> terminal.complete(outcome) }
        return withTimeoutOrNull(QUERY_TIMEOUT_MILLIS) { terminal.await() }
    }

    // --------------------------------------------------------------- cancel

    fun cancel(meetingId: String) {
        val turn = synchronized(lock) { turns[meetingId] } ?: return
        if (turn.phase == MeetingAssistantTurnPhase.CANCELLING) return
        val conversationId = turn.conversationId
        val runId = turn.runId
        if (conversationId == null || runId == null) return
        setPhase(turn, MeetingAssistantTurnPhase.CANCELLING)
        scope.launch {
            val snapshot = readSnapshot(conversationId, runId)
            if (snapshot == null) {
                setPhase(turn, MeetingAssistantTurnPhase.RUNNING)
                publishErrorFor(
                    turn.meetingId,
                    MeetingAssistantFailure(MeetingAssistantFailureCode.CANCEL_REFUSED),
                )
                return@launch
            }
            if (snapshot.isTerminal) {
                requestSettle(turn, "cancel")
                return@launch
            }
            val outcome = request(
                HostCommandRequest(
                    command = "run.cancel",
                    scope = HostScope.TaskExecution(conversationId, runId),
                    stateful = true,
                    correlationID = host.commandClient.correlationID("macancel"),
                    revision = HostRevision(
                        snapshot.revision.resourceID,
                        snapshot.revision.version,
                    ),
                    payload = buildJsonObject {
                        put("expectedState", snapshot.durableState)
                    },
                ),
            )
            if (outcome !is HostOperationOutcome.Completed) {
                setPhase(turn, MeetingAssistantTurnPhase.RUNNING)
                publishErrorFor(
                    turn.meetingId,
                    MeetingAssistantFailure(
                        MeetingAssistantFailureCode.CANCEL_REFUSED,
                        MeetingAssistantWire.boundedDetail(
                            (outcome as? HostOperationOutcome.Rejected)?.code
                                ?: (outcome as? HostOperationOutcome.Failed)?.code,
                        ),
                    ),
                )
            }
            // Accepted means the stop was requested, not that it settled. The
            // run stream's real terminal is the only thing that finishes it.
        }
    }

    /** One bounded authoritative re-read of an active run after a lost stream. */
    fun checkActive(meetingId: String) {
        val turn = synchronized(lock) { turns[meetingId] } ?: return
        requestSettle(turn, "check")
    }

    // ------------------------------------------------------- recovery/readback

    /** Re-reads an entry left PENDING/UNRESOLVED by an earlier process. */
    fun checkAgain(meetingId: String, entryId: String) {
        if (!isIdentifier(meetingId)) return
        if (!entryId.startsWith("$meetingId${MeetingAssistantStore.ENTRY_ID_SEPARATOR}")) return
        synchronized(lock) {
            if (selectedMeetingId != meetingId) return
            if (turns[meetingId]?.entryId == entryId) return
            updateLocked { current ->
                current.copy(
                    checkingEntryIds = current.checkingEntryIds + entryId,
                    error = null,
                )
            }
        }
        scope.launch {
            try {
                val binding = withContext(ioDispatcher) { store.load(meetingId) }
                val entry = binding.entries.firstOrNull { it.id == entryId }
                val conversationId = entry?.conversationId
                val runId = entry?.runId
                if (entry == null || conversationId == null || runId == null) {
                    publishErrorFor(
                        meetingId,
                        MeetingAssistantFailure(MeetingAssistantFailureCode.RESULT_UNREADABLE),
                    )
                    return@launch
                }
                val resolved = resolveRun(conversationId, runId)
                if (!resolved.readable) {
                    publishErrorFor(
                        meetingId,
                        MeetingAssistantFailure(MeetingAssistantFailureCode.RESULT_UNREADABLE),
                    )
                    return@launch
                }
                if (!resolved.terminal) {
                    publishErrorFor(
                        meetingId,
                        MeetingAssistantFailure(MeetingAssistantFailureCode.STILL_RUNNING),
                    )
                    return@launch
                }
                val status = MeetingAssistantWire.classifyOutcome(
                    resolved.state,
                    resolved.answer,
                )
                val failure = when (status) {
                    MeetingAssistantEntryStatus.FAILED -> MeetingAssistantFailureCode.RUN_FAILED
                    MeetingAssistantEntryStatus.CANCELLED ->
                        MeetingAssistantFailureCode.RUN_CANCELLED
                    MeetingAssistantEntryStatus.UNRESOLVED ->
                        MeetingAssistantFailureCode.RESULT_UNREADABLE
                    else -> null
                }
                val updated = entry.copy(
                    status = status,
                    answer = resolved.answer,
                    failure = failure,
                    assistantMessageId = resolved.assistantMessageId,
                    answerTruncated = resolved.truncated,
                )
                val persisted = withContext(ioDispatcher) {
                    runCatching { store.complete(meetingId, updated) }.getOrDefault(false)
                }
                if (!persisted) {
                    publishErrorFor(
                        meetingId,
                        MeetingAssistantFailure(MeetingAssistantFailureCode.STORE_FAILED),
                    )
                    return@launch
                }
                reloadEntriesIfSelected(meetingId)
            } finally {
                synchronized(lock) {
                    if (stateFlow.value.meetingId == meetingId) {
                        updateLocked { current ->
                            current.copy(
                                checkingEntryIds = current.checkingEntryIds - entryId,
                            )
                        }
                    }
                }
            }
        }
    }

    private suspend fun reconcilePending(meetingId: String, epoch: Long) {
        val binding = withContext(ioDispatcher) { store.load(meetingId) }
        val candidates = binding.entries
            .filter {
                it.status == MeetingAssistantEntryStatus.PENDING &&
                    it.conversationId != null &&
                    it.runId != null
            }
            .take(MAX_RECONCILE_ENTRIES)
        for (entry in candidates) {
            val current = synchronized(lock) {
                selectionEpoch == epoch && selectedMeetingId == meetingId &&
                    turns[meetingId]?.entryId != entry.id
            }
            if (!current) return
            val conversationId = entry.conversationId ?: continue
            val runId = entry.runId ?: continue
            val resolved = resolveRun(conversationId, runId)
            if (!resolved.readable || !resolved.terminal) continue
            val status = MeetingAssistantWire.classifyOutcome(resolved.state, resolved.answer)
            val failure = when (status) {
                MeetingAssistantEntryStatus.FAILED -> MeetingAssistantFailureCode.RUN_FAILED
                MeetingAssistantEntryStatus.CANCELLED ->
                    MeetingAssistantFailureCode.RUN_CANCELLED
                MeetingAssistantEntryStatus.UNRESOLVED ->
                    MeetingAssistantFailureCode.RESULT_UNREADABLE
                else -> null
            }
            withContext(ioDispatcher) {
                runCatching {
                    store.complete(
                        meetingId,
                        entry.copy(
                            status = status,
                            answer = resolved.answer,
                            failure = failure,
                            assistantMessageId = resolved.assistantMessageId,
                            answerTruncated = resolved.truncated,
                        ),
                    )
                }
            }
        }
        reloadEntriesIfSelected(meetingId)
    }

    // ---------------------------------------------------------------- helpers

    fun close() {
        availabilityJob?.cancel()
        availabilityJob = null
        synchronized(lock) { closed = true }
        // The native run belongs to the run domain. Detaching the page never
        // cancels it and never discards a completed answer: in-flight jobs keep
        // writing the durable result, and a rebuilt page reconciles pending
        // entries through checkAgain/reconcilePending.
    }

    private fun isCurrentTurn(turn: ActiveTurn): Boolean = synchronized(lock) {
        turns[turn.meetingId] === turn && !turn.finished.get()
    }

    private fun setPhase(turn: ActiveTurn, phase: MeetingAssistantTurnPhase) {
        synchronized(lock) {
            if (turns[turn.meetingId] !== turn) return
            turn.phase = phase
            if (selectedMeetingId == turn.meetingId) {
                updateLocked { current -> current.copy(active = turn.view()) }
            }
        }
    }

    private fun failTurn(turn: ActiveTurn, failure: MeetingAssistantFailure) {
        if (!turn.finished.compareAndSet(false, true)) return
        turn.stream?.close()
        turn.stream = null
        synchronized(lock) {
            turns.remove(turn.meetingId)
            if (selectedMeetingId == turn.meetingId) {
                updateLocked { current ->
                    current.copy(active = null, error = failure)
                }
            }
        }
    }

    private suspend fun reloadEntriesIfSelected(meetingId: String) {
        val epoch = synchronized(lock) {
            if (selectedMeetingId == meetingId) selectionEpoch else -1L
        }
        if (epoch < 0L) return
        val binding = withContext(ioDispatcher) { store.load(meetingId) }
        synchronized(lock) {
            if (selectionEpoch == epoch && selectedMeetingId == meetingId) {
                updateLocked { current ->
                    current.copy(
                        entries = binding.entries,
                        historyUnreadable = binding.unreadable,
                    )
                }
            }
        }
    }

    private fun publishErrorFor(
        meetingId: String,
        failure: MeetingAssistantFailure,
    ) {
        synchronized(lock) {
            if (selectedMeetingId != meetingId) return
            updateLocked { current -> current.copy(error = failure) }
        }
    }

    private fun publishAvailability() {
        val facts = synchronized(lock) {
            AvailabilityFacts(
                providerAdmitted = providerAdmitted,
                modelsLoaded = modelsLoaded,
                models = latestModels,
                preferredModelId = preferredModelId,
                storedModelId = meetingModelId,
            )
        }
        val availability = MeetingAssistantWire.resolveAvailability(
            runtimeReady = (host.nativeRootEpoch() ?: 0L) > 0L,
            providerAdmitted = facts.providerAdmitted,
            modelsLoaded = facts.modelsLoaded,
            models = facts.models,
            preferredModelId = facts.preferredModelId,
            storedModelId = facts.storedModelId,
        )
        synchronized(lock) {
            if (closed) return
            updateLocked { current -> current.copy(availability = availability) }
        }
    }

    private fun updateLocked(transform: (MeetingAssistantState) -> MeetingAssistantState) {
        val current = stateFlow.value
        val next = transform(current)
        if (next != current) stateFlow.value = next
    }

    private data class AvailabilityFacts(
        val providerAdmitted: Boolean,
        val modelsLoaded: Boolean,
        val models: List<ModelOptionUi>,
        val preferredModelId: String?,
        val storedModelId: String?,
    )

    private companion object {
        const val QUERY_TIMEOUT_MILLIS = 15_000L
        const val MAX_RECONCILE_ENTRIES = 3
    }
}
