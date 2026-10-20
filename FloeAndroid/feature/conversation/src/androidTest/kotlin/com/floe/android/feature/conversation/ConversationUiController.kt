// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY synthetic controller for the conversation component fixture.
//
// Everything here is labelled synthetic: no provider, database, network,
// credential store or file system is involved. The host implements the real
// 52-callback seam, records every effect with its exact arguments, runs the
// REAL bounded commonmark adapter off the UI thread through
// [MarkdownParseService] (echoing results on the main thread like a future
// production host), and demonstrates the async launch admission/prepare/
// failure correlation contract with honest delays. It never mints durable
// domain ids and never touches a real backend.

package com.floe.android.feature.conversation

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import com.floe.android.contracts.EventCursor
import com.floe.android.contracts.Revision
import java.util.Collections

enum class ConversationUiScenario {
    EMPTY,
    MISSING_PROVIDER,
    STREAMING,
    APPROVAL,
    ERROR_CONTINUATION,
    COMPACT_COMPOSER,
    FULL_EDITOR,
    TEMP_BADGE,
    TEMP_ABOUT,
    TEMP_KEEP,
    TEMP_DISCARD,
    HISTORY_SEARCH,
    HISTORY_MANAGE,
    HISTORY_ARCHIVE,
    CHILD_TRANSCRIPT,
    GOAL_PLAN,
    MARKDOWN_RICH,
    MARKDOWN_HEADER,
    MARKDOWN_BODY,
    USER_LONG,
}

/** How the synthetic host answers the launch admission contract. */
enum class LaunchEcho { NONE, PREPARE, FAIL }

