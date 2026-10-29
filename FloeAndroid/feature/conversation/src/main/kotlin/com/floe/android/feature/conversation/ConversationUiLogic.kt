// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation logic extracted 1:1 from the original Swift sources so the
// composables stay declarative and the rules are JVM-testable without a
// device. Nothing here performs I/O, parses payloads, decides permissions or
// persists. Each object names its Swift authority in the KDoc.

package com.floe.android.feature.conversation

/* --------------------------- run state → presentation ----------------------- */

/** Semantic color ROLES (resolved through Floe.colors at render time). */
enum class FloeStateColorRole { ACCENT, PENDING, DESTRUCTIVE, SUCCESS, UNKNOWN }

/**
 * ⇄ FloeApp/Chat/RunStateLocalizer.swift — the ONLY mapping from run-state
 * machine names to presentation. Views must not interpret state names
 * themselves; unknown names fall back to the honest "unknown" state instead of
 * leaking raw machine text. Rule of record retained: an error event or the
 * failed state ends the loading state immediately.
 */
object FloeRunStateLocalizer {

    /** String-resource KEY names (the module maps them to EN/ZH strings; the
     * resource lookup happens at the Compose edge, never in this object). */
    fun titleKey(stateName: String): String = when (stateName) {
        "preparing", "idle" -> "state_preparing"
        "streamingModel" -> "state_streaming"
        "reconnecting" -> "state_reconnecting"
        "committingResults" -> "state_committing_results"
        "reviewingApproval" -> "state_reviewing_approval"
        "verifying" -> "state_verifying"
        "executingTool" -> "state_executing_tool"
        "waitingApproval" -> "state_waiting_approval"
        "compacting" -> "state_compacting"
        "checkpointed", "paused", "interrupted" -> "state_paused"
        "noProgress", "blocked" -> "state_blocked"
        "budgetLimited" -> "state_budget_limited"
        "truncated" -> "state_truncated"
        "waitingUser" -> "state_waiting_user"
        "cancelled" -> "state_stopped"
        "cancelling" -> "state_cancelling"
        "completed" -> "state_round_ended"
        "recoveryFailed" -> "state_recovery_failed"
        "failed" -> "state_failed"
        else -> "state_unknown"
    }

    fun colorRole(stateName: String): FloeStateColorRole = when (stateName) {
        "preparing", "idle", "streamingModel", "reconnecting", "committingResults",
        "reviewingApproval", "executingTool", "verifying" -> FloeStateColorRole.ACCENT
        "waitingApproval", "waitingUser", "compacting", "checkpointed", "paused",
        "interrupted", "blocked", "noProgress", "budgetLimited", "truncated" -> FloeStateColorRole.PENDING
        "cancelling", "recoveryFailed", "failed" -> FloeStateColorRole.DESTRUCTIVE
        "completed" -> FloeStateColorRole.SUCCESS
        else -> FloeStateColorRole.UNKNOWN
    }

    /** ⇄ isLoading(stateName:hasError:): the sole loading decision function. */
    fun isLoading(stateName: String, hasError: Boolean): Boolean {
        if (hasError) return false
        return when (stateName) {
            "preparing", "streamingModel", "reconnecting", "committingResults",
            "reviewingApproval", "executingTool", "cancelling", "compacting", "verifying" -> true
            else -> false
        }
    }

    /** ⇄ isTerminal: `checkpointed` is a durable PARKED state and must count
     * terminal for persisted reads (the composer then leaves steering-only
     * mode against a parked run). */
    fun isTerminal(stateName: String): Boolean = stateName in setOf(
        "completed", "failed", "recoveryFailed", "interrupted", "cancelled",
        "noProgress", "budgetLimited", "truncated", "checkpointed",
    )

    /** ⇄ attentionSymbol: nil = none (spinner/checkmark decided by the badge). */
    fun attentionSymbolKey(stateName: String): String? = when (stateName) {
        "failed", "recoveryFailed" -> "attention_failed"
        "paused", "interrupted", "checkpointed", "blocked", "noProgress",
        "budgetLimited", "truncated", "waitingApproval", "waitingUser" -> "attention_warning"
        else -> null
    }

