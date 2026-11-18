// SPDX-License-Identifier: MPL-2.0
//
// User-facing copy for typed meeting-transcription failures. The host never
// surfaces provider response bodies, endpoints or credential material.
package com.floe.android.host.meetingtranscription

import android.content.Context
import com.floe.android.R

object MeetingTranscriptionText {
    fun messageRes(failure: MeetingTranscriptionFailure): Int = when (failure.code) {
        MeetingTranscriptionFailureCode.INVALID_IDENTIFIER,
        MeetingTranscriptionFailureCode.INVALID_REQUEST,
        MeetingTranscriptionFailureCode.NOT_FOUND -> R.string.meeting_transcription_source_unavailable
        MeetingTranscriptionFailureCode.BUSY -> R.string.meeting_transcription_busy
        MeetingTranscriptionFailureCode.NOT_CONFIGURED,
        MeetingTranscriptionFailureCode.UNSUPPORTED_MODEL -> R.string.meeting_transcription_unconfigured
        MeetingTranscriptionFailureCode.CREDENTIAL_MISSING,
        MeetingTranscriptionFailureCode.AUTHENTICATION -> R.string.meeting_transcription_credential_missing
        MeetingTranscriptionFailureCode.TRANSPORT_UNAVAILABLE,
        MeetingTranscriptionFailureCode.NETWORK -> R.string.meeting_transcription_service_unavailable
        MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
        MeetingTranscriptionFailureCode.NEEDS_CORE_UPDATE -> R.string.meeting_transcription_core_unavailable
        MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE,
        MeetingTranscriptionFailureCode.SOURCE_UNREADABLE -> R.string.meeting_transcription_source_unavailable
        MeetingTranscriptionFailureCode.UNSUPPORTED_AUDIO -> R.string.meeting_transcription_unsupported_audio
        MeetingTranscriptionFailureCode.SOURCE_TOO_LARGE -> R.string.meeting_transcription_source_too_large
        MeetingTranscriptionFailureCode.PROVIDER_REJECTED -> R.string.meeting_transcription_provider_rejected
        MeetingTranscriptionFailureCode.QUOTA_OR_RATE_LIMITED -> R.string.meeting_transcription_quota_limited
        MeetingTranscriptionFailureCode.TIMEOUT -> R.string.meeting_transcription_timeout
        MeetingTranscriptionFailureCode.EMPTY_TRANSCRIPT,
        MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT -> R.string.meeting_transcription_empty
        MeetingTranscriptionFailureCode.STALE_REVISION -> R.string.meeting_transcription_conflict
        MeetingTranscriptionFailureCode.STORAGE_FAILURE -> R.string.meeting_transcription_storage_failed
        MeetingTranscriptionFailureCode.CANCELLED -> R.string.meeting_transcription_cancelled
        MeetingTranscriptionFailureCode.INTERNAL -> R.string.meeting_transcription_failed
    }

    fun message(context: Context, failure: MeetingTranscriptionFailure): String =
        context.getString(messageRes(failure))
}
