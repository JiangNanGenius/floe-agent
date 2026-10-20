// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY synthetic preview for the conversation presentation flow.
//
// This source lives in `src/debug` ONLY: it is part of the debug variant and
// is NEVER compiled into a release build, never reachable from production
// navigation, and never contains real history. Every value is synthetic and
// the mandatory notice bar says so. It exists so the binder/UI qualification
// stage can inspect composition (thread rows, approval card, plan/goal strip,
// queue, history list) before the shared bridge is wired; the real entry is
// [FloeConversationDestination] / [FloeConversationHistoryDestination].
//
// The synthetic host returns "started" for pure UI inspection only and never
// touches a network, store, credential or file. Since the REAL bounded
// commonmark adapter qualified in this module, the debug host now runs
// ACTUAL parses off the UI thread through [MarkdownParseService] and echoes
// generation-fenced results back on the main thread — this is the same
// adapter seam a future production host binds, not a synthetic projection.

package com.floe.android.feature.conversation

import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.contracts.EventCursor
import com.floe.android.contracts.Revision
import com.floe.android.design.Floe
import com.floe.android.design.FloeText

@Composable
fun ConversationUiSyntheticPreview(modifier: Modifier = Modifier) {
    // REAL adapter through the qualified bounded service (debug-only host
    // wiring; the production binder stage reuses the same seam).
    val parseService = remember { MarkdownParseService() }
    DisposableEffect(parseService) {
        onDispose { parseService.close() }
    }
    val host = remember(parseService) {
        SyntheticConversationHost(parseService)
    }
    val holder = remember(host) {
        ConversationFlowHolder(host, "synthetic-conversation").also { h ->
            h.applyHostSnapshot(syntheticThreadState(h.session))
            host.onParseResult = { session, source, generation, blocks ->
                h.applyMarkdownParseResult(session, source, generation, blocks)
            }
        }
    }
    Column(modifier = modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.10f))
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        FloeConversationDestination(holder = holder)
    }
}

@Composable
fun HistoryUiSyntheticPreview(modifier: Modifier = Modifier) {
    val parseService = remember { MarkdownParseService() }
    DisposableEffect(parseService) {
        onDispose { parseService.close() }
    }
    val host = remember(parseService) { SyntheticConversationHost(parseService) }
    val holder = remember(host) {
        ConversationHistoryHolder(host).also { it.applyHostState(syntheticHistoryState()) }
    }
    Column(modifier = modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.10f))
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        FloeConversationHistoryDestination(holder = holder)
    }
}

/* ----------------------------- synthetic fixtures ---------------------------- */

