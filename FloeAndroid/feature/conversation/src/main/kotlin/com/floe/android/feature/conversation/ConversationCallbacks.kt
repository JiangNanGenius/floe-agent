// SPDX-License-Identifier: MPL-2.0
//
// The single narrow seam between the conversation presentation flow (this
// module) and the host that owns EVERY real effect (shared Swift services
// behind the accepted bridge): run start/cancel/retry, queue/steer, approval
// resolution, attachments import, plan/goal commands, temporary-session
// keep/end, history mutations and bulk task management.
//
// The module NEVER performs I/O, never persists, never parses provider or
// event wire bytes, and never renders success on its own. Async results
// arrive exclusively as new immutable [ThreadUiState] / [HistoryListUiState]
// projections addressed to the matching [ConversationSessionToken]; stale
// identities are ignored (epoch contract).
//
// Every effect that can start an operation returns Boolean: true means the
// host actually STARTED it; false means nothing began and the UI must not
// claim progress. Fire-and-observe routing requests return Unit and only ask
// the host to navigate/own chrome.

package com.floe.android.feature.conversation

import com.floe.android.contracts.EventCursor
import com.floe.android.contracts.Revision

/* ------------------------------- request types ------------------------------ */

/**
 * Presentation-only correlation identity for ONE launch attempt (Main's
 * async-launch addendum): an accepted `startRun` is an OWNED-PREPARATION
 * ADMISSION, not an atomic durable prepare. The host MUST echo exactly one
 * terminal outcome per admitted launch — prepared (⇄ the real atomic prepare
 * / started acknowledgment) or failed (⇄ preflight rejection) — carrying the
 * IMMUTABLE fields of this correlation back through
 * [ConversationFlowHolder.applyLaunchPrepared] /
 * [ConversationFlowHolder.applyLaunchFailure].
 *
 * [launchGeneration] is a monotonic per-holder fencing counter. It is NOT a
 * domain id: the real host owns task/run identities, this token only fences
 * late echoes so a stale outcome from request A can never restore or consume
 * request B (or another route). Nothing here is persisted and the host must
 * never treat it as a conversation/run id.
 */
data class LaunchCorrelation(
    val conversationId: String,
    val sessionEpoch: Long,
    val launchGeneration: Long,
    val temporaryIncarnationId: String?,
) {
    init {
        require(launchGeneration > 0) { "launchGeneration must be positive" }
    }
}

/** ⇄ center.startRun / submitRunningInput argument envelope. [goalText] is
 * sensitive user content and is masked by [toString]. */
data class RunLaunchRequest(
    val conversationId: String,
    val sessionEpoch: Long,
    val goalText: String,
    val attachments: List<StagedAttachmentUi>,
    val executionMode: AgentExecutionModeUi,
    val modelId: String?,
    val workspaceId: String?,
    /** The session incarnation a temporary send belongs to; null for ordinary
     * conversations. A late callback may only touch this send's drafts while
     * the SAME incarnation is current (⇄ SendOrigin gate). */
    val temporaryIncarnationId: String?,
    /** ⇄ startOrigin: .explicitUserAction — UI sends are always explicit;
     * this module never auto-retries external effects. */
    val startOrigin: StartOriginUi = StartOriginUi.EXPLICIT_USER_ACTION,
    /** Presentation fencing generation for this launch (see [LaunchCorrelation]). */
    val launchGeneration: Long = 0,
    /** The REAL provider identity of [modelId] (native `run.start` requires
     * `providerID` + `modelID` as UUIDs; the composer projection carries the
     * exact owning provider). */
    val providerId: String? = null,
    /**
     * The draft-task approval mode the user explicitly chose on the Home
     * launchpad for the FIRST launch of this new conversation (⇄
     * DraftTaskPermissionsSheet persisted atomically with the first launch).
     * Null = no explicit draft choice: the key is omitted and the native
     * ORIGINAL default (`.ask`) applies. Never set for a temporary launch
     * (temporary chats bind no permission surface) and never re-sent once
     * the conversation owns a durable task-policy row.
     */
    val approvalMode: ApprovalModeUi? = null,
    /**
     * The structured goal definition for an existing-thread goal-mode
     * launch (⇄ approved `run.start` additive `goalDefinition` key).
     * Non-null ONLY for an ordinary (non-temporary) GOAL launch produced by
     * the thread GoalBuilder. Absent = the original generic goal path
     * (native `ensureDurableGoal` mints the default goal). The App never
     * writes a goal row directly and never flattens criteria into the goal
     * text.
     */
    val goalDefinition: GoalDefinitionUi? = null,
) {
    /** The immutable correlation the host must echo back verbatim with this
     * launch's prepared/failed outcome. */
    fun correlation(): LaunchCorrelation = LaunchCorrelation(
        conversationId = conversationId,
        sessionEpoch = sessionEpoch,
        launchGeneration = launchGeneration,
        temporaryIncarnationId = temporaryIncarnationId,
    )

    override fun toString(): String =
        "RunLaunchRequest(conv=$conversationId, epoch=$sessionEpoch, chars=${goalText.length}, " +
            "attachments=${attachments.size}, mode=${executionMode.swiftRaw}, model=$modelId, " +
            "launchGen=$launchGeneration)"
}

