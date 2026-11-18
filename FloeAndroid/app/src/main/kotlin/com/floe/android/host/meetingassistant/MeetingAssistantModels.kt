// SPDX-License-Identifier: MPL-2.0
//
// Meeting assistant presentation/contract models.
//
// The assistant is NOT a new task, project or provider service. One meeting is
// bound to ONE real ordinary conversation/task through the EXISTING run
// domain, and every answer is read back from the durable assistant message.
// These types only carry the bounded projection the meeting page renders; no
// model output, path or provider secret is ever invented here.
package com.floe.android.host.meetingassistant

import com.floe.android.feature.conversation.ModelOptionUi

/** The only three user-visible asks this surface performs. */
internal enum class MeetingAssistantAction { ASK, MINUTES, TODOS }

/**
 * Lifecycle of one recorded assistant turn.
 *
 * [PARTIAL] means a durable assistant message exists but the run did not end
 * in the ordinary `completed` state (for example a checkpoint). [UNRESOLVED]
 * means the answer could not be read yet; it is never rendered as an answer.
 */
internal enum class MeetingAssistantEntryStatus {
    PENDING,
    ANSWERED,
    PARTIAL,
    FAILED,
    CANCELLED,
    UNRESOLVED,
}

/** Closed failure vocabulary; copy is resolved by the page, never raw text. */
internal enum class MeetingAssistantFailureCode {
    RUNTIME_UNAVAILABLE,
    PROVIDERS_NOT_READY,
    NO_TEXT_MODEL,
    MODEL_UNAVAILABLE,
    NO_CONTEXT,
    INVALID_QUESTION,
    PROMPT_TOO_LARGE,
    BUSY,
    CONTEXT_UNAVAILABLE,
    LAUNCH_REFUSED,
    LAUNCH_FAILED,
    STREAM_LOST,
    RESULT_UNREADABLE,
    RUN_FAILED,
    RUN_CANCELLED,
    NO_ANSWER,
    STILL_RUNNING,
    CANCEL_REFUSED,
    HISTORY_UNAVAILABLE,
    STORE_FAILED,
}

/**
 * One typed assistant failure.
 *
 * [detail] is a bounded identifier/reason carried for diagnostics only; the
 * ordinary surface shows the mapped copy and never raw provider text.
 */
internal data class MeetingAssistantFailure(
    val code: MeetingAssistantFailureCode,
    val detail: String? = null,
)

/** One usable text model, projected from the real configured provider rows. */
internal data class MeetingAssistantModelOption(
    val modelId: String,
    val providerId: String,
    val label: String,
)

/** Honest availability of the real assistant route for the current meeting. */
internal sealed interface MeetingAssistantAvailability {
    data object Checking : MeetingAssistantAvailability

    data class Ready(
        val modelId: String,
        val modelLabel: String,
        val models: List<MeetingAssistantModelOption>,
    ) : MeetingAssistantAvailability

    data class NotConfigured(val reason: MeetingAssistantFailureCode) :
        MeetingAssistantAvailability

    data class Unavailable(val reason: MeetingAssistantFailureCode) :
        MeetingAssistantAvailability
}

/**
 * One persisted assistant turn for a meeting.
 *
 * [conversationId]/[runId] always come from the native `prepared` commit, never
 * from model text. [answer] is the exact durable assistant message (bounded);
 * [assistantMessageId] proves which stored row it came from.
 */
internal data class MeetingAssistantEntry(
    val id: String,
    val action: MeetingAssistantAction,
    val question: String,
    val status: MeetingAssistantEntryStatus,
    val answer: String?,
    val createdAtMillis: Long,
    val notesRevision: Long,
    val transcriptRevision: Long,
    val conversationId: String?,
    val runId: String?,
    val failure: MeetingAssistantFailureCode? = null,
    val assistantMessageId: String? = null,
    val answerTruncated: Boolean = false,
)

/** The active turn for one meeting; never shared across meetings. */
internal data class MeetingAssistantTurnView(
    val action: MeetingAssistantAction,
    val phase: MeetingAssistantTurnPhase,
)

internal enum class MeetingAssistantTurnPhase { PREPARING, RUNNING, CANCELLING }

/** The page observes exactly this state for the selected meeting. */
internal data class MeetingAssistantState(
    val meetingId: String? = null,
    val availability: MeetingAssistantAvailability = MeetingAssistantAvailability.Checking,
    val entries: List<MeetingAssistantEntry> = emptyList(),
    val active: MeetingAssistantTurnView? = null,
    val checkingEntryIds: Set<String> = emptySet(),
    val error: MeetingAssistantFailure? = null,
    val historyUnreadable: Boolean = false,
)

/** One durable per-meeting binding plus its bounded local history. */
internal data class MeetingAssistantBinding(
    val conversationId: String?,
    val modelId: String?,
    val entries: List<MeetingAssistantEntry>,
    val unreadable: Boolean = false,
)

/** Result of a host query; `NotReady` is distinct from a real refusal. */
internal sealed interface MeetingAssistantQueryResult<out T> {
    data class Value<T>(val value: T) : MeetingAssistantQueryResult<T>
    data object NotReady : MeetingAssistantQueryResult<Nothing>
}

internal fun ModelOptionUi.toMeetingAssistantModelOption(): MeetingAssistantModelOption =
    MeetingAssistantModelOption(
        modelId = modelId,
        providerId = providerId,
        label = if (providerName.isBlank()) displayName else "$displayName · $providerName",
    )