private fun syntheticThreadState(session: ConversationSessionToken): ThreadUiState {
    val assistantSource = "## Synthetic summary\n\n- first point\n- second point\n\n```kotlin\nval synthetic = true\n```"
    val approval = syntheticApprovalCard(session)
    return ThreadUiState(
        session = session,
        taskTitle = "Synthetic task",
        isTemporary = false,
        temporaryIncarnationId = null,
        promotedConversationId = null,
        isConversationMissing = false,
        hasLoaded = true,
        hasProviderActivity = true,
        needsProvider = false,
        runs = listOf(RunRowUi("synthetic-run-1", "streamingModel", "synthetic-model-1", "10:00")),
        selectedRunId = "synthetic-run-1",
        liveStateName = "streamingModel",
        isRunning = true,
        isDraining = false,
        selectedRunWaitingForJobs = false,
        rows = listOf(
            TimelineRowUi.UserMessage(
                MessageUi(
                    id = "synthetic-msg-1",
                    conversationId = session.conversationId,
                    runId = "synthetic-run-1",
                    role = MessageRoleUi.USER,
                    text = "Synthetic prompt (no real data)",
                    attachmentChips = listOf(
                        AttachmentChipUi("synthetic-att-1", "synthetic-notes.md", isImage = false, attachmentId = null),
                    ),
                    timeLabel = "10:00",
                )
            ),
            TimelineRowUi.StepGroup(
                groupId = "synthetic-group-1",
                isLatest = true,
                events = listOf(
                    RunEventUi(
                        id = "synthetic-event-1",
                        runId = "synthetic-run-1",
                        sequence = 1,
                        kind = RunEventKindUi.TOOL_REQUEST,
                        timeLabel = "10:00",
                        tool = ToolEventProjectionUi(
                            callId = "synthetic-call-1",
                            toolName = "workspace.writeFile",
                            statusRaw = "pending",
                            inputSummary = "path=synthetic.txt",
                        ),
                    )
                ),
            ),
            TimelineRowUi.Event(
                RunEventUi(
                    id = "synthetic-reasoning",
                    runId = "synthetic-run-1",
                    sequence = 2,
                    kind = RunEventKindUi.REASONING,
                    timeLabel = "10:00",
                    reasoningExcerpt = "Synthetic reasoning excerpt. Not a real model output.",
                )
            ),
            TimelineRowUi.LiveAssistantTail,
            TimelineRowUi.Approval(approval),
            TimelineRowUi.Terminal(
                RunEventUi(
                    id = "synthetic-terminal",
                    runId = "synthetic-run-1",
                    sequence = 9,
                    kind = RunEventKindUi.TERMINAL,
                    timeLabel = "10:01",
                    stopReason = "completed",
                )
            ),
        ),
        pendingApprovals = listOf(approval),
        pendingInputs = listOf(
            PendingInputUi(
                id = "synthetic-input-1",
                content = "Synthetic queued follow-up",
                status = PendingInputStatusUi.QUEUED,
                mode = RunningInputModeUi.QUEUE,
                executionModeRaw = "agent",
                position = 0,
                trustedSummary = null,
            )
        ),
        models = listOf(ModelOptionUi("synthetic-model-1", "synthetic/wire-model", "Synthetic model", "synthetic-provider", "Synthetic provider", true)),
        projects = listOf(ProjectOptionUi("synthetic-project-1", "Synthetic workspace")),
        // Explicit host binding projection (never inferred from list order).
        boundWorkspaceId = "synthetic-project-1",
        approvalMode = ApprovalModeUi.ASK,
        usage = UsageUi(100, 50, 120, 2000, isEstimatedLive = true, cacheReadTokens = 40),
        contextUsage = UsageUi(100, 50, 120, 2000, isEstimatedLive = false),
        compactionStatus = null,
        canContinue = false,
        continuationTitle = null,
        continuationDetail = null,
        hasEarlierMessages = false,
        loadingEarlierMessages = false,
        loadingEventRunIds = emptySet(),
        earlierMessageCursor = null,
        importantFiles = listOf(ImportantFileUi("synthetic/notes.md", "Edited")),
        checklist = null,
        plan = PlanUi(
            id = "synthetic-plan-1",
            title = "Synthetic plan title",
            statusRaw = "ready",
            isDecisionComplete = true,
            executionRecommendation = PlanRecommendationUi.NORMAL,
            recommendationReason = "Synthetic recommendation reason",
            revisionNumber = 1,
            revision = Revision("synthetic-plan-1", "synthetic-digest-1"),
        ),
        goal = GoalUi("synthetic-goal-1", "Synthetic goal objective", "active", 1, 3),
        childRuns = emptyList(),
        decisions = emptyList(),
        liveAssistantText = assistantSource,
        liveReasoningText = "",
        networkActionsAvailable = true,
        usesLocalModel = false,
        voiceAvailable = false,
        capabilityChips = emptyList(),
    )
}

private fun syntheticApprovalCard(session: ConversationSessionToken) = ApprovalCardUi(
    approvalId = "synthetic-call-1",
    runId = "synthetic-run-1",
    conversationId = session.conversationId,
    workspaceId = null,
    toolName = "workspace.writeFile",
    target = ApprovalTargetUi.Local,
    scopeDescription = "local",
    reason = "Synthetic approval reason for layout inspection",
    riskLabels = setOf("writesFiles"),
    isSideEffecting = true,
    requestedAtLabel = "10:00",
    evidenceLines = listOf("path: synthetic/notes.md", "bytes: 128"),
)

// NOTE: the earlier synthetic Markdown projector was REMOVED once the real
// commonmark adapter qualified — the debug preview now renders genuine parsed
// blocks (still over clearly synthetic, banner-labelled content).

private fun syntheticHistoryState(): HistoryListUiState = HistoryListUiState(
    isLoading = false,
    items = listOf(
        ConversationListItemUi("synthetic-1", "Synthetic chat one", "10:00", "completed", false, null),
        ConversationListItemUi("synthetic-2", "Synthetic chat two", "10:01", "streamingModel", false, null),
    ),
    archivedItems = listOf(
        ConversationListItemUi("synthetic-3", "Synthetic archived chat", "09:00", null, true, "09:30"),
    ),
    contentSnippets = emptyMap(),
    searchEpoch = 0,
    isSearching = false,
    needsProvider = false,
    runningConversationIds = emptySet(),
    bulkProgress = null,
    networkActionsAvailable = true,
)

/* ------------------------------- synthetic host ------------------------------ */