internal class ConversationFixtureHost(
    private val main: Handler,
    private val parseService: MarkdownParseService,
) : ConversationUiCallbacks {

    val effects: MutableList<HostCall> = Collections.synchronizedList(mutableListOf())

    var launchEcho: LaunchEcho = LaunchEcho.NONE
    /** Set by the controller before each scenario: echoes route back here. */
    var threadHolder: ConversationFlowHolder? = null
    var historyHolder: ConversationHistoryHolder? = null
    var keepsRequested = 0
    var bulkTokenStarted: Long? = null

    fun names(): List<String> = synchronized(effects) { effects.map { it.name } }
    fun count(name: String): Int = synchronized(effects) { effects.count { it.name == name } }
    fun lastArgs(name: String): List<Any?>? = synchronized(effects) { effects.lastOrNull { it.name == name }?.args }
    fun resetEffects() = synchronized(effects) { effects.clear() }

    private fun record(name: String, vararg args: Any?) = synchronized(effects) { effects += HostCall(name, args.toList()) }

    data class HostCall(val name: String, val args: List<Any?>)

    /* ------------------------------ thread load ------------------------------ */

    override fun loadThread(session: ConversationSessionToken) = record("loadThread", session)
    override fun threadViewDetached(session: ConversationSessionToken) = record("threadViewDetached", session)
    override fun requestOpenConversation(sourceSession: ConversationSessionToken?, conversationId: String): Boolean {
        record("requestOpenConversation", sourceSession, conversationId)
        return true
    }

    override fun requestNewTask(sourceSession: ConversationSessionToken?): Boolean {
        record("requestNewTask", sourceSession)
        return true
    }

    /* -------------------------------- launch --------------------------------- */

    override fun startRun(request: RunLaunchRequest): Boolean {
        record("startRun", request)
        val holder = threadHolder ?: return true
        when (launchEcho) {
            LaunchEcho.NONE -> Unit
            LaunchEcho.PREPARE -> main.postDelayed(
                { holder.applyLaunchPrepared(request.correlation()) },
                120L,
            )
            LaunchEcho.FAIL -> main.postDelayed(
                { holder.applyLaunchFailure(request.correlation(), "synthetic preflight rejection") },
                120L,
            )
        }
        return true
    }

    override fun submitRunningInput(request: RunningInputRequest): Boolean {
        record("submitRunningInput", request)
        return true
    }

    override fun cancelRun(session: ConversationSessionToken, runId: String): Boolean {
        record("cancelRun", session, runId); return true
    }

    override fun retryRun(session: ConversationSessionToken, runId: String): Boolean {
        record("retryRun", session, runId); return true
    }

    /* --------------------------- queue & approvals --------------------------- */

    override fun promotePendingInput(session: ConversationSessionToken, inputId: String, expectedRunId: String): Boolean {
        record("promotePendingInput", session, inputId, expectedRunId); return true
    }

    override fun editPendingInput(session: ConversationSessionToken, inputId: String, content: String): Boolean {
        record("editPendingInput", session, inputId, content); return true
    }

    override fun removePendingInput(session: ConversationSessionToken, inputId: String): Boolean {
        record("removePendingInput", session, inputId); return true
    }

    override fun reorderPendingInputs(session: ConversationSessionToken, orderedInputIds: List<String>): Boolean {
        record("reorderPendingInputs", session, orderedInputIds); return true
    }

    override fun resolveApproval(request: ApprovalDecisionRequest): Boolean {
        record("resolveApproval", request); return true
    }

    /* ------------------------------- paging ---------------------------------- */

    override fun loadEarlierMessages(session: ConversationSessionToken): Boolean {
        record("loadEarlierMessages", session); return true
    }

    override fun loadEarlierEvents(session: ConversationSessionToken, cursor: EventCursor): Boolean {
        record("loadEarlierEvents", session, cursor); return true
    }

    /* ------------------------------ attachments ------------------------------ */

    override fun requestAttachmentImport(session: ConversationSessionToken): Boolean {
        record("requestAttachmentImport", session)
        // Synthetic picker outcome: the staged row appears on the next
        // generation-0 reconstruction, so the fixture seeds via handoff.
        return true
    }

    override fun retryAttachmentImport(session: ConversationSessionToken, attachmentId: String): Boolean {
        record("retryAttachmentImport", session, attachmentId)
        threadHolder?.let { holder ->
            main.postDelayed({ holder.applyAttachmentOutcome(attachmentId, AttachmentImportUi.Ready) }, 100L)
        }
        return true
    }

    override fun cancelAttachmentImport(session: ConversationSessionToken, attachmentId: String): Boolean {
        record("cancelAttachmentImport", session, attachmentId); return true
    }

    override fun discardStagedAttachment(session: ConversationSessionToken, attachmentId: String) {
        record("discardStagedAttachment", session, attachmentId)
    }

    override fun openMessageAttachment(session: ConversationSessionToken, request: AttachmentOpenRequest): Boolean {
        record("openMessageAttachment", session, request); return true
    }

    /* ------------------------------ plan & goal ------------------------------ */

    override fun acceptPlan(
        session: ConversationSessionToken,
        planId: String,
        revision: Revision,
        execution: PlanRecommendationUi,
    ): Boolean {
        record("acceptPlan", session, planId, revision, execution); return true
    }

    override fun createGoal(request: GoalCreateRequest): Boolean {
        record("createGoal", request); return true
    }

    override fun confirmGoalCompletion(session: ConversationSessionToken, goalId: String): Boolean {
        record("confirmGoalCompletion", session, goalId); return true
    }

    /* ------------------------------- composer -------------------------------- */

    override fun selectModel(session: ConversationSessionToken, modelId: String): Boolean {
        record("selectModel", session, modelId); return true
    }

    override fun setRunningInputMode(session: ConversationSessionToken, mode: RunningInputModeUi): Boolean {
        record("setRunningInputMode", session, mode); return true
    }

    override fun saveDraft(
        session: ConversationSessionToken,
        text: String,
        attachmentIds: List<String>,
        caretIndex: Int?,
        selectionLength: Int?,
    ) {
        record("saveDraft", session, text.length, attachmentIds, caretIndex, selectionLength)
    }

    override fun clearDraftAfterSend(session: ConversationSessionToken, sentText: String, sentAttachmentIds: List<String>) {
        record("clearDraftAfterSend", session, sentText, sentAttachmentIds)
    }

    override fun requestManualCompaction(session: ConversationSessionToken): Boolean {
        record("requestManualCompaction", session); return true
    }

    /* ------------------------------ thread menu ------------------------------- */

    override fun exportStructuredConversation(session: ConversationSessionToken): Boolean {
        record("exportStructuredConversation", session); return true
    }

    override fun shareConversationText(session: ConversationSessionToken, asMarkdown: Boolean): Boolean {
        record("shareConversationText", session, asMarkdown); return true
    }

    override fun refreshMediaJobs(session: ConversationSessionToken): Boolean {
        record("refreshMediaJobs", session); return true
    }

    override fun openTaskPermissions(session: ConversationSessionToken): Boolean {
        record("openTaskPermissions", session); return true
    }

    override fun openWorkspaceFile(session: ConversationSessionToken, relativePath: String): Boolean {
        record("openWorkspaceFile", session, relativePath); return true
    }

    override fun showInspector(content: InspectorRouteUi, conversationId: String) {
        record("showInspector", content, conversationId)
    }

    override fun loadChildRunDetail(session: ConversationSessionToken, childRunId: String): Boolean {
        record("loadChildRunDetail", session, childRunId)
        val holder = threadHolder ?: return true
        main.postDelayed(
            {
                val state = holder.snapshot.value ?: return@postDelayed
                holder.applyHostSnapshot(
                    state.copy(
                        childDetails = state.childDetails + (
                            childRunId to ChildRunDetailUi(
                                childRunId = childRunId,
                                title = "Synthetic child transcript",
                                stateName = "completed",
                                rows = listOf(
                                    TimelineRowUi.AssistantMessage(
                                        rowId = "child-assistant-1",
                                        text = "Synthetic delegated work summary.",
                                    ),
                                ),
                            )
                            ),
                    ),
                )
            },
            100L,
        )
        return true
    }

    /* ------------------------------ temporary -------------------------------- */

    override fun keepTemporaryChat(ref: TemporarySessionRef): Boolean {
        record("keepTemporaryChat", ref)
        keepsRequested += 1
        val holder = threadHolder ?: return true
        val outcome: TemporaryKeepOutcomeUi =
            if (keepsRequested == 1) TemporaryKeepOutcomeUi.TailPending
            else TemporaryKeepOutcomeUi.Failed("synthetic keep retry")
        main.postDelayed({ holder.applyTemporaryKeepOutcome(ref, outcome) }, 120L)
        return true
    }

    override fun endTemporaryChat(ref: TemporarySessionRef): Boolean {
        record("endTemporaryChat", ref); return true
    }

    /* -------------------------------- history -------------------------------- */

    override fun reloadHistory() {
        record("reloadHistory")
    }

    override fun createConversation(): Boolean {
        record("createConversation"); return true
    }

    override fun archiveConversation(conversationId: String): Boolean {
        record("archiveConversation", conversationId); return true
    }

    override fun restoreConversation(conversationId: String): Boolean {
        record("restoreConversation", conversationId); return true
    }

    override fun deleteConversation(conversationId: String): Boolean {
        record("deleteConversation", conversationId); return true
    }

    override fun requestContentSearch(query: String, epoch: Long): Boolean {
        record("requestContentSearch", query, epoch)
        val holder = historyHolder ?: return true
        main.postDelayed(
            {
                holder.state.value?.let { current ->
                    holder.applyHostState(
                        current.copy(
                            contentSnippets = if (query.contains("first", ignoreCase = true)) {
                                mapOf("conv-1" to "…synthetic FIRST content hit…")
                            } else {
                                emptyMap()
                            },
                            searchEpoch = epoch,
                            isSearching = false,
                        ),
                    )
                }
            },
            120L,
        )
        return true
    }

    override fun requestBulk(operation: TaskBulkOperationUi, conversationIds: List<String>, token: Long): Boolean {
        record("requestBulk", operation, conversationIds, token)
        bulkTokenStarted = token
        val holder = historyHolder ?: return true
        main.postDelayed(
            {
                holder.applyBulkReceipt(
                    BulkReceiptUi(
                        operation = operation,
                        results = conversationIds.mapIndexed { index, id ->
                            BulkItemResultUi(
                                conversationId = id,
                                title = "Synthetic $id",
                                outcome = if (index < conversationIds.size - 1) {
                                    when (operation) {
                                        TaskBulkOperationUi.ARCHIVE -> BulkItemOutcomeUi.Archived
                                        TaskBulkOperationUi.RESTORE -> BulkItemOutcomeUi.Restored
                                        TaskBulkOperationUi.DELETE -> BulkItemOutcomeUi.Deleted
                                    }
                                } else {
                                    BulkItemOutcomeUi.Skipped(BulkSkipReasonUi.ALREADY_IN_TARGET_STATE)
                                },
                            )
                        },
                        wasCancelled = false,
                    ),
                )
            },
            150L,
        )
        return true
    }

    override fun cancelBulk(token: Long) = record("cancelBulk", token)

    /* ----------------------------- content actions ---------------------------- */

    override fun requestMarkdownParse(session: ConversationSessionToken, source: String, generation: Long): Boolean {
        record("requestMarkdownParse", session, source.length, generation)
        val holder = threadHolder ?: return false
        return parseService.schedule(source, generation) { s, g, blocks ->
            main.post { holder.applyMarkdownParseResult(session, s, g, blocks) }
        }
    }

    override fun openMessageLink(session: ConversationSessionToken, urlString: String): Boolean {
        record("openMessageLink", session, urlString); return true
    }

    override fun openRichArtifactPreview(session: ConversationSessionToken, artifactId: String): Boolean {
        record("openRichArtifactPreview", session, artifactId); return true
    }

    override fun copyMessageText(session: ConversationSessionToken, text: String): Boolean {
        record("copyMessageText", session, text); return true
    }

    override fun speakMessageText(session: ConversationSessionToken, text: String): Boolean {
        record("speakMessageText", session, text); return true
    }

    override fun stopSpeaking(session: ConversationSessionToken) = record("stopSpeaking", session)

    override fun saveMessageToNotes(session: ConversationSessionToken, text: String): Boolean {
        record("saveMessageToNotes", session, text); return true
    }
}

