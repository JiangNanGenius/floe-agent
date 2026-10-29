// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ApprovalCardUi
import com.floe.android.feature.conversation.ApprovalModeUi
import com.floe.android.feature.conversation.ApprovalTargetUi
import com.floe.android.feature.conversation.AttachmentChipUi
import com.floe.android.feature.conversation.AttachmentKindUi
import com.floe.android.feature.conversation.CapabilityChipUi
import com.floe.android.feature.conversation.RunOutputCardUi
import com.floe.android.feature.conversation.ChecklistDetailUi
import com.floe.android.feature.conversation.ChecklistStepStatusUi
import com.floe.android.feature.conversation.ChecklistStepUi
import com.floe.android.feature.conversation.ChecklistUi
import com.floe.android.feature.conversation.ChildRunDetailUi
import com.floe.android.feature.conversation.ChildRunUi
import com.floe.android.feature.conversation.ConversationListItemUi
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.contracts.EventCursor
import com.floe.android.feature.conversation.GoalUi
import com.floe.android.feature.conversation.GoalCriterionRowUi
import com.floe.android.feature.conversation.GoalDetailUi
import com.floe.android.feature.conversation.GoalEvidenceRowUi
import com.floe.android.feature.conversation.GoalStepRowUi
import com.floe.android.feature.conversation.ImportantFileUi
import com.floe.android.feature.conversation.MessagePageCursorUi
import com.floe.android.feature.conversation.MessageRoleUi
import com.floe.android.feature.conversation.MessageUi
import com.floe.android.feature.conversation.ModelOptionUi
import com.floe.android.feature.conversation.PendingInputStatusUi
import com.floe.android.feature.conversation.PendingInputUi
import com.floe.android.feature.conversation.PlanRecommendationUi
import com.floe.android.feature.conversation.PlanUi
import com.floe.android.feature.conversation.PlanAssumptionRowUi
import com.floe.android.feature.conversation.PlanCriterionRowUi
import com.floe.android.feature.conversation.PlanDetailUi
import com.floe.android.feature.conversation.PlanRiskRowUi
import com.floe.android.feature.conversation.PlanSectionRowUi
import com.floe.android.feature.conversation.PendingInputBodyStateUi
import com.floe.android.feature.conversation.PendingInputBodyUi
import com.floe.android.feature.conversation.ProjectOptionUi
import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.RunEventKindUi
import com.floe.android.feature.conversation.RunEventUi
import com.floe.android.feature.conversation.ToolEventProjectionUi
import com.floe.android.feature.conversation.ToolArtifactUi
import com.floe.android.feature.conversation.RunLaunchRequest
import com.floe.android.feature.conversation.RunRowUi
import com.floe.android.feature.conversation.RunningInputModeUi
import com.floe.android.feature.conversation.RunningInputRequest
import com.floe.android.feature.conversation.StagedAttachmentUi
import com.floe.android.feature.conversation.ThreadUiState
import com.floe.android.feature.conversation.TimelineRowUi
import com.floe.android.feature.conversation.UsageUi
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Incremental, host-owned [ThreadUiState] projection builder. One builder
 * exists per conversation surface; it accumulates the durable session reply,
 * message pages, run events, attachments and child details, and emits
 * complete immutable snapshots through [ConversationFlowHolder.applyHostSnapshot].
 * The builder never invents identities: everything traces to a decoded wire
 * page or typed effect.
 */
