// SPDX-License-Identifier: MPL-2.0
//
// Immutable presentation projections for the G02 conversation flow.
//
// Mapping authority (current FloeApp sources, verified against the working
// tree on 2026-10-18; NOT a re-implementation):
//  - TimelineRowUi              ⇄ FloeApp/Chat/ThreadTimeline.swift ThreadTimelineItem
//  - RunEventUi + Kind          ⇄ FloeModels/AgentThread.swift RunEventRecord (+ payload
//                               fields projected BY THE HOST — Kotlin never parses
//                               payloadJSON; see lane rule "no second protocol parser")
//  - MessageUi                  ⇄ FloePersistence PersistedMessage (role subset)
//  - AttachmentChipUi           ⇄ FloeApp/Chat/UserMessageBubble.swift AttachmentChipItem
//  - StagedAttachmentUi         ⇄ FloeModels/AgentThread.swift AttachmentRef + Android
//                               SAF import lifecycle (CHA-ATTACH-INGEST-AND / -LIFECYCLE-AND)
//  - ApprovalCardUi             ⇄ FloeApp/Remote/ConversationCenter.swift PendingApproval
//                               (identity = runID + callID; raw provider call ids are NOT
//                               unique across runs — the card scopes by both)
//  - ApprovalTargetUi           ⇄ FloeModels/ToolCall.swift ToolScope
//  - PendingInputUi             ⇄ FloeModels/RunningInput.swift PendingUserInput
//  - PlanUi / GoalUi / ChecklistUi ⇄ FloeAgentRuntime PlanningModels/GoalModels +
//                               TaskChecklist projections
//  - UsageUi                    ⇄ FloeApp/Chat/ThreadDetailViewModel.swift ThreadUsageSummary
//  - ChildRunUi / ToolDecisionUi ⇄ ThreadTimeline.swift ChildRunRecord projection +
//                               ToolDecisionAnnotation
//  - ModelOptionUi              ⇄ ModelProfile: saved UUID vs wire id vs display name stay
//                               THREE DISTINCT fields (contract).
//  - ConversationListItemUi     ⇄ FloePersistence ConversationRecord (subset)
//  - BulkReceiptUi              ⇄ FloeApp/Chat/TaskBulkManagement.swift TaskBulkSummary
//
// These types carry NO business logic, NO persistence and NO wire calls. They
// are supplied by the host (shared Swift services behind the accepted bridge)
// and consumed by the composables in this module. IDs are host-authored strings
// (existing model UUIDs / run ids); this module never mints authoritative ids,
// grants or sessions.

package com.floe.android.feature.conversation

import com.floe.android.contracts.EventCursor
import com.floe.android.contracts.Revision

/* --------------------------------- identity -------------------------------- */

/**
 * One bound presentation session of a conversation thread. [conversationId] is
 * the host task identity (existing ConversationRecord.id uuidString);
 * [sessionEpoch] is owned by [ConversationFlowHolder] and increases on every
 * rebind, so a late host projection or callback addressed to an older epoch is
 * provably stale and is ignored (the provider flow's epoch contract, reused
 * here for threads; iOS achieves the same with per-conversation view models).
 */
data class ConversationSessionToken(
    val conversationId: String,
    val sessionEpoch: Long,
) {
    init {
        require(sessionEpoch >= 0) { "sessionEpoch must be non-negative" }
    }

    fun isCurrentFor(other: ConversationSessionToken): Boolean =
        conversationId == other.conversationId && sessionEpoch == other.sessionEpoch
}

/* --------------------------------- timeline -------------------------------- */

/** Persisted run-event kinds (⇄ RunEventRecord.Kind raw values, preserved). */
enum class RunEventKindUi(val swiftRaw: String) {
    ASSISTANT_TEXT("assistantText"),
    REASONING("reasoning"),
    TOOL_REQUEST("toolRequest"),
    TOOL_RESULT("toolResult"),
    TERMINAL("terminal"),
    FILE("file"),
    APPROVAL("approval"),
    ERROR("error"),
    USAGE("usage"),
    CHECKPOINT("checkpoint"),
    STATUS("status"),
    AUTO_APPROVED("autoApproved"),
    NOTICE("notice"),
}

/** One digest-addressed tool artifact (⇄ ToolArtifactReference). Bytes are never
 * carried here; previews load only through an explicit host-verified URI the
 * host chose to publish, and only when that projection says the host verified
 * the recorded digest. */
data class ToolArtifactUi(
    val id: String,
    val mimeType: String,
    val byteCount: Int,
    /** Recorded relative path (⇄ relativePath) — display only. */
    val relativePath: String,
    val sha256: String,
    /** True only after the host re-read and re-verified bytes == digest. */
    val hostVerified: Boolean = false,
    /** Explicit content/preview URI the host resolved, or null when the host
     * cannot expose one. This module never derives a filesystem path itself. */
    val previewUri: String? = null,
)

/** Host-projected fields of one tool event (payload decode authority stays
 * with the shared Swift core; these slots mirror the exact keys StepGroupView
 * and ToolCallCardView read). */