/* ------------------------------- fixtures -------------------------------- */

internal object UiFixtures {
    /** Corpus A (first assistant message): headings, lists, quote, table. */
    val richMarkdownA = """
        ## Rich synthetic summary

        1. Ordered **first** point
           - nested emoji 🎉
           - nested `code run`
        2. Ordered second point

        > quoted **emphasis** with a nested
        > - quote item

        | Metric | Value |
        |--------|-------|
        | 输入 | **1,234** |
        | 输出 | `567` |
        """.trimIndent()

    /** MARKDOWN_HEADER scenario: heading + nested lists only (fits one
     * bottom-anchored screen, so every styled node is genuinely displayed). */
    val richMarkdownHeader = """
        ## Rich synthetic summary

        1. Ordered **first** point
           - nested emoji 🎉
           - nested `code run`
        2. Ordered second point
        """.trimIndent()

    /** MARKDOWN_BODY scenario: quote + GFM table + verbatim code + rule +
     * CJK link (also single-screen). */
    val richMarkdownBody = """
        > quoted **emphasis** with a nested
        > - quote item

        | Metric | Value |
        |--------|-------|
        | 输入 | **1,234** |
        | 输出 | `567` |

        ```python
        def greet(name):  # verbatim 🐍
            return f"你好, {name}"
        ```

        ---

        See [the synthetic doc](https://example.invalid/文档) for details.
        """.trimIndent()

