// SPDX-License-Identifier: MPL-2.0
//
// Shared synthetic fixtures for the conversation module's JVM unit tests.
// Everything here is synthetic: no provider, database, network, credential
// store, file system or Android runtime is involved. The fake host records
// every effect in order so tests can assert EXACT effect count and arguments
// (including the navigation source-token contract).

package com.floe.android.feature.conversation

import com.floe.android.contracts.EventCursor
import com.floe.android.contracts.Revision

/** One recorded host effect: name + the exact arguments the module passed. */
data class HostEffect(val name: String, val args: List<Any?> = emptyList())

class RecordingHost : ConversationUiCallbacks {

    val effects = mutableListOf<HostEffect>()

    // Test knobs: an effect returning false = "the host did not start it".
    var startRunAccepted = true
    var submitAccepted = true
    var keepStarted = true
    var endStarted = true
    var openConversationAccepted = true
    var newTaskAccepted = true
    var markdownBackendAvailable = true
    var selectModelPersisted = true

    /** C04 queue-body lane: default false = "the host refused the bounded
     * body read" (the interface default); calls are recorded so tests can
     * assert exact dispatch counts and retry behaviour. */
    var pendingBodyReadAccepted = false

    private fun record(name: String, vararg args: Any?) {
        effects += HostEffect(name, args.toList())
    }

    fun names(): List<String> = effects.map { it.name }
    fun count(name: String): Int = effects.count { it.name == name }
    fun lastArgs(name: String): List<Any?>? = effects.lastOrNull { it.name == name }?.args

    override fun loadThread(session: ConversationSessionToken) = record("loadThread", session)
    override fun threadViewDetached(session: ConversationSessionToken) = record("threadViewDetached", session)

    override fun requestOpenConversation(sourceSession: ConversationSessionToken?, conversationId: String): Boolean {
        record("requestOpenConversation", sourceSession, conversationId)
        return openConversationAccepted
    }

    override fun requestNewTask(sourceSession: ConversationSessionToken?): Boolean {
        record("requestNewTask", sourceSession)
        return newTaskAccepted
    }

    override fun startRun(request: RunLaunchRequest, onOutcome: ((Boolean, String?) -> Unit)?): Boolean {
        record("startRun", request)
        return startRunAccepted
    }

    override fun submitRunningInput(request: RunningInputRequest): Boolean {
        record("submitRunningInput", request)
        return submitAccepted
    }

    override fun cancelRun(session: ConversationSessionToken, runId: String): Boolean {
        record("cancelRun", session, runId); return true
    }

    override fun retryRun(session: ConversationSessionToken, runId: String): Boolean {
        record("retryRun", session, runId); return true
    }

    override fun promotePendingInput(session: ConversationSessionToken, inputId: String, expectedRunId: String): Boolean {
        record("promotePendingInput", session, inputId, expectedRunId); return true
    }