data class ToolEventProjectionUi(
    val callId: String,
    val toolName: String,
    /** Raw producer vocabulary ("ok"/"failed"/"pending"/"denied"/"expired"/
     * "cancelled"/"needsUser"/"running"/…); presentation maps it, never re-times it. */
    val statusRaw: String,
    val inputSummary: String? = null,
    val resultSummary: String? = null,
    /** Approval outcome projected for this call (⇄ approval/autoApproved rows). */
    val approvalSummary: String? = null,
    val durationSeconds: Double? = null,
    val artifacts: List<ToolArtifactUi> = emptyList(),
    /** Harness suppression is host-authoritative protocol bookkeeping; the
     * projection marks it so the timeline keeps skipping the paired rows. */
    val harnessSuppressed: Boolean = false,
)

/** One persisted run event projected for display. */
data class RunEventUi(
    val id: String,
    val runId: String,
    val sequence: Int,
    val kind: RunEventKindUi,
    /** "HH:mm"-style label the host resolved from createdAt. */
    val timeLabel: String,
    /** ⇄ status payload["state"] — run-state name for status rows. */
    val stateName: String? = null,
    /** ⇄ status payload["reason"] — durable reason (job-wait etc). */
    val statusReason: String? = null,
    /** ⇄ error payload message / notice text — already redacted by the host. */
    val message: String? = null,
    /** ⇄ assistantText payload["text"]. */
    val assistantText: String? = null,
    /** ⇄ reasoning payload excerpt. */
    val reasoningExcerpt: String? = null,
    /** ⇄ terminal payload["stopReason"]. */
    val stopReason: String? = null,
    /** Filled for toolRequest/toolResult/approval/autoApproved kinds. */
    val tool: ToolEventProjectionUi? = null,
)

/** One attachment chip of a persisted message (⇄ AttachmentChipItem: the REAL
 * part kind renders, image never masquerades as file). */
data class AttachmentChipUi(
    val id: String,
    val name: String,
    /** ⇄ MessagePart.Kind subset that can be an attachment. */
    val isImage: Boolean,
    val attachmentId: String?,
)

/** Message roles the thread renders. Unknown raw roles keep the honest
 * "other" rendering instead of silently becoming assistant text. */
enum class MessageRoleUi(val swiftRaw: String) {
    USER("user"),
    ASSISTANT("assistant"),
    GOAL_CONTINUATION("goalContinuation"),
    SYSTEM("system"),
    OTHER("");

    companion object {
        fun from(raw: String): MessageRoleUi =
            entries.firstOrNull { it.swiftRaw == raw } ?: OTHER
    }
}

data class MessageUi(
    val id: String,
    val conversationId: String,
    val runId: String?,
    val role: MessageRoleUi,
    val text: String,
    val attachmentChips: List<AttachmentChipUi> = emptyList(),
    val timeLabel: String,
    /** Trusted internal notices render the host's concise user-facing summary
     * (⇄ InternalNoticeProjection / ProposalDecisionPresentation); raw template
     * bytes never reach the ordinary surface, and `trustedNotice` says why. */
    val trustedNoticeSummary: String? = null,
)

/* -------------------------------- approvals -------------------------------- */

/** ⇄ FloeModels ToolScope: what the call may touch, host-projected. */
sealed interface ApprovalTargetUi {
    data object Local : ApprovalTargetUi
    data class Host(val hostId: String) : ApprovalTargetUi
    data class HostPath(val hostId: String, val path: String) : ApprovalTargetUi
}

/** The four grant tiers the approval card offers (⇄ ApprovalScopeChoice). */
enum class ApprovalScopeChoiceUi(val swiftRaw: String) {
    ONCE("once"),
    TASK("task"),
    PROJECT("project"),
    HOST("host"),
}

/**
 * A pending human decision bound to one EXACT call in one EXACT run
 * (⇄ PendingApproval). `id` is the provider call id — deliberately NOT unique
 * across runs — so [runId] is part of every identity comparison
 * (APR-CALL-BOUND). [workspaceId] is the workspace captured when the approval
 * first became visible: an allowed workspace action is denied if the user
 * switches roots (the host enforces; the UI preserves the identity).
 */
data class ApprovalCardUi(
    val approvalId: String,           // ⇄ toolCall.id (provider call id)
    val runId: String,
    val conversationId: String,
    val workspaceId: String?,
    val toolName: String,
    val target: ApprovalTargetUi,
    val scopeDescription: String,
    /** Why the policy escalated to a human (host-provided, redacted). */
    val reason: String,
    /** Deterministic catalog risk labels — never model-derived
     * (⇄ PendingApproval.riskLabels; imported content cannot add any). */
    val riskLabels: Set<String>,
    val isSideEffecting: Boolean,
    val requestedAtLabel: String,
    /** Foldable exact evidence (⇄ argumentSummary): host-projected key-sorted
     * argument lines, size-capped and redacted upstream. Display-only. */
    val evidenceLines: List<String>,
) {
    /** Exact card identity: runID + callID (the membership predicate rule). */
    val key: String get() = "$runId/$approvalId"
}