class ThreadProjectionBuilder internal constructor(
    private val conversationId: String,
) {
    var session: ConversationSessionToken = ConversationSessionToken(conversationId, 0L)
    var taskTitle: String = ""
    var isTemporary: Boolean = false
    var temporaryIncarnationId: String? = null
    /**
     * The REAL durable identity an atomic Keep committed for THIS exact
     * conversation (the `temp.keep` receipt's `conversationID`, adopted
     * only from a committed/alreadyCommitted value carrier). Null until a
     * committed Keep is projected: the holder's promoted guard is fenced
     * on `promotedConversationId == conversationId && !isTemporary`, so a
     * bare success string can never acknowledge promotion.
     */
    var promotedConversationId: String? = null
    var conversationRevision: Revision? = null
    var earlierCursor: MessagePageCursorUi? = null
    var hasEarlierMessages: Boolean = false
    var selectedRunId: String? = null
    val childDetails = mutableMapOf<String, ChildRunDetailUi>()

    private var missing: Boolean = false
    private var hasLoaded: Boolean = false
    private val userMessages = LinkedHashMap<String, MessageUi>()
    private val assistantMessages = LinkedHashMap<String, MessageUi>()
    private val runEvents = LinkedHashMap<String, MutableList<RunEventUi>>()
    private val runRows = LinkedHashMap<String, RunRowUi>()
    private val staged = LinkedHashMap<String, StagedAttachmentUi>()
    private val pendingApprovalsByRun = LinkedHashMap<String, MutableList<ApprovalCardUi>>()
    private val pendingInputs = LinkedHashMap<String, PendingInputUi>()
    private var liveAssistant: String = ""
    private var liveReasoning: String = ""
    /**
     * Authoritative CURRENT streamed text from the last applied
     * `run.snapshot` (`answerText`/`reasoningText`). The native snapshot
     * carries the run service's own in-progress accumulation for the current
     * assistant step; durable `assistantText`/`reasoning` rows flush only at
     * segment boundaries. The overlay REPLACES (never appends to) the already
     * durable prefix of that same step — see [composeLiveTail] — so live
     * content becomes visible without double counting durable segments.
     * `null` means "no authoritative live text known" (cold/no live owner,
     * dropped-by-budget or a failed refresh): the durable tail stays as-is.
     */
    private var snapshotAnswerOverlay: String? = null
    private var snapshotReasoningOverlay: String? = null
    /**
     * Durable flush segments of the CURRENT live tail, in arrival order. They
     * are exact prefixes of the native in-progress text while a step streams,
     * so the authoritative overlay can replace exactly the already-durable
     * prefix of the step. Bounded: oldest segments are dropped first and the
     * overlay then only replaces what the retained window proves.
     */
    private val liveAssistantSegments = ArrayDeque<String>()
    private val liveReasoningSegments = ArrayDeque<String>()
    private var liveSegmentChars: Int = 0
    /** Run that owns the live tail buffers currently displayed. */
    private var liveTailRunId: String? = null
    /** Run whose live tail reached its durable close boundary (never revived). */
    private var liveTailClosedFor: String? = null
    private var actionError: String? = null
    /**
     * D04 owned run-output cards per run, fed ONLY by the native owned
     * reader (the run's own durable toolResult records + verified
     * availability). Nothing here is inferred from model markdown, raw
     * paths or arbitrary artifact metadata. [runOutputActionStates] is a
     * RAM-only transient overlay (saving/saved/failed/cancelled) merged
     * into the cards on projection; it is never persisted and never
     * survives as a claim on reload.
     */
    private val runOutputsByRun = LinkedHashMap<String, MutableList<RunOutputCardUi>>()
    private val runOutputScanTruncatedByRun = LinkedHashMap<String, Boolean>()
    private val runOutputActionStates = LinkedHashMap<String, String>()
    private var policyApprovalMode: ApprovalModeUi = ApprovalModeUi.ASK
    /**
     * The REAL durable task-policy CAS pair (`taskPolicy.<uuid>` /
     * `updatedAt`), read ONLY from actual wire pages: the `conversation.get`
     * taskPolicy projection or the authoritative `run.snapshot`
     * `policyRevision`. Null means "no proven revision" — a policy update
     * then refuses instead of sending a fabricated version.
     */
    private var policyRevisionValue: Revision? = null
    /** Native raw vocabulary of the persisted row (never guessed). */
    private var policyRecoveryRaw: String? = null
    private var policyNotificationRaw: String? = null
    private var snapshotCounter = 0L

    /**
     * Host-projected composer model options. The host owns the REAL
     * provider/model join (enabled provider + configured secret + enabled
     * model row); the builder never infers usability from row presence.
     */
    var models: List<ModelOptionUi> = emptyList()
        private set

    /**
     * Honest "configure a provider/model" state. True only when the host
     * projection has no usable model; never a hard-coded false.
     */
    var needsProvider: Boolean = false
        private set

    /** Per-run CAS revision (`run.<UPPER uuid>` / native durable state). */
    private val runRevisions = LinkedHashMap<String, Revision>()

    /** Per-approval CAS revision version (`requestedAt` wire date). */
    private val approvalVersions = LinkedHashMap<String, String>()

    /**
     * Per-run ABA fence for the transient approval projection: the newest
     * run sequence at which approval state for this run was observed from
     * an authoritative carrier (a `run.snapshot` page or a durable approval
     * record). A page older than this fence is a late pre-decision read:
     * its approval member — present or absent — must neither clear a newer
     * request nor resurrect a retired card. The value is the run's own
     * append-only sequence (`SnapshotPage.durableWatermark` / the durable
     * record's `sequence`); no wall clock and no invented state.
     */
    private val approvalFenceByRun = LinkedHashMap<String, Long>()
    private val approvalAbsenceFenceByRun = LinkedHashMap<String, Long>()
    private val approvalVersionByRunCall = LinkedHashMap<String, String>()
    private val retiredApprovalVersions = LinkedHashSet<String>()
    private fun approvalKey(runID: String, callID: String) = "$runID/$callID"

    private fun pruneApprovalFences() {
        while (retiredApprovalVersions.size > 4096) {
            retiredApprovalVersions.remove(retiredApprovalVersions.first())
        }
        while (approvalFenceByRun.size > 512) {
            val old = approvalFenceByRun.keys.firstOrNull {
                it != selectedRunId && pendingApprovalsByRun[it].isNullOrEmpty()
            } ?: break
            approvalFenceByRun.remove(old)
            approvalAbsenceFenceByRun.remove(old)
            approvalVersionByRunCall.keys.removeAll { it.startsWith("$old/") }
            retiredApprovalVersions.removeAll { it.startsWith("$old/") }
        }
    }

    private fun approvalFence(runID: String): Long = approvalFenceByRun[runID] ?: 0L

    private fun advanceApprovalFence(runID: String, observed: Long) {
        if (observed > approvalFence(runID)) approvalFenceByRun[runID] = observed
        pruneApprovalFences()
    }

    /**
     * Retires every projected pending-approval card of ONE run because a
     * fresh authoritative carrier proved the run has none. Display-only:
     * this never claims allow/deny, execution or success — the grant
     * authority stays with the native runtime. Other runs' cards and CAS
     * versions are untouched; a version entry drops only when no other run
     * still projects a card with the same call id.
     */
    private fun retirePendingApprovals(runID: String, watermark: Long) {
        approvalAbsenceFenceByRun[runID] = maxOf(
            approvalAbsenceFenceByRun[runID] ?: -1L, watermark)
        val cards = pendingApprovalsByRun.remove(runID).orEmpty()
        for (card in cards) {
            val key = approvalKey(runID, card.approvalId)
            approvalVersionByRunCall.remove(key)?.let { retiredApprovalVersions.add("$key/$it") }
            val stillProjectedElsewhere = pendingApprovalsByRun.values.any { list ->
                list.any { it.approvalId == card.approvalId }
            }
            if (!stillProjectedElsewhere) approvalVersions.remove(card.approvalId)
        }
    }

    /** Pending-input row CAS versions (`pendingInput.<uuid>` / updatedAt). */
    private val inputVersions = LinkedHashMap<String, String>()

    /**
     * Editor hydration state for one durable queue row, published ONLY by
     * the bounded `conversation.get.detail{kind:"pendingInput"}` chain on a
     * digest-verified complete assembly (Loading → Ready(text, native CAS
     * version) | Failed(code)). The full editable body NEVER exists before
     * Ready; a preview is display content, not editor content.
     */
    private val pendingInputBodies = LinkedHashMap<String, PendingInputBodyUi>()

    /**
     * Rows ABSENT from the most recent authoritative COMPLETE queue page.
     * A row is retired only after TWO consecutive complete pages proved its
     * absence: one late pre-change complete page (read before a newer row
     * was durable, settled after a newer page showed it) can mark it a
     * candidate but never deletes it, while the steady state (consumed /
     * cancelled rows leaving the native pending predicate) retires within
     * one extra refresh. Truncated pages never touch this set.
     */
    private val queueAbsentCandidates = LinkedHashSet<String>()

    /** One projected queue row, by durable id (editor-open validation). */
    fun pendingInputRow(inputID: String): PendingInputUi? = pendingInputs[inputID]

    /** The current editor hydration state for one queue row. */
    fun pendingInputBody(inputID: String): PendingInputBodyUi? = pendingInputBodies[inputID]

    /** Publish/clear one editor hydration state (bounded; stale rows drop). */
    internal fun setPendingInputBody(inputID: String, state: PendingInputBodyUi?) {
        if (state == null) {
            pendingInputBodies.remove(inputID)
            return
        }
        pendingInputBodies[inputID] = state
        while (pendingInputBodies.size > 32) {
            val drop = pendingInputBodies.keys.firstOrNull { it !in pendingInputs }
                ?: pendingInputBodies.keys.firstOrNull()
                ?: break
            pendingInputBodies.remove(drop)
        }
    }

    /**
     * Publishes ONE proven-complete durable body: the row's display slot
     * becomes the exact full text (never blank, never preview) and the
     * editor binding carries the native CAS version the read proved. A row
     * the projection has already retired (or whose projected version moved
     * past this read) is refused — the caller re-reads instead.
     */
    internal fun applyPendingInputBody(inputID: String, text: String, inputVersion: String): Boolean {
        val row = pendingInputs[inputID] ?: return false
        val version = inputVersions[inputID]
        if (version != null && version != inputVersion) return false
        pendingInputs[inputID] = row.copy(
            content = text,
            bodyState = PendingInputBodyStateUi.COMPLETE,
            inputVersion = inputVersion,
        )
        pendingInputBodies[inputID] = PendingInputBodyUi.Ready(text, inputVersion)
        return true
    }

    /**
     * The CAS version at which this row CURRENTLY has a proven complete
     * body, or null when no editable full text exists. `run.input.edit`
     * dispatch re-proves this against a FRESH snapshot before any envelope
     * leaves the App (an unread original is never overwritten by blank or
     * by a bounded preview).
     */
    internal fun provenBodyVersion(inputID: String): String? {
        val version = inputVersions[inputID]
        when (val body = pendingInputBodies[inputID]) {
            is PendingInputBodyUi.Ready ->
                if (version == null || version == body.inputVersion) return body.inputVersion
            is PendingInputBodyUi.Loading, is PendingInputBodyUi.Failed, null -> Unit
        }
        val row = pendingInputs[inputID]
            ?: return null
        return if (row.bodyState == PendingInputBodyStateUi.COMPLETE &&
            row.inputVersion != null &&
            (version == null || version == row.inputVersion)
        ) row.inputVersion else null
    }

    /**
     * Applies the retirement rule described on [queueAbsentCandidates].
     * `complete` is the native PROVEN completeness of this page's queue
     * window (`pendingInputsTruncated == false`); a trimmed/legacy page is
     * never retirement authority and keeps every unknown row.
     */
    private fun reconcileQueueAbsentRows(presentIDs: Set<String>, complete: Boolean) {
        if (!complete) return
        val absent = pendingInputs.keys.filterTo(LinkedHashSet()) { it !in presentIDs }
        val retire = absent.intersect(queueAbsentCandidates)
        queueAbsentCandidates.clear()
        queueAbsentCandidates.addAll(absent)
        if (retire.isEmpty()) return
        for (id in retire) {
            pendingInputs.remove(id)
            inputVersions.remove(id)
            pendingInputBodies.remove(id)
            queueAbsentCandidates.remove(id)
        }
    }

    /**
     * Merge one `conversation.get` page row into a known projection. That
     * lane carries NO body and NO CAS version, so an already proven body
     * (hydrated full text or native-complete content) and the tracked
     * version stay exactly as they are; only metadata refreshes.
     */
    private fun PendingInputUi.mergeSessionPage(incoming: PendingInputUi): PendingInputUi =
        copy(
            status = incoming.status,
            mode = incoming.mode,
            executionModeRaw = incoming.executionModeRaw,
            position = incoming.position,
            contentBytes = incoming.contentBytes ?: contentBytes,
            trustedSummary = incoming.trustedSummary ?: trustedSummary,
        )

    /**
     * Merge one `run.snapshot` wire row (typed `PendingInputWire`) into the
     * projection. Body precedence: a proven COMPLETE slot is NEVER replaced
     * by a bounded preview; the native `previewComplete` proof may promote
     * the slot to COMPLETE (short bodies travel whole); otherwise the fresh
     * preview replaces an unproven slot, and a same-version PREVIEW is kept
     * when this page carries no preview member. A version move resets the
     * slot to THIS page's truth (the old text described the previous row).
     */
    private fun PendingInputUi?.mergeSnapshotWire(
        input: ConversationWire.PendingInputWire,
        versionMoved: Boolean,
    ): PendingInputUi {
        val known = this
        val knownComplete = known != null && !versionMoved &&
            known.bodyState == PendingInputBodyStateUi.COMPLETE
        val incomingComplete = input.preview != null && input.previewComplete == true
        val (text, state) = when {
            knownComplete -> known!!.content to PendingInputBodyStateUi.COMPLETE
            incomingComplete -> input.preview!! to PendingInputBodyStateUi.COMPLETE
            input.preview != null -> input.preview to PendingInputBodyStateUi.PREVIEW
            known != null && !versionMoved &&
                known.bodyState == PendingInputBodyStateUi.PREVIEW ->
                known.content to PendingInputBodyStateUi.PREVIEW
            else -> "" to PendingInputBodyStateUi.NOT_READ
        }
        return PendingInputUi(
            id = input.id,
            content = text,
            status = input.status,
            mode = input.mode,
            executionModeRaw = input.executionModeRaw
                ?: known?.takeIf { !versionMoved }?.executionModeRaw
                ?: "agent",
            position = input.position,
            contentBytes = input.contentBytes
                ?: known?.takeIf { !versionMoved }?.contentBytes,
            bodyState = state,
            inputVersion = input.inputVersion,
            trustedSummary = if (versionMoved) null else known?.trustedSummary,
        )
    }

    /** Durable queue order revision (`pendingQueue.<uuid>` / queue digest). */
    var queueRevision: Revision? = null
        private set

    /** Durable child graph rows (real `child.list` page). */
    private var childRuns: List<ChildRunUi> = emptyList()

    /**
     * Additive `conversation.get` plan/goal projections (approved
     * goal-core-code-batch-20261021 read map). Decoded ONLY from real page
     * members: an absent member stays null (never a RAM reconstruction);
     * a TRIMMED page is honestly labelled by the availability members
     * below. Full criterion/step/evidence content travels the separate
     * bounded `conversation.get.detail` byte-exact read — never inferred
     * from these counts.
     */
    var plan: PlanUi? = null
        private set
    var goal: GoalUi? = null
        private set

    /** ROUNDS 2/3 `projected|trimmed|absent` availability (verbatim; null
     * = a legacy reply). Trimming is never conflated with absence. */
    var planAvailabilityRaw: String? = null
        private set
    var goalAvailabilityRaw: String? = null
        private set

    /**
     * Additive `conversation.get.workspace` projection (workspace-core
     * batch 2026-10-23): the REAL durable ownership binding of THIS thread,
     * decoded only from the native page member. An absent/null member is an
     * honest unbound (a temporary session never carries one, and a header
     * before its first durable launch has no ownership row) — never a
     * first-workspace guess or a RAM reconstruction.
     */
    internal var workspace: ConversationWire.WorkspaceBindingUi? = null
        private set

    /** Per-run post-run review/continuation registry activity ("none"/
     * "active"/"stopping") read ONLY from an actual `run.snapshot` page.
     * A run the pages never mention has NO entry — never assumed. */
    private val goalReviewByRunValue = LinkedHashMap<String, String>()

    /** Host-composed localized manual-compaction status line (real reply
     * members only; cleared by a newer durable refresh). */
    var compactionStatus: String? = null
        private set

    /** Apply one settled `conversation.compact` reply (typed page members). */
    fun applyCompactionStatus(line: String?) {
        compactionStatus = line
    }

    fun runIds(): Set<String> = runRows.keys.toSet()

    /** Apply the host's real model projection (see [models] above). */
    internal fun applyModels(options: List<ModelOptionUi>, needsProvider: Boolean) {
        models = options
        this.needsProvider = needsProvider
    }

    /** The tracked durable state name of a run (native vocabulary). */
    internal fun runStateName(runID: String): String? = runRows[runID]?.stateName

    /** The tracked CAS revision of a run, when a real producer supplied it. */
    internal fun runRevision(runID: String): Revision? = runRevisions[runID]

    /** The tracked `requestedAt` approval version for one live call. */
    internal fun approvalVersion(callID: String): String? = approvalVersions[callID]

    /** The tracked `inputVersion` of one durable pending-input row. */
    internal fun inputVersion(inputID: String): String? = inputVersions[inputID]

    internal fun applySession(reply: ConversationWire.SessionReply) {
        hasLoaded = true
        taskTitle = reply.title
        conversationRevision = reply.revision
        // The native snapshot orders runs NEWEST-FIRST (`started_at DESC, id`,
        // RuntimeFacadeConversations), so the FIRST row is the most recent
        // run. A fresh builder must select that newest run — the live or
        // retryable tail the user actually continues — never the oldest row
        // (the previous `lastOrNull()` pinned the OLDEST run, so a cold reopen
        // after a checkpoint rendered the stale round with no Continue). A
        // refresh keeps the current selection while that run still exists in
        // the page: no jump on reload, no clobber of an explicit selection,
        // and a run selected by applyPrepared survives while present.
        if (selectedRunId == null || reply.runs.none { it.runID == selectedRunId }) {
            selectedRunId = reply.runs.firstOrNull()?.runID ?: selectedRunId
        }
        for (run in reply.runs) {
            runRows[run.runID] = RunRowUi(
                id = run.runID,
                stateName = run.state,
                modelId = run.modelName,
                startedAtLabel = run.startedAt,
            )
            if (run.state.isNotBlank() && run.state != "unknown") {
                runRevisions[run.runID] =
                    Revision(ConversationWire.runResourceID(run.runID), run.state)
            }
        }
        for (input in reply.pendingInputs) {
            val known = pendingInputs[input.id]
            pendingInputs[input.id] = if (known == null) input else known.mergeSessionPage(input)
        }
        // Authoritative queue reconciliation (G04R2 repair): only a page
        // whose native builder PROVED completeness (`pendingInputsTruncated
        // == false`) may retire absent rows. A trimmed page, or a legacy
        // page without the member, keeps every known row — an unknown row
        // is never a gone row. See [reconcileQueueAbsentRows].
        reconcileQueueAbsentRows(
            presentIDs = reply.pendingInputs.map { it.id }.toSet(),
            complete = reply.pendingInputsTruncated == false,
        )
        reply.approvalMode?.let { policyApprovalMode = it }
        reply.policyRecoveryRaw?.let { policyRecoveryRaw = it }
        reply.policyNotificationRaw?.let { policyNotificationRaw = it }
        // The session reply proves a durable taskPolicy row exists when it
        // carries the row's `updatedAt`; adopt that exact CAS identity. A
        // reply without the member leaves the previous (possibly snapshot-
        // derived) revision untouched — never a synthesized one.
        if (reply.policyRevision != null) policyRevisionValue = reply.policyRevision
        // Plan/goal summaries: the CURRENT page is the whole truth for the
        // projection — an absent member is an absent surface (a trimmed page
        // under native page pressure reads the same way; the accept/confirm
        // producers then refuse rather than bind stale identities, and the
        // bounded conversation.get.detail read is the recovery path for a
        // TRIMMED page — the availability members record which it is).
        plan = reply.plan
        goal = reply.goal
        planAvailabilityRaw = reply.planAvailabilityRaw
        goalAvailabilityRaw = reply.goalAvailabilityRaw
        // The CURRENT page is the whole truth (same rule as plan/goal): an
        // absent member clears the binding — a moved/deleted ownership row is
        // never shadow-projected from an older page.
        workspace = reply.workspace
    }

    /**
     * Applies the ACTUAL typed `run.snapshot` page (F7 typed carrier). This
     * is the authoritative CAS source: the durable run state/revision, the
     * live pending approval (`callID` + `requestedAt` version), the durable
     * pending-input rows with their `inputVersion`, and the queue-order
     * revision. Nothing here is synthesized: a missing member stays absent.
     */
    internal fun applySnapshot(page: ConversationWire.SnapshotPage) {
        runRows[page.runID] = (runRows[page.runID]
            ?: RunRowUi(page.runID, page.durableState, null, ""))
            .copy(stateName = page.durableState)
        runRevisions[page.runID] = page.revision
        val approval = page.pendingApproval
        if (page.isTerminal && page.durableWatermark >= approvalFence(page.runID)) {
            // A proven terminal run cannot accept a pending decision even
            // after its live owner retired. This does not claim an allow.
            retirePendingApprovals(page.runID, page.durableWatermark)
            advanceApprovalFence(page.runID, page.durableWatermark)
        } else if (approval != null) {
            // A page older than the newest observed approval state for this
            // run is a late pre-decision read: it must not resurrect a
            // retired card nor roll back a newer request.
            val key = approvalKey(page.runID, approval.callID)
            val incomingVersion = page.approvalRevision?.version
            val retired = incomingVersion != null && "$key/$incomingVersion" in retiredApprovalVersions
            if (page.durableWatermark >= approvalFence(page.runID) &&
                page.durableWatermark > (approvalAbsenceFenceByRun[page.runID] ?: -1L) && !retired
            ) {
                val cards = pendingApprovalsByRun.getOrPut(page.runID) { mutableListOf() }
                val existing = cards.firstOrNull { it.approvalId == approval.callID }
                val knownVersion = approvalVersions[approval.callID]
                if (existing == null) {
                    cards.add(
                        ApprovalCardUi(
                            approvalId = approval.callID,
                            runId = page.runID,
                            conversationId = conversationId,
                            workspaceId = null,
                            toolName = approval.tool,
                            target = ApprovalTargetUi.Local,
                            scopeDescription = "",
                            reason = approval.reason,
                            riskLabels = emptySet(),
                            isSideEffecting = false,
                            requestedAtLabel = approval.requestedAt,
                            evidenceLines = emptyList(),
                        ),
                    )
                } else if (incomingVersion != null && incomingVersion != knownVersion) {
                    // A genuinely NEW request for the SAME call id (a new
                    // `requestedAt` ⇒ a new CAS version): refresh the
                    // request-bound fields; the run/card identity is kept.
                    cards[cards.indexOf(existing)] = existing.copy(
                        reason = approval.reason,
                        requestedAtLabel = approval.requestedAt,
                    )
                }
                incomingVersion?.let {
                    approvalVersions[approval.callID] = it
                    approvalVersionByRunCall[key] = it
                }
                advanceApprovalFence(page.runID, page.durableWatermark)
            }
        } else if (page.liveOwner) {
            // The live owner reporting NO pending approval is authoritative
            // absence: the native builder emits this member for every owned
            // run and never budget-drops it (RuntimeFacadeRunEvents). Without
            // a live owner the page writes an explicit null that means
            // "unknowable", never "none" — that absence is NOT authoritative
            // and must not clear anything. A page older than the fence is a
            // pre-request read: it predates a later durable request and must
            // not clear it either.
            if (page.durableWatermark >= approvalFence(page.runID)) {
                retirePendingApprovals(page.runID, page.durableWatermark)
                advanceApprovalFence(page.runID, page.durableWatermark)
            }
        }
        for (input in page.pendingInputs) {
            val previousVersion = inputVersions[input.id]
            inputVersions[input.id] = input.inputVersion
            val known = pendingInputs[input.id]
            val versionMoved = (previousVersion != null && previousVersion != input.inputVersion) ||
                (known?.inputVersion != null && known.inputVersion != input.inputVersion)
            if (versionMoved) {
                // The CAS version moved: any previously read full body or
                // preview described the OLD row content and must never keep
                // the editor bound to it. The slot rebuilds from THIS page.
                pendingInputBodies.remove(input.id)
            }
            pendingInputs[input.id] = known.mergeSnapshotWire(input, versionMoved)
        }
        // Snapshot-side retirement: the native builder reports the REAL
        // truncation of this page's queue window. Completeness here is
        // authoritative for the pending predicate (queued/promoting/
        // steerPending); absent pending rows on TWO consecutive complete
        // pages are retired from the projection (display only — the durable
        // store stays the sole content authority).
        reconcileQueueAbsentRows(
            presentIDs = page.pendingInputs.map { it.id }.toSet(),
            complete = page.pendingInputsTruncated == false,
        )
        page.queueRevision?.let { queueRevision = it }
        // The snapshot is the authoritative CAS source for the live task
        // policy (the native builder computes `policyRevision` from the
        // persisted row itself). Adopt it whenever it proves a revision.
        page.policyRevision?.let { policyRevisionValue = it }
        // ROUNDS 2/3: the REAL goal-review registry activity for THIS run.
        // A page carrying the member records it; a page WITHOUT the member
        // (legacy) records nothing — the App never assumes active or settled.
        page.goalReviewRaw?.let { goalReviewByRunValue[page.runID] = it }
    }

    internal fun applyMessagePage(page: ConversationWire.MessagePage, earlier: Boolean) {
        for (message in page.rows) {
            when (message.role) {
                MessageRoleUi.USER -> userMessages[message.id] = message
                MessageRoleUi.ASSISTANT -> assistantMessages[message.id] = message
                else -> Unit
            }
        }
    }

    /**
     * Appends one verified `content.read` chunk to the SAME message row.
     * Only an oversize row that arrived with a handle can reach this; the
     * row's text grows in exact chunk order and the row identity/role/run is
     * never rewritten.
     */
    internal fun appendMessageContent(messageID: String, chunk: String) {
        if (chunk.isEmpty()) return
        userMessages[messageID]?.let {
            userMessages[messageID] = it.copy(text = it.text + chunk)
        }
        assistantMessages[messageID]?.let {
            assistantMessages[messageID] = it.copy(text = it.text + chunk)
        }
    }

    internal fun applyPrepared(prepared: ConversationWire.Prepared) {
        // A new run owns a fresh live tail: the previous run's buffers must
        // never leak into it.
        resetLiveTail(prepared.runID)
        runRows[prepared.runID] = RunRowUi(
            id = prepared.runID,
            stateName = "prepared",
            modelId = null,
            startedAtLabel = "",
        )
        selectedRunId = prepared.runID
    }

    /** Drop every live-tail buffer/overlay and bind the tail to [runID]. */
    private fun resetLiveTail(runID: String?) {
        liveAssistant = ""
        liveReasoning = ""
        snapshotAnswerOverlay = null
        snapshotReasoningOverlay = null
        liveAssistantSegments.clear()
        liveReasoningSegments.clear()
        liveSegmentChars = 0
        liveTailRunId = runID
        liveTailClosedFor = null
    }

    /**
     * Projects ONE durable `RunEventRecord` from the ORIGINAL engine
     * vocabulary (FloeModels/AgentThread.swift Kind):
     * `assistantText`/`reasoning{text}`/`toolRequest`/`toolResult`/
     * `terminal{stopReason}`/`file`/`approval{tool,callID,scope,reason}` or
     * `approval{tool,callID,outcome}`/`error`/`usage`/`checkpoint`/
     * `status{state,reason}`/`autoApproved`/`notice`.
     *
     * `status` carries the run-state transitions (including the terminal
     * status appended for failed/checkpointed runs); `terminal` is only the
     * successful provider-completion close. Both update the durable run state
     * and its CAS revision version — never an invented `stateChanged`.
     */
    fun applyRunEvent(frame: HostRunEventFrame) {
        val kind = frame.kind
        val payload = frame.payload
        when (kind) {
            "assistantText" -> {
                val text = payload?.string("text")
                if (text != null) {
                    if (!liveTailAccepts(frame.runID)) return
                    liveAssistant += text
                    recordLiveSegment(text, reasoning = false)
                }
            }
            "reasoning" -> {
                // Native reasoning payload is {"text"}.
                val text = payload?.string("text") ?: payload?.string("excerpt")
                if (text != null) {
                    if (!liveTailAccepts(frame.runID)) return
                    liveReasoning += text
                    recordLiveSegment(text, reasoning = true)
                }
            }
            "terminal" -> {
                val runID = frame.runID
                if (frame.sequence >= approvalFence(runID)) {
                    retirePendingApprovals(runID, frame.sequence)
                    advanceApprovalFence(runID, frame.sequence)
                }
                val current = runRows[runID]
                // The provider-completion close; the durable state transition
                // (completed) arrives through `status`/the snapshot. Keep a
                // real non-terminal state if the status has not landed yet.
                val next = current?.takeIf { it.stateName in ACTIVE_STATES }
                    ?: (current ?: RunRowUi(runID, "completed", null, ""))
                runRows[runID] = next
                if (current == null) {
                    runRevisions[runID] =
                        Revision(ConversationWire.runResourceID(runID), "completed")
                }
            }
            "status" -> {
                val state = payload?.string("state")
                if (state != null) {
                    runRows[frame.runID] = (runRows[frame.runID]
                        ?: RunRowUi(frame.runID, state, null, ""))
                        .copy(stateName = state)
                    runRevisions[frame.runID] =
                        Revision(ConversationWire.runResourceID(frame.runID), state)
                    if (state in TERMINAL_STATES && frame.sequence >= approvalFence(frame.runID)) {
                        retirePendingApprovals(frame.runID, frame.sequence)
                        advanceApprovalFence(frame.runID, frame.sequence)
                    }
                }
            }
            "approval" -> {
                // Engine approval rows: a REQUEST carries
                // {tool,callID,scope,reason}; an OUTCOME carries
                // {tool,callID,outcome}. Presence of `outcome` is the exact
                // discriminator (never an invented approvalResolved).
                val callID = payload?.string("callID")
                if (callID != null && frame.sequence >= approvalFence(frame.runID) &&
                    frame.sequence > (approvalAbsenceFenceByRun[frame.runID] ?: -1L)
                ) {
                    if (payload.string("outcome") != null) {
                        val key = approvalKey(frame.runID, callID)
                        approvalVersionByRunCall.remove(key)?.let { retiredApprovalVersions.add("$key/$it") }
                        pendingApprovalsByRun[frame.runID]?.removeAll { it.approvalId == callID }
                        if (pendingApprovalsByRun.values.none { cards -> cards.any { it.approvalId == callID } }) {
                            approvalVersions.remove(callID)
                        }
                        approvalAbsenceFenceByRun[frame.runID] = frame.sequence
                        // Fence at the outcome record: a pre-outcome snapshot
                        // page (or a replayed request) must never resurrect
                        // the retired card.
                        advanceApprovalFence(frame.runID, frame.sequence)
                    } else {
                        val card = ConversationWire.decodeApprovalCard(
                            conversationId, frame.runID, payload)
                        if (card != null) {
                            pendingApprovalsByRun.getOrPut(frame.runID) {
                                mutableListOf()
                            }.removeAll { it.approvalId == card.approvalId }
                            pendingApprovalsByRun.getOrPut(frame.runID) {
                                mutableListOf()
                            }.add(card)
                            // Fence at the request record: a snapshot page
                            // fetched before this request landed is stale and
                            // must not clear the just-projected card.
                            advanceApprovalFence(frame.runID, frame.sequence)
                        }
                    }
                }
            }
            "userInputConsumed" -> {
                // Historical/forward-compatible vocabulary: the durable queue
                // row status is authoritative (snapshot `pendingInputs`).
                val inputID = payload?.string("inputID")
                if (inputID != null) {
                    pendingInputs[inputID] = pendingInputs[inputID]?.copy(
                        status = PendingInputStatusUi.CONSUMED) ?: return
                }
            }
            "stateChanged" -> {
                val state = payload?.string("state")
                if (state != null) {
                    runRows[frame.runID] = (runRows[frame.runID]
                        ?: RunRowUi(frame.runID, state, null, ""))
                        .copy(stateName = state)
                    runRevisions[frame.runID] =
                        Revision(ConversationWire.runResourceID(frame.runID), state)
                }
            }
            else -> Unit
        }
        // Durable event record (bounded, typed).
        val list = runEvents.getOrPut(frame.runID) { mutableListOf() }
        run {
            if (list.size >= 512) list.removeAt(0)
            list.add(
                RunEventUi(
                    id = "${frame.runID}:${frame.sequence}",
                    runId = frame.runID,
                    sequence = frame.sequence.toInt(),
                    kind = when (kind) {
                        "assistantText" -> RunEventKindUi.ASSISTANT_TEXT
                        "reasoning" -> RunEventKindUi.REASONING
                        "terminal" -> RunEventKindUi.TERMINAL
                        "approval" -> RunEventKindUi.APPROVAL
                        "approvalRequested", "approvalResolved" -> RunEventKindUi.APPROVAL
                        "status", "stateChanged" -> RunEventKindUi.STATUS
                        "toolRequest" -> RunEventKindUi.TOOL_REQUEST
                        "toolResult" -> RunEventKindUi.TOOL_RESULT
                        "usage" -> RunEventKindUi.USAGE
                        "file" -> RunEventKindUi.FILE
                        "checkpoint" -> RunEventKindUi.CHECKPOINT
                        "childRunChanged" -> RunEventKindUi.STATUS
                        "userInputConsumed" -> RunEventKindUi.STATUS
                        "autoApproved" -> RunEventKindUi.AUTO_APPROVED
                        "notice" -> RunEventKindUi.NOTICE
                        "error" -> RunEventKindUi.ERROR
                        else -> RunEventKindUi.NOTICE
                    },
                    timeLabel = "",
                    stateName = payload?.string("state"),
                    statusReason = payload?.string("reason"),
                    message = payload?.string("message"),
                    assistantText = payload?.string("text"),
                    reasoningExcerpt = payload?.string("text") ?: payload?.string("excerpt"),
                    stopReason = payload?.string("stopReason"),
                    tool = ConversationWire.decodeToolEvent(kind, payload),
                ),
            )
        }
    }

    fun stageAttachment(stagedAttachment: StagedAttachmentUi) {
        staged[stagedAttachment.id] = stagedAttachment
    }

    fun unstageAttachment(attachmentId: String) {
        staged.remove(attachmentId)
    }

    fun markMissing(reason: String) {
        missing = true
        actionError = reason
    }

    fun actionError(reason: String) {
        actionError = reason
    }

    /** A later real acceptance supersedes a stale error banner. */
    fun clearActionError() {
        actionError = null
    }

    /**
     * Clears the live display buffers once the durable close boundary has
     * been reached; the committed message rows are the authority from then on.
     * The closed run is remembered so a LATE authoritative snapshot (a read
     * that raced the terminal) can never resurrect the retired tail.
     */
    internal fun clearLiveBuffers() {
        liveAssistant = ""
        liveReasoning = ""
        snapshotAnswerOverlay = null
        snapshotReasoningOverlay = null
        liveAssistantSegments.clear()
        liveReasoningSegments.clear()
        liveSegmentChars = 0
        liveTailClosedFor = liveTailRunId
    }

    /**
     * Closes the live tail of [runID] at its durable close boundary. A
     * terminal callback for ANOTHER run (a late old-run terminal while a newer
     * run is selected) must never clear or close the selected run's tail, so
     * this is a no-op unless [runID] is the current selection.
     */
    internal fun closeLiveTail(runID: String): Boolean {
        if (selectedRunId != runID) return false
        clearLiveBuffers()
        liveTailClosedFor = runID
        return true
    }

    /**
     * Re-arms a NEW stream incarnation of the SAME durable run after a REAL
     * accepted `run.retry`. This is the only path that may lift the terminal
     * close boundary: retrying the same run id keeps its durable messages,
     * CAS revision and checkpoint, and only the presentation tail is rebound.
     * Stale/failed retries, cold reads, live hints and late snapshots must
     * never call this.
     */
    internal fun rearmLiveTailForRetry(runID: String): Boolean {
        if (selectedRunId != runID) return false
        val closedHere = liveTailClosedFor == runID
        val retryableState = runRows[runID]?.stateName in RETRYABLE_STATES
        if (!closedHere && !retryableState) return false
        resetLiveTail(runID)
        return true
    }

    /**
     * Applies the authoritative current answer/reasoning text of one typed
     * `run.snapshot` page by REPLACEMENT of the already-durable prefix of the
     * same streaming step (see [composeLiveTail]).
     *
     * Honesty rules (never relaxed):
     * * Only the SELECTED run's tail is touched; a snapshot for another run is
     *   canonical for its revisions only.
     * * A terminal page or a run whose durable close boundary was observed is
     *   refused — committed durable messages are the terminal authority and a
     *   late snapshot must not revive the old tail.
     * * `liveOwner = false` (cold history / no live service) or a missing
     *   text member leaves the durable tail untouched: absence is unknown,
     *   never an empty answer.
     * * `answerContinuationHandle != null` means the inline text is a bounded
     *   PREFIX: it is displayed, never treated as complete, and never clears
     *   the durable tail. The final message page remains the full truth.
     */
    internal fun applySnapshotLiveText(page: ConversationWire.SnapshotPage) {
        if (page.runID != selectedRunId) return
        if (page.isTerminal) return
        if (liveTailClosedFor == page.runID) return
        if (!page.liveOwner) return
        val durableState = runRows[page.runID]?.stateName ?: page.durableState
        if (durableState in TERMINAL_STATES) return
        val answer = page.answerText
        val reasoning = page.reasoningText
        if (answer == null && reasoning == null) return
        liveTailRunId = page.runID
        answer?.let { snapshotAnswerOverlay = it }
        // Reasoning absence is honest absence: keep the last authoritative
        // reasoning text rather than wiping it on a dropped member.
        reasoning?.let { snapshotReasoningOverlay = it }
    }

    /** A durable frame may extend the tail only for the run that owns it. */
    private fun liveTailAccepts(runID: String): Boolean {
        if (liveTailClosedFor == runID) return false
        val owner = liveTailRunId
        if (owner != null && owner != runID) {
            // A different run's durable text must never append onto another
            // run's answer. The SELECTED run rebinds a fresh tail instead.
            if (runID != selectedRunId) return false
            resetLiveTail(runID)
            return true
        }
        liveTailRunId = runID
        return true
    }

    private fun recordLiveSegment(text: String, reasoning: Boolean) {
        if (text.isEmpty()) return
        val segments = if (reasoning) liveReasoningSegments else liveAssistantSegments
        segments.addLast(text)
        liveSegmentChars += text.length
        while (segments.size > LIVE_SEGMENT_LIMIT ||
            liveSegmentChars > LIVE_SEGMENT_CHAR_LIMIT
        ) {
            val dropped = segments.removeFirstOrNull() ?: break
            liveSegmentChars -= dropped.length
        }
    }

    /** Display tails: durable segmented truth plus the authoritative overlay. */
    private fun assistantTailText(): String =
        composeLiveTail(liveAssistant, liveAssistantSegments, snapshotAnswerOverlay)

    private fun reasoningTailText(): String =
        composeLiveTail(liveReasoning, liveReasoningSegments, snapshotReasoningOverlay)

    /**
     * The authoritative overlay already contains the current step's durable
     * prefix (native `streamedText` accumulates the same deltas that flush to
     * `assistantText`/`reasoning` rows), so the displayed tail replaces that
     * prefix instead of appending on top of it:
     *
     * * `overlay == null` → durable tail (no authoritative live text known).
     * * `overlay` empty → durable tail (nothing streaming right now).
     * * durable tail empty → overlay.
     * * the overlay already landed durably (same suffix) → durable tail.
     * * otherwise remove the longest trailing run of durable segments that is
     *   an exact prefix of the overlay, then append the overlay.
     *
     * Every branch is bounded by the retained segment window and the buffer
     * sizes; nothing loops per token.
     */
    private fun composeLiveTail(
        durable: String,
        segments: ArrayDeque<String>,
        overlay: String?,
    ): String {
        if (overlay == null) return durable
        if (overlay.isEmpty()) return durable
        if (durable.isEmpty()) return overlay
        if (overlay.length <= durable.length && durable.endsWith(overlay)) {
            return durable
        }
        var overlap = 0
        val candidate = StringBuilder()
        var index = segments.size - 1
        while (index >= 0) {
            candidate.insert(0, segments[index])
            if (candidate.length >= overlay.length) {
                // The durable tail already carries at least the overlay's
                // characters: it is FRESHER than this (possibly stale) read,
                // so never append the older prefix again.
                if (candidate.startsWith(overlay)) return durable
                break
            }
            if (overlay.startsWith(candidate)) overlap = candidate.length
            index -= 1
        }
        return if (overlap > 0) durable.dropLast(overlap) + overlay else durable + overlay
    }

    /** Replace the durable child graph rows (child.list page). */
    internal fun applyChildRuns(rows: List<ChildRunUi>) {
        childRuns = rows
    }

    /** The proven durable task-policy CAS pair, or null when unread. */
    internal val policyRevision: Revision? get() = policyRevisionValue

    /** Forget an invalidated revision (typed stale refusal): the next
     * policy action must re-read the authoritative page, never replay the
     * rejected version. The mode projection itself stays at the durable
     * truth (the last accepted `conversation.get`/`run.snapshot` value). */
    internal fun invalidatePolicyRevision() {
        policyRevisionValue = null
    }

    /** Apply ONE accepted `run.policy.update` result: the accepted mode is
     * the host's own explicit value and the reply's `policyVersion` is the
     * REAL new CAS identity (never a bump the App invents). */
    internal fun applyPolicyUpdateSettled(
        mode: ApprovalModeUi,
        policyVersion: String?,
    ) {
        policyApprovalMode = mode
        if (policyVersion != null) {
            policyRevisionValue = Revision(
                ConversationWire.taskPolicyResourceID(conversationId),
                policyVersion,
            )
        } else {
            policyRevisionValue = null
        }
    }

    /**
     * A typed pump failure for [runID]: surfaced in the projection so the UI
     * can show an actionable line; the durable snapshot remains authoritative.
     */
    fun eventStreamFailure(runID: String, code: String) {
        actionError = code
    }

    // ------------------------------------------------ D04 run-output cards

    /** Replaces the last verified owned-output view for one run. An empty
     * list removes the group entirely (the honest "this run sealed no
     * user outputs"); it never leaves stale cards behind. Transient action
     * states are merged by (run/output) key. */
    fun applyRunOutputs(runID: String, items: List<RunOutputCardUi>, scanTruncated: Boolean) {
        if (items.isEmpty()) {
            runOutputsByRun.remove(runID)
            runOutputScanTruncatedByRun.remove(runID)
            return
        }
        runOutputsByRun[runID] = items.map { card ->
            card.copy(actionStateRaw = runOutputActionStates["$runID/${card.outputId}"]
                ?: card.actionStateRaw)
        }.toMutableList()
        runOutputScanTruncatedByRun[runID] = scanTruncated
    }

    /** The native lane itself is unavailable/fenced for this run: existing
     * verified cards stay (they came from real durable records) but flip to
     * the honest non-actionable "unavailable" state. Never the reverse. */
    fun markRunOutputsUnavailable(runID: String) {
        runOutputsByRun[runID]?.replaceWith { it.copy(availabilityRaw = "unavailable") }
    }

    private fun MutableList<RunOutputCardUi>.replaceWith(
        transform: (RunOutputCardUi) -> RunOutputCardUi,
    ) {
        for (index in indices) this[index] = transform(this[index])
    }

    fun setRunOutputActionState(runID: String, outputID: String, stateRaw: String?) {
        val key = "$runID/$outputID"
        if (stateRaw == null) runOutputActionStates.remove(key)
        else runOutputActionStates[key] = stateRaw
        runOutputsByRun[runID]?.replaceWith {
            if (it.outputId == outputID) it.copy(actionStateRaw = stateRaw) else it
        }
    }

    fun cachedRunOutputCard(runID: String, outputID: String): RunOutputCardUi? =
        runOutputsByRun[runID]?.firstOrNull { it.outputId == outputID }

    /** Build the complete immutable snapshot. */
    fun build(): ThreadUiState {
        snapshotCounter += 1
        val rows = ArrayList<TimelineRowUi>()
        val messages = (userMessages.values + assistantMessages.values)
            .sortedBy { it.timeLabel }
        val projectedEventRuns = mutableSetOf<String>()
        fun appendRecordedActivity(runId: String?) {
            if (runId == null || !projectedEventRuns.add(runId)) return
            val events = runEvents[runId].orEmpty().sortedBy { it.sequence }
            val tools = events.filter {
                it.tool != null && it.kind in setOf(
                    RunEventKindUi.TOOL_REQUEST, RunEventKindUi.TOOL_RESULT,
                    RunEventKindUi.APPROVAL, RunEventKindUi.AUTO_APPROVED,
                )
            }
            if (tools.isNotEmpty()) {
                rows.add(TimelineRowUi.StepGroup("$runId:recorded-tools", tools, runId == selectedRunId))
            }
            events.filter {
                (it.kind == RunEventKindUi.ERROR || it.kind == RunEventKindUi.NOTICE) &&
                    !it.message.isNullOrBlank()
            }.forEach { rows.add(TimelineRowUi.Event(it)) }
            runOutputsByRun[runId]?.takeIf { it.isNotEmpty() }?.let { outputs ->
                rows.add(
                    TimelineRowUi.RunOutputGroup(
                        runId, outputs.toList(),
                        runOutputScanTruncatedByRun[runId] == true,
                    ),
                )
            }
        }
        for (message in messages) {
            when (message.role) {
                MessageRoleUi.USER -> rows.add(TimelineRowUi.UserMessage(message))
                MessageRoleUi.ASSISTANT, MessageRoleUi.GOAL_CONTINUATION -> {
                    appendRecordedActivity(message.runId)
                    rows.add(
                        TimelineRowUi.AssistantMessage(
                            rowId = "a:${message.id}",
                            text = message.text,
                            attachedMessageId = message.id,
                            attachmentChips = message.attachmentChips,
                        ),
                    )
                }
                else -> Unit
            }
        }
        runEvents.keys.forEach(::appendRecordedActivity)
        // Cards survive App reload from real stored records: on cold load
        // terminal runs have no pumped events, but the native owned reader
        // still answered their sealed outputs — emit those groups too
        // (appendRecordedActivity dedups via projectedEventRuns).
        runOutputsByRun.keys.forEach(::appendRecordedActivity)
        val assistantTail = assistantTailText()
        val reasoningTail = reasoningTailText()
        if (assistantTail.isNotEmpty()) {
            rows.add(TimelineRowUi.LiveAssistantTail)
        }
        if (reasoningTail.isNotEmpty()) {
            rows.add(TimelineRowUi.LiveReasoning)
        }
        val selected = selectedRunId
        val approvals = selected?.let { pendingApprovalsByRun[it].orEmpty() }.orEmpty()
        val selectedState = selected?.let { runRows[it]?.stateName }
        // ⇄ the ORIGINAL AgentState vocabulary (FloeAgentRuntime/AgentState.swift):
        // only these states are live work; `interrupted` is a PARKED
        // dead-generation row (no live window), and completed/failed/
        // checkpointed/idle are durable-terminal.
        val running = selectedState != null && selectedState in ACTIVE_STATES
        val retryable = selectedState != null && selectedState in RETRYABLE_STATES
        return ThreadUiState(
            session = session,
            taskTitle = taskTitle,
            isTemporary = isTemporary,
            temporaryIncarnationId = temporaryIncarnationId,
            promotedConversationId = promotedConversationId,
            isConversationMissing = missing,
            hasLoaded = hasLoaded,
            hasProviderActivity = assistantTail.isNotEmpty(),
            needsProvider = needsProvider,
            runs = runRows.values.toList(),
            selectedRunId = selected,
            liveStateName = selectedState,
            isRunning = running,
            isDraining = false,
            selectedRunWaitingForJobs = false,
            rows = rows,
            pendingApprovals = approvals,
            pendingInputs = pendingInputs.values.toList(),
            pendingInputBodies = pendingInputBodies.toMap(),
            models = models,
            // The ONE honest projection: at most the thread's OWN bound
            // workspace (never the first project, never an empty placeholder
            // hiding a real durable row).
            projects = workspace?.let { listOf(ProjectOptionUi(it.id, it.name)) }.orEmpty(),
            boundWorkspaceId = workspace?.id,
            approvalMode = policyApprovalMode,
            usage = null,
            contextUsage = null,
            compactionStatus = compactionStatus,
            canContinue = retryable,
            continuationTitle = if (retryable) "Continue" else null,
            continuationDetail = actionError,
            hasEarlierMessages = hasEarlierMessages,
            loadingEarlierMessages = false,
            loadingEventRunIds = emptySet(),
            earlierMessageCursor = earlierCursor,
            importantFiles = emptyList(),
            checklist = null,
            plan = plan,
            goal = goal,
            planAvailabilityRaw = planAvailabilityRaw,
            goalAvailabilityRaw = goalAvailabilityRaw,
            goalReviewByRun = goalReviewByRunValue.toMap(),
            childRuns = childRuns,
            decisions = emptyList(),
            childDetails = childDetails.toMap(),
            liveAssistantText = assistantTail,
            liveReasoningText = reasoningTail,
            networkActionsAvailable = true,
            usesLocalModel = false,
            voiceAvailable = false,
            capabilityChips = emptyList(),
            taskPolicyRevision = policyRevisionValue,
            taskRecoveryPolicyRaw = policyRecoveryRaw,
            taskNotificationPolicyRaw = policyNotificationRaw,
        )
    }

    companion object {
        /** Native ACTIVE (live) run states — FloeAndroidCore
         * `FacadeRunDomain.activeRunStates` minus `interrupted`, which is a
         * parked dead-generation marker with no live window. */
        internal val ACTIVE_STATES = setOf(
            "preparing", "streamingModel", "waitingApproval", "executingTool",
            "compacting", "paused", "verifying", "cancelling",
        )

        /** Native durable-terminal states (`terminalRunStates`). */
        internal val TERMINAL_STATES = setOf(
            "completed", "failed", "checkpointed", "idle",
        )

        /** States that honestly offer Continue/retry (native resume sources). */
        internal val RETRYABLE_STATES = setOf(
            "failed", "checkpointed", "interrupted",
        )

        /** Bounded live-tail segment window (answer + reasoning share it). */
        private const val LIVE_SEGMENT_LIMIT = 256
        private const val LIVE_SEGMENT_CHAR_LIMIT = 1 shl 20
    }
}