    /** ⇄ terminalTitle(stopReason:): wire names never reach the UI. */
    fun terminalTitleKey(stopReason: String): String = when (stopReason) {
        "endTurn", "completed", "stop", "toolUse" -> "state_round_ended"
        "cancelled" -> "state_stopped"
        "maxTokens", "length" -> "state_truncated"
        "budgetLimited", "noProgress" -> "state_task_unfinished"
        else -> "state_unknown"
    }
}

/* ----------------------------- tool status mapping --------------------------- */

/** ⇄ ToolCallCardView statusIcon/statusColor/statusTitle (single table). */
data class ToolStatusPresentation(
    val iconKey: String,
    val colorRole: FloeStateColorRole,
    val titleKey: String,
)

object FloeToolStatusPresentation {
    fun forStatus(statusRaw: String): ToolStatusPresentation = when (statusRaw) {
        "ok", "completed" -> ToolStatusPresentation("icon_check_circle", FloeStateColorRole.SUCCESS, "tool_status_succeeded")
        "failed", "error" -> ToolStatusPresentation("icon_error", FloeStateColorRole.DESTRUCTIVE, "tool_status_failed")
        "denied" -> ToolStatusPresentation("icon_denied", FloeStateColorRole.DESTRUCTIVE, "tool_status_denied")
        "expired" -> ToolStatusPresentation("icon_expired", FloeStateColorRole.DESTRUCTIVE, "tool_status_expired")
        "cancelled" -> ToolStatusPresentation("icon_cancelled", FloeStateColorRole.DESTRUCTIVE, "tool_status_cancelled")
        "running", "executingTool" -> ToolStatusPresentation("icon_running", FloeStateColorRole.ACCENT, "tool_status_running")
        "pending", "needsUser" -> ToolStatusPresentation("icon_pending", FloeStateColorRole.PENDING, if (statusRaw == "needsUser") "tool_status_needs_user" else "tool_status_pending")
        else -> ToolStatusPresentation("icon_tool", FloeStateColorRole.UNKNOWN, "tool_status_unknown")
    }

    /** ⇄ onChange(of: status): failed/error/denied/expired/needsUser auto-open
     * the card details so the honest failure is never hidden behind a fold. */
    fun shouldAutoExpand(statusRaw: String): Boolean =
        statusRaw in setOf("failed", "error", "denied", "expired", "needsUser")
}

/* ------------------------------ step-group rules ----------------------------- */

/** ⇄ StepGroupDisclosurePolicy.initiallyExpanded. */
object StepGroupDisclosurePolicy {
    fun initiallyExpanded(isLatest: Boolean, isLive: Boolean, hasError: Boolean, hasPendingApproval: Boolean): Boolean =
        isLatest || isLive || hasError || hasPendingApproval
}

/**
 * ⇄ StepGroupView pairing helpers, operating on HOST-PROJECTED fields (never
 * payload JSON): request rows own one disclosure, the paired result supplies
 * the recorded output, and unpaired rows render standalone. Detached approval
 * rows fold into their tool summary when a matching call exists.
 */
object StepGroupPairing {

    fun callIdOf(event: RunEventUi): String? = when (event.kind) {
        RunEventKindUi.TOOL_REQUEST, RunEventKindUi.TOOL_RESULT -> event.tool?.callId?.takeIf { it.isNotEmpty() }
        else -> null
    }

    fun resultsByCall(events: List<RunEventUi>): Map<String, RunEventUi> =
        events.filter { it.kind == RunEventKindUi.TOOL_RESULT }
            .mapNotNull { e -> e.tool?.callId?.takeIf { it.isNotEmpty() }?.let { it to e } }
            .toMap()

    fun requestCallIds(events: List<RunEventUi>): Set<String> =
        events.filter { it.kind == RunEventKindUi.TOOL_REQUEST }.mapNotNull { callIdOf(it) }.toSet()

    /** ⇄ isPairedToolResult: results whose call already owns a request row are
     * folded into that request's disclosure. */
    fun isPairedResult(event: RunEventUi, requestCalls: Set<String>): Boolean =
        event.kind == RunEventKindUi.TOOL_RESULT && callIdOf(event)?.let { it in requestCalls } == true

    /** ⇄ requestStatus(for:): result status wins; a pending approval is
     * "pending"; live without result is "running"; historical without result
     * is the honest "failed" (never a silent success string). */
    fun requestStatus(
        event: RunEventUi,
        resultByCall: Map<String, RunEventUi>,
        hasPendingApproval: Boolean,
        isLive: Boolean,
    ): String? {
        if (event.kind != RunEventKindUi.TOOL_REQUEST) return null
        val call = callIdOf(event) ?: return null
        resultByCall[call]?.let { return it.tool?.statusRaw ?: "completed" }
        if (hasPendingApproval) return "pending"
        return if (isLive) "running" else "failed"
    }