/* ------------------------------ pending inputs ------------------------------ */

/** ⇄ RunningInputMode (AppSettings): what Enter does while a run is active. */
enum class RunningInputModeUi(val swiftRaw: String) { QUEUE("queue"), STEER("steer") }

/** ⇄ PendingUserInputStatus (transient states ARE projected: they are the
 * durable queue vocabulary, not invented UI states). */
enum class PendingInputStatusUi(val swiftRaw: String) {
    QUEUED("queued"),
    PROMOTING("promoting"),
    STEER_PENDING("steerPending"),
    CONSUMED("consumed"),
    CANCELLED("cancelled");

    /** ⇄ isPending */
    val isPending: Boolean
        get() = this == QUEUED || this == PROMOTING || this == STEER_PENDING
}

data class PendingInputUi(
    val id: String,
    /** Verbatim queue text (user content — masked in toString below). */
    val content: String,
    val status: PendingInputStatusUi,
    val mode: RunningInputModeUi,
    /** App-layer execution-mode raw ("agent"/"browserHandoff"/…). */
    val executionModeRaw: String,
    val position: Long,
    /** Trusted proposal-decision rows show the concise localized summary
     * instead of the raw grant/target payload (⇄ ProposalDecisionPresentation
     * .summary(for:)); null = show content verbatim. */
    val trustedSummary: String? = null,
) {
    val isBrowserHandoff: Boolean get() = executionModeRaw == "browserHandoff"

    /** User prompts are sensitive content: never dump them into logs. */
    override fun toString(): String =
        "PendingInputUi(id=$id, status=${status.swiftRaw}, mode=${mode.swiftRaw}, chars=${content.length})"
}

/* ------------------------------- plan / goal ------------------------------- */

/** ⇄ PlanExecutionRecommendation. */
enum class PlanRecommendationUi(val swiftRaw: String) { NORMAL("normal"), GOAL("goal") }

/** ⇄ PlanDraft subset the thread surface renders (status raw + decision state). */
data class PlanUi(
    val id: String,
    val title: String,
    /** ⇄ PlanStatus rawValue ("drafting"/"awaitingInput"/"ready"/"accepted"…). */
    val statusRaw: String,
    val isDecisionComplete: Boolean,
    val executionRecommendation: PlanRecommendationUi?,
    val recommendationReason: String?,
    /** ⇄ PlanDraft.revision — the number the explicit mode choice pins. */
    val revisionNumber: Int,
    /** Revision+digest identity: an accept binds to the EXACT revision the
     * user saw (host authority validates on accept; never fabricate one). */
    val revision: Revision,
    /** The durable plan's ACTUAL `digest` string from the `conversation.get`
     * plan projection (≤128). Null = not supplied by the wire: the accept
     * action then refuses honestly instead of sending a fabricated digest. */
    val digest: String? = null,
) {
    companion object {
        /** ⇄ PlanStatus awaitingInput || ready — the active-plan window. */
        fun isActiveAwaitingReview(statusRaw: String): Boolean =
            statusRaw == "awaitingInput" || statusRaw == "ready"
    }
}

/** ⇄ ConversationGoal subset for the status strip (additive goal-mode fields
 * default to "not supplied"; the confirmation affordance requires the REAL
 * revision identity members from the `conversation.get` goal projection). */
data class GoalUi(
    val id: String,
    val objective: String,
    /** ⇄ GoalStatus rawValue ("active"/"verifying"/"blocked"/…). */
    val statusRaw: String,
    val stepsCompleted: Int,
    val stepsTotal: Int,
    /** Latest non-terminal goal's durable revision + its CAS identity,
     * verbatim from the wire (`revisionVersion` is the envelope version the
     * `goal.confirm` command must echo). Null = no proven identity. */
    val revision: Int = 0,
    val revisionResourceID: String? = null,
    val revisionVersion: String? = null,
    val criteriaTotal: Int = 0,
    val criteriaSatisfied: Int = 0,
    val criteriaAwaitingUserConfirmation: Int = 0,
    val cycleCount: Int = 0,
    val modelCallCount: Int = 0,
    val totalIterationCount: Int = 0,
)

/**
 * The ORIGINAL durable goal row, reconstructed ONLY from the bounded
 * `conversation.get.detail` canonical-JSON read (exact UTF-8 byte offsets,
 * digest/revision proven across pages). The summary NEVER substitutes for
 * it: criteria/steps/evidence/blockers/budget text exists only here. No
 * checklist field exists on the goal by contract (the original
 * TaskChecklistStore read is a separate Main-owned lane; nothing here may
 * fake it).
 */
data class GoalCriterionRowUi(
    val id: String,
    val text: String,
    val isSatisfied: Boolean,
    val evidenceIDs: List<String>,
    val requiresUserConfirmation: Boolean,
)

data class GoalStepRowUi(
    val id: String,
    val title: String,
    val detail: String,
    /** ⇄ GoalStepStatus rawValue ("pending"/"inProgress"/"completed"/
     * "failed"/"skipped"). */
    val statusRaw: String,
    val order: Int,
)