    /** Corpus B (second assistant message): code, rule, CJK link. */
    internal val richMarkdownB = """
        ```python
        def greet(name):  # verbatim 🐍
            return f"你好, {name}"
        ```

        ---

        See [the synthetic doc](https://example.invalid/文档) for details.
        """.trimIndent()

    fun threadState(
        session: ConversationSessionToken,
        scenario: ConversationUiScenario,
    ): ThreadUiState {
        val baseRows = when (scenario) {
            ConversationUiScenario.EMPTY,
            ConversationUiScenario.MISSING_PROVIDER,
            -> emptyList()

            // History scenarios never render the thread surface; the empty
            // branch keeps this builder total (defensive, not a product path).
            ConversationUiScenario.HISTORY_SEARCH,
            ConversationUiScenario.HISTORY_MANAGE,
            ConversationUiScenario.HISTORY_ARCHIVE,
            -> emptyList()

            ConversationUiScenario.STREAMING -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi("msg-1", session.conversationId, "run-1", MessageRoleUi.USER, "Synthetic long question?", timeLabel = "10:00"),
                ),
                TimelineRowUi.StepGroup(
                    groupId = "group-1",
                    isLatest = true,
                    events = listOf(
                        RunEventUi(
                            id = "ev-reason-1", runId = "run-1", sequence = 1,
                            kind = RunEventKindUi.REASONING, timeLabel = "10:00",
                            reasoningExcerpt = "Synthetic reasoning excerpt for the stream inspection.",
                        ),
                        RunEventUi(
                            id = "ev-tool-1", runId = "run-1", sequence = 2,
                            kind = RunEventKindUi.TOOL_REQUEST, timeLabel = "10:00",
                            tool = ToolEventProjectionUi(
                                callId = "call-1",
                                toolName = "workspace.list",
                                statusRaw = "running",
                                inputSummary = "path=Synthetic/",
                            ),
                        ),
                    ),
                ),
                TimelineRowUi.LiveAssistantTail,
            )