    /** ⇄ stateTitle priorities (approval > review-needed > running > records). */
    fun groupStateKey(failedCount: Int, activeCount: Int, pendingApprovalCount: Int, isLive: Boolean): String = when {
        pendingApprovalCount > 0 -> "group_waiting_confirmation"
        failedCount > 0 -> if (failedCount == 1) "group_one_needs_review" else "group_items_need_review"
        activeCount > 0 -> if (activeCount == 1) "group_one_running" else "group_items_running"
        isLive -> "group_run_records"
        else -> "group_view_run_records"
    }

    fun groupStateColorRole(failedCount: Int, activeCount: Int, pendingApprovalCount: Int): FloeStateColorRole = when {
        pendingApprovalCount > 0 -> FloeStateColorRole.PENDING
        failedCount > 0 -> FloeStateColorRole.DESTRUCTIVE
        activeCount > 0 -> FloeStateColorRole.ACCENT
        else -> FloeStateColorRole.UNKNOWN
    }

    /** ⇄ displayedEvents: drop detached approval rows (their outcome folded
     * into the tool card) and paired results (shown by the request row).
     * Harness-suppression itself is a TIMELINE rule the host builder applies
     * before this projection — this module never re-derives suppression. */
    fun displayedEvents(events: List<RunEventUi>): List<RunEventUi> {
        val requests = requestCallIds(events)
        val approvalSummaries = approvalSummariesByCall(events)
        return events.filter { event ->
            val approvalCall = event.tool?.callId
                .takeIf { event.kind == RunEventKindUi.APPROVAL || event.kind == RunEventKindUi.AUTO_APPROVED }
            val detachedApproval = approvalCall != null && approvalCall.isNotEmpty() &&
                approvalCall in requests && approvalCall in approvalSummaries
            !detachedApproval && !isPairedResult(event, requests)
        }
    }

    /** ⇄ approvalSummariesByCallID. */
    fun approvalSummariesByCall(events: List<RunEventUi>): Map<String, String> {
        val out = mutableMapOf<String, String>()
        for (event in events) {
            if (event.kind != RunEventKindUi.APPROVAL && event.kind != RunEventKindUi.AUTO_APPROVED) continue
            val call = event.tool?.callId?.takeIf { it.isNotEmpty() } ?: continue
            val summary = event.tool?.approvalSummary
                ?: if (event.kind == RunEventKindUi.AUTO_APPROVED) AUTO_APPROVED_SENTINEL else ""
            if (summary.isNotEmpty()) out[call] = summary
        }
        return out
    }

    private const val AUTO_APPROVED_SENTINEL = "auto-approved"
}

/* --------------------- run-scoped child / decision resolution ---------------- */

/**
 * ⇄ ThreadRunScopedResolution — raw provider call ids are NOT unique across
 * runs, so delegate cards and decision annotations resolve ONLY within the
 * run that rendered the call (newest child wins within one run; legacy
 * annotations without a run are accepted only when nothing scoped matches).
 */
object ThreadRunScopedResolution {

    fun child(callId: String?, parentRunId: String, records: List<ChildRunUi>): ChildRunUi? {
        if (callId.isNullOrEmpty()) return null
        return records.filter { it.delegateCallId == callId && it.parentRunId == parentRunId }
            .maxByOrNull { it.startedAtLabel } // host projects ISO-ordered labels
    }

    fun decisionSummaries(callId: String?, runId: String, annotations: List<ToolDecisionUi>): List<String> {
        if (callId.isNullOrEmpty()) return emptyList()
        var matched = annotations.filter { it.callId == callId && it.runId == runId }
        if (matched.isEmpty()) matched = annotations.filter { it.callId == callId && it.runId == null }
        return matched.map { it.summary }.distinct()
    }
}

/* ----------------------------- approval grant tiers -------------------------- */