data class GoalEvidenceRowUi(
    val id: String,
    /** ⇄ GoalEvidence.Kind rawValue. */
    val kindRaw: String,
    val reference: String,
    val summary: String,
    val fingerprint: String?,
)

data class GoalDetailUi(
    val id: String,
    val objective: String,
    val statusRaw: String,
    val revision: Int?,
    val sourcePlanID: String?,
    val sourcePlanDigest: String?,
    val criteria: List<GoalCriterionRowUi>,
    val steps: List<GoalStepRowUi>,
    val evidence: List<GoalEvidenceRowUi>,
    /** Explicit null = member absent from the durable row; empty list =
     * genuinely empty (the two render differently, never conflated). */
    val blockingConditions: List<String>?,
    val stoppingConditions: List<String>?,
    val maxCycles: Int?,
    val maxModelCalls: Int?,
    val cycleCount: Int,
    val modelCallCount: Int,
    val totalIterationCount: Int,
)

/** The ORIGINAL durable plan row (same detail read, `kind:"plan"`). */
data class PlanSectionRowUi(
    val id: String,
    val title: String,
    val body: String,
    val order: Int,
)

data class PlanAssumptionRowUi(
    val id: String,
    val text: String,
    val isAccepted: Boolean,
)

data class PlanRiskRowUi(
    val id: String,
    val text: String,
    val mitigation: String?,
    /** ⇄ PlanRisk.Severity rawValue. */
    val severityRaw: String,
)

data class PlanCriterionRowUi(
    val id: String,
    val text: String,
    val verification: String,
)

data class PlanDetailUi(
    val id: String,
    val revision: Int,
    /** ⇄ PlanStatus rawValue. */
    val statusRaw: String,
    val title: String,
    val summary: String,
    val sections: List<PlanSectionRowUi>,
    val assumptions: List<PlanAssumptionRowUi>,
    val risks: List<PlanRiskRowUi>,
    val criteria: List<PlanCriterionRowUi>,
    val digest: String?,
)

/** The bounded detail-read state for one conversation row (goal or plan).
 * All-or-nothing: READY carries ONLY a fully accumulated + digest-proven
 * canonical row; any mid-chain refusal keeps the LAST state visible and
 * reports typed failure honestly (never a partial row). */
/**
 * The ORIGINAL durable task-checklist row (`TaskChecklistStore`) read over
 * the SAME `conversation.get.detail` wire with `kind:"checklist"`. Its
 * step evidence is MODEL-AUTHORED progress material: `finished` means every
 * step settled (completed OR cancelled) and NEVER proves Goal
 * confirmation/completion; cancelled steps stay distinct from completed
 * ones. Ordinary sessions only — the temporary ceiling has no checklist
 * producer by contract.
 */
data class ChecklistDetailUi(
    /** The reply identity: the ACTUAL checklist.runID. */
    val runID: String,
    val revision: Int,
    val title: String,
    /** Reply-level status: "finished" (all steps settled, including
     * cancelled) or "inProgress". */
    val statusRaw: String,
    val steps: List<ChecklistStepUi>,
)

sealed interface PlanGoalDetailStateUi {
    data object Idle : PlanGoalDetailStateUi
    data object Loading : PlanGoalDetailStateUi
    /** The durable row genuinely is not there (native absence reply or the
     * checklist `notFound` typed refusal — never presented as an error). */
    data object Absent : PlanGoalDetailStateUi
    data class Failed(val code: String) : PlanGoalDetailStateUi
    data class GoalReady(val row: GoalDetailUi) : PlanGoalDetailStateUi
    data class PlanReady(val row: PlanDetailUi) : PlanGoalDetailStateUi
    data class ChecklistReady(val row: ChecklistDetailUi) : PlanGoalDetailStateUi
}

/** ⇄ TaskChecklist step statuses. */
enum class ChecklistStepStatusUi(val swiftRaw: String) {
    PENDING("pending"),
    IN_PROGRESS("inProgress"),
    COMPLETED("completed"),
    BLOCKED("blocked"),
    CANCELLED("cancelled"),
}

data class ChecklistStepUi(
    val id: String,
    val title: String,
    val status: ChecklistStepStatusUi,
    val evidence: List<String>,
)

data class ChecklistUi(
    val title: String,
    val currentStepTitle: String?,
    val progressSummary: String,
    val steps: List<ChecklistStepUi>,
)

/* --------------------------- children & decisions --------------------------- */

/** Durable delegated-child record (⇄ ChildRunRecord projection). The child
 * state is its own vocabulary — the host resolves the localized title. */
data class ChildRunUi(
    val id: String,
    val parentRunId: String,
    val delegateCallId: String,
    val stateName: String,
    /** Host-localized child-state title (never a raw machine name). */
    val stateTitle: String,
    val isTerminal: Boolean,
    val title: String,
    val summary: String?,
    val startedAtLabel: String,
)

/** A validated decision projected onto its tool call (⇄ ToolDecisionAnnotation).
 * [runId] is null only for legacy uncorrelated rows — presentation then falls
 * back exactly like the Swift helper does. */
