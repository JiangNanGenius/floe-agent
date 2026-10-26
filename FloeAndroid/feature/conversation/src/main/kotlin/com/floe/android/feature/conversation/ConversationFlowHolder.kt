// SPDX-License-Identifier: MPL-2.0
//
// Caller-retained, RAM-only presentation holder for ONE conversation thread
// (⇄ ThreadDetailViewModel's @Published state minus every durable read).
//
// Lifetime contract:
//  - The host retains this holder in RAM across configuration changes; a
//    recreation re-reads the SAME session object. There is no SavedStateHandle,
//    no Bundle, no rememberSaveable, no DataStore: drafts, queued prompts,
//    temporary-session content and secret-shaped payloads NEVER leave RAM
//    through this module, and process death restores nothing.
//  - [rebind] increases [ConversationSessionToken.sessionEpoch]; every host
//    projection and every applied outcome is fenced on that epoch and on the
//    host incarnation id, so a late callback from a previous conversation (or
//    a replaced temporary generation) cannot mutate this thread
//    (TMP-NAV-DISCARD / APR-CALL-BOUND / CHA-DRAFT-KEEP).
//  - The holder never fabricates run/stream/approval outcomes: host
//    projections are the only source of truth and Boolean effects report real
//    starts. User-facing failure COPY arrives localized from the host; this
//    module only carries decision vocabularies and resource keys.
//  - Genuine navigation to another conversation/New Task fences and discards
//    temporary content HOST-SIDE (epoch bump here only detaches this view);
//    view reconstruction is not navigation.

package com.floe.android.feature.conversation

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.floe.android.contracts.EventCursor
import com.floe.android.design.ComposerAvailability
import com.floe.android.design.ComposerSendPolicy
import java.util.UUID
import kotlin.jvm.JvmName

/* ------------------------------ result vocabulary ---------------------------- */

/** Outcome of one holder action (same vocabulary as the provider flow). */
sealed interface ConversationFlowResult {
    data object Accepted : ConversationFlowResult
    data object Stale : ConversationFlowResult
    data class Rejected(val reason: ConversationRejectedReason) : ConversationFlowResult
}

enum class ConversationRejectedReason {
    /** No bound session (nothing to attach the effect to). */
    NO_SESSION,
    /** The draft/selection cannot support this action right now. */
    INPUT_INSUFFICIENT,
    /** A launch/keep/accept/dispatch is already in flight for this identity. */
    OPERATION_IN_FLIGHT,
    /** The displayed run is not in a continuable durable state. */
    RUN_NOT_CONTINUABLE,
    /** The referenced row/identity no longer matches the projection. */
    STALE,
    /** The host has no usable bridge for this action right now. */
    HOST_UNAVAILABLE,
}

private fun rejected(reason: ConversationRejectedReason): ConversationFlowResult =
    ConversationFlowResult.Rejected(reason)

/** Host UUID strings are opaque ids; parse defensively for the cursor type. */
internal fun parseHostUuid(raw: String): UUID? = try {
    UUID.fromString(raw)
} catch (_: IllegalArgumentException) {
    null
}

/* --------------------------------- the holder -------------------------------- */