/**
 * ⇄ ApprovalCardView.approvalScope mapping (host authority still enforces the
 * result; this only projects the user's tier onto the visible target):
 * once → single-use; task → run-lifetime (not single-use); project → keeps the
 * scope description as the path constraint for local calls; host → drops the
 * path constraint on hostPath targets. Catastrophic-gate stops are NEVER
 * weakened by the chosen scope (the host's second-auth requirement is outside
 * this UI's authority).
 */
object ApprovalGrantMapping {
    fun grant(toolName: String, target: ApprovalTargetUi, scopeDescription: String, choice: ApprovalScopeChoiceUi): ApprovalGrantUi =
        when (target) {
            is ApprovalTargetUi.Local -> ApprovalGrantUi(
                toolName = toolName,
                hostId = null,
                paths = if (choice == ApprovalScopeChoiceUi.PROJECT) listOf(scopeDescription) else emptyList(),
                singleUse = choice == ApprovalScopeChoiceUi.ONCE,
            )
            is ApprovalTargetUi.Host -> ApprovalGrantUi(
                toolName = toolName,
                hostId = target.hostId,
                paths = emptyList(),
                singleUse = choice == ApprovalScopeChoiceUi.ONCE,
            )
            is ApprovalTargetUi.HostPath -> ApprovalGrantUi(
                toolName = toolName,
                hostId = target.hostId,
                // "This host" drops the path constraint; narrower tiers keep
                // the exact normalized path.
                paths = if (choice == ApprovalScopeChoiceUi.HOST) emptyList() else listOf(target.path),
                singleUse = choice == ApprovalScopeChoiceUi.ONCE,
            )
        }

    /** ⇄ isGateStopped: a stop the human must see in destructive red. This is
     * a PRESENTATION HINT derived from the host-provided reason string only —
     * it never changes what the host will enforce. */
    fun isGateStopped(reason: String): Boolean {
        val lower = reason.lowercase()
        return lower.contains("gate") || lower.contains("catastrophic")
    }

    /** ⇄ isWriteClass / requiresExactEvidence. */
    fun requiresEvidence(isSideEffecting: Boolean, riskLabels: Set<String>): Boolean =
        (isSideEffecting && (riskLabels.contains("writesFiles") || riskLabels.contains("deletesFiles"))) ||
            riskLabels.contains("executesRemoteCommand")

    /** ⇄ localizedRiskLabel mapping: known catalog labels get resource keys;
     * unknown labels render their raw value (still non-secret). */
    fun riskLabelKey(raw: String): String = when (raw) {
        "readsFiles" -> "risk_reads_files"
        "writesFiles" -> "risk_writes_files"
        "deletesFiles" -> "risk_deletes_files"
        "executesLocalCode" -> "risk_executes_local_code"
        "executesRemoteCommand" -> "risk_executes_remote_command"
        "modifiesRemoteSystem" -> "risk_modifies_remote_system"
        "networkAccess" -> "risk_network_access"
        "sendsDataToProvider" -> "risk_sends_data_to_provider"
        "controlsGUI" -> "risk_controls_gui"
        "accessesCredentials" -> "risk_accesses_credentials"
        else -> ""
    }

    /** ⇄ isSkillCreation: skill.create saves a reusable skill for ALL tasks —
     * the card must spell that out. */
    fun isSkillCreation(toolName: String): Boolean = toolName == "skill.create"

    /* -------- owned Linux engine slot conflict (Main ruling 2026-10-28) -------- */

    /** The EXACT typed conflict class the runtime puts on the existing
     * approval-escalation `reason` channel when this conversation's own live
     * interactive terminal holds the single runtime-UID engine workload slot
     * (⇄ `LinuxEngineSlotConflict.approvalReasonToken`). Matched EXACTLY, never
     * by substring: unlike [isGateStopped] this drives a real destructive
     * action, so a fuzzy match could offer to end a terminal that is not the
     * blocker. The token is an opaque identifier and is never rendered as
     * prose — [terminalHandoffConflict] callers show their own localized copy. */
    const val TERMINAL_HANDOFF_REASON_TOKEN = "linuxEngineSlotHeldByOwnInteractiveTerminal"

    fun terminalHandoffConflict(reason: String): Boolean = reason == TERMINAL_HANDOFF_REASON_TOKEN

    /** The model-facing tools that must ACQUIRE the single engine slot before
     * they can start anything (⇄ `LinuxEngineSlotTools.slotAcquiring`). Only
     * these may ever offer the explicit end-and-run action: tools that operate
     * on an already-open session, and every non-engine tool, keep the ordinary
     * card even while a terminal is live. */
    fun acquiresLinuxEngineSlot(toolName: String): Boolean =
        toolName == "exec.shell" || toolName == "shell.open"
}