            ConversationUiScenario.APPROVAL -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi("msg-1", session.conversationId, "run-1", MessageRoleUi.USER, "Write the file please", timeLabel = "10:00"),
                ),
                TimelineRowUi.Event(
                    RunEventUi(
                        id = "ev-tool-1", runId = "run-1", sequence = 1,
                        kind = RunEventKindUi.TOOL_REQUEST, timeLabel = "10:01",
                        tool = ToolEventProjectionUi(
                            callId = "call-1",
                            toolName = "workspace.writeFile",
                            statusRaw = "pending",
                            inputSummary = "path=notes.md",
                        ),
                    ),
                ),
                TimelineRowUi.Approval(approvalCard()),
            )

            ConversationUiScenario.ERROR_CONTINUATION -> listOf(
                TimelineRowUi.Event(
                    RunEventUi(
                        id = "ev-error-1", runId = "run-1", sequence = 5,
                        kind = RunEventKindUi.ERROR, timeLabel = "10:05",
                        message = "synthetic provider stream broke",
                    ),
                ),
                TimelineRowUi.Terminal(
                    RunEventUi(
                        id = "ev-term-1", runId = "run-1", sequence = 6,
                        kind = RunEventKindUi.TERMINAL, timeLabel = "10:05",
                        stopReason = "failed",
                    ),
                ),
            )

            ConversationUiScenario.COMPACT_COMPOSER,
            ConversationUiScenario.FULL_EDITOR,
            ConversationUiScenario.TEMP_BADGE,
            ConversationUiScenario.TEMP_ABOUT,
            ConversationUiScenario.TEMP_KEEP,
            ConversationUiScenario.TEMP_DISCARD,
            -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi("msg-1", session.conversationId, null, MessageRoleUi.USER, "Earlier synthetic prompt", timeLabel = "09:58"),
                ),
            )

            ConversationUiScenario.CHILD_TRANSCRIPT -> listOf(
                TimelineRowUi.StepGroup(
                    groupId = "group-1",
                    isLatest = false,
                    events = listOf(
                        RunEventUi(
                            id = "ev-delegate", runId = "run-1", sequence = 1,
                            kind = RunEventKindUi.TOOL_REQUEST, timeLabel = "10:00",
                            tool = ToolEventProjectionUi(
                                callId = "call-1",
                                toolName = "agent.delegate",
                                statusRaw = "ok",
                                inputSummary = "subtask: summarise",
                                resultSummary = "delegated",
                            ),
                        ),
                    ),
                ),
            )

            ConversationUiScenario.GOAL_PLAN -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi("msg-1", session.conversationId, "run-1", MessageRoleUi.USER, "Plan the migration", timeLabel = "09:55"),
                ),
            )

            ConversationUiScenario.MARKDOWN_RICH -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi("msg-1", session.conversationId, "run-1", MessageRoleUi.USER, "Give me the rich report", timeLabel = "10:00"),
                ),
                TimelineRowUi.AssistantMessage(
                    rowId = "assistant-rich-a",
                    text = richMarkdownA,
                ),
                TimelineRowUi.AssistantMessage(
                    rowId = "assistant-rich-b",
                    text = richMarkdownB,
                ),
            )

            ConversationUiScenario.MARKDOWN_HEADER -> listOf(
                TimelineRowUi.AssistantMessage(rowId = "assistant-header", text = richMarkdownHeader),
            )

            ConversationUiScenario.MARKDOWN_BODY -> listOf(
                TimelineRowUi.AssistantMessage(rowId = "assistant-body", text = richMarkdownBody),
            )

            ConversationUiScenario.USER_LONG -> listOf(
                TimelineRowUi.UserMessage(
                    MessageUi(
                        id = "msg-long",
                        conversationId = session.conversationId,
                        runId = null,
                        role = MessageRoleUi.USER,
                        text = "Long synthetic prompt: " + "内容逐字保留 ".repeat(90),
                        timeLabel = "10:02",
                    ),
                ),
            )
        }

        val temporary = scenario in setOf(
            ConversationUiScenario.TEMP_BADGE,
            ConversationUiScenario.TEMP_ABOUT,
            ConversationUiScenario.TEMP_KEEP,
            ConversationUiScenario.TEMP_DISCARD,
        )

        return ThreadUiState(
            session = session,
            taskTitle = "Synthetic task",
            isTemporary = temporary,
            temporaryIncarnationId = if (temporary) "inc-1" else null,
            promotedConversationId = null,
            isConversationMissing = false,
            hasLoaded = true,
            hasProviderActivity = scenario == ConversationUiScenario.STREAMING,
            needsProvider = scenario == ConversationUiScenario.MISSING_PROVIDER,
            runs = if (baseRows.isEmpty()) emptyList() else listOf(RunRowUi("run-1", runState(scenario), "model-1", "09:59")),
            selectedRunId = when {
                scenario == ConversationUiScenario.STREAMING -> "run-1"
                baseRows.isEmpty() -> null
                else -> "run-1"
            },
            liveStateName = if (scenario == ConversationUiScenario.STREAMING) "streamingModel" else null,
            isRunning = scenario == ConversationUiScenario.STREAMING,
            isDraining = false,
            selectedRunWaitingForJobs = false,
            rows = baseRows,
            pendingApprovals = if (scenario == ConversationUiScenario.APPROVAL) listOf(approvalCard()) else emptyList(),
            pendingInputs = if (scenario == ConversationUiScenario.COMPACT_COMPOSER) {
                listOf(pendingInput("input-1"), pendingInput("input-2", content = "second synthetic queued item"))
            } else {
                emptyList()
            },
            models = listOf(modelOption("model-1")),
            projects = listOf(ProjectOptionUi("project-1", "Synthetic workspace")),
            boundWorkspaceId = if (temporary) null else "project-1",
            approvalMode = ApprovalModeUi.ASK,
            usage = if (scenario == ConversationUiScenario.STREAMING) UsageUi(900, 320, 1220, 200_000, isEstimatedLive = true) else null,
            contextUsage = if (scenario == ConversationUiScenario.EMPTY) null else UsageUi(900, 320, 1220, 200_000, isEstimatedLive = false),
            compactionStatus = null,
            canContinue = scenario == ConversationUiScenario.ERROR_CONTINUATION,
            continuationTitle = if (scenario == ConversationUiScenario.ERROR_CONTINUATION) "Synthetic continuation available" else null,
            continuationDetail = if (scenario == ConversationUiScenario.ERROR_CONTINUATION) "Continue when you are ready." else null,
            hasEarlierMessages = false,
            loadingEarlierMessages = false,
            loadingEventRunIds = emptySet(),
            earlierMessageCursor = null,
            importantFiles = if (scenario == ConversationUiScenario.GOAL_PLAN) {
                listOf(ImportantFileUi("synthetic/plan.md", "Edited"))
            } else {
                emptyList()
            },
            checklist = if (scenario == ConversationUiScenario.GOAL_PLAN) {
                ChecklistUi(
                    title = "Synthetic checklist",
                    currentStepTitle = "Step two",
                    progressSummary = "1/2",
                    steps = listOf(
                        ChecklistStepUi("s1", "Step one", ChecklistStepStatusUi.COMPLETED, listOf("synthetic evidence 1")),
                        ChecklistStepUi("s2", "Step two", ChecklistStepStatusUi.IN_PROGRESS, emptyList()),
                    ),
                )
            } else {
                null
            },
            plan = if (scenario == ConversationUiScenario.GOAL_PLAN) {
                PlanUi(
                    id = "plan-1",
                    title = "Synthetic plan",
                    statusRaw = "ready",
                    isDecisionComplete = true,
                    executionRecommendation = PlanRecommendationUi.NORMAL,
                    recommendationReason = "Synthetic recommendation reason",
                    revisionNumber = 3,
                    revision = Revision("plan-1", "digest-abc"),
                )
            } else {
                null
            },
            goal = if (scenario == ConversationUiScenario.GOAL_PLAN) {
                GoalUi("goal-1", "Synthetic verifying goal", "verifying", 2, 3)
            } else {
                null
            },
            childRuns = if (scenario == ConversationUiScenario.CHILD_TRANSCRIPT) {
                listOf(
                    ChildRunUi(
                        id = "child-1",
                        parentRunId = "run-1",
                        delegateCallId = "call-1",
                        stateName = "completed",
                        stateTitle = "Completed",
                        isTerminal = true,
                        title = "Synthetic delegated summary",
                        summary = null,
                        startedAtLabel = "10:00",
                    ),
                )
            } else {
                emptyList()
            },
            decisions = emptyList(),
            childDetails = emptyMap(),
            liveAssistantText = if (scenario == ConversationUiScenario.STREAMING) "Streaming synthetic **tail**…" else "",
            liveReasoningText = if (scenario == ConversationUiScenario.STREAMING) "synthetic live reasoning tail" else "",
            networkActionsAvailable = true,
            usesLocalModel = false,
            voiceAvailable = false,
            capabilityChips = emptyList(),
        )
    }

    private fun runState(scenario: ConversationUiScenario): String = when (scenario) {
        ConversationUiScenario.STREAMING -> "streamingModel"
        ConversationUiScenario.ERROR_CONTINUATION -> "failed"
        else -> "idle"
    }

    fun modelOption(id: String) = ModelOptionUi(
        modelId = id,
        remoteModelId = "wire-$id",
        displayName = "Synthetic model",
        providerId = "provider-1",
        providerName = "Synthetic provider",
        isUsable = true,
    )

    fun approvalCard() = ApprovalCardUi(
        approvalId = "call-1",
        runId = "run-1",
        conversationId = "conv-1",
        workspaceId = null,
        toolName = "workspace.writeFile",
        target = ApprovalTargetUi.Local,
        scopeDescription = "local",
        reason = "Synthetic approval: needs file writes",
        riskLabels = setOf("writesFiles"),
        isSideEffecting = true,
        requestedAtLabel = "10:01",
        evidenceLines = listOf("path: synthetic/notes.md", "bytes: 2048"),
    )

    fun pendingInput(id: String, content: String = "first synthetic queued item") = PendingInputUi(
        id = id,
        content = content,
        status = PendingInputStatusUi.QUEUED,
        mode = RunningInputModeUi.QUEUE,
        executionModeRaw = "agent",
        position = 0,
        trustedSummary = null,
    )

    fun staged(id: String, lifecycle: AttachmentImportUi = AttachmentImportUi.Ready) = StagedAttachmentUi(
        id = id,
        displayName = "synthetic-notes.md",
        mimeType = "text/markdown",
        kind = AttachmentKindUi.DOCUMENT,
        byteCount = 2048,
        sha256 = "0".repeat(64),
        ownerConversationId = "conv-1",
        import = lifecycle,
    )

    fun historyState(scenario: ConversationUiScenario) = HistoryListUiState(
        isLoading = false,
        items = listOf(
            ConversationListItemUi("conv-1", "First synthetic chat", "10:00", "completed", false, null),
            ConversationListItemUi("conv-2", "Second synthetic chat", "10:01", "streamingModel", false, null),
            ConversationListItemUi("conv-3", "Third synthetic chat", "10:02", null, false, null),
        ),
        archivedItems = if (scenario == ConversationUiScenario.HISTORY_ARCHIVE) {
            listOf(ConversationListItemUi("conv-9", "Archived synthetic chat", "09:00", null, true, "09:30"))
        } else {
            emptyList()
        },
        contentSnippets = emptyMap(),
        searchEpoch = 0,
        isSearching = false,
        needsProvider = false,
        runningConversationIds = if (scenario == ConversationUiScenario.HISTORY_MANAGE) setOf("conv-2") else emptySet(),
        bulkProgress = null,
        networkActionsAvailable = true,
    )
}
