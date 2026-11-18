// SPDX-License-Identifier: MPL-2.0
//
// Android-free SAF result admission. The OS result carries only an opaque
// URI + grant; the meeting identity and document snapshot live in the request
// object created before the picker opened. A late result from an old request
// is therefore rejected rather than exporting the newly selected meeting.
package com.floe.android.host.meetingexchange

import java.util.UUID

internal object MeetingDocumentExchange {
    private const val CONTENT_SCHEME = "content://"

    fun request(document: MeetingExportDocument): MeetingDocumentRequest =
        MeetingDocumentRequest(
            requestId = UUID.randomUUID().toString(),
            meetingId = document.meetingId,
            format = document.format,
            suggestedFileName = document.suggestedFileName,
            mimeType = document.format.mimeType,
            document = document,
        )

    /**
     * [selectedMeetingId] is the meeting currently visible in the UI at the
     * moment the picker callback arrives, not the meeting that launched the
     * picker. A mismatch is a stale result and never becomes a write target.
     */
    fun accept(
        request: MeetingDocumentRequest,
        resultOk: Boolean,
        uri: String?,
        hasWriteGrant: Boolean,
        selectedMeetingId: String?,
    ): MeetingDocumentDestinationResult {
        if (!resultOk || uri.isNullOrBlank()) {
            return MeetingDocumentDestinationResult.Cancelled
        }
        if (selectedMeetingId != request.meetingId) {
            return MeetingDocumentDestinationResult.Rejected(
                MeetingExportFailure(MeetingExportFailureCode.MEETING_CHANGED),
            )
        }
        if (!uri.startsWith(CONTENT_SCHEME)) {
            return MeetingDocumentDestinationResult.Rejected(
                MeetingExportFailure(MeetingExportFailureCode.INVALID_DESTINATION),
            )
        }
        if (!hasWriteGrant) {
            return MeetingDocumentDestinationResult.Rejected(
                MeetingExportFailure(MeetingExportFailureCode.WRITE_PERMISSION_MISSING),
            )
        }
        return MeetingDocumentDestinationResult.Ready(
            MeetingDocumentTarget(
                requestId = request.requestId,
                meetingId = request.meetingId,
                format = request.format,
                uri = uri,
                suggestedFileName = request.suggestedFileName,
                document = request.document,
            ),
        )
    }
}