/** Strict-tolerant decoders for the conversation/run owner wire pages. */
internal object ConversationWire {
    private val wireTime = SimpleDateFormat("HH:mm", Locale.US)

    /** ORIGINAL persisted event members from ConversationRunService. Output
     * is the recorded, redacted summary, never a manufactured success string.
     * Artifact metadata alone confers no preview/file or tool authority.
     */
    fun decodeToolEvent(kind: String, payload: JsonObject?): ToolEventProjectionUi? {
        if (kind !in setOf("toolRequest", "toolResult", "approval", "autoApproved")) return null
        val value = payload ?: return null
        val callId = value.string("id") ?: value.string("callID") ?: return null
        val name = value.string("tool") ?: return null
        val status = value.string("status") ?: value.string("outcome") ?: return null
        val artifacts = value.string("artifactRefsJSON")?.let { raw ->
            runCatching { kotlinx.serialization.json.Json.parseToJsonElement(raw) as? JsonArray }.getOrNull()
        }.orEmpty().mapNotNull { element ->
            val artifact = element as? JsonObject ?: return@mapNotNull null
            val id = artifact.string("id") ?: return@mapNotNull null
            val mime = artifact.string("mimeType") ?: return@mapNotNull null
            val bytes = artifact.long("byteCount")?.takeIf { it in 0..Int.MAX_VALUE.toLong() }
                ?: return@mapNotNull null
            val path = artifact.string("relativePath") ?: return@mapNotNull null
            val digest = artifact.string("sha256") ?: return@mapNotNull null
            ToolArtifactUi(id, mime, bytes.toInt(), path, digest, hostVerified = false)
        }
        return ToolEventProjectionUi(
            callId = callId,
            toolName = name,
            statusRaw = status,
            inputSummary = value.string("input"),
            resultSummary = value.string("summary"),
            approvalSummary = value.string("outcome"),
            durationSeconds = value.string("durationMs")?.toDoubleOrNull()
                ?.takeIf { it.isFinite() && it >= 0 }?.div(1000.0),
            artifacts = artifacts,
            harnessSuppressed = value.bool("harnessSuppressed") ?: false,
        )
    }