data class ToolDecisionUi(
    val id: String,
    val callId: String,
    val runId: String?,
    val proposalId: String,
    /** Raw recorded decision vocabulary ("applied"/"rejected"/…). */
    val decision: String,
    /** Concise decision-specific localized sentence (host-resolved). */
    val summary: String,
)

/** One row of a delegated child's durable transcript (same projection family
 * as the parent thread; opened on demand, never prefetched). */
data class ChildRunDetailUi(
    val childRunId: String,
    val title: String,
    val stateName: String,
    val rows: List<TimelineRowUi>,
)

/* -------------------------------- attachments ------------------------------- */

/** ⇄ AttachmentRef.Kind. */
enum class AttachmentKindUi(val swiftRaw: String) {
    IMAGE("image"),
    DOCUMENT("document"),
    AUDIO("audio"),
    OTHER("other"),
}

/** Host-projected import lifecycle of one staged attachment
 * (CHA-ATTACH-LIFECYCLE-AND: progress, cancel, retry and failure are real;
 * a late callback cannot resurrect a removed row). */
sealed interface AttachmentImportUi {
    /** Bytes durably staged (bookmark/lease held by the host) — sendable. */
    data object Ready : AttachmentImportUi
    /** Ingest running; fraction null when the source cannot report one. */
    data class InProgress(val fraction: Float?) : AttachmentImportUi
    /** Honest failure with host-resolved, secret-free message. */
    data class Failed(val message: String) : AttachmentImportUi
}

/**
 * A composer-staged attachment. Carries the REAL name/MIME/size/digest the host
 * recorded from the picked URI (no JSON-binary fabrication), and its ownership
 * conversation — a staged row never applies to another task.
 */
data class StagedAttachmentUi(
    val id: String,
    val displayName: String,
    val mimeType: String,
    val kind: AttachmentKindUi,
    val byteCount: Long,
    val sha256: String,
    val ownerConversationId: String,
    val import: AttachmentImportUi,
) {
    val isReady: Boolean get() = import == AttachmentImportUi.Ready
    val isProcessing: Boolean get() = import is AttachmentImportUi.InProgress

    /** Digest/name are user-content-derived; keep the default data-class output
     * but never append secret-shaped payloads. (displayName is a file name; the
     * class carries no secret fields by construction.) */
    override fun toString(): String =
        "StagedAttachmentUi(id=$id, kind=${kind.swiftRaw}, bytes=$byteCount, import=${import::class.simpleName})"
}

/** Request to open one persisted message attachment (⇄ ChatAttachmentOpenRequest). */
data class AttachmentOpenRequest(
    val conversationId: String,
    val messageId: String,
    val attachmentId: String?,
) {
    val key: String get() = "$conversationId/$messageId/${attachmentId ?: "missing"}"
}

/* ------------------------------- composer chips ----------------------------- */

/** ⇄ ComposerProject (workspace scope of the conversation; selection of an
 * existing task's workspace is immutable in the thread composer). */
data class ProjectOptionUi(val id: String, val name: String)

/**
 * One selectable model (⇄ ModelProfile via center.providerAndModel). The three
 * identities stay DISTINCT by construction: [modelId] is the saved host UUID,
 * [remoteModelId] the wire id outbound requests use, [displayName] the user
 * label (contract; Android is cloud-only — no local model rows exist here).
 */
data class ModelOptionUi(
    val modelId: String,
    val remoteModelId: String,
    val displayName: String,
    val providerId: String,
    val providerName: String,
    /** Enabled + configured + actually usable (SKL-DISCOVER-USABLE rule for
     * capability chips elsewhere reuses the same availability enum). */
    val isUsable: Boolean,
)

/** ⇄ AgentExecutionMode. */
enum class AgentExecutionModeUi(val swiftRaw: String) {
    AGENT("agent"),
    CHAT("chat"),
    PLAN("plan"),
    GOAL("goal"),
}

/** ⇄ AgentExecutionTarget: only local exists until host remote tools land. */
enum class ExecutionTargetUi(val swiftRaw: String) { LOCAL("local") }

/** ⇄ TaskApprovalMode (taskPolicy.resolvedApprovalMode projection). */
enum class ApprovalModeUi(val swiftRaw: String) {
    ASK("ask"),
    AUTOMATIC("automatic"),
    FULL_ACCESS("fullAccess"),
}

/* ---------------------------------- usage ---------------------------------- */

/** ⇄ ThreadUsageSummary (computed properties preserved). */
data class UsageUi(
    val inputTokens: Int,
    val outputTokens: Int,
    val contextTokens: Int,
    val contextWindowTokens: Int,
    val isEstimatedLive: Boolean,
    val cacheReadTokens: Int? = null,
    val cacheWriteTokens: Int? = null,
    val reasoningTokens: Int? = null,
    val tokensPerSecond: Double? = null,
    val timeToFirstTokenMs: Int? = null,
    val totalDurationMs: Int? = null,
) {
    val totalTokens: Int
        get() = inputTokens + outputTokens + (cacheReadTokens ?: 0) + (cacheWriteTokens ?: 0)

    val contextFraction: Double
        get() = if (contextWindowTokens <= 0) 0.0
        else minOf(1.0, contextTokens.toDouble() / contextWindowTokens.toDouble())

    val cacheHitRate: Double?
        get() {
            val read = cacheReadTokens ?: return null
            val cacheable = inputTokens + read + (cacheWriteTokens ?: 0)
            return if (cacheable <= 0) null else read.toDouble() / cacheable.toDouble()
        }
}