/** ⇄ center.submitRunningInput(content:in:expectedRunID:mode:…). */
data class RunningInputRequest(
    val conversationId: String,
    val sessionEpoch: Long,
    val expectedRunId: String,
    val content: String,
    val mode: RunningInputModeUi,
    val modelId: String?,
    val workspaceId: String?,
    val executionMode: AgentExecutionModeUi,
    val attachments: List<StagedAttachmentUi>,
    val temporaryIncarnationId: String?,
) {
    override fun toString(): String =
        "RunningInputRequest(conv=$conversationId, run=$expectedRunId, mode=${mode.swiftRaw}, " +
            "chars=${content.length}, attachments=${attachments.size})"
}

/** ⇄ ConversationCenter.startOrigin vocabulary (only explicit user actions
 * exist on this surface; automatic/dependency origins are host-internal). */
enum class StartOriginUi { EXPLICIT_USER_ACTION }

/**
 * The user's decision on one EXACT approval. [scopeGrant] is the projection of
 * the chosen tier for the projected target — the host maps it to the real
 * ApprovalScope (single-use / run-lifetime / workspace paths / host-wide) and
 * enforces the catastrophic gate independently. The UI grant proposal NEVER
 * comes from imported content: only a human tap on this card produces it.
 */
data class ApprovalDecisionRequest(
    val conversationId: String,
    val sessionEpoch: Long,
    val approvalId: String,
    val runId: String,
    val workspaceId: String?,
    val toolName: String,
    val decision: ApprovalUserDecisionUi,
    /** ⇄ ApprovalScope mapping (once/task/project/host × local/host/hostPath). */
    val grant: ApprovalGrantUi?,
    val reason: String?,
) {
    override fun toString(): String =
        "ApprovalDecisionRequest(approval=$approvalId, run=$runId, decision=$decision)"
}

/** ⇄ ApprovalDecision subset a human can emit from the card. */
sealed interface ApprovalUserDecisionUi {
    data class Allow(val scopeChoice: ApprovalScopeChoiceUi) : ApprovalUserDecisionUi
    data object Deny : ApprovalUserDecisionUi
}

/** UI projection of the grant tier, computed from the chosen tier + the
 * projected target (pure; the host remains the grant authority). */
data class ApprovalGrantUi(
    val toolName: String,
    val hostId: String?,
    val paths: List<String>,
    val singleUse: Boolean,
)

/** ⇄ GoalBuilderSheet fields (one per line already split by the caller).
 * [modelId]/[providerId] are the thread's ACTUAL selected configured model
 * identities; the host refuses a goal launch without them (never a
 * first-usable substitution). */
data class GoalCreateRequest(
    val conversationId: String,
    val sessionEpoch: Long,
    val objective: String,
    val criteria: List<String>,
    val blockingConditions: List<String>,
    val stoppingConditions: List<String>,
    val modelId: String? = null,
    val providerId: String? = null,
) {
    override fun toString(): String =
        "GoalCreateRequest(conv=$conversationId, objectiveChars=${objective.length}, " +
            "criteria=${criteria.size})"
}

/**
 * The structured goal definition carried by an existing-thread goal-mode
 * `run.start` (approved additive `goalDefinition` key). Field bounds
 * (objective ≤16384, ≤32 criteria ×2048, ≤16+16 conditions ×2048) are the
 * NATIVE parser's; the App trims, drops empty entries and refuses an
 * over-budget producer field typed BEFORE dispatch instead of letting the
 * bridge truncate it. The empty-criteria default criterion is the native
 * ORIGINAL rule — the App never composes it locally.
 */