    class SessionReply(
        val title: String,
        val revision: Revision?,
        val runs: List<RunSummary>,
        val pendingInputs: List<PendingInputUi>,
        val approvalMode: ApprovalModeUi?,
        /** `taskPolicy.<uuid>` / the row's `updatedAt` when the reply
         * proves a durable policy row; null = no proven revision. */
        val policyRevision: Revision? = null,
        /** Native raw vocabulary of the persisted row (absent = unknown). */
        val policyRecoveryRaw: String? = null,
        val policyNotificationRaw: String? = null,
        /** Additive goal-core batch projections (absent/null = genuinely
         * absent — a temporary session or a store without rows answers
         * null; never an empty-object reinterpretation). */
        val plan: PlanUi? = null,
        val goal: GoalUi? = null,
        /** Additive goal-core batch projections (ROUNDS 2/3): the
         * `projected|trimmed|absent` availability vocabulary, decoded
         * verbatim. TRIMMING (a summary squeezed out by page pressure) is
         * never conflated with ABSENCE (no durable row): the App offers the
         * bounded detail read for `trimmed` and shows nothing for `absent`.
         * Null = a legacy round-1 reply without the members. */
        val planAvailabilityRaw: String? = null,
        val goalAvailabilityRaw: String? = null,
        /** Additive workspace-core projection: the real durable ownership
         * binding. A missing/null member decodes to null — the honest
         * unbound. */
        val workspace: WorkspaceBindingUi? = null,
        /** Additive queue-content repair (G04R2): the native page's REAL
         * full-store pending count and the honest truncation flag of this
         * window. Only `pendingInputsTruncated == false` proves the page
         * listed every durable pending row (retirement authority); a
         * trimmed page (`true`) or a legacy null NEVER is. */
        val pendingInputsTotalCount: Long? = null,
        val pendingInputsTruncated: Boolean? = null,
    )

