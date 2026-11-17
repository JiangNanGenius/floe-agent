// SPDX-License-Identifier: MPL-2.0
//
// User-facing copy for the meeting export/share host. Only typed codes cross
// this boundary; no notes, titles, paths, provider messages or URIs are
// interpolated into a message.
package com.floe.android.host.meetingexchange

import android.content.Context
import com.floe.android.R

object MeetingExportText {
    fun messageRes(code: MeetingExportFailureCode): Int = when (code) {
        MeetingExportFailureCode.INVALID_IDENTIFIER,
        MeetingExportFailureCode.NOT_FOUND -> R.string.meeting_exchange_error_not_found
        MeetingExportFailureCode.READ_FAILED -> R.string.meeting_exchange_error_read_failed
        MeetingExportFailureCode.IDENTITY_MISMATCH -> R.string.meeting_exchange_error_identity_mismatch
        MeetingExportFailureCode.TOO_LARGE -> R.string.meeting_exchange_error_too_large
        MeetingExportFailureCode.MEETING_CHANGED -> R.string.meeting_exchange_error_meeting_changed
        MeetingExportFailureCode.INVALID_DESTINATION -> R.string.meeting_exchange_error_invalid_destination
        MeetingExportFailureCode.WRITE_PERMISSION_MISSING ->
            R.string.meeting_exchange_error_write_permission_missing
        MeetingExportFailureCode.DESTINATION_NOT_EMPTY ->
            R.string.meeting_exchange_error_destination_not_empty
        MeetingExportFailureCode.DESTINATION_UNREADABLE ->
            R.string.meeting_exchange_error_destination_unreadable
        MeetingExportFailureCode.WRITE_FAILED -> R.string.meeting_exchange_error_write_failed
        MeetingExportFailureCode.SHARE_TOO_LARGE -> R.string.meeting_exchange_error_share_too_large
        MeetingExportFailureCode.SHARE_FAILED -> R.string.meeting_exchange_error_share_failed
    }

    fun formatLabelRes(format: MeetingExportFormat): Int = when (format) {
        MeetingExportFormat.TXT -> R.string.meeting_exchange_format_txt
        MeetingExportFormat.MARKDOWN -> R.string.meeting_exchange_format_markdown
    }

    fun message(context: Context, code: MeetingExportFailureCode): String =
        context.getString(messageRes(code))

    fun formatLabel(context: Context, format: MeetingExportFormat): String =
        context.getString(formatLabelRes(format))
}

internal fun meetingExportLabels(context: Context): MeetingExportLabels = MeetingExportLabels(
    created = context.getString(R.string.meeting_exchange_label_created),
    updated = context.getString(R.string.meeting_exchange_label_updated),
    materials = context.getString(R.string.meeting_exchange_label_materials),
    recordings = context.getString(R.string.meeting_exchange_label_recordings),
    imports = context.getString(R.string.meeting_exchange_label_imports),
    notesHeading = context.getString(R.string.meeting_exchange_heading_notes),
    transcriptHeading = context.getString(R.string.meeting_exchange_heading_transcript),
    noNotes = context.getString(R.string.meeting_exchange_no_notes),
    noTranscript = context.getString(R.string.meeting_exchange_no_transcript),
    speakerFallback = context.getString(R.string.meeting_exchange_speaker_fallback),
    untitledMeeting = context.getString(R.string.meeting_exchange_untitled_meeting),
)