/* ------------------------------- follow & drafts ----------------------------- */

/** ⇄ FloeCore/LatestMessageFollowState.swift (content growth is not a scroll). */
class ConversationFollowState {
    var followsLatest = true
        private set
    var isAwayFromLatest = false
        private set
    private var previousOffset: Double? = null

    fun returnToLatest() { followsLatest = true }

    fun observe(offset: Double, bottomDistance: Double, userScrolling: Boolean) {
        isAwayFromLatest = bottomDistance > 48
        if (userScrolling) {
            if (bottomDistance <= 48) {
                followsLatest = true
            } else if (previousOffset != null && offset < previousOffset!! - 0.5) {
                followsLatest = false
            }
        }
        previousOffset = offset
    }
}

/**
 * ⇄ FloeApp/Chat/ComposerEditingPrimitives.swift ComposerSendCommit: ONE
 * send's claim on the composer field. Text equality is NOT identity — the
 * user can edit A → B → A while the send is in flight; the commit pins the
 * exact editor generation so a success clears only what it consumed and a
 * pre-accept failure can restore the complete original text (never a trimmed
 * version). The durable store side is the host's (clearDraftAfterSend).
 */
data class ComposerSendCommit(
    val conversationId: String,
    val sentText: String,
    val sentAttachments: List<StagedAttachmentUi>,
    /** Live editor generation when the send consumed the field. */
    val editorGeneration: Long,
    /** ⇄ temporaryIncarnation bound at send start; null for ordinary sends
     * (ordinary failure recovery is never gated). */
    val temporaryIncarnationId: String?,
    /** Launch fencing pair (presentation-only correlation, see
     * [LaunchCorrelation]): the session epoch and monotonic launch
     * generation the host must echo back verbatim on the prepared/failed
     * outcome. 0 = a commit that never dispatches a correlated launch
     * (the running-input queue path). */
    val launchGeneration: Long = 0,
    val launchSessionEpoch: Long = 0,
) {
    fun editorStillConsumed(currentGeneration: Long): Boolean = currentGeneration == editorGeneration

    /** Empty field only while nothing was typed since this send consumed it. */
    fun draftAfterSuccess(currentDraft: String, currentGeneration: Long): String =
        if (editorStillConsumed(currentGeneration)) "" else currentDraft

    /** Only the sent refs are consumed: a file staged mid-flight keeps its
     * identity in the composer. */
    fun attachmentsAfterSuccess(current: List<StagedAttachmentUi>): List<StagedAttachmentUi> {
        val sentIds = sentAttachments.map { it.id }.toSet()
        if (sentIds.isEmpty()) return current
        return current.filter { it.id !in sentIds }
    }
}

/**
 * ⇄ ThreadDetailViewModel.sendOriginAllowsDraftMutation: a late send callback
 * may restore/clear drafts only while its exact temporary-session generation
 * is current — or after THAT identity was successfully promoted (the
 * conversation is now ordinary and ordinary recovery applies). A destroyed
 * session or a same-id replacement never leaks into another generation.
 */
object TemporarySendOriginGate {
    fun allowsDraftMutation(
        originIncarnation: String?,
        currentIncarnation: String?,
        isTemporaryNow: Boolean,
        conversationId: String,
        promotedConversationId: String?,
    ): Boolean {
        val origin = originIncarnation ?: return true // ordinary send: never gated
        if (isTemporaryNow && currentIncarnation != null) {
            return currentIncarnation == origin
        }
        return promotedConversationId == conversationId
    }
}

/* ------------------------------- queue & plans ------------------------------- */

/** ⇄ PendingInputQueueView + ThreadDetailViewModel pending-input actions. */
object PendingInputQueueLogic {

    fun queuedIds(pending: List<PendingInputUi>): List<String> =
        pending.filter { it.status == PendingInputStatusUi.QUEUED }.map { it.id }