    /** One honest conversation workspace binding (native `{workspaceID,
     * name,kind}` read shape). Missing identity or name is a null decode —
     * the App never binds a guessed workspace. */
    data class WorkspaceBindingUi(val id: String, val name: String, val kind: String)

    class RunSummary(
        val runID: String,
        val state: String,
        val modelName: String?,
        val startedAt: String,
    )

    class MessagePage(
        val rows: List<MessageUi>,
        val earlierCursor: MessagePageCursorUi?,
        val hasEarlier: Boolean,
    )

    class Prepared(
        val conversationID: String,
        val runID: String,
        val resourceID: String,
        val version: String,
    )

    /** One typed `run.snapshot` document (F7 carrier) — the CAS source. */
    class SnapshotPage(
        val runID: String,
        val durableState: String,
        val revision: Revision,
        val isTerminal: Boolean,
        val pendingApproval: PendingApprovalWire?,
        val approvalRevision: Revision?,
        val pendingInputs: List<PendingInputWire>,
        val queueRevision: Revision?,
        /**
         * Last durable event sequence the native run store already holds.
         * A resumed stream (same run id after retry) must start AFTER this
         * watermark so prior-incarnation durable events (including an old
         * terminal) are never replayed.
         */
        val durableWatermark: Long = 0L,
        /**
         * Native `liveOwner`: a live run service currently owns this run.
         * False means the transient live text is unknowable (cold history).
         */
        val liveOwner: Boolean = false,
        /** Authoritative current-step answer text (null = honest absence). */
        val answerText: String? = null,
        /** Native completion claim; a handle-prefixed text is never complete. */
        val answerComplete: Boolean = false,
        /** Non-null when [answerText] is a bounded prefix of the full text. */
        val answerContinuationHandle: String? = null,
        val reasoningText: String? = null,
        val reasoningComplete: Boolean = false,
        val reasoningContinuationHandle: String? = null,
        /** The durable task-policy CAS pair for `run.policy.update`
         * (`taskPolicy.<uuid>` / row `updatedAt`), computed by the native
         * snapshot builder from the persisted row. Null for a temporary run
         * (no durable row — the honest null) or when the member is absent. */
        val policyRevision: Revision? = null,
        /** ROUNDS 2/3 additive `goalReview` — the REAL post-run review/
         * continuation registry for THIS run: "none" / "active" /
         * "stopping". Flipping stopping→none IS the settlement proof; no
         * local timer or ack word substitutes for it. Null = a round-1
         * page without the member (never assumed). */
        val goalReviewRaw: String? = null,
        /** Additive queue-content repair (G04R2): the native builder's REAL
         * completeness proof for this page's `pendingInputs` window. False
         * means EVERY durable pending row (the store's pending predicate)
         * was listed — the only state from which absent rows may retire.
         * True means the window was budget-trimmed (unknown rows exist);
         * null = a legacy page without the member (never retirement
         * authority). */
        val pendingInputsTruncated: Boolean? = null,
    )

    class PendingApprovalWire(
        val callID: String,
        val tool: String,
        val reason: String,
        val requestedAt: String,
    )

    class PendingInputWire(
        val id: String,
        val position: Long,
        val status: PendingInputStatusUi,
        val mode: RunningInputModeUi,
        val inputVersion: String,
        /** Bounded UTF-8 preview of the durable row (native ≤512-byte
         * lane). Null = a legacy page WITHOUT the member — the slot stays
         * unread, never blank-as-complete. */
        val preview: String? = null,
        /** Native PROOF the preview equals the whole row text (short body). */
        val previewComplete: Boolean? = null,
        /** REAL durable UTF-8 length (preview labelling). */
        val contentBytes: Long? = null,
        /** ORIGINAL row vocabulary (null = legacy absence, never guessed). */
        val executionModeRaw: String? = null,
    )