data class GoalDefinitionUi(
    val objective: String,
    val criteria: List<String>,
    val blockingConditions: List<String>,
    val stoppingConditions: List<String>,
) {
    /** The native parser's closed bounds (UTF-8 BYTES, not chars). The host
     * refuses an over-budget producer typed BEFORE dispatch; nothing is ever
     * truncated on the way to the bridge. */
    fun exceedsNativeBounds(): Boolean {
        if (objective.trim().utf8Bytes() > MAX_OBJECTIVE_BYTES) return true
        val c = criteria.map { it.trim() }.filter { it.isNotEmpty() }
        if (c.size > MAX_CRITERIA || c.any { it.utf8Bytes() > MAX_ITEM_BYTES }) return true
        val b = blockingConditions.map { it.trim() }.filter { it.isNotEmpty() }
        if (b.size > MAX_CONDITIONS || b.any { it.utf8Bytes() > MAX_ITEM_BYTES }) return true
        val s = stoppingConditions.map { it.trim() }.filter { it.isNotEmpty() }
        if (s.size > MAX_CONDITIONS || s.any { it.utf8Bytes() > MAX_ITEM_BYTES }) return true
        return false
    }

    /** Trimmed, empty-dropped arrays; null when empty (ABSENT key — the
     * ORIGINAL native default-criterion rule stays Swift-side). */
    fun boundedCriteria(): List<String>? =
        criteria.map { it.trim() }.filter { it.isNotEmpty() }.takeIf { it.isNotEmpty() }

    fun boundedBlockingConditions(): List<String>? =
        blockingConditions.map { it.trim() }.filter { it.isNotEmpty() }.takeIf { it.isNotEmpty() }

    fun boundedStoppingConditions(): List<String>? =
        stoppingConditions.map { it.trim() }.filter { it.isNotEmpty() }.takeIf { it.isNotEmpty() }

    /** Sensitive user content: masked like the goal text. */
    override fun toString(): String =
        "GoalDefinitionUi(objectiveChars=${objective.length}, criteria=${criteria.size}, " +
            "blocking=${blockingConditions.size}, stopping=${stoppingConditions.size})"

    companion object {
        const val MAX_OBJECTIVE_BYTES = 16_384
        const val MAX_ITEM_BYTES = 2_048
        const val MAX_CRITERIA = 32
        const val MAX_CONDITIONS = 16
    }
}

private fun String.utf8Bytes(): Int = toByteArray(Charsets.UTF_8).size

/** ⇄ ConversationCenter temporary keep/end identity pair. Both ids must match
 * the host's live session exactly; a replacement generation reusing the same
 * conversation id is a different incarnation and rejects the stale call.
 *
 * G02 native epoch separation (MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION_20261019):
 * `sessionEpoch` stays the UI holder/session/disposal counter;
 * `nativeRootEpoch` is the ACTUAL trusted native root-generation epoch
 * bound from the authoritative temp.start value (or bootstrap readback).
 * Default -1 = unbound: the navigation fence can never admit until the
 * trusted host binds a real native epoch — never a fabricated 0 and never
 * the UI counter echoed as authority. */
data class TemporarySessionRef(
    val conversationId: String,
    val sessionEpoch: Long,
    val incarnationId: String,
    val nativeRootEpoch: Long = -1L,
)

/** ⇄ AppRouter.InspectorRoute.content routing request (chrome stays host-owned). */
enum class InspectorRouteUi {
    PROGRESS,
    WORKSPACE_FILES,
    CHANGES,
    BROWSER,
    TERMINAL,
    CHILD_AGENTS,
    PERMISSIONS,
}

/* --------------------------------- the seam --------------------------------- */

interface ConversationUiCallbacks {

    /* ------------------------------ thread load ------------------------------ */

    /** Request the initial snapshot + live subscription for this session. */
    fun loadThread(session: ConversationSessionToken)

    /** The destination left the thread: stop live updates for this session
     * (⇄ stopLiveUpdates). Presentation drafts survive; owned live tasks do
     * not transfer to this view. THIS IS NOT A NAVIGATION: an Activity/view
     * detach (onDisappear-equivalent) must never discard temporary RAM state
     * — the host keeps the session exactly as iOS does, and only a genuine
     * route change or New Task fences and destroys it. */
    fun threadViewDetached(session: ConversationSessionToken)