/* -------------------------------- run rows --------------------------------- */

/** ⇄ RunRecord display subset (newest first ordering is host-authoritative). */
data class RunRowUi(
    val id: String,
    /** Raw state-machine name; ONLY presentation reads it through the localizer. */
    val stateName: String,
    val modelId: String?,
    val startedAtLabel: String,
)

/* ------------------------------- timeline rows ------------------------------ */

/**
 * One unified-timeline row (⇄ ThreadTimelineItem). ORDERING (sequence rules,
 * step grouping, dedup, live slots) is computed by the SHARED Swift authority
 * (ThreadTimelineBuilder) and arrives projected; this module never re-derives
 * event order from raw records and never parses payload JSON.
 */
sealed interface TimelineRowUi {
    val id: String

    /** ⇄ .earlierEvents — lazy page affordance for a run's older events.
     * [firstLoadedSequence] is the oldest loaded sequence so far so the module
     * can hand the host an honest EventCursor. */
    data class EarlierEvents(val runId: String, val firstLoadedSequence: Int?) : TimelineRowUi {
        override val id get() = "earlier-events.$runId"
    }

    data class UserMessage(val message: MessageUi) : TimelineRowUi {
        override val id get() = "user.${message.id}"
    }

    /** Final/interim assistant text row (from an assistantText event or a
     * persisted message; [attachedMessageId] links real returned attachments). */
    data class AssistantMessage(
        val rowId: String,
        val text: String,
        val attachedMessageId: String? = null,
        val attachmentChips: List<AttachmentChipUi> = emptyList(),
    ) : TimelineRowUi {
        override val id get() = "assistant.$rowId"
    }

    data class Event(val event: RunEventUi) : TimelineRowUi {
        override val id get() = "event.${event.id}"
    }

    /** Consecutive reasoning/tool events collapsed into one disclosure
     * (⇄ .stepGroup). [events] are already in stored sequence order. */
    data class StepGroup(
        val groupId: String,
        val events: List<RunEventUi>,
        val isLatest: Boolean,
    ) : TimelineRowUi {
        override val id get() = "stepGroup.${events.firstOrNull()?.id ?: "empty"}"
    }

    data class Terminal(val event: RunEventUi) : TimelineRowUi {
        override val id get() = "terminal.${event.id}"
    }

    /** Honest "no final reply" surface (⇄ .missingFinalMessage). */
    data class MissingFinal(val runId: String) : TimelineRowUi {
        override val id get() = "missingFinal.$runId"
    }

    data object LiveReasoning : TimelineRowUi { override val id get() = "live.reasoning" }
    data object LiveAssistantTail : TimelineRowUi { override val id get() = "live.tail" }
    data object LiveThinking : TimelineRowUi { override val id get() = "live.thinking" }

    data class Approval(val card: ApprovalCardUi) : TimelineRowUi {
        override val id get() = "approval.${card.key}"
    }
}

/* ------------------------------ thread snapshot ----------------------------- */

/** ⇄ ConversationMessagePage cursor projected for older-message paging. */
data class MessagePageCursorUi(val createdAtLabel: String, val messageId: String)

/**
 * Everything the host publishes about the ACTIVE conversation at one moment.
 * Presentation state the iOS view model owns (draft, staged attachments,
 * selected model/queue mode, temporary keep state, scroll intent) lives in
 * [ConversationFlowHolder], not here; durable facts live here.
 */