private class SyntheticConversationHost(
    private val parseService: MarkdownParseService,
) : ConversationUiCallbacks {

    private val mainHandler = Handler(Looper.getMainLooper())

    var onParseResult: ((ConversationSessionToken, String, Long, List<MarkdownBlockUi>?) -> Unit)? = null

    override fun loadThread(session: ConversationSessionToken) = Unit
    override fun threadViewDetached(session: ConversationSessionToken) = Unit
    override fun requestOpenConversation(sourceSession: ConversationSessionToken?, conversationId: String) = true
    override fun requestNewTask(sourceSession: ConversationSessionToken?) = true
    override fun startRun(
        request: RunLaunchRequest,
        onOutcome: ((admitted: Boolean, reason: String?) -> Unit)?,
    ) = true
    override fun submitRunningInput(request: RunningInputRequest) = true
    override fun cancelRun(session: ConversationSessionToken, runId: String) = true
    override fun retryRun(session: ConversationSessionToken, runId: String) = true
    override fun promotePendingInput(session: ConversationSessionToken, inputId: String, expectedRunId: String) = true
    override fun editPendingInput(session: ConversationSessionToken, inputId: String, content: String) = true
    override fun removePendingInput(session: ConversationSessionToken, inputId: String) = true
    override fun reorderPendingInputs(session: ConversationSessionToken, orderedInputIds: List<String>) = true
    override fun resolveApproval(request: ApprovalDecisionRequest) = true
    override fun loadEarlierMessages(session: ConversationSessionToken) = true
    override fun loadEarlierEvents(session: ConversationSessionToken, cursor: EventCursor) = true
    override fun requestAttachmentImport(session: ConversationSessionToken) = true
    override fun retryAttachmentImport(session: ConversationSessionToken, attachmentId: String) = true
    override fun cancelAttachmentImport(session: ConversationSessionToken, attachmentId: String) = true
    override fun discardStagedAttachment(session: ConversationSessionToken, attachmentId: String) = Unit
    override fun openMessageAttachment(session: ConversationSessionToken, request: AttachmentOpenRequest) = true
    override fun acceptPlan(session: ConversationSessionToken, planId: String, revision: Revision, execution: PlanRecommendationUi) = true
    override fun createGoal(request: GoalCreateRequest) = true
    override fun confirmGoalCompletion(session: ConversationSessionToken, goalId: String) = true
    override fun selectModel(session: ConversationSessionToken, modelId: String) = true
    override fun setRunningInputMode(session: ConversationSessionToken, mode: RunningInputModeUi) = true
    override fun saveDraft(session: ConversationSessionToken, text: String, attachmentIds: List<String>, caretIndex: Int?, selectionLength: Int?) = Unit
    override fun clearDraftAfterSend(session: ConversationSessionToken, sentText: String, sentAttachmentIds: List<String>) = Unit
    override fun requestManualCompaction(session: ConversationSessionToken) = true
    override fun exportStructuredConversation(session: ConversationSessionToken) = true
    override fun shareConversationText(session: ConversationSessionToken, asMarkdown: Boolean) = true
    override fun refreshMediaJobs(session: ConversationSessionToken) = true
    override fun openTaskPermissions(session: ConversationSessionToken) = true
    override fun openWorkspaceFile(session: ConversationSessionToken, relativePath: String) = true
    override fun showInspector(content: InspectorRouteUi, conversationId: String) = Unit
    override fun loadChildRunDetail(session: ConversationSessionToken, childRunId: String) = true
    override fun keepTemporaryChat(ref: TemporarySessionRef) = true
    override fun endTemporaryChat(ref: TemporarySessionRef) = true
    override fun reloadHistory() = Unit
    override fun createConversation() = true
    override fun archiveConversation(conversationId: String) = true
    override fun restoreConversation(conversationId: String) = true
    override fun deleteConversation(conversationId: String) = true
    override fun requestContentSearch(query: String, epoch: Long) = true
    override fun requestBulk(operation: TaskBulkOperationUi, conversationIds: List<String>, token: Long) = true
    override fun cancelBulk(token: Long) = Unit

    override fun requestMarkdownParse(session: ConversationSessionToken, source: String, generation: Long): Boolean =
        // REAL bounded adapter off the UI thread; the generation-fenced echo
        // returns to the main thread exactly as a production host binding
        // would (no synchronous fake projection any more).
        parseService.schedule(source, generation) { echoedSource, echoedGeneration, blocks ->
            mainHandler.post { onParseResult?.invoke(session, echoedSource, echoedGeneration, blocks) }
        }

    override fun openMessageLink(session: ConversationSessionToken, urlString: String) = true
    override fun openRichArtifactPreview(session: ConversationSessionToken, artifactId: String) = true
    override fun copyMessageText(session: ConversationSessionToken, text: String) = true
    override fun speakMessageText(session: ConversationSessionToken, text: String) = true
    override fun stopSpeaking(session: ConversationSessionToken) = Unit
    override fun saveMessageToNotes(session: ConversationSessionToken, text: String) = true
}