    /**
     * Navigation effects carry an EXPLICIT SOURCE TOKEN so the host can
     * revalidate the authoritative current route before obeying:
     *  - [sourceSession] == null: a direct user tap on the history/management
     *    surface (it always navigates);
     *  - [sourceSession] != null: a thread surface asks to navigate. After a
     *    genuine navigation the host's current route authority no longer
     *    matches this token, so a late callback from a RETAINED old holder
     *    cannot hijack the new route — the host returns false and nothing
     *    happens. Returning true means the host actually navigated for this
     *    exact source.
     */
    fun requestOpenConversation(sourceSession: ConversationSessionToken?, conversationId: String): Boolean

    /** ⇄ router.startNewTask(): same source-token contract as above. */
    fun requestNewTask(sourceSession: ConversationSessionToken?): Boolean

    /* -------------------------------- run control ---------------------------- */

    /**
     * ⇄ center.startRun. TRUE means the host ADMITTED the launch into its
     * OWNED PREPARATION (the real BridgeV3 enqueue receipt is NOT an atomic
     * durable prepare). It is NOT permission to claim a started run or to
     * destroy the draft permanently: the host MUST echo exactly one terminal
     * outcome back for the request's immutable correlation —
     * [ConversationFlowHolder.applyLaunchPrepared] when the run actually
     * durably started (atomic prepare complete), or
     * [ConversationFlowHolder.applyLaunchFailure] when preflight rejected it.
     * The holder consumes the durable draft only on the matching prepared
     * echo and reversibly restores the visual draft on the matching failure;
     * outcomes carrying stale/foreign correlations are ignored (never block
     * the UI/JNI waiting for the async native work).
     */
    fun startRun(
        request: RunLaunchRequest,
        onOutcome: ((admitted: Boolean, reason: String?) -> Unit)? = null,
    ): Boolean

    /** ⇄ center.submitRunningInput (queue/steer while a run owns the thread). */
    fun submitRunningInput(request: RunningInputRequest): Boolean

    /** ⇄ center.cancel(runID:). Stop is explicit and only touches THIS run. */
    fun cancelRun(session: ConversationSessionToken, runId: String): Boolean

    /** ⇄ center.retry(runID:): resume the durable run without duplicating its
     * user message. */
    fun retryRun(session: ConversationSessionToken, runId: String): Boolean

    /** ⇄ promoteToSteer(inputID:expectedRunID:). */
    fun promotePendingInput(session: ConversationSessionToken, inputId: String, expectedRunId: String): Boolean

    fun editPendingInput(session: ConversationSessionToken, inputId: String, content: String): Boolean

    fun removePendingInput(session: ConversationSessionToken, inputId: String): Boolean

    /** ⇄ reorderPendingInputs(orderedIDs:) — queue order only; the host
     * re-reads the durable queue afterwards. */
    fun reorderPendingInputs(session: ConversationSessionToken, orderedInputIds: List<String>): Boolean

    /* --------------------------------- approvals ------------------------------ */

    /** ⇄ center.resolve(approval, decision:) for the EXACT run+call identity.
     * True only when the host accepted the decision for that identity. */
    fun resolveApproval(request: ApprovalDecisionRequest): Boolean

    /* ---------------------------------- paging ------------------------------- */

    /** ⇄ loadEarlierMessages (bounded page; cursor owned by the host store). */
    fun loadEarlierMessages(session: ConversationSessionToken): Boolean

    /** ⇄ loadEarlierEvents(runID:) via an explicit (runId, sequence) cursor. */
    fun loadEarlierEvents(session: ConversationSessionToken, cursor: EventCursor): Boolean

    /* -------------------------------- attachments ----------------------------- */

    /** Open the platform picker for THIS conversation's composer; the host
     * performs the bounded MIME/size/path validation on import
     * (CHA-ATTACH-INGEST-AND). True = picker/host import actually started. */
    fun requestAttachmentImport(session: ConversationSessionToken): Boolean

    /** Retry a FAILED import row (same attachment id, host re-derives bytes). */
    fun retryAttachmentImport(session: ConversationSessionToken, attachmentId: String): Boolean

    /** Cancel an IN-PROGRESS import; a late success callback cannot resurrect
     * the removed row (CHA-ATTACH-LIFECYCLE-AND). */
    fun cancelAttachmentImport(session: ConversationSessionToken, attachmentId: String): Boolean

    /** Drop a staged (never-sent) attachment; host releases any lease. */
    fun discardStagedAttachment(session: ConversationSessionToken, attachmentId: String)

    /** ⇄ ChatAttachmentOpenSheet: open one message attachment through the
     * host's ownership-checked path (exact conversation/message/attachment
     * identity; no fabricated grant). */
    fun openMessageAttachment(session: ConversationSessionToken, request: AttachmentOpenRequest): Boolean