data class ThreadUiState(
    val session: ConversationSessionToken,
    val taskTitle: String,
    val isTemporary: Boolean,
    /** The host's active temporary-session incarnation id, or null when no
     * temporary session owns this conversation. Send-origin and keep/end
     * fences compare against it (late callbacks cannot touch a replacement
     * generation that reused the same id). */
    val temporaryIncarnationId: String?,
    /** ⇄ center.lastPromotedConversationID: the conversation this host just
     * atomically promoted, if any. */
    val promotedConversationId: String?,
    /** ⇄ isConversationMissing: the durable parent row is gone. */
    val isConversationMissing: Boolean,
    val hasLoaded: Boolean,
    /** ⇄ hasProviderActivity: any provider bytes have arrived this run. */
    val hasProviderActivity: Boolean,
    /** ⇄ needsProvider: no usable provider+model exists. */
    val needsProvider: Boolean,
    val runs: List<RunRowUi>,
    val selectedRunId: String?,
    /** ⇄ liveStateName (toolbar run-state text). */
    val liveStateName: String?,
    /** ⇄ isRunning (the displayed run is non-terminal). */
    val isRunning: Boolean,
    /** ⇄ isDraining: the animator is finishing a terminal stream display. */
    val isDraining: Boolean,
    /** ⇄ selectedRunWaitingForJobs (durable `awaiting.finite.job:` reason). */
    val selectedRunWaitingForJobs: Boolean,
    val rows: List<TimelineRowUi>,
    /** Pending approvals of the SELECTED run (host-scoped filter like the VM). */
    val pendingApprovals: List<ApprovalCardUi>,
    val pendingInputs: List<PendingInputUi>,
    val models: List<ModelOptionUi>,
    val projects: List<ProjectOptionUi>,
    /**
     * The host's AUTHORITATIVE workspace binding for this task, or null when
     * the task is genuinely unbound. This is deliberately an explicit
     * projection, NOT something the presentation may infer: repository policy
     * forbids silently choosing the first project (FloeEnvironments resolves
     * session → project → shared → base with an explicit write layer, and an
     * existing task's ownership is immutable here). The composer initializes
     * its locked selection ONLY from this binding; a null stays an honest
     * "no workspace" display and a null workspaceId on the launch request.
     */
    val boundWorkspaceId: String? = null,
    val approvalMode: ApprovalModeUi,
    val usage: UsageUi?,
    /** Context window known before the first usage receipt (ring stays
     * available without inventing tokens). */
    val contextUsage: UsageUi?,
    /** ⇄ compactionStatus — host-resolved localized line. */
    val compactionStatus: String?,
    /** ⇄ canContinue inputs: durable state + live ownership. */
    val canContinue: Boolean,
    val continuationTitle: String?,
    val continuationDetail: String?,
    val hasEarlierMessages: Boolean,
    val loadingEarlierMessages: Boolean,
    /** ⇄ loadingEventRunIDs: per-run older-event pages in flight. */
    val loadingEventRunIds: Set<String>,
    val earlierMessageCursor: MessagePageCursorUi?,
    val importantFiles: List<ImportantFileUi>,
    val checklist: ChecklistUi?,
    val plan: PlanUi?,
    val goal: GoalUi?,
    val childRuns: List<ChildRunUi>,
    val decisions: List<ToolDecisionUi>,
    /** On-demand delegated-child transcripts, published per load request. */
    val childDetails: Map<String, ChildRunDetailUi> = emptyMap(),
    /** ⇄ liveStreamedText / liveReasoningText (host display buffers). */
    val liveAssistantText: String,
    val liveReasoningText: String,
    /** Honest availability of the shared-core network/bridge actions. */
    val networkActionsAvailable: Boolean,
    /** ⇄ usesLocalModel — always false on Android (cloud-only); kept as an
     * explicit projection so bindings cannot silently invent the flag. */
    val usesLocalModel: Boolean,
    /** ⇄ Voice availability for this host build (Apple speech service has no
     * Android product implementation; false until a real adapter exists). */
    val voiceAvailable: Boolean,
    /** ⇄ skill-capability availability surfaced in chat selectors
     * (enabled+configured+usable; admin pages are a later package). */
    val capabilityChips: List<CapabilityChipUi>,
    /** The proven durable task-policy CAS pair (`taskPolicy.<uuid>` /
     * `updatedAt`) read ONLY from an actual `conversation.get` taskPolicy
     * row or `run.snapshot` `policyRevision`. Null = no proven revision:
     * a policy update refuses instead of sending a fabricated version. */
    val taskPolicyRevision: Revision? = null,
    /** Native raw vocabulary of the persisted row (absent = unknown; NEVER
     * a guessed default — the display shows the raw machine value only in
     * diagnostics, an honest pending line otherwise). */
    val taskRecoveryPolicyRaw: String? = null,
    val taskNotificationPolicyRaw: String? = null,
    /** `conversation.get` availability vocabulary
     * ("projected"/"trimmed"/"absent"), verbatim from the reply. TRIMMING
     * is never conflated with ABSENCE: a trimmed page shows its counts as
     * honestly incomplete and offers the bounded detail read; an absent
     * page shows nothing. Null = a legacy reply without the members. */
    val planAvailabilityRaw: String? = null,
    val goalAvailabilityRaw: String? = null,
    /** Per-run post-run goal-REVIEW/continuation registry activity from the
     * authoritative `run.snapshot` (`none`/`active`/`stopping`). This is
     * the REAL activity readback: an inactive goal STATUS is not a stopped
     * proof, `alreadyRequested` is not a settled proof, and flipping to
     * `none` is the only settlement proof. Runs the native reply omits
     * simply have no entry (never assumed active or settled). */
    val goalReviewByRun: Map<String, String> = emptyMap(),
)

/** ⇄ ImportantFileShortcut (host-projected working set; this module never
 * decodes tool payloads to compute it). */
data class ImportantFileUi(val path: String, val action: String)

/** Usable-capability chip projection (SKL-DISCOVER-USABLE vocabulary). */
data class CapabilityChipUi(
    val id: String,
    val label: String,
    /** ⇄ core.contracts Availability — unavailable/needs-config rows render
     * honestly disabled, never fake-enabled. */
    val availability: com.floe.android.contracts.Availability,
)