    /** ⇄ movePendingInput: only QUEUED items reorder, and only inside the
     * queued slice; out-of-range moves are dropped (never a silent no-op swap). */
    fun reorderQueued(pending: List<PendingInputUi>, inputId: String, offset: Int): List<String>? {
        val queued = queuedIds(pending)
        val source = queued.indexOf(inputId).takeIf { it >= 0 } ?: return null
        val destination = source + offset
        if (destination !in queued.indices) return null
        val next = queued.toMutableList()
        val tmp = next[source]
        next[source] = next[destination]
        next[destination] = tmp
        return next
    }

    /** ⇄ convert_to_steer enablement: only while a run is live and the row is
     * still queued. */
    fun canPromoteToSteer(isRunning: Boolean, status: PendingInputStatusUi): Boolean =
        isRunning && status == PendingInputStatusUi.QUEUED

    /** ⇄ statusTitle key mapping. */
    fun statusTitleKey(status: PendingInputStatusUi): String = when (status) {
        PendingInputStatusUi.QUEUED -> "queue_status_waits_for_run"
        PendingInputStatusUi.PROMOTING -> "queue_status_converting"
        PendingInputStatusUi.STEER_PENDING -> "queue_status_waiting_insert"
        PendingInputStatusUi.CONSUMED -> "queue_status_sent"
        PendingInputStatusUi.CANCELLED -> "queue_status_cancelled"
    }

    /** ⇄ displayText(for:): trusted decision rows show the host-projected
     * concise summary; browser-handoff rows their fixed notice; a row whose
     * body has NOT arrived yet shows the honest unread marker (never a
     * silently blank slot — the observed G04R2 defect); everything else
     * shows the projected text (a PREVIEW is labelled by the view from
     * [PendingInputUi.bodyState], which this logic never rewrites). */
    fun displayText(input: PendingInputUi): String = when {
        input.trustedSummary != null -> input.trustedSummary
        input.isBrowserHandoff -> BROWSER_HANDED_BACK
        input.content.isNotEmpty() -> input.content
        else -> BODY_UNREAD
    }

    /** ⇄ PendingInputEditorSheet notice selection (C04 cold-load repair):
     * the "Loading the full message…" promise is shown ONLY while a bounded
     * body read actually owns this row's slot ([PendingInputBodyUi.Loading]).
     * A null slot means the host never started a read for this open (a guard
     * refusal now publishes a typed Failed instead, and a refused open with
     * no live surface keeps the honest unread marker) — the sheet must never
     * promise a load that is not in flight. A labelled preview still wins
     * over both while the full body is unproven. */
    fun editorNoticeKey(body: PendingInputBodyUi?, hasPreview: Boolean): EditorNoticeKey = when {
        hasPreview -> EditorNoticeKey.PREVIEW
        body is PendingInputBodyUi.Loading -> EditorNoticeKey.LOADING
        else -> EditorNoticeKey.UNREAD
    }

    enum class EditorNoticeKey { PREVIEW, LOADING, UNREAD }

    /** Marker vocabulary resolved by the queue view into localized copy
     * (kept out of pure logic so unit tests bind exact strings). */
    const val BROWSER_HANDED_BACK = "__floe.browser_control_returned__"
    const val BODY_UNREAD = "__floe.queue_body_unread__"
}

/** ⇄ ThreadDetailViewModel plan-mode reconciliation: a session refresh must
 * restore Plan mode while an unfinished plan awaits review, but NEVER invent
 * an exit from a deliberate per-turn choice at the SAME revision. */
object PlanModeReconciler {

    /** ⇄ activePlanRevision: awaitingInput or ready plans pin the revision. */
    fun activePlanRevision(plan: PlanUi?): Int? =
        if (plan != null && PlanUi.isActiveAwaitingReview(plan.statusRaw)) plan.revisionNumber else null

    /** ⇄ reconcilePlanComposerMode. */
    fun reconcile(
        plan: PlanUi?,
        explicitModePlanRevision: Int?,
        currentMode: AgentExecutionModeUi,
    ): AgentExecutionModeUi {
        val revision = activePlanRevision(plan) ?: return currentMode
        return if (explicitModePlanRevision == revision) currentMode else AgentExecutionModeUi.PLAN
    }

    /** ⇄ selectAgentMode: an explicit switch records the active revision so
     * later refreshes respect it. */
    fun onExplicitModeSwitch(plan: PlanUi?): Int? = activePlanRevision(plan)
}

/* -------------------------------- token units -------------------------------- */

/** ⇄ ThreadDetailView TokenUnitFormatter (K/M/B scaling, integral values lose
 * the ".0"). */