    /* ------------------------------ plan / goal ------------------------------ */

    /**
     * ⇄ acceptLatestPlan(as:) over the approved `plan.accept` command:
     * [planRevision]+[planDigest] are the EXACT members of the durable plan
     * the user saw (from the `conversation.get` plan projection — never a
     * locally bumped number); [execution] is the user's explicit choice or
     * null to keep the plan's own durable recommendation; [modelId]/
     * [providerId] are the thread's ACTUAL selected model identities. The
     * host binds the CURRENT conversation-row digest CAS and consumes the
     * SAME prepared/started/terminal receipt flow as `run.start` — the plan
     * accept IS the one launch (never a separate run.start).
     */
    fun acceptPlan(
        session: ConversationSessionToken,
        planId: String,
        planRevision: Int,
        planDigest: String,
        execution: PlanRecommendationUi?,
        modelId: String?,
        providerId: String?,
    ): Boolean

    /** ⇄ createGoal(...): the host starts the goal-mode run with the
     * structured `goalDefinition` (the native C1 owns the durable goal row). */
    fun createGoal(request: GoalCreateRequest): Boolean

    /**
     * ⇄ confirmGoalCompletion() (host evaluates the completion gate). The
     * trusted command itself is the explicit human action; [expectedRevision]
     * + [revisionResourceID]/[revisionVersion] are the goal's ACTUAL server
     * fields (envelope version echoes `revisionVersion` verbatim). A blocked
     * or stale result never persists a confirmation — the host re-reads the
     * durable truth and surfaces the typed blockers.
     */
    fun confirmGoalCompletion(
        session: ConversationSessionToken,
        goalId: String,
        expectedRevision: Int,
        revisionResourceID: String,
        revisionVersion: String,
    ): Boolean

    /* --------------------------- composer side effects ------------------------ */

    /** ⇄ selectedModelID persistence through center preferences; false means
     * the durable default was NOT changed (banner, honest current state). */
    fun selectModel(session: ConversationSessionToken, modelId: String): Boolean

    /** ⇄ settingsCenter.runningInputMode persistence. */
    fun setRunningInputMode(session: ConversationSessionToken, mode: RunningInputModeUi): Boolean

    /** ⇄ ComposerDraftStore durable save (host debounces and stamps revisions;
     * the module only calls this while the temporary handoff gate allows it). */
    fun saveDraft(session: ConversationSessionToken, text: String, attachmentIds: List<String>, caretIndex: Int?, selectionLength: Int?)

    /** ⇄ clearDraft on a consumed send (the host keeps its revision floor).
     * The holder now calls this ONLY from the matching
     * [ConversationFlowHolder.applyLaunchPrepared] echo — never on the
     * synchronous admission — so a preflight failure can reverse the launch
     * without any durable draft loss. */
    fun clearDraftAfterSend(session: ConversationSessionToken, sentText: String, sentAttachmentIds: List<String>)

    /**
     * ⇄ requestManualCompaction over the approved `conversation.compact`
     * command (no revision — the core owns the reservation/quiescence
     * guard). [modelId] is the thread's ACTUAL selected model or null, in
     * which case the native side uses the persisted default (never a
     * first-usable substitution). The reply is the REAL
     * compacted/noHistory/shortHistory outcome; the host composes the
     * localized status line from it.
     */
    fun requestManualCompaction(session: ConversationSessionToken, modelId: String?): Boolean

    /* ------------------------------ thread menu actions ---------------------- */

    /** ⇄ exportStructuredConversation (host writes the file + share sheet). */
    fun exportStructuredConversation(session: ConversationSessionToken): Boolean

    /** ⇄ ShareLink(exportText/exportMarkdown): the host serializes and shares
     * the durable transcript; formats are host-resolved. */
    fun shareConversationText(session: ConversationSessionToken, asMarkdown: Boolean): Boolean

    /** ⇄ refreshMediaJobs: reconcile this task's durable media jobs once. */
    fun refreshMediaJobs(session: ConversationSessionToken): Boolean

    /** ⇄ TaskPermissionsInspectorView presentation (host owns the sheet). */
    fun openTaskPermissions(session: ConversationSessionToken): Boolean

    /** ⇄ FilePreviewView for one important-file shortcut: the host resolves
     * the relative path behind its workspace guard and presents the preview;
     * this module never touches the filesystem itself. */
    fun openWorkspaceFile(session: ConversationSessionToken, relativePath: String): Boolean