/* ------------------------------ draft restore ------------------------------- */

/**
 * Durable draft the host restores when a thread opens (⇄ ComposerDraftStore
 * entry load at init). [text] is sensitive user content: masked in toString.
 */
data class ComposerDraftSeedUi(
    val text: String,
    val attachments: List<StagedAttachmentUi>,
    val caretIndex: Int?,
    val selectionLength: Int?,
) {
    override fun toString(): String =
        "ComposerDraftSeedUi(chars=${text.length}, attachments=${attachments.size})"
}

/* ----------------------------- history projections -------------------------- */

/** One sidebar/Chat-list conversation (⇄ ConversationRecord subset). */
data class ConversationListItemUi(
    val id: String,
    val title: String,
    val updatedAtLabel: String,
    /** ⇄ ConversationActivityBadge projected state (live run, or durable latest
     * run state with terminal stopReason/goal overrides resolved by the host). */
    val projectedStateName: String?,
    val isArchived: Boolean,
    val archivedAtLabel: String?,
)

/** ⇄ ConversationTaskBulkService.runningCount(among:) input. */
enum class TaskBulkOperationUi(val swiftRaw: String) { ARCHIVE("archive"), RESTORE("restore"), DELETE("delete") }

/** ⇄ TaskBulkSkipReason. */
enum class BulkSkipReasonUi { ALREADY_GONE, ALREADY_IN_TARGET_STATE, NOT_MANAGED_HERE }

/** ⇄ TaskBulkItemOutcome. */
sealed interface BulkItemOutcomeUi {
    data object Archived : BulkItemOutcomeUi
    data object Restored : BulkItemOutcomeUi
    data object Deleted : BulkItemOutcomeUi
    data class Skipped(val reason: BulkSkipReasonUi) : BulkItemOutcomeUi
    data class Failed(val message: String) : BulkItemOutcomeUi
    /** Attempted but durable state unprovable — never success, never gone. */
    data class Unverified(val message: String) : BulkItemOutcomeUi
    data object NotAttempted : BulkItemOutcomeUi

    /** ⇄ isResolved: acted on, provably needs no action, or was never managed
     * here. `unverified` is NOT resolved: it may not even have been applied. */
    val isResolved: Boolean
        get() = this is Archived || this is Restored || this is Deleted || this is Skipped

    /** Display-ready issue line, null for clean resolutions. */
    val issueText: String?
        get() = when (this) {
            is Failed -> message
            is Unverified -> message
            else -> null
        }
}

data class BulkItemResultUi(
    val conversationId: String,
    val title: String,
    val outcome: BulkItemOutcomeUi,
)

/** ⇄ TaskBulkSummary: one batch receipt. Counts/selection rules mirror the
 * Swift pure logic exactly (Kotlin never executes it; the host publishes the
 * receipt after running the existing single-target commands). */
data class BulkReceiptUi(
    val operation: TaskBulkOperationUi,
    val results: List<BulkItemResultUi>,
    val wasCancelled: Boolean,
) {
    val isEmpty: Boolean get() = results.isEmpty()

    val archivedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Archived }
    val restoredCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Restored }
    val deletedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Deleted }
    val skippedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Skipped }
    val failedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Failed }
    val notAttemptedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.NotAttempted }
    val unverifiedCount: Int get() = results.count { it.outcome is BulkItemOutcomeUi.Unverified }

    /** Resolved identities leave the selection… */
    val removedIds: Set<String> get() = results.filter { it.outcome.isResolved }.map { it.conversationId }.toSet()

    /** …unresolved ones stay selected for a truthful retry. */
    val retainedIds: Set<String> get() = results.filter { !it.outcome.isResolved }.map { it.conversationId }.toSet()

    val unresolvedItems: List<BulkItemResultUi> get() = results.filter { it.outcome.issueText != null }
}

/** Host projection of in-flight batch progress. */
data class BulkProgressUi(val operation: TaskBulkOperationUi, val token: Long, val doneCount: Int, val totalCount: Int)

/**
 * Everything the Chat/history surface renders at one moment. Selection,
 * edit-mode, confirmation freeze, search query and receipts stay in
 * [ConversationHistoryHolder] (presentation RAM); durable rows arrive here.
 */
data class HistoryListUiState(
    val isLoading: Boolean,
    val items: List<ConversationListItemUi>,
    val archivedItems: List<ConversationListItemUi>,
    /** Host CJK-capable content search results (⇄ matchingConversationSnippets),
     * keyed by conversation id; [searchEpoch] echoes the request epoch so a
     * stale page for an earlier query cannot land on a newer one. */
    val contentSnippets: Map<String, String>,
    val searchEpoch: Long,
    val isSearching: Boolean,
    val needsProvider: Boolean,
    /** Conversation ids with live runs (delete/archive impact wording only). */
    val runningConversationIds: Set<String>,
    val bulkProgress: BulkProgressUi?,
    val networkActionsAvailable: Boolean,
)
