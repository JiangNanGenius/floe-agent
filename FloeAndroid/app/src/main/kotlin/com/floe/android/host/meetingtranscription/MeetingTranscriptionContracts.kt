// SPDX-License-Identifier: MPL-2.0
//
// Public contracts for independent meeting cloud transcription.
//
// A meeting is not a task, project, conversation or G09 media project. The
// only identity here is the meeting ID + material ID pair resolved by the
// meeting store; no path, task ID or utterance owner enters this API.
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MeetingTranscriptionReceipt

/** Observable phase of the single process-wide meeting transcription owner. */
enum class MeetingTranscriptionPhase {
    IDLE,
    PREPARING,
    TRANSCRIBING,
    FINALIZING,
    CANCELLING,
    COMPLETED,
    FAILED,
    CANCELLED,
}

/**
 * One active transcription session.
 *
 * [completedChunks] is an exact count of chunks accepted by the cloud route.
 * [totalChunks] is an estimate until the native chunker reports its real
 * final total; it is never presented as a completed count.
 */
data class MeetingTranscriptionSession(
    val meetingId: String,
    val materialId: String,
    val startedAtMillis: Long,
    val completedChunks: Int,
    val totalChunks: Int,
    val progress: Double,
)

/** Typed, bounded failure vocabulary. Provider bodies and URLs never enter it. */
enum class MeetingTranscriptionFailureCode {
    INVALID_IDENTIFIER,
    INVALID_REQUEST,
    NOT_FOUND,
    BUSY,
    NOT_CONFIGURED,
    CREDENTIAL_MISSING,
    UNSUPPORTED_MODEL,
    TRANSPORT_UNAVAILABLE,
    CORE_UNAVAILABLE,
    NEEDS_CORE_UPDATE,
    SOURCE_UNAVAILABLE,
    SOURCE_UNREADABLE,
    UNSUPPORTED_AUDIO,
    SOURCE_TOO_LARGE,
    PROVIDER_REJECTED,
    AUTHENTICATION,
    QUOTA_OR_RATE_LIMITED,
    NETWORK,
    TIMEOUT,
    EMPTY_TRANSCRIPT,
    NO_TIMED_TRANSCRIPT,
    STALE_REVISION,
    STORAGE_FAILURE,
    CANCELLED,
    INTERNAL,
}

data class MeetingTranscriptionFailure(
    val code: MeetingTranscriptionFailureCode,
    /** Lane-authored bounded reason; safe for diagnostics and UI details. */
    val reason: String? = null,
    val retryable: Boolean = false,
)

/** Only failure type thrown by [MeetingTranscriptionManager.transcribe]. */
class MeetingTranscriptionException(
    val failure: MeetingTranscriptionFailure,
    cause: Throwable? = null,
) : Exception(
    "${failure.code}${failure.reason?.let { ":$it" } ?: ""}",
    cause,
)

data class MeetingTranscriptionState(
    val phase: MeetingTranscriptionPhase = MeetingTranscriptionPhase.IDLE,
    val session: MeetingTranscriptionSession? = null,
    val failure: MeetingTranscriptionFailure? = null,
    val receipt: MeetingTranscriptionReceipt? = null,
)

/**
 * Cheap readiness result for disabling/explaining the transcription action
 * before an operation is created. It never requests a provider completion.
 */
sealed interface MeetingTranscriptionReadiness {
    data class Ready(
        val meetingId: String,
        val materialId: String,
        val providerName: String,
        val durationMillis: Long,
        val transcriptionRevision: Long,
    ) : MeetingTranscriptionReadiness

    data class Unavailable(
        val failure: MeetingTranscriptionFailure,
    ) : MeetingTranscriptionReadiness
}