    override fun requestPendingInputBody(session: ConversationSessionToken, inputId: String): Boolean {
        record("requestPendingInputBody", session, inputId)
        return pendingBodyReadAccepted
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

    /** What the host would answer for the on-demand single-slot capture. Null
     * by default: a live TTY alone is not a blocker under the separated pool. */
    var liveTerminalConsent: TerminalHandoffConsentUi? = null

    override fun liveTerminalHandoffConsent(
        session: ConversationSessionToken,
    ): TerminalHandoffConsentUi? {
        record("liveTerminalHandoffConsent", session)
        return liveTerminalConsent
    }

    override fun loadEarlierMessages(session: ConversationSessionToken): Boolean {
        record("loadEarlierMessages", session); return true
    }

    override fun loadEarlierEvents(session: ConversationSessionToken, cursor: EventCursor): Boolean {
        record("loadEarlierEvents", session, cursor); return true
    }

    var threadSearchAccepted = true
    var revealAccepted = true
    var pendingQuestionAccepted = true
    var questionAnswerAccepted = true
    var questionCancelAccepted = true

    override fun requestThreadSearch(
        session: ConversationSessionToken, query: String, epoch: Long,
    ): Boolean {
        record("requestThreadSearch", session, query, epoch)
        return threadSearchAccepted
    }

    override fun revealThreadSearchHit(
        session: ConversationSessionToken, messageId: String, requestToken: Long,
    ): Boolean {
        record("revealThreadSearchHit", session, messageId, requestToken)
        return revealAccepted
    }

    override fun requestPendingQuestion(
        session: ConversationSessionToken, requestId: String?,
    ): Boolean {
        record("requestPendingQuestion", session, requestId)
        return pendingQuestionAccepted
    }

    override fun answerUserQuestion(
        session: ConversationSessionToken, request: UserQuestionAnswerRequestUi,
    ): Boolean {
        record("answerUserQuestion", session, request)
        return questionAnswerAccepted
    }

    override fun cancelUserQuestion(
        session: ConversationSessionToken, requestId: String,
    ): Boolean {
        record("cancelUserQuestion", session, requestId)
        return questionCancelAccepted
    }

    override fun requestAttachmentImport(session: ConversationSessionToken): Boolean {
        record("requestAttachmentImport", session); return true
    }

    override fun retryAttachmentImport(session: ConversationSessionToken, attachmentId: String): Boolean {
        record("retryAttachmentImport", session, attachmentId); return true
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

    override fun acceptPlan(session: ConversationSessionToken, planId: String,
        planRevision: Int, planDigest: String, execution: PlanRecommendationUi?,
        modelId: String?, providerId: String?): Boolean {
        record("acceptPlan", session, planId, planRevision, planDigest, execution, modelId, providerId); return true
    }

    override fun createGoal(request: GoalCreateRequest): Boolean {
        record("createGoal", request); return true
    }

    override fun confirmGoalCompletion(session: ConversationSessionToken, goalId: String,
        expectedRevision: Int, revisionResourceID: String, revisionVersion: String): Boolean {
        record("confirmGoalCompletion", session, goalId, expectedRevision, revisionResourceID, revisionVersion); return true
    }

    override fun selectModel(session: ConversationSessionToken, modelId: String): Boolean {
        record("selectModel", session, modelId); return selectModelPersisted
    }

    override fun setRunningInputMode(session: ConversationSessionToken, mode: RunningInputModeUi): Boolean {
        record("setRunningInputMode", session, mode); return true
    }

    override fun saveDraft(session: ConversationSessionToken, text: String, attachmentIds: List<String>, caretIndex: Int?, selectionLength: Int?) {
        record("saveDraft", session, text, attachmentIds, caretIndex, selectionLength)
    }

    override fun clearDraftAfterSend(session: ConversationSessionToken, sentText: String, sentAttachmentIds: List<String>) {
        record("clearDraftAfterSend", session, sentText, sentAttachmentIds)
    }

    override fun requestManualCompaction(session: ConversationSessionToken, modelId: String?): Boolean {
        record("requestManualCompaction", session, modelId); return true
    }

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
        record("loadChildRunDetail", session, childRunId); return true
    }

    override fun keepTemporaryChat(ref: TemporarySessionRef): Boolean {
        record("keepTemporaryChat", ref); return keepStarted
    }

    override fun endTemporaryChat(ref: TemporarySessionRef): Boolean {
        record("endTemporaryChat", ref); return endStarted
    }

    override fun reloadHistory() = record("reloadHistory")

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

    override fun renameConversation(conversationId: String, title: String, requestToken: Long): Boolean {
        record("renameConversation", conversationId, title, requestToken); return true
    }

    override fun requestContentSearch(query: String, epoch: Long): Boolean {
        record("requestContentSearch", query, epoch); return true
    }

    override fun requestBulk(operation: TaskBulkOperationUi, conversationIds: List<String>, token: Long): Boolean {
        record("requestBulk", operation, conversationIds, token); return true
    }

    override fun cancelBulk(token: Long) = record("cancelBulk", token)

    override fun requestMarkdownParse(session: ConversationSessionToken, source: String, generation: Long): Boolean {
        record("requestMarkdownParse", session, source, generation)
        return markdownBackendAvailable
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

/* --------------------------------- fixtures --------------------------------- */

fun model(id: String = "model-1", usable: Boolean = true) = ModelOptionUi(
    modelId = id,
    remoteModelId = "wire-$id",
    displayName = "Model $id",
    providerId = "provider-1",
    providerName = "Provider",
    isUsable = usable,
)

fun stagedAttachment(
    id: String = "attachment-1",
    owner: String = "conv-1",
    lifecycle: AttachmentImportUi = AttachmentImportUi.Ready,
) = StagedAttachmentUi(
    id = id,
    displayName = "notes.md",
    mimeType = "text/markdown",
    kind = AttachmentKindUi.DOCUMENT,
    byteCount = 128,
    sha256 = "0".repeat(64),
    ownerConversationId = owner,
    import = lifecycle,
)

fun approvalCard(
    callId: String = "call-1",
    runId: String = "run-1",
    conversationId: String = "conv-1",
    target: ApprovalTargetUi = ApprovalTargetUi.Local,
    reason: String = "Needs file writes",
    riskLabels: Set<String> = setOf("writesFiles"),
) = ApprovalCardUi(
    approvalId = callId,
    runId = runId,
    conversationId = conversationId,
    workspaceId = null,
    toolName = "workspace.writeFile",
    target = target,
    scopeDescription = "local",
    reason = reason,
    riskLabels = riskLabels,
    isSideEffecting = true,
    requestedAtLabel = "10:00",
    evidenceLines = listOf("path: notes.md"),
)

fun pendingInput(
    id: String = "input-1",
    status: PendingInputStatusUi = PendingInputStatusUi.QUEUED,
    content: String = "follow up",
) = PendingInputUi(
    id = id,
    content = content,
    status = status,
    mode = RunningInputModeUi.QUEUE,
    executionModeRaw = "agent",
    position = 0,
    trustedSummary = null,
)

/** Complete immutable projection fixture. Every field is synthetic; no
 * durable store, network or provider is represented. */
fun threadState(
    session: ConversationSessionToken,
    isTemporary: Boolean = false,
    temporaryIncarnationId: String? = null,
    promotedConversationId: String? = null,
    isRunning: Boolean = false,
    rows: List<TimelineRowUi> = emptyList(),
    pendingApprovals: List<ApprovalCardUi> = emptyList(),
    pendingInputs: List<PendingInputUi> = emptyList(),
    plan: PlanUi? = null,
    goal: GoalUi? = null,
    importantFiles: List<ImportantFileUi> = emptyList(),
    needsProvider: Boolean = false,
    canContinue: Boolean = false,
    hasLoaded: Boolean = true,
    liveAssistantText: String = "",
    liveReasoningText: String = "",
    voiceAvailable: Boolean = false,
    models: List<ModelOptionUi> = listOf(model()),
    // A RUNNING projection always owns a displayed run (host truth); an idle
    // one without rows honestly has none.
    selectedRunId: String? = if (rows.isEmpty() && !isRunning) null else "run-1",
    liveStateName: String? = null,
    runStateName: String = "idle",
    usage: UsageUi? = null,
    contextUsage: UsageUi? = null,
    childDetails: Map<String, ChildRunDetailUi> = emptyMap(),
    decisions: List<ToolDecisionUi> = emptyList(),
    childRuns: List<ChildRunUi> = emptyList(),
    checklist: ChecklistUi? = null,
    projects: List<ProjectOptionUi> = listOf(ProjectOptionUi("project-1", "Project")),
    /** Explicit host workspace binding (Main addendum): defaults to the
     * single canonical project; null or a foreign id are passed by the
     * binding-ordering tests. */
    boundWorkspaceId: String? = if (projects.size == 1) projects[0].id else null,
    approvalMode: ApprovalModeUi = ApprovalModeUi.ASK,
    capabilityChips: List<CapabilityChipUi> = emptyList(),
) = ThreadUiState(
    session = session,
    taskTitle = "Task",
    isTemporary = isTemporary,
    temporaryIncarnationId = temporaryIncarnationId,
    promotedConversationId = promotedConversationId,
    isConversationMissing = false,
    hasLoaded = hasLoaded,
    hasProviderActivity = isRunning,
    needsProvider = needsProvider,
    runs = listOf(RunRowUi("run-1", runStateName, "model-1", "09:59")),
    selectedRunId = selectedRunId,
    liveStateName = liveStateName,
    isRunning = isRunning,
    isDraining = false,
    selectedRunWaitingForJobs = false,
    rows = rows,
    pendingApprovals = pendingApprovals,
    pendingInputs = pendingInputs,
    models = models,
    projects = projects,
    boundWorkspaceId = boundWorkspaceId,
    approvalMode = approvalMode,
    usage = usage,
    contextUsage = contextUsage,
    compactionStatus = null,
    canContinue = canContinue,
    continuationTitle = null,
    continuationDetail = null,
    hasEarlierMessages = false,
    loadingEarlierMessages = false,
    loadingEventRunIds = emptySet(),
    earlierMessageCursor = null,
    importantFiles = importantFiles,
    checklist = checklist,
    plan = plan,
    goal = goal,
    childRuns = childRuns,
    decisions = decisions,
    childDetails = childDetails,
    liveAssistantText = liveAssistantText,
    liveReasoningText = liveReasoningText,
    networkActionsAvailable = true,
    usesLocalModel = false,
    voiceAvailable = voiceAvailable,
    capabilityChips = capabilityChips,
)

fun historyState(
    items: List<ConversationListItemUi> = listOf(
        ConversationListItemUi("conv-1", "First", "10:00", null, false, null),
        ConversationListItemUi("conv-2", "Second", "10:01", null, false, null),
        ConversationListItemUi("conv-3", "Third", "10:02", null, false, null),
    ),
    archivedItems: List<ConversationListItemUi> = listOf(
        ConversationListItemUi("conv-9", "Archived", "09:00", null, true, "09:30"),
    ),
    contentSnippets: Map<String, String> = emptyMap(),
    searchEpoch: Long = 0,
    isSearching: Boolean = false,
    loading: Boolean = false,
    runningIds: Set<String> = emptySet(),
) = HistoryListUiState(
    isLoading = loading,
    items = items,
    archivedItems = archivedItems,
    contentSnippets = contentSnippets,
    searchEpoch = searchEpoch,
    isSearching = isSearching,
    needsProvider = false,
    runningConversationIds = runningIds,
    bulkProgress = null,
    networkActionsAvailable = true,
)