    /** ⇄ router.showInspector(content, conversationID). */
    fun showInspector(content: InspectorRouteUi, conversationId: String)

    /** ⇄ presentedChild sheet: request the durable child transcript (bounded). */
    fun loadChildRunDetail(session: ConversationSessionToken, childRunId: String): Boolean

    /* ------------------------------ temporary chat --------------------------- */

    /** ⇄ keepTemporaryChat(expectedConversationID:expectedIncarnation:).
     * Atomic promotion is host-side; the UI flips to durable state only when
     * the projection confirms THIS incarnation promoted. */
    fun keepTemporaryChat(ref: TemporarySessionRef): Boolean

    /** ⇄ endTemporaryChat(expectedConversationID:expectedIncarnation:):
     * cancels owned runs and discards RAM content synchronously host-side. */
    fun endTemporaryChat(ref: TemporarySessionRef): Boolean

    /* --------------------------------- history -------------------------------- */

    /** ⇄ ConversationListViewModel.load / center.reload. */
    fun reloadHistory()

    /** ⇄ createConversation(title: nil); the host opens the new thread itself. */
    fun createConversation(): Boolean

    /** ⇄ archiveConversation(id:) / restoreConversation(id:) / deleteConversation(id:). */
    fun archiveConversation(conversationId: String): Boolean
    fun restoreConversation(conversationId: String): Boolean
    fun deleteConversation(conversationId: String): Boolean

    /** Existing native conversation.rename CAS; no optimistic title change. */
    fun renameConversation(conversationId: String, title: String, requestToken: Long): Boolean = false

    /** ⇄ matchingConversationSnippets(query): the durable FTS authority runs
     * the search (incl. CJK); [epoch] echoes into [HistoryListUiState.searchEpoch]
     * so stale pages cannot land. */
    fun requestContentSearch(query: String, epoch: Long): Boolean

    /** ⇄ ConversationTaskBulkService.run(operation:items:cancellation:) —
     * existing single-target lifecycle commands composed by the host; [token]
     * identifies this batch for [cancelBulk]. True only if the batch started. */
    fun requestBulk(operation: TaskBulkOperationUi, conversationIds: List<String>, token: Long): Boolean

    /** ⇄ TaskBulkCancellationToken.cancel(): stop the batch after the current
     * item; already-run effects stay durable and the receipt says so. */
    fun cancelBulk(token: Long)

    /* ---------------------------- content affordances ------------------------ */

    /**
     * ASYNC projection request for one Markdown fragment. The module NEVER
     * parses Markdown, never embeds HTML, and never blocks composition:
     * requests are scheduled post-composition; the host runs the actual
     * parse OFF the UI thread through the qualified portable adapter
     * (the original Swift FloeMarkdown module is NOT part of the current
     * Android shared overlay; see ConversationMarkdownUi.kt header — the
     * AST/dependency qualification is an unresolved integration gate) and
     * echoes (session, source, generation, blocks-or-null) back to
     * [ConversationFlowHolder.applyMarkdownParseResult]. True means the host
     * SCHEDULED this generation; false means no backend exists and the UI
     * keeps the honest literal recovery rendering (content is never dropped
     * and styled parity is never claimed).
     */
    fun requestMarkdownParse(session: ConversationSessionToken, source: String, generation: Long): Boolean

    /** Markdown link tap: launch through the APPROVED host browser surface
     * (⇄ environment browser/LinkPresentation routing). The module never
     * fetches and treats link text as untrusted content, never a permission. */
    fun openMessageLink(session: ConversationSessionToken, urlString: String): Boolean

    /** Rich-artifact interactive preview: the host opens its digest-verified
     * sandboxed surface (⇄ SandboxedArtifactWebView); this module never
     * embeds a WebView or renders raw HTML. */
    fun openRichArtifactPreview(session: ConversationSessionToken, artifactId: String): Boolean

    /** Copy one message text (⇄ UIPasteboard). The host owns the clipboard. */
    fun copyMessageText(session: ConversationSessionToken, text: String): Boolean

    /** Read-aloud request (⇄ SpeechService): only offered when the host
     * projects the capability as usable; no local synthesis is implied. */
    fun speakMessageText(session: ConversationSessionToken, text: String): Boolean
    fun stopSpeaking(session: ConversationSessionToken)

    /** ⇄ onSaveToNotes (embedded surfaces): host decides availability. */
    fun saveMessageToNotes(session: ConversationSessionToken, text: String): Boolean
}