    fun decodeSessionReply(value: JsonElement): SessionReply? {
        val root = value as? JsonObject ?: return null
        val id = root.string("conversationID") ?: return null
        val revision = decodeRevision(root)
        val runs = (root["runs"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            RunSummary(
                runID = obj.string("runID") ?: return@mapNotNull null,
                state = obj.string("state") ?: "unknown",
                modelName = obj.string("modelName"),
                startedAt = obj.string("startedAt") ?: "",
            )
        } ?: emptyList()
        val pendingInputs = (root["pendingInputs"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val inputID = obj.string("id") ?: return@mapNotNull null
            PendingInputUi(
                id = inputID,
                content = "",
                status = when (obj.string("status")) {
                    "queued" -> PendingInputStatusUi.QUEUED
                    "promoting" -> PendingInputStatusUi.PROMOTING
                    "steerPending" -> PendingInputStatusUi.STEER_PENDING
                    "consumed" -> PendingInputStatusUi.CONSUMED
                    "cancelled" -> PendingInputStatusUi.CANCELLED
                    else -> PendingInputStatusUi.QUEUED
                },
                mode = if (obj.string("mode") == "steer") {
                    RunningInputModeUi.STEER
                } else {
                    RunningInputModeUi.QUEUE
                },
                executionModeRaw = obj.string("executionMode") ?: "agent",
                position = obj.long("position") ?: 0L,
                // The conversation page carries REAL durable byte length
                // (metadata only — the body stays on the read lanes).
                contentBytes = obj.long("contentBytes"),
            )
        } ?: emptyList()
        val policy = root["taskPolicy"] as? JsonObject
        // `resolvedApprovalMode` is the native TaskApprovalMode rawValue
        // vocabulary (`ask`/`automatic`/`fullAccess`), NOT the Kotlin enum
        // NAME (`FULL_ACCESS`). Comparing names silently dropped the
        // persisted Full access value on a cold-opened task and left the
        // composer chip on its default Ask; map the actual wire spelling and
        // keep an unknown value as honest absence.
        val approvalMode = policy?.string("resolvedApprovalMode")?.let { raw ->
            ApprovalModeUi.entries.firstOrNull { it.swiftRaw == raw }
        }
        // The REAL persisted row identity for run.policy.update CAS: the
        // projection carries `updatedAt` under the native TaskPolicy raw
        // vocabulary; a reply WITHOUT the row (or without a parseable
        // stamp) yields NO revision — the App then re-reads the snapshot
        // or refuses, never fabricates a version.
        val policyRevision = policy?.string("updatedAt")?.takeIf { it.isNotBlank() }?.let {
            Revision(taskPolicyResourceID(id), it)
        }
        return SessionReply(
            title = root.string("title") ?: id,
            revision = revision,
            runs = runs,
            pendingInputs = pendingInputs,
            approvalMode = approvalMode,
            policyRevision = policyRevision,
            policyRecoveryRaw = policy?.string("recoveryPolicy"),
            policyNotificationRaw = policy?.string("notificationPolicy"),
            plan = decodePlanSummary(root["plan"] as? JsonObject),
            goal = decodeGoalSummary(root["goal"] as? JsonObject),
            planAvailabilityRaw = root.string("planAvailability"),
            goalAvailabilityRaw = root.string("goalAvailability"),
            workspace = decodeWorkspaceBinding(root["workspace"] as? JsonObject),
            pendingInputsTotalCount = root.long("pendingInputsTotalCount"),
            pendingInputsTruncated = root.bool("pendingInputsTruncated"),
        )
    }

    /** The additive `conversation.get.workspace` member (approved read
     * shape): `{workspaceID,name,kind}`. A foreign/partial object without
     * its real identity or name decodes to null — the projection then shows
     * the honest unbound instead of binding a guessed workspace. */
    fun decodeWorkspaceBinding(obj: JsonObject?): WorkspaceBindingUi? {
        if (obj == null) return null
        val id = obj.string("workspaceID") ?: return null
        val name = obj.string("name") ?: return null
        return WorkspaceBindingUi(id = id, name = name.take(120), kind = obj.string("kind") ?: "")
    }

    /** The additive `conversation.get.plan` summary (approved read map):
     * `{id,status,isDecisionComplete,executionRecommendation?,
     *   recommendationReason?,revision,digest,title}`. A foreign/partial
     * object without its real id/revision decodes to null — the accept
     * action then refuses rather than binding a guessed identity. */
    fun decodePlanSummary(obj: JsonObject?): PlanUi? {
        if (obj == null) return null
        val id = obj.string("id") ?: return null
        val status = obj.string("status") ?: return null
        val decisionComplete = obj.bool("isDecisionComplete") ?: return null
        val revisionNumber = obj.long("revision")?.toInt() ?: return null
        return PlanUi(
            id = id,
            title = obj.string("title") ?: "",
            statusRaw = status,
            isDecisionComplete = decisionComplete,
            executionRecommendation = when (obj.string("executionRecommendation")) {
                "normal" -> PlanRecommendationUi.NORMAL
                "goal" -> PlanRecommendationUi.GOAL
                else -> null
            },
            recommendationReason = obj.string("recommendationReason"),
            revisionNumber = revisionNumber,
            revision = Revision("plan.$id", revisionNumber.toString()),
            digest = obj.string("digest"),
        )
    }

    /** The additive `conversation.get.goal` summary (approved read map):
     * counts + status + the REAL action revision identity
     * (`revisionResourceID`/`revisionVersion` are echoed verbatim into
     * `goal.confirm`). No criterion/step/evidence text exists in this
     * summary; the bounded detail read (still pending from the Core owner)
     * is the only future source, and nothing here substitutes for it. */
    fun decodeGoalSummary(obj: JsonObject?): GoalUi? {
        if (obj == null) return null
        val id = obj.string("id") ?: return null
        val status = obj.string("status") ?: return null
        return GoalUi(
            id = id,
            objective = obj.string("objective") ?: "",
            statusRaw = status,
            stepsCompleted = obj.long("stepsCompleted")?.toInt() ?: 0,
            stepsTotal = obj.long("stepsTotal")?.toInt() ?: 0,
            revision = obj.long("revision")?.toInt() ?: 0,
            revisionResourceID = obj.string("revisionResourceID"),
            revisionVersion = obj.string("revisionVersion"),
            criteriaTotal = obj.long("criteriaTotal")?.toInt() ?: 0,
            criteriaSatisfied = obj.long("criteriaSatisfied")?.toInt() ?: 0,
            criteriaAwaitingUserConfirmation =
                obj.long("criteriaAwaitingUserConfirmation")?.toInt() ?: 0,
            cycleCount = obj.long("cycleCount")?.toInt() ?: 0,
            modelCallCount = obj.long("modelCallCount")?.toInt() ?: 0,
            totalIterationCount = obj.long("totalIterationCount")?.toInt() ?: 0,
        )
    }

    /**
     * Reads a CAS revision from the ACTUAL conversation replies. The frozen
     * native `ConversationSessionReply` / `ConversationCreateReply` carry
     * `resourceID` and the digest as a STRING sibling
     * (`"revision":"<floe.conversation-row.v1 digest>"`); the authored
     * effect-detail shape uses a `{resourceID,version}` object. Both denote
     * the same canonical revision and neither is synthesized here.
     */
    fun decodeRevision(root: JsonObject): Revision? {
        (root["revision"] as? JsonObject)?.let {
            val resourceID = it.string("resourceID")
            val version = it.string("version")
            if (resourceID != null && version != null) return Revision(resourceID, version)
        }
        val version = root.string("revision")
        val resourceID = root.string("resourceID")
        if (version != null && resourceID != null) return Revision(resourceID, version)
        return null
    }

    fun decodeMessagePage(value: JsonElement, conversationId: String = ""): MessagePage? {
        val root = value as? JsonObject ?: return null
        val rows = (root["rows"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            val roleRaw = obj.string("role") ?: "user"
            val text = obj.string("content") ?: ""
            val createdAt = obj.string("createdAt") ?: ""
            MessageUi(
                id = id,
                conversationId = conversationId,
                runId = obj.string("runID"),
                role = when (roleRaw.lowercase()) {
                    "assistant" -> MessageRoleUi.ASSISTANT
                    "user" -> MessageRoleUi.USER
                    "goalContinuation" -> MessageRoleUi.GOAL_CONTINUATION
                    "system" -> MessageRoleUi.SYSTEM
                    else -> MessageRoleUi.OTHER
                },
                text = text,
                attachmentChips = (obj["attachments"] as? JsonArray)
                    ?.mapNotNull { chip -> decodeAttachmentChip(chip as? JsonObject) }
                    ?: emptyList(),
                timeLabel = formatTime(createdAt),
            )
        } ?: emptyList()
        val earlierCursor = when (val element = root["earlierCursor"]) {
            is JsonObject -> {
                val createdAt = element.string("createdAt")
                val id = element.string("id")
                if (createdAt != null && id != null) {
                    MessagePageCursorUi(createdAtLabel = createdAt, messageId = id)
                } else null
            }
            // ACTUAL native wire: the opaque `k1.` keyset cursor string
            // (base64url of {"createdAt","id"}). Decode it ONLY to recover the
            // real (createdAt,id) for the continuation request; the exact
            // string is re-encoded canonically when the next page is asked.
            is JsonPrimitive -> element.contentOrNull?.let(::decodeOpaqueMessageCursor)
            else -> null
        }
        val hasEarlier = root.bool("hasEarlier") ?: (earlierCursor != null)
        return MessagePage(rows, earlierCursor, hasEarlier)
    }

    /**
     * The oversize-row handles of one ACTUAL `conversation.messagePage`
     * reply. A row whose FULL content moved to an owned handle carries
     * `contentHandle` and no inline content; the host fetches it through the
     * SAME `content.read` contract (temporary handles are re-authorized by
     * the session incarnation core-side). Rows with inline content are not
     * listed and are never re-read.
     */
    fun contentHandles(value: JsonElement?): List<Pair<String, String>> {
        val root = value as? JsonObject ?: return emptyList()
        val rows = root["rows"] as? JsonArray ?: return emptyList()
        return rows.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            val handle = obj.string("contentHandle")?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            if (!handle.startsWith("chunk:v1:")) return@mapNotNull null
            id to handle
        }
    }

    data class ContentSlice(
        val chunk: String,
        val done: Boolean,
        val nextOffset: Int?,
    )

    /** Decodes one ACTUAL `conversationLifecycle content.read` reply. */
    fun decodeContentSlice(value: JsonElement?): ContentSlice? {
        val root = value as? JsonObject ?: return null
        val chunk = root.string("chunk") ?: return null
        return ContentSlice(
            chunk = chunk,
            done = root.bool("done") ?: false,
            nextOffset = root.long("nextOffset")?.toInt(),
        )
    }

    /**
     * Decodes the native `ConversationCursorCodec` message cursor:
     * `k1.` + base64url(JSON `{"createdAt":"<wire date>","id":"<uuid>"}`).
     * A non-`k1.`/malformed cursor is absence, never a guessed position.
     */
    internal fun decodeOpaqueMessageCursor(raw: String): MessagePageCursorUi? {
        if (!raw.startsWith("k1.")) return null
        val encoded = raw.removePrefix("k1.")
            .replace('-', '+')
            .replace('_', '/')
            .let { it + "=".repeat((4 - it.length % 4) % 4) }
        val text = try {
            String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        } catch (t: Throwable) {
            return null
        }
        val root = try {
            kotlinx.serialization.json.Json.parseToJsonElement(text) as? JsonObject
        } catch (t: Throwable) {
            null
        } ?: return null
        val createdAt = root.string("createdAt")?.takeIf { it.isNotBlank() } ?: return null
        val id = root.string("id")?.takeIf { it.isNotBlank() } ?: return null
        runCatching { java.util.UUID.fromString(id) }.getOrNull() ?: return null
        return MessagePageCursorUi(createdAtLabel = createdAt, messageId = id)
    }

    /**
     * Re-encodes the native opaque message cursor from the real identity the
     * previous page carried. Key order is irrelevant to the native JSON
     * decoder; the date/id are never rewritten or truncated.
     */
    internal fun encodeOpaqueMessageCursor(cursor: MessagePageCursorUi): String? {
        if (cursor.createdAtLabel.isBlank() || cursor.messageId.isBlank()) return null
        runCatching { java.util.UUID.fromString(cursor.messageId) }.getOrNull() ?: return null
        val document = JsonObject(linkedMapOf(
            "createdAt" to JsonPrimitive(cursor.createdAtLabel),
            "id" to JsonPrimitive(cursor.messageId),
        ))
        val encoded = java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString(document.toString().toByteArray(Charsets.UTF_8))
        return "k1.$encoded"
    }

    private fun decodeAttachmentChip(obj: JsonObject?): AttachmentChipUi? {
        obj ?: return null
        val id = obj.string("id") ?: return null
        return AttachmentChipUi(
            id = id,
            name = obj.string("displayName") ?: id,
            isImage = obj.string("kind") == "image",
            attachmentId = obj.string("attachmentId"),
        )
    }

    fun decodeApprovalCard(conversationId: String, runId: String, payload: JsonObject): ApprovalCardUi? {
        val callID = payload.string("callID") ?: return null
        val tool = payload.string("tool") ?: return null
        return ApprovalCardUi(
            approvalId = callID,
            runId = runId,
            conversationId = conversationId,
            workspaceId = payload.string("workspaceID"),
            toolName = tool,
            target = ApprovalTargetUi.Local,
            // The engine approval payload's scope description key is `scope`.
            scopeDescription = payload.string("scope")
                ?: payload.string("scopeDescription") ?: "",
            reason = payload.string("reason") ?: "",
            riskLabels = (payload["riskLabels"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }?.toSet() ?: emptySet(),
            isSideEffecting = payload.bool("isSideEffecting") ?: false,
            requestedAtLabel = formatTime(payload.string("requestedAt") ?: ""),
            evidenceLines = emptyList(),
        )
    }

    /**
     * Decodes the ACTUAL typed `run.snapshot` page returned through the F7
     * `RuntimeCommandResult.page` carrier. Required members: `runID`,
     * `durableState`, `revision{resourceID,version}`. The remaining members
     * are projected only when the native page carries them (honest absence).
     */
    fun decodeSnapshotPage(value: JsonElement?): SnapshotPage? {
        val root = value as? JsonObject ?: return null
        val runID = root.string("runID") ?: return null
        val durableState = root.string("durableState") ?: return null
        val revision = (root["revision"] as? JsonObject)?.let {
            val resourceID = it.string("resourceID")
            val version = it.string("version")
            if (resourceID != null && version != null) Revision(resourceID, version) else null
        } ?: return null
        val approval = (root["pendingApproval"] as? JsonObject)?.let { obj ->
            val callID = obj.string("callID") ?: return@let null
            PendingApprovalWire(
                callID = callID,
                tool = obj.string("tool") ?: "",
                reason = obj.string("reason") ?: "",
                requestedAt = obj.string("requestedAt") ?: "",
            )
        }
        val approvalRevision = (root["approvalRevision"] as? JsonObject)?.let {
            val resourceID = it.string("resourceID")
            val version = it.string("version")
            if (resourceID != null && version != null) Revision(resourceID, version) else null
        }
        val inputs = (root["pendingInputs"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("inputID") ?: return@mapNotNull null
            val version = obj.string("inputVersion") ?: return@mapNotNull null
            PendingInputWire(
                id = id,
                position = obj.long("position") ?: 0L,
                status = when (obj.string("status")) {
                    "queued" -> PendingInputStatusUi.QUEUED
                    "promoting" -> PendingInputStatusUi.PROMOTING
                    "steerPending" -> PendingInputStatusUi.STEER_PENDING
                    "consumed" -> PendingInputStatusUi.CONSUMED
                    "cancelled" -> PendingInputStatusUi.CANCELLED
                    else -> PendingInputStatusUi.QUEUED
                },
                mode = if (obj.string("mode") == "steer") {
                    RunningInputModeUi.STEER
                } else {
                    RunningInputModeUi.QUEUE
                },
                inputVersion = version,
                // Queue-content members are honest nullables: a legacy page
                // without them keeps the row UNREAD (never a blank slot that
                // claims completeness).
                preview = obj.string("preview"),
                previewComplete = obj.bool("previewComplete"),
                contentBytes = obj.long("contentBytes"),
                executionModeRaw = obj.string("executionMode"),
            )
        }
        val queueRevision = (root["queueRevision"] as? JsonObject)?.let {
            val resourceID = it.string("resourceID")
            val version = it.string("version")
            if (resourceID != null && version != null) Revision(resourceID, version) else null
        }
        return SnapshotPage(
            runID = runID,
            durableState = durableState,
            revision = revision,
            isTerminal = root.bool("isTerminal") ?: (durableState in ThreadProjectionBuilder.TERMINAL_STATES),
            pendingApproval = approval,
            approvalRevision = approvalRevision,
            pendingInputs = inputs,
            queueRevision = queueRevision,
            durableWatermark = root.long("durableWatermark") ?: 0L,
            // Live text members are honest nullables: a missing member is
            // unknown, never an empty answer. The native page emits them for
            // every owned run and drops them only under its strict frame
            // budget; the decoder mirrors that exactly.
            liveOwner = root.bool("liveOwner") ?: false,
            answerText = root.string("answerText"),
            answerComplete = root.bool("answerComplete") ?: false,
            answerContinuationHandle = root.string("answerContinuationHandle"),
            reasoningText = root.string("reasoningText"),
            reasoningComplete = root.bool("reasoningComplete") ?: false,
            reasoningContinuationHandle = root.string("reasoningContinuationHandle"),
            // The native page emits `policyRevision` as an object OR an
            // explicit null (temporary run / no durable row). Only the
            // object form yields a CAS identity; JSON null and absence both
            // decode to null — never a synthesized version.
            policyRevision = (root["policyRevision"] as? JsonObject)?.let {
                val resourceID = it.string("resourceID")
                val version = it.string("version")
                if (resourceID != null && version != null) Revision(resourceID, version) else null
            },
            goalReviewRaw = root.string("goalReview"),
            pendingInputsTruncated = root.bool("pendingInputsTruncated"),
        )
    }

    /** One `conversation.get.detail` reply page (closed members; the
     * additive ROUNDS 2/3 read). `content` is a valid UTF-8 substring of
     * the canonical durable-row JSON at exact byte boundaries; ONLY
     * `nextOffset` drives continuation. A malformed member decodes to null
     * and the reader treats that as a typed failure (never a partial
     * publish). */
    class DetailPage(
        val kind: String,
        val id: String,
        val statusRaw: String,
        val revision: Long?,
        val digest: String,
        val encoding: String,
        val offset: Long,
        val nextOffset: Long,
        val totalBytes: Long,
        val truncated: Boolean,
        val content: String,
        val revisionResourceID: String?,
        val revisionVersion: String?,
        val planDigest: String?,
        val isDecisionComplete: Boolean?,
    )

    /** Decodes the `detail` member out of a `conversation.get` reply. */
    fun decodeDetailPage(value: JsonElement): DetailPage? {
        val root = value as? JsonObject ?: return null
        val detail = root["detail"] as? JsonObject ?: return null
        val kind = detail.string("kind") ?: return null
        if (kind != "goal" && kind != "plan" && kind != "checklist" &&
            kind != "pendingInput") return null
        val id = detail.string("id") ?: return null
        val digest = detail.string("digest") ?: return null
        if (!digest.matches(Regex("[0-9a-f]{64}")) || detail.string("encoding") != "json-utf8") return null
        val offset = detail.long("offset") ?: return null
        val nextOffset = detail.long("nextOffset") ?: return null
        val totalBytes = detail.long("totalBytes") ?: return null
        if (offset < 0 || nextOffset < offset || totalBytes < nextOffset) return null
        val content = detail.string("content") ?: return null
        return DetailPage(
            kind = kind,
            id = id,
            statusRaw = detail.string("status") ?: "",
            revision = detail.long("revision"),
            digest = digest,
            encoding = "json-utf8",
            offset = offset,
            nextOffset = nextOffset,
            totalBytes = totalBytes,
            truncated = detail.bool("truncated") ?: false,
            content = content,
            revisionResourceID = detail.string("revisionResourceID"),
            revisionVersion = detail.string("revisionVersion"),
            planDigest = detail.string("planDigest"),
            isDecisionComplete = detail.bool("isDecisionComplete"),
        )
    }

    /** Reconstruct the projected queue row from the fully accumulated
     * `detail{kind:"pendingInput"}` byte-exact chain (only ever called on
     * a COMPLETE digest-verified assembly). Strict: the row id must match
     * the page identity, the native CAS pair (`pendingInput.<UPPER uuid>`
     * + updatedAt-derived `inputVersion`) must agree between the page
     * members and the row document, and content/status/mode/executionMode
     * must be REAL members. Any mismatch decodes to null — a partial or
     * foreign document never reaches the editor, and nothing here guesses
     * queue bytes. */
    fun decodePendingInputBodyRow(
        json: JsonObject,
        pageID: String,
        pageRevisionResourceID: String?,
        pageRevisionVersion: String?,
    ): PendingInputBodyRow? {
        val id = json.string("id") ?: return null
        if (id != pageID) return null
        val content = json.string("content") ?: return null
        val status = json.string("status") ?: return null
        val mode = json.string("mode") ?: return null
        val executionMode = json.string("executionMode") ?: return null
        val inputVersion = json.string("inputVersion") ?: return null
        if (pageRevisionVersion != null && pageRevisionVersion != inputVersion) return null
        if (pageRevisionResourceID != null &&
            pageRevisionResourceID != pendingInputResourceID(id)) return null
        return PendingInputBodyRow(
            id = id,
            content = content,
            statusRaw = status,
            modeRaw = mode,
            executionModeRaw = executionMode,
            inputVersion = inputVersion,
        )
    }

    /** One proven-complete durable queue row (editor hydration input). */
    class PendingInputBodyRow(
        val id: String,
        val content: String,
        val statusRaw: String,
        val modeRaw: String,
        val executionModeRaw: String,
        val inputVersion: String,
    )

    /** Reconstruct the ORIGINAL durable goal row from the fully accumulated
     * canonical JSON (only ever called on a COMPLETE byte-exact chain).
     * Strict: the row identity/objective/status must exist; a foreign or
     * partial document decodes to null. Absent optional members stay null
     * (distinct from empty), per the row's real shape. No `checks` field
     * exists on the goal by contract — nothing is synthesized here. */
    fun decodeGoalDetailRow(json: JsonObject): GoalDetailUi? {
        val id = json.string("id") ?: return null
        val objective = json.string("objective") ?: return null
        val statusRaw = json.string("status") ?: return null
        val criteria = (json["acceptanceCriteria"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val cid = obj.string("id") ?: return@mapNotNull null
            GoalCriterionRowUi(
                id = cid,
                text = obj.string("text") ?: "",
                isSatisfied = obj.bool("isSatisfied") ?: false,
                evidenceIDs = (obj["evidenceIDs"] as? JsonArray)
                    ?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                    ?: emptyList(),
                requiresUserConfirmation = obj.bool("requiresUserConfirmation") ?: false,
            )
        }
        val steps = (json["steps"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val sid = obj.string("id") ?: return@mapNotNull null
            GoalStepRowUi(
                id = sid,
                title = obj.string("title") ?: "",
                detail = obj.string("detail") ?: "",
                statusRaw = obj.string("status") ?: "pending",
                order = obj.long("order")?.toInt() ?: 0,
            )
        }
        val evidence = (json["evidence"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val eid = obj.string("id") ?: return@mapNotNull null
            GoalEvidenceRowUi(
                id = eid,
                kindRaw = obj.string("kind") ?: "",
                reference = obj.string("reference") ?: "",
                summary = obj.string("summary") ?: "",
                fingerprint = obj.string("fingerprint"),
            )
        }
        val progress = json["progress"] as? JsonObject
        val budgets = json["budgets"] as? JsonObject
        return GoalDetailUi(
            id = id,
            objective = objective,
            statusRaw = statusRaw,
            revision = json.long("revision")?.toInt(),
            sourcePlanID = json.string("sourcePlanID"),
            sourcePlanDigest = json.string("sourcePlanDigest"),
            criteria = criteria,
            steps = steps.sortedBy { it.order },
            evidence = evidence,
            blockingConditions = (json["blockingConditions"] as? JsonArray)
                ?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content },
            stoppingConditions = (json["stoppingConditions"] as? JsonArray)
                ?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content },
            maxCycles = budgets?.long("maxCycles")?.toInt(),
            maxModelCalls = budgets?.long("maxModelCalls")?.toInt(),
            cycleCount = progress?.long("cycleCount")?.toInt() ?: 0,
            modelCallCount = progress?.long("modelCallCount")?.toInt() ?: 0,
            totalIterationCount = progress?.long("totalIterationCount")?.toInt() ?: 0,
        )
    }

    /** Reconstruct the ORIGINAL durable plan row (same rules as the goal
     * row: complete chain only, strict identity, absent ≠ empty). */
    fun decodePlanDetailRow(json: JsonObject): PlanDetailUi? {
        val id = json.string("id") ?: return null
        val revision = json.long("revision")?.toInt() ?: return null
        val statusRaw = json.string("status") ?: return null
        val sections = (json["sections"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val sid = obj.string("id") ?: return@mapNotNull null
            PlanSectionRowUi(
                id = sid,
                title = obj.string("title") ?: "",
                body = obj.string("body") ?: "",
                order = obj.long("order")?.toInt() ?: 0,
            )
        }
        val assumptions = (json["assumptions"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val aid = obj.string("id") ?: return@mapNotNull null
            PlanAssumptionRowUi(
                id = aid,
                text = obj.string("text") ?: "",
                isAccepted = obj.bool("isAccepted") ?: false,
            )
        }
        val risks = (json["risks"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val rid = obj.string("id") ?: return@mapNotNull null
            PlanRiskRowUi(
                id = rid,
                text = obj.string("text") ?: "",
                mitigation = obj.string("mitigation"),
                severityRaw = obj.string("severity") ?: "",
            )
        }
        val criteria = (json["acceptanceCriteria"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val cid = obj.string("id") ?: return@mapNotNull null
            PlanCriterionRowUi(
                id = cid,
                text = obj.string("text") ?: "",
                verification = obj.string("verification") ?: "",
            )
        }
        return PlanDetailUi(
            id = id,
            revision = revision,
            statusRaw = statusRaw,
            title = json.string("title") ?: "",
            summary = json.string("summary") ?: "",
            sections = sections.sortedBy { it.order },
            assumptions = assumptions,
            risks = risks,
            criteria = criteria,
            digest = json.string("digest"),
        )
    }

    /** Reconstruct the ORIGINAL durable checklist row from its canonical
     * JSON (complete byte-exact chain only). The body carries NO id field;
     * identity travels the reply-level `detail.id` (the real runID) and the
     * body's `runID`/`revision` must agree with the proven page — any
     * mismatch decodes to null (typed failure, never a merged snapshot).
     * Original step statuses are preserved verbatim (completed stays
     * distinct from cancelled). */
    fun decodeChecklistDetailRow(
        json: JsonObject,
        pageRunID: String,
        pageRevision: Long?,
        pageStatusRaw: String,
    ): ChecklistDetailUi? {
        val bodyRunID = json.string("runID") ?: return null
        if (bodyRunID != pageRunID) return null
        val revision = json.long("revision")?.toInt() ?: return null
        if (pageRevision != null && pageRevision.toInt() != revision) return null
        val steps = (json["steps"] as? JsonArray).orEmpty().mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val sid = obj.string("id") ?: return@mapNotNull null
            val statusRaw = obj.string("status") ?: return@mapNotNull null
            val status = ChecklistStepStatusUi.entries.firstOrNull { it.swiftRaw == statusRaw }
                ?: return@mapNotNull null
            ChecklistStepUi(
                id = sid,
                title = obj.string("title") ?: "",
                status = status,
                evidence = (obj["evidence"] as? JsonArray)
                    ?.mapNotNull { (it as? JsonPrimitive)?.content }
                    ?: emptyList(),
            )
        }
        return ChecklistDetailUi(
            runID = bodyRunID,
            revision = revision,
            title = json.string("title") ?: "",
            statusRaw = pageStatusRaw,
            steps = steps,
        )
    }

    fun decodePrepared(value: JsonElement): Prepared? {
        val root = value as? JsonObject ?: return null
        val runID = root.string("runID") ?: return null
        val conversationID = root.string("conversationID") ?: return null
        val revision = decodeRevision(root)
        return Prepared(
            conversationID = conversationID,
            runID = runID,
            resourceID = revision?.resourceID ?: "run.$runID",
            version = revision?.version ?: "",
        )
    }

    /**
     * Reads the REAL run identities from the non-terminal `prepared` effect
     * emitted by the run domain AFTER its atomic launch commit. The frozen
     * producer carries them in the bounded `detail` map:
     * `conversationID`, `runID`, `resourceID` (`run.<uuid>`), `version`
     * (`floe.run-row.v1` state token). The terminal `accepted` deliberately
     * carries no value, so this frame is the only correct source of the
     * minted identities.
     */
    fun preparedFromEffect(detail: Map<String, String>): Prepared? {
        val runID = detail["runID"]?.takeIf { it.isNotBlank() } ?: return null
        val conversationID = detail["conversationID"]?.takeIf { it.isNotBlank() } ?: return null
        val resourceID = detail["resourceID"]?.takeIf { it.isNotBlank() } ?: "run.$runID"
        val version = detail["version"] ?: ""
        return Prepared(conversationID, runID, resourceID, version)
    }

    /**
     * The EXACT frozen `run.start` payload (`RunStartQuery.allowedKeys`):
     * `{goal,mode,providerID,modelID,stagedAttachments,…}` — closed keys.
     *
     * * `mode` is the ORIGINAL `RunLaunchMode` vocabulary `chat|plan|goal`;
     *   the composer's AGENT and CHAT both mean the ordinary chat-capable
     *   turn, while PLAN/GOAL keep their own spellings.
     * * `providerID` + `modelID` are REQUIRED native UUIDs; the App sends the
     *   real selected model's provider/model identities (never a default or a
     *   fabricated id).
     * * No `workspaceID`/`temporaryIncarnation` key exists in this grammar —
     *   the previous App invented both and native rejected the whole
     *   payload. Temporary launches travel the dedicated `temp.*` surface.
     */
    fun runStartPayload(request: RunLaunchRequest, stagedHandles: List<String>): JsonObject {
        val members = mutableMapOf<String, JsonElement>(
            "goal" to JsonPrimitive(request.goalText),
            "mode" to JsonPrimitive(runLaunchMode(request.executionMode)),
            "stagedAttachments" to JsonArray(stagedHandles.map { JsonPrimitive(it) }),
        )
        request.providerId?.let { members["providerID"] = JsonPrimitive(it) }
        request.modelId?.let { members["modelID"] = JsonPrimitive(it) }
        // Product CHAT (an explicit ordinary chat-only turn) sends the EMPTY
        // tool ceiling: the current native assembly already maps an empty
        // ceiling to `toolsEnabled=false`. AGENT omits the key and keeps the
        // native tool path enabled. This NEVER generalizes from the wire
        // `mode:"chat"` — AGENT also travels the chat spelling — only from
        // the composer's own CHAT selection on an ORDINARY launch (a
        // temporary session's ceiling is the native frozen public-web
        // allowlist and must stay unchanged).
        if (request.executionMode == AgentExecutionModeUi.CHAT &&
            request.temporaryIncarnationId == null
        ) {
            members["toolCeiling"] = JsonArray(emptyList())
        }
        // The Home draft-task policy for the FIRST fresh launch of a new
        // ordinary conversation (⇄ persisted atomically with the launch by
        // the native C1). Absent key = the ORIGINAL native default (.ask);
        // recovery/notification keep their existing defaults (never sent).
        request.approvalMode?.let { members["approvalMode"] = JsonPrimitive(it.swiftRaw) }
        // Structured thread GoalBuilder definition (approved additive
        // `goalDefinition` key; mode goal only — the caller contract is the
        // host's createGoal path). Closed members mirror
        // `RunStartQuery.goalDefinitionKeys`; empty criteria arrays stay
        // ABSENT (the ORIGINAL native default-criterion rule is Swift-side,
        // never composed here). Bounds are the native parser's; the host
        // refuses an over-budget producer BEFORE dispatch.
        request.goalDefinition?.let { definition ->
            val objective = definition.objective.trim()
            if (objective.isNotEmpty() && request.executionMode == AgentExecutionModeUi.GOAL) {
                val goalMembers = mutableMapOf<String, JsonElement>(
                    "objective" to JsonPrimitive(objective),
                )
                definition.boundedCriteria()?.let {
                    goalMembers["criteria"] = JsonArray(it.map { v -> JsonPrimitive(v) })
                }
                definition.boundedBlockingConditions()?.let {
                    goalMembers["blockingConditions"] = JsonArray(it.map { v -> JsonPrimitive(v) })
                }
                definition.boundedStoppingConditions()?.let {
                    goalMembers["stoppingConditions"] = JsonArray(it.map { v -> JsonPrimitive(v) })
                }
                members["goalDefinition"] = JsonObject(goalMembers)
            }
        }
        return JsonObject(members)
    }

    /** ⇄ RunLaunchMode raw (chat|plan|goal). */
    internal fun runLaunchMode(mode: AgentExecutionModeUi): String = when (mode) {
        AgentExecutionModeUi.AGENT, AgentExecutionModeUi.CHAT -> "chat"
        AgentExecutionModeUi.PLAN -> "plan"
        AgentExecutionModeUi.GOAL -> "goal"
    }

    /**
     * `run.queue` payload (allowedKeys `content,mode,selectedModelID,
     * stagedAttachments,executionMode`). `run.queue` enqueues a NEW durable
     * pending row; an `inputID` key is not part of this grammar (the
     * previous App sent the RUN id under it, which native rejected).
     *
     * G04R2 queue-input repair: the composer's REAL execution mode rides
     * the payload so the durable row owns it (iOS parity) and the native
     * terminal drain launches exactly the queued mode instead of a silent
     * default. Native keeps the historical `agent` default for an absent
     * key, so the grammar stays additive.
     */
    fun runningInputPayload(request: RunningInputRequest, stagedHandles: List<String>): JsonObject {
        val members = mutableMapOf<String, JsonElement>(
            "content" to JsonPrimitive(request.content),
            "mode" to JsonPrimitive(RunningInputModeUi.QUEUE.swiftRaw),
            "executionMode" to JsonPrimitive(request.executionMode.swiftRaw),
        )
        request.modelId?.let { members["selectedModelID"] = JsonPrimitive(it) }
        if (stagedHandles.isNotEmpty()) members["stagedAttachments"] =
            JsonArray(stagedHandles.map { JsonPrimitive(it) })
        return JsonObject(members)
    }

    /**
     * `run.steer` payload (allowedKeys `inputID,expectedState`). `inputID` is
     * the DURABLE PENDING-ROW uuid (never the run id); steer always promotes
     * an already-queued row.
     */
    fun steerPayload(inputID: String, expectedState: String): JsonObject = JsonObject(
        mapOf(
            "inputID" to JsonPrimitive(inputID),
            "expectedState" to JsonPrimitive(expectedState),
        ),
    )

    fun decodeConversationList(value: JsonElement): HistoryPage? {
        val root = value as? JsonObject ?: return null
        val rows = (root["rows"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("conversationID") ?: return@mapNotNull null
            ConversationListItemUi(
                id = id,
                title = obj.string("title") ?: id,
                updatedAtLabel = formatTime(obj.string("updatedAt") ?: ""),
                projectedStateName = obj.string("projectedStateName"),
                isArchived = obj.bool("archived") ?: false,
                archivedAtLabel = obj.string("archivedAt")?.let { formatTime(it) },
            )
        } ?: emptyList()
        return HistoryPage(
            active = rows.filter { !it.isArchived },
            archived = rows.filter { it.isArchived },
        )
    }

    fun decodeSearch(value: JsonElement): List<ConversationListItemUi> =
        ((value as? JsonObject)?.get("rows") as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("conversationID") ?: return@mapNotNull null
            ConversationListItemUi(
                id = id,
                title = obj.string("conversationTitle") ?: id,
                updatedAtLabel = formatTime(obj.string("createdAt") ?: ""),
                projectedStateName = null,
                isArchived = false,
                archivedAtLabel = null,
            )
        } ?: emptyList()

    /**
     * Decodes the ACTUAL `child.entries` typed page:
     * `{childRunID, entries:[{sequence,kind,payload(JSON string),createdAt}],
     *   hasMore, nextSequence}`. Rows are projected from the entry facts; the
     * previous version always returned an empty row list.
     */
    fun decodeChildDetail(childRunId: String, value: JsonElement?): ChildRunDetailUi {
        val root = value as? JsonObject
        val entries = (root?.get("entries") as? JsonArray).orEmpty()
        val rows = entries.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val sequence = obj.long("sequence") ?: return@mapNotNull null
            val kind = obj.string("kind") ?: return@mapNotNull null
            val payloadRaw = obj.string("payload")
            val payload = payloadRaw?.let {
                try {
                    kotlinx.serialization.json.Json.parseToJsonElement(it) as? JsonObject
                } catch (t: Throwable) {
                    null
                }
            }
            TimelineRowUi.Event(
                RunEventUi(
                    id = "$childRunId:$sequence",
                    runId = childRunId,
                    sequence = sequence.toInt(),
                    kind = when (kind) {
                        "assistantText" -> RunEventKindUi.ASSISTANT_TEXT
                        "reasoning" -> RunEventKindUi.REASONING
                        "terminal" -> RunEventKindUi.TERMINAL
                        "approval" -> RunEventKindUi.APPROVAL
                        "status" -> RunEventKindUi.STATUS
                        "toolRequest" -> RunEventKindUi.TOOL_REQUEST
                        "toolResult" -> RunEventKindUi.TOOL_RESULT
                        "usage" -> RunEventKindUi.USAGE
                        "file" -> RunEventKindUi.FILE
                        "checkpoint" -> RunEventKindUi.CHECKPOINT
                        "autoApproved" -> RunEventKindUi.AUTO_APPROVED
                        "notice" -> RunEventKindUi.NOTICE
                        "error" -> RunEventKindUi.ERROR
                        else -> RunEventKindUi.NOTICE
                    },
                    timeLabel = formatTime(obj.string("createdAt") ?: ""),
                    stateName = payload?.string("state"),
                    statusReason = payload?.string("reason"),
                    message = payload?.string("message"),
                    assistantText = payload?.string("text"),
                    reasoningExcerpt = payload?.string("text"),
                    stopReason = payload?.string("stopReason"),
                    tool = decodeToolEvent(kind, payload),
                ),
            )
        }
        return ChildRunDetailUi(
            childRunId = childRunId,
            title = root?.string("title") ?: childRunId,
            stateName = root?.string("stateName") ?: "unknown",
            rows = rows,
        )
    }

    /**
     * Decodes the ACTUAL `child.list` typed page
     * (`{parentRunID, children:[childJSON], childrenTruncated}`) into the
     * durable child graph rows. No UI-emulated children.
     */
    fun decodeChildList(value: JsonElement?, titleFor: (String) -> String): List<ChildRunUi> {
        val root = value as? JsonObject
        val children = (root?.get("children") as? JsonArray).orEmpty()
        return children.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val childID = obj.string("childRunID") ?: return@mapNotNull null
            val state = obj.string("state") ?: "unknown"
            ChildRunUi(
                id = childID,
                parentRunId = obj.string("parentRunID") ?: "",
                delegateCallId = "",
                stateName = state,
                stateTitle = titleFor(state),
                isTerminal = obj.bool("terminal") ?: false,
                title = obj.string("taskSummary") ?: titleFor(state),
                summary = obj.string("resultSummary"),
                startedAtLabel = formatTime(obj.string("startedAt") ?: ""),
            )
        }
    }

    /**
     * The ORIGINAL durable AgentState vocabulary. `terminal`/`cancelled`/
     * `succeeded` are NOT native states and must never close a pump.
     */
    fun isTerminalState(state: String): Boolean =
        state in ThreadProjectionBuilder.TERMINAL_STATES

    /** A run may only be pumped while the native engine owns a live window. */
    fun isActiveState(state: String): Boolean =
        state in ThreadProjectionBuilder.ACTIVE_STATES

    /**
     * The durable close boundary: the provider-completion `terminal` event OR
     * a `status` transition to a native terminal state. Failed/checkpointed
     * runs settle through the terminal `status` row (there is no durable
     * `terminal` event on that path).
     */
    fun isTerminalFrame(frame: HostRunEventFrame): Boolean =
        frame.kind == "terminal" ||
            (frame.kind == "status" && frame.payload?.string("state")?.let {
                isTerminalState(it)
            } == true)

    fun isTerminalKind(kind: String): Boolean = kind == "terminal"

    /* -------- closed CAS revision resource identities (native spelling) ----- */

    /** `run.<UPPER uuid>` — Swift `UUID.uuidString` is uppercase. */
    fun runResourceID(runID: String): String = "run.${upperUUID(runID)}"

    /** `conversation.<UPPER uuid>`. */
    fun conversationResourceID(conversationID: String): String =
        "conversation.${upperUUID(conversationID)}"

    /** `pendingInput.<UPPER uuid>`. */
    fun pendingInputResourceID(inputID: String): String = "pendingInput.${upperUUID(inputID)}"

    /** `pendingQueue.<UPPER uuid>`. */
    fun pendingQueueResourceID(conversationID: String): String =
        "pendingQueue.${upperUUID(conversationID)}"

    /** `taskPolicy.<UPPER uuid>` (native `RunWireRevision.taskPolicyResourceID`). */
    fun taskPolicyResourceID(conversationID: String): String =
        "taskPolicy.${upperUUID(conversationID)}"

    /** `approval.<callID>` verbatim (call ids are opaque provider ids). */
    fun approvalResourceID(callID: String): String = "approval.$callID"

    private fun upperUUID(raw: String): String = try {
        java.util.UUID.fromString(raw).toString().uppercase()
    } catch (t: Throwable) {
        raw
    }

    fun exportMarkdown(builder: ThreadProjectionBuilder): String {
        val snapshot = builder.build()
        val out = StringBuilder()
        out.append("# ").append(snapshot.taskTitle).append("\n\n")
        for (row in snapshot.rows) {
            when (row) {
                is TimelineRowUi.UserMessage -> {
                    out.append("**User** ").append(row.message.text).append("\n\n")
                }
                is TimelineRowUi.AssistantMessage -> {
                    out.append(row.text).append("\n\n")
                }
                else -> Unit
            }
        }
        return out.toString()
    }

    fun exportPlainText(builder: ThreadProjectionBuilder): String {
        val snapshot = builder.build()
        val out = StringBuilder()
        for (row in snapshot.rows) {
            when (row) {
                is TimelineRowUi.UserMessage -> out.append(row.message.text).append("\n\n")
                is TimelineRowUi.AssistantMessage -> out.append(row.text).append("\n\n")
                else -> Unit
            }
        }
        return out.toString()
    }

    private fun formatTime(raw: String): String = try {
        if (raw.isEmpty()) ""
        else wireTime.format(Date.from(java.time.Instant.parse(raw)))
    } catch (t: Throwable) {
        raw.take(16)
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull
}

class HistoryPage(
    val active: List<com.floe.android.feature.conversation.ConversationListItemUi>,
    val archived: List<com.floe.android.feature.conversation.ConversationListItemUi>,
)