object TokenUnitFormatter {
    fun format(value: Int): String {
        val magnitude = kotlin.math.abs(value)
        return when {
            magnitude >= 1_000_000_000 -> scaled(value, 1_000_000_000.0, "B")
            magnitude >= 1_000_000 -> scaled(value, 1_000_000.0, "M")
            magnitude >= 1_000 -> scaled(value, 1_000.0, "K")
            else -> value.toString()
        }
    }

    private fun scaled(value: Int, divisor: Double, suffix: String): String {
        val quotient = value.toDouble() / divisor
        return if (quotient == quotient.toInt().toDouble()) {
            "${quotient.toInt()}$suffix"
        } else {
            val rounded = Math.round(quotient * 10) / 10.0
            val text = if (rounded == Math.floor(rounded)) rounded.toInt().toString() else rounded.toString()
            text + suffix
        }
    }
}

/* ------------------------------ history search ------------------------------- */

/** ⇄ ConversationListViewModel.filteredConversations + searchContents rules. */
object ConversationSearchRules {

    /** ⇄ localizedStandardContains (case- and diacritic-insensitive on iOS;
     * Android normalizes case; CJK needs no folding). Query is matched as a
     * literal substring — the DURABLE content search is the host FTS. */
    fun titleMatches(title: String, query: String): Boolean =
        query.isNotEmpty() && title.lowercase().contains(query.lowercase())

    fun isVisible(
        item: ConversationListItemUi,
        archivedFilter: Boolean,
        query: String,
        contentSnippets: Map<String, String>,
    ): Boolean =
        item.isArchived == archivedFilter &&
            (query.isEmpty() || titleMatches(item.title, query) || contentSnippets.containsKey(item.id))

    /** ⇄ searchContents debounce guard: a result page is applied only while it
     * belongs to the exact query generation that requested it. */
    fun acceptsSearchPage(requestEpoch: Long, pageEpoch: Long): Boolean = pageEpoch == requestEpoch
}

/** ⇄ TaskBulkManagement.TaskBulkSelectionRules (identical semantics). */
object TaskBulkSelectionRules {
    fun toggled(selection: Set<String>, id: String): Set<String> =
        if (id in selection) selection - id else selection + id

    fun selectionAfterSelectAllToggle(selection: Set<String>, visible: Set<String>): Set<String> {
        if (visible.isEmpty()) return selection
        return if (visible.all { it in selection }) selection - visible else selection + visible
    }

    fun pruned(selection: Set<String>, to: Set<String>): Set<String> = selection.intersect(to)

    fun allVisibleSelected(selection: Set<String>, visible: Set<String>): Boolean =
        visible.isNotEmpty() && visible.all { it in selection }
}

/* ---------------------------- goal builder input ---------------------------- */

/** ⇄ GoalBuilderSheet.lines: split on newlines, trim, drop empties. */
fun splitGoalLines(text: String): List<String> =
    text.split('\n').map { it.trim() }.filter { it.isNotEmpty() }

/* --------------------------- message send policy ---------------------------- */

/**
 * ⇄ ThreadDetailViewModel.canSend + needsProvider: sending requires a present
 * conversation, a usable provider+model, and non-blank text (whitespace scan,
 * no trim copy per keystroke on iOS — kept simple and identical in result).
 * While a run is active the SAME field submits queue/steer instead; Stop
 * remains separate (never merged into send).
 */
object ThreadSendPolicy {
    fun canSend(isConversationMissing: Boolean, providerConfigured: Boolean, draftText: String): Boolean =
        !isConversationMissing && providerConfigured && draftText.any { !it.isWhitespace() }

    /** Temporary chat is text-only: the launch carries no attachments while
     * staged files stay in the composer (the host also refuses a nonempty
     * temporary attachment request before any store/provider effect). */
    fun launchAttachments(isTemporary: Boolean, staged: List<StagedAttachmentUi>): List<StagedAttachmentUi> =
        if (isTemporary) emptyList() else staged

    /** ⇄ effectiveAgentMode: temporary runs are the ordinary agent turn under
     * the host's immutable read-only ceiling — never plan/goal/chat-only. */
    fun effectiveAgentMode(isTemporary: Boolean, agentMode: AgentExecutionModeUi): AgentExecutionModeUi =
        if (isTemporary) AgentExecutionModeUi.AGENT else agentMode
}