class ConversationFlowHolder(
    private val host: ConversationUiCallbacks,
    conversationId: String,
    initialDraft: ComposerDraftSeedUi? = null,
    initialSessionEpoch: Long = 0L,
) {
    private var conversationIdInternal: String = conversationId

    /** The conversation this holder currently presents (host task identity). */
    val conversationId: String get() = conversationIdInternal

    /** Current session identity; epoch bumps on every rebind. */
    var session: ConversationSessionToken = ConversationSessionToken(conversationIdInternal, initialSessionEpoch)
        private set

    /**
     * The EXACT trusted native root epoch bound from the authoritative
     * temp.start value (MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION). -1 = unbound:
     * Keep/End construct their TemporarySessionRef with this value and the
     * navigation fence therefore fails closed until the host binds it.
     * Never the UI session counter and never a fabricated zero.
     */
    var temporaryNativeRootEpoch: Long = -1L

    /** Latest host projection for THIS session (null before the first page). */
    val snapshot: MutableState<ThreadUiState?> = mutableStateOf(null)

    /* ------------------------ composer presentation state ----------------------- */

    /** Draft text + caret. The generation counter advances ONLY on real text
     * changes (attachment staging and caret moves never bump it, mirroring the
     * Swift SendCommitToken rule). */
    val draft: MutableState<TextFieldValue> = mutableStateOf(draftSeedToFieldValue(initialDraft))

    private var draftGenerationInternal = 0L

    /** ⇄ draftGeneration: monotonic identity of the live field text. */
    val draftGeneration: Long get() = draftGenerationInternal

    /** ⇄ isConsumingDraft: true while a send owns the field until its
     * outcome is known. */
    var isConsumingDraft: Boolean by mutableStateOf(false)
        private set

    /** ⇄ temporaryDraftHandoffPending: after a temporary toggle-off handed an
     * unedited ephemeral draft back, the visible text must not reach the
     * durable draft store until the user edits it again (first edit re-arms). */
    var temporaryDraftHandoffPending: Boolean by mutableStateOf(false)
        private set
    val shouldPersistDraftEdits: Boolean get() = !temporaryDraftHandoffPending

    /* ---------------------- full-screen editor (same draft) --------------------- */

    /** ⇄ ThreadComposerView isFullEditorPresented: the composer's expand
     * destination. The sheet binds THIS holder's [draft] state object —
     * one text, one caret/selection, one generation counter, one send
     * pipeline. There is deliberately no second draft, no second submit
     * path and no per-sheet copy (⇄ ComposerFullEditorSheet binds `$draft`). */
    var showsFullEditor: Boolean by mutableStateOf(false)
        private set

    /** ⇄ FullEditorController's editor-instance undo/redo surface. The
     * inline field and the full editor share ONE bounded RAM-only history
     * (⇄ the composer-owned shared UndoManager); it is discarded with every
     * rebind/retirement and never persisted. */
    private val editorUndoHistory = ArrayDeque<TextFieldValue>()
    private val editorRedoHistory = ArrayDeque<TextFieldValue>()

    var canUndoDraft: Boolean by mutableStateOf(false)
        private set
    var canRedoDraft: Boolean by mutableStateOf(false)
        private set

    fun openFullEditor() {
        if (retired) return
        showsFullEditor = true
    }

    /** Done / system Back / dismissal: a PURE close — never a send
     * (⇄ "Done always just dismisses"). Caret/selection survive in the
     * shared [draft] value, exactly like the captured-selection round-trip.
     * The Find bar closes with the sheet but its query/replacement presentation
     * text stays RAM-only for this same holder/session. */
    fun closeFullEditor() {
        closeFindInFullEditor()
        showsFullEditor = false
    }

    /** ⇄ controller.undo(): restore the previous text/caret through the
     * SAME draft pipeline (generation advances, durable save forwards). */
    fun undoDraft() {
        if (retired) return
        val previous = editorUndoHistory.removeLastOrNull() ?: return
        editorRedoHistory.addLast(draft.value)
        if (editorRedoHistory.size > MAX_EDITOR_HISTORY) editorRedoHistory.removeFirst()
        applyDraftEdit(previous, recordPrevious = null)
    }

    /** ⇄ controller.redo(). */
    fun redoDraft() {
        if (retired) return
        val next = editorRedoHistory.removeLastOrNull() ?: return
        editorUndoHistory.addLast(draft.value)
        if (editorUndoHistory.size > MAX_EDITOR_HISTORY) editorUndoHistory.removeFirst()
        applyDraftEdit(next, recordPrevious = null)
    }

    /** ⇄ controller.selectAll(): selection-only change (no generation
     * bump — ⇄ the Swift rule that caret moves never advance the draft
     * generation; the durable selection still follows the host). */
    fun selectAllDraft() {
        if (retired) return
        val current = draft.value
        if (current.text.isEmpty()) return
        if (current.selection.start == 0 && current.selection.end == current.text.length) return
        onDraftChange(current.copy(selection = TextRange(0, current.text.length)))
    }

    /** The editor's send gate mirrors the inline composer EXACTLY: the same
     * design-system [ComposerSendPolicy] inputs (blank draft, IME marked
     * composition, provider configured, attachments processing) plus the
     * projection-level missing-conversation guard. No weaker second rule and
     * no stronger invention — the same guarded entry the inline circle uses. */
    fun fullEditorCanSend(): Boolean {
        val state = snapshot.value ?: return false
        if (retired) return false
        val availability = ComposerAvailability(
            providerConfigured = !state.needsProvider,
            attachmentsProcessing = anyAttachmentProcessing(),
            voiceAvailable = state.voiceAvailable,
            temporaryChatAvailable = false,
        )
        val inlineGuard = ComposerSendPolicy.canSend(
            draftBlank = draft.value.text.isBlank(),
            compositionActive = ComposerSendPolicy.compositionActive(draft.value),
            availability = availability,
        )
        return inlineGuard &&
            ThreadSendPolicy.canSend(state.isConversationMissing, availability.providerConfigured, draft.value.text)
    }

    /** ⇄ performSend: run the composer's OWN send and only close the editor
     * when it actually started (Accepted). Rejected sends leave the sheet
     * open with the draft intact — never a second submit pipeline. */
    fun sendFromFullEditor(): ConversationFlowResult {
        val result = send()
        if (result is ConversationFlowResult.Accepted) {
            closeFindInFullEditor()
            showsFullEditor = false
        }
        return result
    }

    private fun refreshEditorHistoryFlags() {
        canUndoDraft = editorUndoHistory.isNotEmpty()
        canRedoDraft = editorRedoHistory.isNotEmpty()
    }

    /* ---------------------- find/replace (same draft, RAM) ---------------------- */

    /**
     * RAM-only Find/Replace presentation state for THIS holder/session:
     * query, literal replacement, match options, total count, current ordinal
     * and the current real match. There is deliberately no SavedStateHandle,
     * rememberSaveable, DataStore, Bundle or file copy: a host-retained holder
     * survives configuration change, a real rebind/temporary discard resets
     * this state in [discardPresentationPayloads], and process death restores
     * nothing (⇄ the composer's draft contract).
     */
    var findReplace: FindReplaceUiState by mutableStateOf(FindReplaceUiState())
        private set

    /** Open the local Find/Replace bar over the current full-editor draft.
     * Opening never edits text and never sends. */
    fun openFindInFullEditor() {
        if (retired || !showsFullEditor) return
        findReplace = findReplace.copy(isOpen = true, replaceAllRefused = false)
        refreshFindState(selectCurrent = true)
    }

    /** Close only the Find/Replace bar. The editor, draft and selection stay
     * exactly where they are; Back/Escape use this same pure close. */
    fun closeFindInFullEditor() {
        if (!findReplace.isOpen) return
        findReplace = findReplace.copy(
            isOpen = false,
            totalMatches = 0,
            currentOrdinal = -1,
            currentMatch = null,
            replaceAllRefused = false,
        )
    }

    /** Change the literal query. Recomputed against the CURRENT immutable
     * draft text; the first match at/after the shared selection is selected
     * through the selection-only draft path (never an edit/undo entry). */
    fun setFindQuery(query: String) {
        if (retired || !findReplace.isOpen) return
        if (query == findReplace.query) return
        findReplace = findReplace.copy(query = query, replaceAllRefused = false)
        refreshFindState(selectCurrent = true)
    }

    /** The replacement is presentation text until Replace/Replace All runs;
     * it is appended literally (no `$`/`\` template expansion). */
    fun setFindReplacement(replacement: String) {
        if (retired) return
        if (replacement == findReplace.replacement) return
        findReplace = findReplace.copy(
            replacement = replacement,
            replaceAllRefused = false,
        )
    }

    fun setFindMatchCase(enabled: Boolean) {
        if (retired || !findReplace.isOpen) return
        if (enabled == findReplace.matchCase) return
        findReplace = findReplace.copy(matchCase = enabled, replaceAllRefused = false)
        refreshFindState(selectCurrent = true)
    }

    fun setFindWholeWord(enabled: Boolean) {
        if (retired || !findReplace.isOpen) return
        if (enabled == findReplace.wholeWord) return
        findReplace = findReplace.copy(wholeWord = enabled, replaceAllRefused = false)
        refreshFindState(selectCurrent = true)
    }

    /** Next match with wrap. Selection-only: text, generation and undo history
     * are untouched; only the shared draft selection/caret moves. */
    fun findNext(): Boolean {
        if (retired || !findReplace.isOpen) return false
        val current = findReplace
        if (current.query.isEmpty()) return false
        val scanner = FindScanner(draft.value.text, current.query, current.options)
        val from = current.currentMatch?.end ?: draft.value.selection.max
        val match = scanner.next(from) ?: scanner.first() ?: return false
        return applyFindMatch(scanner, match)
    }

    /** Previous match with wrap. Selection-only, exactly like [findNext]. */
    fun findPrevious(): Boolean {
        if (retired || !findReplace.isOpen) return false
        val current = findReplace
        if (current.query.isEmpty()) return false
        val scanner = FindScanner(draft.value.text, current.query, current.options)
        val before = current.currentMatch?.start ?: draft.value.selection.min
        val match = scanner.previous(before) ?: scanner.last() ?: return false
        return applyFindMatch(scanner, match)
    }

    /**
     * The exact identity of the live search snapshot. A caller that computed a
     * result elsewhere may only feed it back through [applyFindSelection]
     * while this key is still equal (same session epoch, draft generation,
     * text, query and options); a newer edit/query/session makes it stale.
     */
    fun findSearchKey(): FindSearchKey = FindSearchKey(
        sessionEpoch = session.sessionEpoch,
        draftGeneration = draftGenerationInternal,
        text = draft.value.text,
        query = findReplace.query,
        matchCase = findReplace.matchCase,
        wholeWord = findReplace.wholeWord,
        temporaryIncarnationId = snapshot.value?.temporaryIncarnationId,
    )

    /**
     * Fenced selection application for a previously captured snapshot. It
     * revalidates the key against the LIVE holder and revalidates [match]
     * against the live text before touching the selection. A stale async result
     * therefore cannot reselect/overwrite a newer edit, query or session.
     */
    fun applyFindSelection(key: FindSearchKey, match: FindMatch): Boolean {
        if (retired || !findReplace.isOpen) return false
        if (key != findSearchKey()) return false
        val scanner = FindScanner(draft.value.text, findReplace.query, findReplace.options)
        val actual = scanner.matchAt(match.start) ?: return false
        if (actual.end != match.end) return false
        return applyFindMatch(scanner, actual)
    }

    /** Replace the current real match exactly once. The new text and caret go
     * through the SAME [applyDraftEdit] pipeline as typing: one shared undo
     * entry, one generation bump and (when allowed) one durable save effect. */
    fun replaceCurrentFindMatch(): FindReplaceEditResult {
        if (retired || !findReplace.isOpen) return FindReplaceEditResult.Stale
        val current = findReplace
        if (current.query.isEmpty()) return FindReplaceEditResult.NoMatch
        val scanner = FindScanner(draft.value.text, current.query, current.options)
        val match = currentMatchForEdit(scanner) ?: return FindReplaceEditResult.NoMatch
        return when (val outcome = scanner.replaceOne(match, current.replacement)) {
            is FindReplaceOneOutcome.Stale -> FindReplaceEditResult.Stale
            is FindReplaceOneOutcome.Replaced -> {
                val nextScanner = FindScanner(outcome.text, current.query, current.options)
                val nextMatch = nextScanner.next(outcome.caretOffset) ?: nextScanner.first()
                val selection = nextMatch?.range
                    ?: TextRange(outcome.caretOffset.coerceIn(0, outcome.text.length))
                applyDraftEdit(
                    TextFieldValue(outcome.text, selection),
                    recordPrevious = draft.value,
                )
                // A no-op replacement does not bump the generation; refresh
                // explicitly so the count/current match always describe the
                // text/selection that is actually visible.
                refreshFindState(selectCurrent = false)
                FindReplaceEditResult.Replaced(1)
            }
        }
    }

    /** Replace every non-overlapping match as ONE atomic draft edit. A typed
     * RefusedTooLarge result leaves the draft/selection/undo stack untouched. */
    fun replaceAllFindMatches(): FindReplaceEditResult {
        if (retired || !findReplace.isOpen) return FindReplaceEditResult.Stale
        val current = findReplace
        if (current.query.isEmpty()) return FindReplaceEditResult.NoMatch
        val scanner = FindScanner(draft.value.text, current.query, current.options)
        return when (val outcome = scanner.replaceAll(
            replacement = current.replacement,
            caretOffset = draft.value.selection.min,
        )) {
            is FindReplaceAllOutcome.NoMatch -> {
                findReplace = findReplace.copy(replaceAllRefused = false)
                FindReplaceEditResult.NoMatch
            }
            is FindReplaceAllOutcome.RefusedTooLarge -> {
                findReplace = findReplace.copy(replaceAllRefused = true)
                FindReplaceEditResult.RefusedTooLarge(outcome.attemptedUtf16Length)
            }
            is FindReplaceAllOutcome.Replaced -> {
                findReplace = findReplace.copy(replaceAllRefused = false)
                applyDraftEdit(
                    TextFieldValue(outcome.text, TextRange(outcome.caretOffset)),
                    recordPrevious = draft.value,
                )
                refreshFindState(selectCurrent = false)
                FindReplaceEditResult.Replaced(outcome.count)
            }
        }
    }

    /** Recompute count/current from the live immutable draft + query snapshot.
     * [selectCurrent] is used only for an explicit query/option/open action;
     * edits refresh counts without stealing the caret the user is typing at. */
    private fun refreshFindState(selectCurrent: Boolean) {
        if (!findReplace.isOpen) return
        val current = findReplace
        if (current.query.isEmpty()) {
            findReplace = current.copy(
                totalMatches = 0,
                currentOrdinal = -1,
                currentMatch = null,
                replaceAllRefused = false,
            )
            return
        }
        val scanner = FindScanner(draft.value.text, current.query, current.options)
        val scan = scanner.scan(draft.value.selection.min)
        findReplace = current.copy(
            totalMatches = scan.totalMatches,
            currentOrdinal = scan.currentOrdinal,
            currentMatch = scan.currentMatch,
            replaceAllRefused = false,
        )
        val match = scan.currentMatch
        if (selectCurrent && match != null && draft.value.selection != match.range) {
            applyDraftEdit(draft.value.copy(selection = match.range), recordPrevious = null)
        }
    }

    /** Selection-only current-match application shared by navigation and the
     * fenced [applyFindSelection] entry. */
    private fun applyFindMatch(scanner: FindScanner, match: FindMatch): Boolean {
        val scan = scanner.scan(match.start)
        if (scan.currentMatch != match) return false
        findReplace = findReplace.copy(
            totalMatches = scan.totalMatches,
            currentOrdinal = scan.currentOrdinal,
            currentMatch = scan.currentMatch,
        )
        if (draft.value.selection != match.range) {
            applyDraftEdit(draft.value.copy(selection = match.range), recordPrevious = null)
        }
        return true
    }

    /** The live state's current match, falling back to the match at the shared
     * caret if the recorded range no longer exists. */
    private fun currentMatchForEdit(scanner: FindScanner): FindMatch? {
        findReplace.currentMatch?.let { recorded ->
            val actual = scanner.matchAt(recorded.start)
            if (actual != null && actual.end == recorded.end) return actual
        }
        return scanner.scan(draft.value.selection.min).currentMatch
    }

    /* --------------------------- selections (RAM) ---------------------------- */

    /** ⇄ selectedModelID (the host projection remains the durable truth). */
    val selectedModelId: MutableState<String?> = mutableStateOf(null)

    /**
     * The Home launchpad's EXPLICIT draft-task approval mode for the FIRST
     * fresh launch of this (brand-new) conversation only (⇄
     * DraftTaskPermissionsSheet persisted atomically with the first launch).
     * Set ONLY by the Home send path; a thread composer never owns one (the
     * durable task-policy row + `run.policy.update` lane is the task truth
     * there). Consumed exactly once at fresh-launch capture and NEVER applied
     * to a temporary session.
     */
    var draftTaskApprovalMode: ApprovalModeUi? = null
        private set

    fun setDraftTaskApprovalMode(mode: ApprovalModeUi?) {
        if (retired) return
        draftTaskApprovalMode = mode
    }

    /** Typed, localized blocker lines from the LAST blocked
     * [confirmGoalCompletion] settlement (never an inferred approval and
     * never kept across a newer settlement; cleared when a new confirm
     * starts). */
    val goalConfirmBlockers: MutableState<List<String>?> = mutableStateOf(null)

    /** ⇄ agentMode with explicit per-turn Plan-choice pinning. */
    var agentMode: AgentExecutionModeUi by mutableStateOf(AgentExecutionModeUi.AGENT)
        private set
    var explicitModePlanRevision: Int? by mutableStateOf(null)
        private set

    /** ⇄ runningInputMode. The @set:JvmName avoids the Kotlin property
     * accessor clashing with the explicit setRunningInputMode() action (the
     * baseline compile's real "platform declaration clash" error). */
    @set:JvmName("updateRunningInputModeState")
    var runningInputMode: RunningInputModeUi by mutableStateOf(RunningInputModeUi.QUEUE)
        private set

    /** ⇄ executionTarget: local only until host remote tools land. */
    val executionTarget: ExecutionTargetUi = ExecutionTargetUi.LOCAL

    /** ⇄ selectedProjectID: existing tasks keep an IMMUTABLE workspace scope —
     * the thread picker is locked (moving a task is a separate explicit flow
     * this surface does not own). */
    val selectedProjectId: MutableState<String?> = mutableStateOf(null)

    /** Composer-staged attachments (presentation mirror of host-owned bytes;
     * seeded from the durable draft the host restored). */
    val stagedAttachments: MutableState<List<StagedAttachmentUi>> = mutableStateOf(
        initialDraft?.attachments?.map { it.copy(import = AttachmentImportUi.Ready) } ?: emptyList()
    )

    /* -------------------------- timeline presentation --------------------------- */

    /** ⇄ selectedRunID (router echo + VM selection). */
    val selectedRunId: MutableState<String?> = mutableStateOf(null)

    /** Expanded step-group disclosures keyed by group id (⇄ @State isExpanded
     * per group with the iOS transition rules preserved below). */
    val expandedGroups: MutableState<Set<String>> = mutableStateOf(emptySet())

    /** Expanded tool cards (⇄ ToolCallCardView @State isExpanded + auto-expand
     * on the failure vocabulary). */
    val expandedToolCards: MutableState<Set<String>> = mutableStateOf(emptySet())

    /** Expanded approval evidence folds keyed by card identity. */
    val expandedApprovalEvidence: MutableState<Set<String>> = mutableStateOf(emptySet())

    /** Chosen grant tier per approval key (⇄ @State scopeChoice default .once). */
    val approvalScopeChoices: MutableState<Map<String, ApprovalScopeChoiceUi>> = mutableStateOf(emptyMap())

    /** Approvals dispatched with no projection change yet (duplicate-press
     * latch; cleared when the card leaves the projection). */
    private val approvalDispatched = mutableSetOf<String>()

    /** ⇄ latestFollow + showsReturnToLatest scroll intent. */
    val followState = ConversationFollowState()
    var showsReturnToLatest: Boolean by mutableStateOf(false)
        private set

    /** ⇄ actionError: honest failure surface (localized host text). */
    var actionError: String? by mutableStateOf(null)
        private set

    /** A failed queue projection read belongs to this holder/session and
     * its exact recovery token, independently of ordinary action errors. */
    var queueRefreshFailureToken: String? by mutableStateOf(null)
        private set

    /** ⇄ ThreadComposerView attachmentError (import-path surface). */
    var attachmentError: String? by mutableStateOf(null)
        private set

    /** ⇄ modelPersistenceFailure banner (selection active, default not saved). */
    var modelPersistenceFailureName: String? by mutableStateOf(null)
        private set

    /** ⇄ isCompacting local latch (the projection owns the status line). */
    var isCompacting: Boolean by mutableStateOf(false)
        private set

    /** ⇄ temporaryKeepState. */
    var temporaryKeepState: TemporaryKeepStateUi by mutableStateOf(TemporaryKeepStateUi.Idle)
        private set

    /** ⇄ isAcceptingPlan latch (a duplicate accept never double-dispatches). */
    var isAcceptingPlan: Boolean by mutableStateOf(false)
        private set

    /** ⇄ exporting / refreshingMediaJobs menu latches (settled by host echo). */
    var exportInFlight: Boolean by mutableStateOf(false)
        private set
    var mediaRefreshInFlight: Boolean by mutableStateOf(false)
        private set

    /** The send whose launch is admitted but NOT yet atomically prepared.
     * Main's async-launch addendum: `startRun == true` is the host's
     * OWNED-PREPARATION ADMISSION, not a durable start; the matching commit
     * (text + staged attachments + generations + temporary incarnation) is
     * RETAINED until the host echoes the real prepared outcome for exactly
     * this correlation, or a correlated failure reverses it. While retained,
     * a second fresh send is gated as in-flight (pending-duplicate gate). */
    private var pendingCommit: ComposerSendCommit? = null

    /** Presentation fencing counter for launch correlations (never a domain
     * id; monotonic for this holder's lifetime — the session epoch fences
     * across rebind/retirement). */
    private var launchGenerationInternal = 0L

    /** ⇄ presentedChild sheet target (on-demand transcript). */
    val openChildRunId: MutableState<String?> = mutableStateOf(null)

    /** ⇄ showsChecklist disclosure. */
    var checklistExpanded: Boolean by mutableStateOf(false)
        private set

    /** ⇄ showingGoalBuilder / showsTemporaryAbout transient sheets. */
    var showingGoalBuilder: Boolean by mutableStateOf(false)
        private set
    var showsTemporaryAbout: Boolean by mutableStateOf(false)
        private set

    /** ⇄ editingPendingInput: which queued row the editor sheet binds to. */
    val editingPendingInputId: MutableState<String?> = mutableStateOf(null)

    /** ⇄ selectedAttachment: the attachment open sheet binds to. */
    val selectedAttachment: MutableState<AttachmentOpenRequest?> = mutableStateOf(null)

    /** ⇄ presentedUsageSummary: retained until the next open so a dismissal
     * never collapses the presentation mid-transition. */
    var presentedUsage: UsageUi? by mutableStateOf(null)
        private set

    /** ⇄ ReasoningBlockView live block @State isExpanded: collapsed by
     * default even while streaming (a spinner marks live content). */
    var liveReasoningExpanded: Boolean by mutableStateOf(false)
        private set

    fun toggleLiveReasoning() { if (retired) return; liveReasoningExpanded = !liveReasoningExpanded }

    /** Groups whose initial disclosure rule has already been applied
     * (⇄ SwiftUI @State seeded at init: never re-seeded on later updates). */
    private var groupDefaultsApplied = mutableSetOf<String>()
    private var groupWasLatest = mutableMapOf<String, Boolean>()

    /* --------------------------------- binding --------------------------------- */

    /** First load for the bound conversation. A retired holder never
     * re-requests: no late reconstruction callback may rehydrate discarded
     * presentation state (the host's epoch fence is not the only layer). */
    fun load() {
        if (retired) return
        host.loadThread(session)
    }

    /** Genuine conversation change (NOT a recreation): fence the old session,
     * drop presentation state, and rebind with a new epoch. View
     * reconstruction never calls this. */
    fun rebind(newConversationId: String, initialDraft: ComposerDraftSeedUi? = null) {
        if (newConversationId == conversationIdInternal) return
        host.threadViewDetached(session)
        conversationIdInternal = newConversationId
        session = ConversationSessionToken(newConversationId, session.sessionEpoch + 1)
        // The OLD conversation's entire presentation payload is discarded
        // (one shared implementation with retirement), then the new task's
        // host-restored draft is seeded.
        discardPresentationPayloads()
        draft.value = draftSeedToFieldValue(initialDraft)
        stagedAttachments.value = initialDraft?.attachments ?: emptyList()
        pendingCommit = null
        temporaryKeepBound = null
        temporaryEndBound = null
        // A rebind is a new session: every cached parse fragment and pending
        // generation belongs to the dead epoch and must not style this one.
        markdownCoordinator.invalidateAll()
        markdownRevision.value += 1L
        host.loadThread(session)
    }

    /** ⇄ ThreadDetailView.onDisappear stopLiveUpdates: leaving the thread
     * stops updates; retained drafts survive with the holder. This is a VIEW
     * DETACH — never a navigation. It must not discard temporary RAM state:
     * a backgrounding/lock/recreation/detach keeps the ephemeral session and
     * any in-flight Keep exactly as iOS does. Only [retireForNavigation]
     * (genuine route change / New Task, host-driven) fences this holder. */
    fun detach() {
        host.threadViewDetached(session)
    }

    /** True after a GENUINE navigation retired this holder. */
    var retired: Boolean = false
        private set

    /**
     * The genuine-navigation invalidation hook. The host calls this ONLY on
     * an actual route change away from this conversation (open another
     * conversation / New Task) — never on recomposition, lock, backgrounding
     * or view detach. It retires the presentation session so no late
     * Keep/end/send/parse echo from this retained object can navigate,
     * style or mutate anything on the new route; the durable/temporary RAM
     * destruction itself belongs to the host (TMP-NAV-DISCARD).
     *
     * Main's correction (2026-10-18): the host destroys its OWN temporary
     * store but cannot clear this retained UI holder's presentation payload,
     * so retirement discards the full ephemeral surface here: the draft
     * field value, staged attachment references, errors/banners, secondary
     * sheet/selection state, scroll presentation, latches and the shared
     * edit history. The temporary posture is captured BEFORE the snapshot
     * clear. Nothing durable is deleted: ordinary drafts survive in the
     * host's durable draft store exactly as before (this holder is
     * RAM-only), and [detach] still retains everything.
     */
    fun retireForNavigation() {
        if (retired) return
        host.threadViewDetached(session)
        // The temporary posture is captured BEFORE the snapshot clear
        // (Main): the in-flight Keep is temporary-session state and must
        // flip to Idle with the discard, never after — the discard below
        // reads nothing from the snapshot it is about to null.
        retired = true
        session = ConversationSessionToken(conversationIdInternal, session.sessionEpoch + 1)
        discardPresentationPayloads()
        // A retired holder keeps NO launch commit and no temporary keep/end
        // bindings: late echoes are rejected first by [retired], and the
        // payload itself must not linger in the retained object.
        pendingCommit = null
        temporaryKeepBound = null
        temporaryEndBound = null
        markdownCoordinator.invalidateAll()
        markdownRevision.value += 1L
    }

    /**
     * Discards every ephemeral presentation payload this holder retains:
     * the draft (text, caret, selection), staged attachment references,
     * action/attachment/model errors, sheet and disclosure state, scroll
     * presentation, selection/dispatch latches and the shared editor
     * history. Used by [retireForNavigation]; a rebind re-seeds afterwards.
     */
    private fun discardPresentationPayloads() {
        snapshot.value = null
        draft.value = TextFieldValue("")
        draftGenerationInternal = 0
        stagedAttachments.value = emptyList()
        editorUndoHistory.clear()
        editorRedoHistory.clear()
        refreshEditorHistoryFlags()
        selectedModelId.value = null
        selectedProjectId.value = null
        selectedRunId.value = null
        expandedGroups.value = emptySet()
        expandedToolCards.value = emptySet()
        expandedApprovalEvidence.value = emptySet()
        approvalScopeChoices.value = emptyMap()
        approvalDispatched.clear()
        followState.returnToLatest()
        showsReturnToLatest = false
        actionError = null
        attachmentError = null
        modelPersistenceFailureName = null
        queueRefreshFailureToken = null
        isCompacting = false
        temporaryKeepState = TemporaryKeepStateUi.Idle
        temporaryDraftHandoffPending = false
        isAcceptingPlan = false
        exportInFlight = false
        mediaRefreshInFlight = false
        showsFullEditor = false
        // Find/Replace is ephemeral presentation state: a genuine new session,
        // rebind or temporary discard must not retain a query, replacement,
        // match options or a current match from the discarded draft.
        findReplace = FindReplaceUiState()
        openChildRunId.value = null
        editingPendingInputId.value = null
        selectedAttachment.value = null
        presentedUsage = null
        groupDefaultsApplied = mutableSetOf()
        groupWasLatest = mutableMapOf()
        agentMode = AgentExecutionModeUi.AGENT
        explicitModePlanRevision = null
        checklistExpanded = false
        showingGoalBuilder = false
        showsTemporaryAbout = false
        liveReasoningExpanded = false
    }

    /** Every host→holder echo entry first checks this: after genuine
     * navigation NOTHING lands, independent of any epoch equality held
     * inside this now-dead object. */
    private fun echoAccepted(echoSession: ConversationSessionToken): Boolean =
        !retired && echoSession.isCurrentFor(session)

    private fun draftSeedToFieldValue(seed: ComposerDraftSeedUi?): TextFieldValue {
        if (seed == null) return TextFieldValue("")
        val caret = (seed.caretIndex ?: seed.text.length).coerceIn(0, seed.text.length)
        val end = (caret + (seed.selectionLength ?: 0)).coerceIn(caret, seed.text.length)
        return TextFieldValue(text = seed.text, selection = TextRange(caret, end))
    }

    /* ------------------------------ host projections ----------------------------- */

    /** Apply one immutable host snapshot. Stale epochs and foreign
     * conversations are ignored (late results cannot touch another session). */
    fun applyHostSnapshot(next: ThreadUiState) {
        if (!echoAccepted(next.session)) return
        val previous = snapshot.value
        snapshot.value = next

        // A replaced temporary incarnation (or promotion out of temporary) is
        // an ACTUAL session change even when the conversation id/epoch is
        // reused. The previous incarnation's Find presentation must not leak a
        // query/current match into the new ephemeral content.
        if (previous != null &&
            previous.temporaryIncarnationId != next.temporaryIncarnationId
        ) {
            findReplace = FindReplaceUiState()
        }

        // ⇄ first-page model restore: run's model, else first usable.
        if (selectedModelId.value == null) {
            val runModel = next.runs.firstOrNull { it.id == next.selectedRunId }?.modelId
                ?: next.runs.firstOrNull()?.modelId
            selectedModelId.value = runModel?.takeIf { id ->
                next.models.any { it.modelId == id && it.isUsable }
            } ?: next.models.firstOrNull { it.isUsable }?.modelId
        }
        // ⇄ selectedProjectID from the host's EXPLICIT bound-workspace
        // projection (Main addendum; repository AGENTS: never silently choose
        // the first project). Null is an honest "unbound": the locked chip
        // shows no workspace and the launch carries workspaceId = null — the
        // send can never silently claim a different workspace than the
        // binding. The picker stays locked (existing-task ownership is the
        // host's immutable decision); an unknown binding id cannot masquerade
        // as a real workspace.
        selectedProjectId.value = next.boundWorkspaceId?.takeIf { id ->
            next.projects.any { it.id == id }
        }
        // ⇄ reconcilePlanComposerMode after every plan refresh.
        agentMode = PlanModeReconciler.reconcile(next.plan, explicitModePlanRevision, agentMode)

        // Approvals that left the projection were resolved/expired
        // host-side; their dispatch latches are released with the card.
        val liveKeys = next.pendingApprovals.map { it.key }.toSet()
        approvalDispatched.retainAll(liveKeys)

        // ⇄ onChange(of: hasLoaded) → scroll to latest anchor.
        if (previous?.hasLoaded != true && next.hasLoaded) {
            followState.returnToLatest()
            showsReturnToLatest = false
        }

        applyGroupTransitions(next)
    }

    /** ⇄ StepGroupView @State transitions: seed the disclosure rule exactly
     * once per group; collapse when a group loses "latest"; force-expand when
     * a pending approval lands in the group (never re-expand after an
     * explicit user collapse unless a NEW approval arrives). */
    private fun applyGroupTransitions(next: ThreadUiState) {
        val pendingKeys = next.pendingApprovals.map { it.key }.toSet()
        val expanded = expandedGroups.value.toMutableSet()
        next.rows.filterIsInstance<TimelineRowUi.StepGroup>().forEach { group ->
            val hasApproval = group.events.any { event ->
                val call = StepGroupPairing.callIdOf(event)
                call != null && pendingKeys.contains("${event.runId}/$call")
            }
            if (group.groupId !in groupDefaultsApplied) {
                groupDefaultsApplied.add(group.groupId)
                val isLive = group.isLatest && next.isRunning
                val hasError = group.events.any { it.kind == RunEventKindUi.ERROR }
                if (StepGroupDisclosurePolicy.initiallyExpanded(
                        isLatest = group.isLatest, isLive = isLive,
                        hasError = hasError, hasPendingApproval = hasApproval,
                    )
                ) {
                    expanded.add(group.groupId)
                }
            } else if (groupWasLatest[group.groupId] == true && !group.isLatest) {
                expanded.remove(group.groupId)
            }
            if (hasApproval) expanded.add(group.groupId)
            groupWasLatest[group.groupId] = group.isLatest
        }
        expandedGroups.value = expanded
    }

    /** ⇄ draftStore.sendHandoffUpdate: a freshly reconstructed editor (still
     * at generation 0) follows launch reconciliation; any real edit owns a
     * newer epoch and is never overwritten. */
    fun applySendHandoff(newText: String?, newAttachments: List<StagedAttachmentUi>?) {
        if (retired) return
        if (draftGeneration != 0L) return
        val previousText = draft.value.text
        newText?.let { text -> draft.value = TextFieldValue(text) }
        newAttachments?.let { stagedAttachments.value = it }
        if (newText != null && newText != previousText) {
            refreshFindState(selectCurrent = false)
        }
    }

    /* --------------------------------- draft API --------------------------------- */

    /** Field edits flow through here: real text changes advance the
     * generation, re-arm persistence after a handoff, and forward the durable
     * save effect to the host while persistence is allowed (the host debounces
     * and stamps its own revision floor). */
    fun onDraftChange(next: TextFieldValue) {
        if (retired) return
        applyDraftEdit(next, recordPrevious = draft.value)
    }

    /** Single draft mutation pipeline shared by the inline field, the full
     * editor, undo/redo and select-all. [recordPrevious] is non-null only
     * for direct user keystrokes: undo/redo replay and programmatic sets
     * never re-record (⇄ the shared UndoManager's own semantics), and a
     * caret-only change never creates a history entry. */
    private fun applyDraftEdit(next: TextFieldValue, recordPrevious: TextFieldValue?) {
        val previous = draft.value
        draft.value = next
        val textChanged = next.text != previous.text
        if (textChanged) {
            if (recordPrevious != null && next.text != previous.text) {
                editorUndoHistory.addLast(recordPrevious)
                if (editorUndoHistory.size > MAX_EDITOR_HISTORY) editorUndoHistory.removeFirst()
                editorRedoHistory.clear()
            }
            draftGenerationInternal += 1
            if (temporaryDraftHandoffPending) {
                temporaryDraftHandoffPending = false // first edit re-arms
            }
            // A live Find bar follows the NEW immutable text revision. This is
            // count/current-match refresh only: it never moves the caret the
            // user is typing at and never records an edit.
            refreshFindState(selectCurrent = false)
        }
        refreshEditorHistoryFlags()
        if (textChanged && shouldPersistDraftEdits) {
            host.saveDraft(
                session, next.text,
                stagedAttachments.value.map { it.id },
                next.selection.min, next.selection.length,
            )
        } else if (shouldPersistDraftEdits && next.selection != previous.selection) {
            // Caret-only moves update the stored selection; text generation
            // is unchanged (⇄ updateSelection on the Swift store).
            host.saveDraft(
                session, next.text,
                stagedAttachments.value.map { it.id },
                next.selection.min, next.selection.length,
            )
        }
    }

    /** ⇄ noteDraftEditedByUser: composer wiring calls this when a non-keystroke
     * producer changed the draft so the handoff re-arms exactly once. */
    fun noteDraftEditedByUser() {
        if (temporaryDraftHandoffPending) temporaryDraftHandoffPending = false
    }

    /* ------------------------------ attachments API ----------------------------- */

    /** Apply one host import outcome for a staged row (row-existence fenced).
     * A row the user already removed never reappears from a late callback
     * (CHA-ATTACH-LIFECYCLE-AND). */
    fun applyAttachmentOutcome(attachmentId: String, outcome: AttachmentImportUi) {
        if (retired) return
        val current = stagedAttachments.value
        val index = current.indexOfFirst { it.id == attachmentId }
        if (index < 0) return
        val updated = current.toMutableList()
        updated[index] = updated[index].copy(import = outcome)
        stagedAttachments.value = updated
        when (outcome) {
            is AttachmentImportUi.Failed -> attachmentError = outcome.message
            AttachmentImportUi.Ready -> attachmentError = null
            else -> Unit
        }
    }

    fun anyAttachmentProcessing(): Boolean = stagedAttachments.value.any { it.isProcessing }

    /** Temporary chat never stages import UI (staged files stay in the draft,
     * the launch carries none — ⇄ ThreadComposerView temporary composer). */
    fun requestAttach(): ConversationFlowResult {
        if (snapshot.value?.isTemporary == true) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        return if (host.requestAttachmentImport(session)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun retryAttachment(attachmentId: String): ConversationFlowResult {
        if (stagedAttachments.value.none { it.id == attachmentId }) return ConversationFlowResult.Stale
        return if (host.retryAttachmentImport(session, attachmentId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun cancelAttachment(attachmentId: String): ConversationFlowResult {
        val exists = stagedAttachments.value.any {
            it.id == attachmentId && it.import is AttachmentImportUi.InProgress
        }
        if (!exists) return ConversationFlowResult.Stale
        // Remove the presentation row FIRST: a late success callback then finds
        // no matching id and is dropped (fence above).
        stagedAttachments.value = stagedAttachments.value.filterNot { it.id == attachmentId }
        host.cancelAttachmentImport(session, attachmentId)
        return ConversationFlowResult.Accepted
    }

    fun removeStagedAttachment(attachmentId: String) {
        stagedAttachments.value = stagedAttachments.value.filterNot { it.id == attachmentId }
        host.discardStagedAttachment(session, attachmentId)
    }

    fun openMessageAttachment(request: AttachmentOpenRequest): ConversationFlowResult =
        if (host.openMessageAttachment(session, request)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /* ---------------------------------- sending ---------------------------------- */

    /** ⇄ ThreadDetailViewModel.send(): canonical launch/queue path with
     * draft-generation identity, temporary text-only launch, send-origin gate
     * and pre-accept failure restore of the COMPLETE original draft. */
    fun send(
        onLaunchOutcome: ((admitted: Boolean, reason: String?) -> Unit)? = null,
    ): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (state.isConversationMissing) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        // The canonical pipeline enforces the SAME provider gate as the
        // inline guard (first JVM-run finding: a programmatic send must not
        // dispatch a launch the disabled send circle could never start).
        if (state.needsProvider) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val goal = draft.value.text.trim()
        if (goal.isEmpty()) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val model = state.models.firstOrNull { it.modelId == selectedModelId.value && it.isUsable }
            ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)

        val isTemporary = state.isTemporary
        val launchAttachments = ThreadSendPolicy.launchAttachments(isTemporary, stagedAttachments.value)
        val effectiveMode = ThreadSendPolicy.effectiveAgentMode(isTemporary, agentMode)
        // Send-origin identity captured BEFORE the effect: a late result may
        // only mutate drafts while this exact incarnation is current.
        val originIncarnation = if (isTemporary) state.temporaryIncarnationId else null
        // The Home draft-task policy applies ONLY to the first fresh launch of
        // a brand-new ordinary conversation (⇄ persisted atomically with the
        // first launch). A temporary session never carries it, and once the
        // conversation owns durable runs the durable task-policy row +
        // run.policy.update lane is the task truth — this field stays null.
        val launchApprovalMode = if (!isTemporary && state.runs.isEmpty()) draftTaskApprovalMode else null

        if (state.isRunning) {
            // Queue/steer: the field keeps the draft until the submit lands;
            // the commit identity is captured before the await (⇄ iOS).
            val runId = state.selectedRunId ?: return rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE)
            isConsumingDraft = true
            val commit = ComposerSendCommit(
                conversationId = conversationId,
                sentText = draft.value.text,
                sentAttachments = launchAttachments,
                editorGeneration = draftGeneration,
                temporaryIncarnationId = originIncarnation,
            )
            val started = host.submitRunningInput(
                RunningInputRequest(
                    conversationId = conversationId,
                    sessionEpoch = session.sessionEpoch,
                    expectedRunId = runId,
                    content = goal,
                    mode = runningInputMode,
                    modelId = model.modelId,
                    workspaceId = selectedProjectId.value,
                    executionMode = effectiveMode,
                    attachments = launchAttachments,
                    temporaryIncarnationId = originIncarnation,
                )
            )
            isConsumingDraft = false
            if (!started) return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
            if (sendOriginAllows(originIncarnation)) consumeSentDraft(commit)
            return ConversationFlowResult.Accepted
        }

        // Fresh run (⇄ iOS ordering): the send's OWN clear happens first and
        // advances the generation; the commit pins that post-clear identity,
        // so "from here only user edits own the field." The optimistic field
        // clear REMAINS reversible until the real prepared echo arrives.
        if (pendingCommit != null) {
            // Pending-duplicate gate: one admitted-but-not-yet-prepared
            // launch at a time (⇄ the inline guard's "task being created").
            return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        }
        val sentText = draft.value.text
        launchGenerationInternal += 1
        isConsumingDraft = true
        draft.value = TextFieldValue("")
        draftGenerationInternal += 1
        refreshFindState(selectCurrent = false)
        val commit = ComposerSendCommit(
            conversationId = conversationId,
            sentText = sentText,
            sentAttachments = launchAttachments,
            editorGeneration = draftGenerationInternal,
            temporaryIncarnationId = originIncarnation,
            launchGeneration = launchGenerationInternal,
            launchSessionEpoch = session.sessionEpoch,
        )
        pendingCommit = commit
        val started = host.startRun(
            RunLaunchRequest(
                conversationId = conversationId,
                sessionEpoch = session.sessionEpoch,
                goalText = goal,
                attachments = launchAttachments,
                executionMode = effectiveMode,
                modelId = model.modelId,
                workspaceId = selectedProjectId.value,
                temporaryIncarnationId = originIncarnation,
                launchGeneration = commit.launchGeneration,
                providerId = model.providerId,
                approvalMode = launchApprovalMode,
            ),
            onLaunchOutcome,
        )
        isConsumingDraft = false
        if (started) {
            // The draft choice was captured into THIS launch's request; the
            // durable policy row (if the launch commits) or the restored
            // draft (if it fails before admission) owns everything from
            // here, so the holder never re-sends the same draft key.
            draftTaskApprovalMode = null
        }
        if (!started) {
            // Nothing began: put the complete original draft back unless the
            // user already owns a newer field generation.
            if (sendOriginAllows(originIncarnation) && commit.editorStillConsumed(draftGeneration)) {
                draft.value = TextFieldValue(sentText, TextRange(sentText.length))
                draftGenerationInternal += 1
                refreshFindState(selectCurrent = false)
            }
            pendingCommit = null
            return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        }
        // ADMISSION only: the optimistic visual consumption stays
        // REVERSIBLE; the commit is retained; the durable draft clear is
        // deferred to the matching prepared echo (applyLaunchPrepared).
        if (sendOriginAllows(originIncarnation)) consumeSentDraft(commit)
        return ConversationFlowResult.Accepted
    }

    /**
     * Host echo: the admitted launch ACTUALLY completed its atomic prepare
     * (the run durably started). Only now is the retained matching commit
     * consumed exactly once: the durable draft store is cleared for exactly
     * this send and the commit is released. Any correlation mismatch — or a
     * retired holder — is rejected: a late success for request A can never
     * consume request B or a replaced session.
     */
    fun applyLaunchPrepared(correlation: LaunchCorrelation) {
        if (retired) return
        val commit = pendingCommit ?: return
        if (!matchesLaunchCommit(commit, correlation)) return
        commit.clearStoredDraft()
        pendingCommit = null
    }

    /**
     * Host echo: the admitted launch FAILED before execution (preflight
     * reversal after the queued acceptance — the exact case the synchronous
     * boolean could not express). Restores the COMPLETE original draft and
     * staged attachments while the field is still owned by this send
     * (reversible optimistic clear), surfaces the host-localized failure, and
     * releases the commit exactly once. A correlation mismatch — or a retired
     * holder — touches nothing: late failure A must not clobber draft B or
     * navigate another route.
     */
    fun applyLaunchFailure(correlation: LaunchCorrelation, message: String) {
        if (retired) return
        val commit = pendingCommit ?: return
        if (!matchesLaunchCommit(commit, correlation)) return
        if (sendOriginAllows(commit.temporaryIncarnationId) && commit.editorStillConsumed(draftGeneration)) {
            draft.value = TextFieldValue(commit.sentText, TextRange(commit.sentText.length))
            stagedAttachments.value = stagedAttachments.value +
                commit.sentAttachments.filter { staged -> stagedAttachments.value.none { it.id == staged.id } }
            draftGenerationInternal += 1
            refreshFindState(selectCurrent = false)
        }
        pendingCommit = null
        isConsumingDraft = false
        actionError = message
    }

    /** Launch echoes fence on the IMMUTABLE request identity: conversation,
     * session epoch, launch generation and temporary incarnation must all
     * equal the retained commit's. */
    private fun matchesLaunchCommit(commit: ComposerSendCommit, correlation: LaunchCorrelation): Boolean =
        correlation.conversationId == conversationId &&
            correlation.sessionEpoch == commit.launchSessionEpoch &&
            correlation.launchGeneration == commit.launchGeneration &&
            correlation.temporaryIncarnationId == commit.temporaryIncarnationId

    /** ⇄ commit.commitStore(): the host's durable draft reconciliation for
     * exactly the consumed text identity. */
    private fun ComposerSendCommit.clearStoredDraft() {
        host.clearDraftAfterSend(session, sentText, sentAttachments.map { it.id })
    }

    /** ⇄ consumeSentDraft: clears exactly the generation this send consumed. */
    private fun consumeSentDraft(commit: ComposerSendCommit) {
        val currentText = commit.draftAfterSuccess(draft.value.text, draftGeneration)
        val caret = if (currentText == draft.value.text) draft.value.selection else TextRange(currentText.length)
        draft.value = TextFieldValue(currentText, caret)
        refreshFindState(selectCurrent = false)
        stagedAttachments.value = commit.attachmentsAfterSuccess(stagedAttachments.value)
    }

    /** ⇄ sendOriginAllowsDraftMutation. */
    private fun sendOriginAllows(originIncarnation: String?): Boolean {
        val state = snapshot.value ?: return originIncarnation == null
        return TemporarySendOriginGate.allowsDraftMutation(
            originIncarnation = originIncarnation,
            currentIncarnation = state.temporaryIncarnationId,
            isTemporaryNow = state.isTemporary,
            conversationId = conversationId,
            promotedConversationId = state.promotedConversationId,
        )
    }

    /* --------------------------------- run control -------------------------------- */

    /** ⇄ cancel(): stop the composer immediately; the durable cancelled state
     * arrives later through the authoritative projection. */
    fun cancel(): ConversationFlowResult {
        val runId = snapshot.value?.selectedRunId
            ?: return rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE)
        actionError = null
        return if (host.cancelRun(session, runId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Explicit human Stop for LIVE post-run goal REVIEW/continuation work.
     * Routes the EXISTING `run.cancel` at the EXACT review-owning run (the
     * native control wires the review stop before its retired/terminal fast
     * paths; unrelated or replacement runs are never touched). The ack is
     * never a settled claim: the surface shows `stopping` until the SAME
     * `run.snapshot` `goalReview` readback actually reaches `none`. */
    fun requestGoalReviewStop(runId: String): ConversationFlowResult {
        if (retired) return rejected(ConversationRejectedReason.NO_SESSION)
        if (runId.isBlank()) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        actionError = null
        return if (host.cancelRun(session, runId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** ⇄ retry(): resume the durable selected run without duplicating its
     * user message; job-parked runs are never resumed by Continue. */
    fun retry(): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (state.selectedRunWaitingForJobs) return rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE)
        val runId = state.selectedRunId ?: return rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE)
        val started = host.retryRun(session, runId)
        return if (started) { actionError = null; ConversationFlowResult.Accepted }
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun selectRun(runId: String) {
        if (retired) return
        selectedRunId.value = runId
    }

    /* ---------------------------------- approvals ---------------------------------- */

    /** Current projected card for one run+call key, or null. */
    fun approvalCard(key: String): ApprovalCardUi? =
        snapshot.value?.pendingApprovals?.firstOrNull { it.key == key }

    /** ⇄ resolve(approval, decision): dispatch the EXACT run+call identity
     * once. Deny carries the stable "user denied" vocabulary; the grant tier
     * is the user's chosen scope for the projected target — never a
     * content-imported permission (APR-UNTRUSTED-NO-GRANT / APR-CALL-BOUND). */
    fun resolveApproval(approval: ApprovalCardUi, allow: Boolean): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val live = state.pendingApprovals.firstOrNull { it.key == approval.key }
            ?: return ConversationFlowResult.Stale
        if (live.key in approvalDispatched) return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        val choice = approvalScopeChoices.value[live.key] ?: ApprovalScopeChoiceUi.ONCE
        val decision: ApprovalUserDecisionUi =
            if (allow) ApprovalUserDecisionUi.Allow(choice) else ApprovalUserDecisionUi.Deny
        val grant = (decision as? ApprovalUserDecisionUi.Allow)?.let {
            ApprovalGrantMapping.grant(live.toolName, live.target, live.scopeDescription, it.scopeChoice)
        }
        val started = host.resolveApproval(
            ApprovalDecisionRequest(
                conversationId = conversationId,
                sessionEpoch = session.sessionEpoch,
                approvalId = live.approvalId,
                runId = live.runId,
                workspaceId = live.workspaceId,
                toolName = live.toolName,
                decision = decision,
                grant = grant,
                reason = if (allow) null else DENY_REASON,
            )
        )
        if (!started) return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        approvalDispatched.add(live.key)
        return ConversationFlowResult.Accepted
    }

    fun setApprovalScope(key: String, choice: ApprovalScopeChoiceUi) {
        approvalScopeChoices.value = approvalScopeChoices.value + (key to choice)
    }

    fun toggleApprovalEvidence(key: String) {
        val current = expandedApprovalEvidence.value
        expandedApprovalEvidence.value = if (key in current) current - key else current + key
    }

    /* ------------------------------- pending inputs ------------------------------- */

    fun openPendingInputEditor(inputId: String) {
        if (retired) return
        val state = snapshot.value ?: return
        val input = state.pendingInputs.firstOrNull { it.id == inputId } ?: return
        editingPendingInputId.value = inputId
        // Queue-content hydration (G04R2): the sheet may only become
        // editable for a PROVEN body — the row's COMPLETE slot (native
        // short-row proof or an already-published read) or a published
        // Ready. Everything else starts/awaits the bounded detail read;
        // the unread original is never shown as an empty editable.
        val proven = input.bodyState == PendingInputBodyStateUi.COMPLETE ||
            state.pendingInputBodies[inputId] is PendingInputBodyUi.Ready
        if (!proven) {
            host.requestPendingInputBody(session, inputId)
        }
    }

    fun closePendingInputEditor() { editingPendingInputId.value = null }

    /** ⇄ editPendingInput: the trimmed content replaces the queued row —
     * but ONLY when the projected slot is a PROVEN complete body (or a
     * published Ready read at the row's current CAS version). A blank or
     * bounded-preview editor NEVER overwrites the unread original; the
     * host additionally re-proves the CAS against a fresh snapshot before
     * the envelope leaves the App. */
    fun editPendingInput(inputId: String, content: String): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val input = state.pendingInputs.firstOrNull { it.id == inputId }
            ?: return ConversationFlowResult.Stale
        val body = state.pendingInputBodies[inputId]
        val provenComplete = input.bodyState == PendingInputBodyStateUi.COMPLETE &&
            (input.inputVersion == null || body == null ||
                (body is PendingInputBodyUi.Ready && body.inputVersion == input.inputVersion))
        if (!provenComplete && body !is PendingInputBodyUi.Ready) {
            return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        }
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        return if (host.editPendingInput(session, inputId, trimmed)) {
            editingPendingInputId.value = null
            ConversationFlowResult.Accepted
        } else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun removePendingInput(inputId: String): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (state.pendingInputs.none { it.id == inputId }) return ConversationFlowResult.Stale
        return if (host.removePendingInput(session, inputId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** ⇄ movePendingInput(offset): validated on the QUEUED slice only; an
     * out-of-range move dispatches nothing. */
    fun movePendingInput(inputId: String, offset: Int): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val order = PendingInputQueueLogic.reorderQueued(state.pendingInputs, inputId, offset)
            ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        return if (host.reorderPendingInputs(session, order)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** ⇄ promotePendingInput: steer only while a run is live. */
    fun promotePendingInput(inputId: String): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val runId = state.selectedRunId ?: return rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE)
        val input = state.pendingInputs.firstOrNull { it.id == inputId }
            ?: return ConversationFlowResult.Stale
        if (!PendingInputQueueLogic.canPromoteToSteer(state.isRunning, input.status)) {
            return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        }
        return if (host.promotePendingInput(session, inputId, runId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /* ------------------------------ composer selections ----------------------------- */

    /** ⇄ chooseModel: selection applies to THIS composer immediately; a failed
     * durable default persistence is a visible banner (no silent revert). */
    fun selectModel(modelId: String): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val model = state.models.firstOrNull { it.modelId == modelId && it.isUsable }
            ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        selectedModelId.value = model.modelId
        val persisted = host.selectModel(session, modelId)
        if (!persisted) modelPersistenceFailureName = model.displayName
        return ConversationFlowResult.Accepted
    }

    fun dismissModelPersistenceBanner() { modelPersistenceFailureName = null }

    fun setRunningInputMode(mode: RunningInputModeUi) {
        runningInputMode = mode
        host.setRunningInputMode(session, mode)
    }

    /** ⇄ selectAgentMode(mode): explicit choices pin the plan revision so a
     * later refresh cannot invent an exit from the same plan. */
    fun selectAgentMode(mode: AgentExecutionModeUi) {
        explicitModePlanRevision = PlanModeReconciler.onExplicitModeSwitch(snapshot.value?.plan)
        agentMode = mode
    }

    /* -------------------------------- plan & goal -------------------------------- */

    /** ⇄ acceptLatestPlan(as:): only a ready+decision-complete plan accepts,
     * bound to the EXACT revision+digest the user saw. */
    fun acceptPlan(execution: PlanRecommendationUi?): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val plan = state.plan ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        if (plan.statusRaw != "ready" || !plan.isDecisionComplete) {
            return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        }
        if (isAcceptingPlan || state.isRunning) return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        if (state.needsProvider) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        // The accept binds the EXACT durable plan members the user saw. A
        // wire without the real digest/revision is an honest refusal — the
        // App never sends a fabricated identity and never launches a second
        // run behind the accept (plan.accept IS the one launch).
        val planDigest = plan.digest ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val model = state.models.firstOrNull { it.modelId == selectedModelId.value && it.isUsable }
            ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        isAcceptingPlan = true
        val started = host.acceptPlan(
            session,
            planId = plan.id,
            planRevision = plan.revisionNumber,
            planDigest = planDigest,
            // null = keep the plan's OWN durable execution recommendation;
            // the App never materializes a default into the payload.
            execution = execution,
            modelId = model.modelId,
            providerId = model.providerId,
        )
        if (!started) isAcceptingPlan = false
        return if (started) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Host echo for the settled plan accept (any terminal): releases the
     * latch; the durable refresh/re-read owns the new projection. */
    fun applyPlanAcceptSettled() {
        if (retired) return
        isAcceptingPlan = false
    }

    fun openGoalBuilder() { if (retired) return; showingGoalBuilder = true }
    fun dismissGoalBuilder() { showingGoalBuilder = false }

    /** ⇄ createGoal(...): the launch carries the structured fields as the
     * approved `run.start` additive `goalDefinition`; the native C1 owns the
     * durable goal row (default criterion copy is Swift-side). This UI only
     * validates the objective and forwards the explicit conditions with the
     * thread's ACTUAL selected model — never a first-usable substitution. */
    fun createGoal(
        objective: String,
        criteria: List<String>,
        blockers: List<String>,
        stops: List<String>,
    ): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val cleanObjective = objective.trim()
        if (cleanObjective.isEmpty()) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        if (state.isRunning || state.needsProvider) {
            return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        }
        val model = state.models.firstOrNull { it.modelId == selectedModelId.value && it.isUsable }
            ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val started = host.createGoal(
            GoalCreateRequest(
                conversationId = conversationId,
                sessionEpoch = session.sessionEpoch,
                objective = cleanObjective,
                criteria = criteria.filter { it.isNotBlank() },
                blockingConditions = blockers.filter { it.isNotBlank() },
                stoppingConditions = stops.filter { it.isNotBlank() },
                modelId = model.modelId,
                providerId = model.providerId,
            )
        )
        if (!started) return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        showingGoalBuilder = false
        return ConversationFlowResult.Accepted
    }

    /** ⇄ confirmGoalCompletion(): only a verifying goal offers it; the
     * completion gate is the host's authority. The command itself is the
     * explicit human gesture (no model/inferred approval exists anywhere on
     * this path) and it binds the goal's ACTUAL server revision. */
    fun confirmGoalCompletion(): ConversationFlowResult {
        val goal = snapshot.value?.goal ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (goal.statusRaw != "verifying") return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val revisionVersion = goal.revisionVersion ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val revisionResource = goal.revisionResourceID ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        if (goal.revision <= 0) return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        goalConfirmBlockers.value = null // a new explicit attempt owns fresh results
        val started = host.confirmGoalCompletion(
            session,
            goalId = goal.id,
            expectedRevision = goal.revision,
            revisionResourceID = revisionResource,
            revisionVersion = revisionVersion,
        )
        return if (started) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Host echo: the last confirm settlement was BLOCKED/stale. [blockers]
     * are the host-localized human lines for the REAL machine codes (an
     * empty list means the typed refusal carried none). Nothing persisted —
     * the durable projection re-read is the truth. */
    fun applyGoalConfirmBlocked(blockers: List<String>) {
        if (retired) return
        goalConfirmBlockers.value = blockers
    }

    /** Host echo: a confirmed (or re-read) goal projection replaced the last
     * blocked surface. */
    fun clearGoalConfirmBlockers() {
        if (retired) return
        goalConfirmBlockers.value = null
    }

    /* ------------------------------ temporary chat ------------------------------ */

    /** ⇄ keepTemporaryChat: binds to the exact incarnation shown. A retry is
     * allowed from PartialRetry/Failed, never while Saving. */
    fun keepTemporaryChat(): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (temporaryKeepState == TemporaryKeepStateUi.Saving) {
            return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        }
        val incarnation = state.temporaryIncarnationId
            ?: return rejected(ConversationRejectedReason.STALE)
        if (!state.isTemporary) return rejected(ConversationRejectedReason.STALE)
        temporaryKeepBound = TemporarySessionRef(
            conversationId,
            session.sessionEpoch,
            incarnation,
            nativeRootEpoch = temporaryNativeRootEpoch,
        )
        temporaryKeepState = TemporaryKeepStateUi.Saving
        actionError = null
        val started = host.keepTemporaryChat(temporaryKeepBound!!)
        if (!started) {
            temporaryKeepState = TemporaryKeepStateUi.Idle
            temporaryKeepBound = null
            return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        }
        return ConversationFlowResult.Accepted
    }

    private var temporaryKeepBound: TemporarySessionRef? = null

    /** Host keep outcome echo, fenced on the bound incarnation. Promotion is
     * only acknowledged when the projection confirms THIS identity left the
     * temporary state (or landed as promoted) — never a bare success string. */
    fun applyTemporaryKeepOutcome(ref: TemporarySessionRef, outcome: TemporaryKeepOutcomeUi) {
        if (retired) return
        val bound = temporaryKeepBound ?: return
        if (ref.incarnationId != bound.incarnationId ||
            ref.sessionEpoch != session.sessionEpoch ||
            ref.conversationId != conversationId
        ) return
        when (outcome) {
            TemporaryKeepOutcomeUi.Promoted -> {
                val state = snapshot.value
                if (state != null && state.promotedConversationId == conversationId && !state.isTemporary) {
                    temporaryKeepState = TemporaryKeepStateUi.Idle
                    temporaryDraftHandoffPending = false
                    temporaryKeepBound = null
                }
                // Otherwise wait: the projection owns the durable truth.
            }
            TemporaryKeepOutcomeUi.TailPending -> {
                val state = snapshot.value ?: return
                if (state.isTemporary && state.temporaryIncarnationId == bound.incarnationId) {
                    temporaryKeepState = TemporaryKeepStateUi.PartialRetry
                }
            }
            is TemporaryKeepOutcomeUi.Failed -> {
                val state = snapshot.value ?: return
                if (state.isTemporary && state.temporaryIncarnationId == bound.incarnationId) {
                    temporaryKeepState = TemporaryKeepStateUi.Failed(outcome.message)
                    actionError = outcome.message
                }
            }
        }
    }

    /** ⇄ endTemporaryChat: destroy binds to the exact incarnation shown. */
    fun endTemporaryChat(): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        val incarnation = state.temporaryIncarnationId
            ?: return rejected(ConversationRejectedReason.STALE)
        if (!state.isTemporary) return rejected(ConversationRejectedReason.STALE)
        temporaryEndBound = TemporarySessionRef(
            conversationId,
            session.sessionEpoch,
            incarnation,
            nativeRootEpoch = temporaryNativeRootEpoch,
        )
        val started = host.endTemporaryChat(temporaryEndBound!!)
        if (!started) temporaryEndBound = null
        return if (started) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    private var temporaryEndBound: TemporarySessionRef? = null

    /**
     * ⇄ TemporaryNavigation echo with the EXPLICIT-SOURCE-TOKEN contract:
     *  1. a holder retired by genuine navigation never emits anything
     *     ([retired] is checked FIRST — not just epoch equality inside the
     *     stale object);
     *  2. the echo's incarnation/conversation/session must match the exact
     *     bound End request; Unavailable mutates nothing;
     *  3. navigation is requested with [session] as the SOURCE identity: the
     *     host revalidates that this session is still the authoritative
     *     current route before obeying and returns whether it actually
     *     navigated. Only on true does this holder reset the Keep/handoff
     *     surfaces — a rejected (host-revalidated) navigation leaves this
     *     view's state untouched rather than pretending to have moved.
     */
    fun applyTemporaryEndOutcome(ref: TemporarySessionRef, target: TemporaryEndTargetUi) {
        if (retired) return
        val bound = temporaryEndBound ?: return
        if (ref.incarnationId != bound.incarnationId ||
            ref.conversationId != conversationId ||
            ref.sessionEpoch != session.sessionEpoch
        ) return
        when (target) {
            TemporaryEndTargetUi.Unavailable -> return // stale echo: touch nothing
            is TemporaryEndTargetUi.OpenConversation -> {
                if (host.requestOpenConversation(session, target.conversationId)) {
                    temporaryEndBound = null
                    temporaryKeepState = TemporaryKeepStateUi.Idle
                    temporaryDraftHandoffPending = false
                }
            }
            TemporaryEndTargetUi.OpenNewTask -> {
                if (host.requestNewTask(session)) {
                    temporaryEndBound = null
                    temporaryKeepState = TemporaryKeepStateUi.Idle
                    temporaryDraftHandoffPending = false
                }
            }
        }
    }

    /** ⇄ toggleTemporaryChat(.restoredOrdinary): a toggle-off handed the RAM
     * draft back unedited — visible, but not durable until re-edited. */
    fun noteTemporaryDraftHandoff(draftWasNonEmpty: Boolean) {
        if (retired) return
        temporaryDraftHandoffPending = draftWasNonEmpty
    }

    fun openTemporaryAbout() { if (retired) return; showsTemporaryAbout = true }
    fun dismissTemporaryAbout() { showsTemporaryAbout = false }

    /* ------------------------------- misc surfaces ------------------------------- */

    /** ⇄ requestManualCompaction (single in-flight latch). The thread's
     * ACTUAL selected usable model is passed when one exists; otherwise the
     * key stays absent and the native persisted default applies (never a
     * first-usable substitution chosen by the App). */
    fun requestManualCompaction(): ConversationFlowResult {
        if (isCompacting) return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        val state = snapshot.value
        val selected = state?.models?.firstOrNull {
            it.modelId == selectedModelId.value && it.isUsable
        }?.modelId
        return if (host.requestManualCompaction(session, selected)) {
            isCompacting = true
            ConversationFlowResult.Accepted
        } else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Host echo: the compaction attempt finished (status line is projected
     * separately; this only releases the manual spinner). */
    fun applyCompactionSettled() {
        if (retired) return
        isCompacting = false
    }

    fun toggleChecklist() { if (retired) return; checklistExpanded = !checklistExpanded }

    fun exportStructured(): ConversationFlowResult {
        if (exportInFlight) return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        return if (host.exportStructuredConversation(session)) {
            exportInFlight = true
            ConversationFlowResult.Accepted
        } else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Host echo for the bounded export job (success opens the share surface
     * host-side; failure text is localized by the host). */
    fun applyExportSettled(message: String?) {
        if (retired) return
        exportInFlight = false
        if (message != null) actionError = message
    }

    fun shareText(asMarkdown: Boolean): ConversationFlowResult =
        if (host.shareConversationText(session, asMarkdown)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    fun refreshMediaJobs(): ConversationFlowResult {
        if (mediaRefreshInFlight) return rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        return if (host.refreshMediaJobs(session)) {
            mediaRefreshInFlight = true
            ConversationFlowResult.Accepted
        } else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** Host echo: the explicit media reconcile pass finished (optionally with
     * the first user-presentable error). */
    fun applyMediaRefreshSettled(message: String?) {
        if (retired) return
        mediaRefreshInFlight = false
        if (message != null) actionError = message
    }

    fun openPermissions() { host.openTaskPermissions(session) }

    fun loadEarlierMessages(): ConversationFlowResult =
        if (host.loadEarlierMessages(session)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /** ⇄ loadEarlierEvents(runID:) with the honest loaded-sequence cursor. */
    fun loadEarlierEvents(row: TimelineRowUi.EarlierEvents): ConversationFlowResult {
        val runUuid = parseHostUuid(row.runId) ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val sequence = row.firstLoadedSequence ?: return rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        return if (host.loadEarlierEvents(session, EventCursor(runUuid, sequence.toLong()))) {
            ConversationFlowResult.Accepted
        } else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun openChildRun(childRunId: String): ConversationFlowResult {
        if (retired) return rejected(ConversationRejectedReason.NO_SESSION)
        openChildRunId.value = childRunId
        return if (host.loadChildRunDetail(session, childRunId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** ⇄ openChild(nil): the child is unknown, fall back to the host's
     * child-agents inspector list (same durable store, one source). */
    fun requestChildAgentsList() {
        host.showInspector(InspectorRouteUi.CHILD_AGENTS, conversationId)
    }

    /** Presentation routing intents (host owns the actual chrome). */
    fun requestInspector(content: InspectorRouteUi) {
        host.showInspector(content, conversationId)
    }

    fun requestWorkspaceFilesInspector() {
        host.showInspector(InspectorRouteUi.WORKSPACE_FILES, conversationId)
    }

    /** ⇄ selectedImportantFile sheet: route the preview to the host's
     * guarded workspace file service (no path is opened from here). ONE
     * effect per tap carrying the ACTUAL projected path under the current
     * session — no dummy message/attachment identities exist here. */
    fun openImportantFile(file: ImportantFileUi): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (state.importantFiles.none { it.path == file.path }) return ConversationFlowResult.Stale
        return if (host.openWorkspaceFile(session, file.path)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun closeChildRun() { openChildRunId.value = null }

    fun toggleGroup(groupId: String) {
        val current = expandedGroups.value
        expandedGroups.value = if (groupId in current) current - groupId else current + groupId
    }

    fun isGroupExpanded(groupId: String): Boolean = groupId in expandedGroups.value

    fun toggleToolCard(eventId: String) {
        val current = expandedToolCards.value
        expandedToolCards.value = if (eventId in current) current - eventId else current + eventId
    }

    /** The tool card auto-reveals honest failures (⇄ onChange(of: status));
     * reading the state marks the auto-expand exactly once per card. */
    fun toolCardExpanded(event: RunEventUi): Boolean {
        val status = event.tool?.statusRaw ?: return event.id in expandedToolCards.value
        if (FloeToolStatusPresentation.shouldAutoExpand(status) && event.id !in expandedToolCards.value) {
            expandedToolCards.value = expandedToolCards.value + event.id
        }
        return event.id in expandedToolCards.value
    }

    fun dismissActionError() { actionError = null }
    fun dismissAttachmentError() { attachmentError = null }

    fun noteQueueRefreshFailure(failureToken: String) {
        if (retired || failureToken.isBlank()) return
        queueRefreshFailureToken = failureToken
    }

    fun clearQueueRefreshFailure(expectedFailureToken: String): Boolean {
        if (retired || queueRefreshFailureToken != expectedFailureToken) return false
        queueRefreshFailureToken = null
        return true
    }

    /** Refreshing projection reads never resumes or re-executes a run.
     * Dispatch alone is not recovery: keep the failure until the host
     * confirms an authoritative read for the same exact token. */
    fun retryQueueRefresh(): Boolean {
        if (retired) return false
        val token = queueRefreshFailureToken ?: return false
        return host.refreshQueuedInputProjection(session, token)
    }

    /** The host surfaces a typed queue-mutation refusal on the thread error
     * banner. The pending-input editor sheet closes optimistically when the
     * dispatch is queued, so an honest refusal (stale CAS, row changed,
     * native rejection) must stay visible after the sheet is gone; the
     * durable row keeps its original body on every refusal. */
    fun noteHostActionError(message: String) {
        if (retired) return
        actionError = message
    }

    /* --------------------------------- scrolling --------------------------------- */

    /** Feed observed scroll geometry (⇄ onScrollGeometryChange). */
    fun observeScroll(offset: Double, bottomDistance: Double, userScrolling: Boolean) {
        followState.observe(offset, bottomDistance, userScrolling)
        showsReturnToLatest = followState.isAwayFromLatest && !followState.followsLatest
    }

    fun returnToLatest() {
        followState.returnToLatest()
        showsReturnToLatest = false
    }

    /** ⇄ capture-snapshot-before-present (dismiss never collapses mid-flight). */
    fun openUsageDetails(usage: UsageUi) { presentedUsage = usage }

    /** Availability loss clears the presented state so a later run's usage
     * cannot resurrect it. */
    fun usagePresented(): Boolean = presentedUsage != null

    fun closeUsageDetails() { presentedUsage = null }

    /* ------------------------------ content actions ------------------------------ */

    fun copyMessage(text: String): ConversationFlowResult =
        if (host.copyMessageText(session, text)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /* ------------------------- markdown projection states ------------------------- */

    /**
     * Bounded async coordinator for the [MarkdownContentUi] contract (see
     * ConversationMarkdownUi.kt header for the qualification gate). The
     * Compose edge only reads [markdownState]; [ensureMarkdownParse] is
     * called from post-composition effects; the host runs the parse OFF the
     * UI thread and echoes generation-fenced results via
     * [applyMarkdownParseResult]. Results are immutable, LRU-bounded, and
     * fully invalidated on rebind — a late parse can never style a replaced
     * session, and nothing grows unbounded during a long stream.
     */
    private val markdownCoordinator = MarkdownParseCoordinator()

    /** Observable revision: bumped by EVERY coordinator mutation (schedule,
     * echo, invalidation). [markdownState] reads it first so composition
     * subscribes — without this, a Parsed result arriving after the last
     * stream tick (a static final message) would leave the surface on
     * Preparing forever, because the coordinator's map itself is plain
     * state. Found by the API37 component fixture, fixed at the holder. */
    private val markdownRevision = mutableStateOf(0L)

    fun markdownState(source: String): MarkdownContentUi {
        markdownRevision.value // subscription edge
        return markdownCoordinator.state(source)
    }

    fun ensureMarkdownParse(source: String) {
        if (retired) return
        markdownCoordinator.ensureRequested(source) { generation ->
            val scheduled = host.requestMarkdownParse(session, source, generation)
            if (!scheduled) MarkdownScheduleResult.BACKEND_UNAVAILABLE else MarkdownScheduleResult.SCHEDULED
        }
        markdownRevision.value += 1L
    }

    /** Host echo of one off-UI-thread parse. Foreign epochs are dropped; the
     * coordinator then fences the generation, so a superseded fragment can
     * never style the current stream tail. */
    fun applyMarkdownParseResult(
        echoSession: ConversationSessionToken,
        source: String,
        generation: Long,
        blocks: List<MarkdownBlockUi>?,
    ) {
        if (!echoAccepted(echoSession)) return
        markdownCoordinator.applyResult(source, generation, blocks)
        markdownRevision.value += 1L
    }

    /** Test/diagnostic hook: bounded cache size (never a public surface). */
    internal fun markdownCacheSize(): Int = markdownCoordinator.cachedCount()

    /** Test/diagnostic hook: bounded shared editor history sizes (never a
     * public product surface). */
    internal fun editorHistorySize(): Int = editorUndoHistory.size

    internal fun editorRedoSize(): Int = editorRedoHistory.size

    /** Link taps and artifact previews are approved host effects only. */
    fun openMessageLink(urlString: String): ConversationFlowResult =
        if (host.openMessageLink(session, urlString)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    fun openRichArtifactPreview(artifactId: String): ConversationFlowResult =
        if (host.openRichArtifactPreview(session, artifactId)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /** Read-aloud is offered only when the host projects voice as usable; a
     * false host state never claims the affordance works. */
    fun speakMessage(text: String): ConversationFlowResult {
        val state = snapshot.value ?: return rejected(ConversationRejectedReason.NO_SESSION)
        if (!state.voiceAvailable) return rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        return if (host.speakMessageText(session, text)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    fun stopSpeaking() { host.stopSpeaking(session) }

    fun saveMessageToNotes(text: String): ConversationFlowResult =
        if (host.saveMessageToNotes(session, text)) ConversationFlowResult.Accepted
        else rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    companion object {
        /** ⇄ ApprovalCardView deny(reason: "user denied") stable vocabulary. */
        const val DENY_REASON = "user denied"

        /** ⇄ UndoManager's bounded grouping: the shared editor history keeps
         * at most this many keystroke snapshots per holder (RAM-only). */
        const val MAX_EDITOR_HISTORY = 64
    }
}

/* ------------------------- temporary state vocabularies ------------------------- */

/** ⇄ ThreadDetailViewModel.TemporaryKeepState. */
sealed interface TemporaryKeepStateUi {
    data object Idle : TemporaryKeepStateUi
    data object Saving : TemporaryKeepStateUi
    /** Durable save committed; the stream tail is still forwarding: a retry
     * completes the remainder (never a false "nothing saved"). */
    data object PartialRetry : TemporaryKeepStateUi
    data class Failed(val message: String) : TemporaryKeepStateUi
}

/** ⇄ the keepTemporaryChat outcome taxonomy (tailPending vs other). */
sealed interface TemporaryKeepOutcomeUi {
    data object Promoted : TemporaryKeepOutcomeUi
    data object TailPending : TemporaryKeepOutcomeUi
    data class Failed(val message: String) : TemporaryKeepOutcomeUi
}

/** ⇄ ThreadDetailViewModel.TemporaryNavigation targets (host routes). */
sealed interface TemporaryEndTargetUi {
    data class OpenConversation(val conversationId: String) : TemporaryEndTargetUi
    data object OpenNewTask : TemporaryEndTargetUi
    /** The ended identity is no longer the active session: a stale callback
     * must not mutate this view or navigate anywhere. */
    data object Unavailable : TemporaryEndTargetUi
}
