// SPDX-License-Identifier: MPL-2.0
//
// Meeting export models. This package is a disposable delivery layer: it reads
// one explicitly selected durable meeting through the existing meeting store,
// renders a UTF-8 document, and writes it only to a user-selected system
// document or a user-launched share chooser. It owns no meeting storage and
// never constructs a second catalog.
package com.floe.android.host.meetingexchange

import com.floe.android.host.meeting.MeetingDetail

/** The two plain-text interchange forms offered to the user. */
enum class MeetingExportFormat(
    val extension: String,
    val mimeType: String,
) {
    TXT("txt", "text/plain"),
    MARKDOWN("md", "text/markdown"),
}

/**
 * Localized labels for the document body. The formatter is Android-free; the
 * host supplies the labels from the same application resources as the UI, so
 * an export uses the user's current language without embedding English copy
 * in a Japanese/Chinese transcript.
 */
internal data class MeetingExportLabels(
    val created: String,
    val updated: String,
    val materials: String,
    val recordings: String,
    val imports: String,
    val notesHeading: String,
    val transcriptHeading: String,
    val noNotes: String,
    val noTranscript: String,
    val speakerFallback: String,
    val untitledMeeting: String,
)

/**
 * A rendered, immutable export bound to one exact meeting revision.
 *
 * The object intentionally does not expose a path or URI. [text] is the only
 * content payload and is written only to the destination selected for this
 * request. Its `toString` never includes the title, notes or transcript, so an
 * accidental log statement cannot copy private meeting material.
 */
class MeetingExportDocument internal constructor(
    val meetingId: String,
    val meetingRevision: Long,
    val title: String,
    val format: MeetingExportFormat,
    val suggestedFileName: String,
    val text: String,
    val byteCount: Long,
    val hasNotes: Boolean,
    val hasTranscript: Boolean,
) {
    override fun toString(): String =
        "MeetingExportDocument(meeting=$meetingId, format=$format, bytes=$byteCount)"
}

/** A typed failure with no meeting content, path or URI attached. */
data class MeetingExportFailure(
    val code: MeetingExportFailureCode,
    val retryable: Boolean = false,
)

enum class MeetingExportFailureCode {
    INVALID_IDENTIFIER,
    NOT_FOUND,
    READ_FAILED,
    IDENTITY_MISMATCH,
    TOO_LARGE,
    MEETING_CHANGED,
    INVALID_DESTINATION,
    WRITE_PERMISSION_MISSING,
    DESTINATION_NOT_EMPTY,
    DESTINATION_UNREADABLE,
    WRITE_FAILED,
    SHARE_TOO_LARGE,
    SHARE_FAILED,
}

sealed interface MeetingExportPreparationResult {
    data class Ready(val document: MeetingExportDocument) : MeetingExportPreparationResult

    data class Failed(val failure: MeetingExportFailure) : MeetingExportPreparationResult
}

/**
 * One system document creation attempt.
 *
 * [requestId] makes a stale Activity result distinguishable from the current
 * request. The request also carries the exact meeting snapshot it was created
 * from; a result can never silently switch to whichever meeting is selected
 * later. UI code should keep this object in the composition that launched the
 * picker, call [MeetingExchange.acceptDocumentResult] with the current meeting
 * id, and clear the reference after the callback so the text snapshot is not
 * retained for longer than the export attempt.
 */
class MeetingDocumentRequest internal constructor(
    val requestId: String,
    val meetingId: String,
    val format: MeetingExportFormat,
    val suggestedFileName: String,
    val mimeType: String,
    internal val document: MeetingExportDocument,
) {
    init {
        require(meetingId == document.meetingId) { "requestMeetingMismatch" }
        require(format == document.format) { "requestFormatMismatch" }
        require(suggestedFileName == document.suggestedFileName) { "requestNameMismatch" }
    }

    override fun toString(): String =
        "MeetingDocumentRequest(meeting=$meetingId, format=$format)"
}

/**
 * An OS picker result that was accepted for this exact meeting snapshot.
 *
 * [uri] is the user-selected document. It is not logged by this package and is
 * only opened for the bounded write. The raw URI is kept here because the
 * writer needs it; callers should not display it as a path. Clear the target
 * reference after the write result so neither the URI nor the text snapshot is
 * retained by UI state.
 */
class MeetingDocumentTarget internal constructor(
    val requestId: String,
    val meetingId: String,
    val format: MeetingExportFormat,
    internal val uri: String,
    val suggestedFileName: String,
    internal val document: MeetingExportDocument,
) {
    init {
        require(meetingId == document.meetingId) { "targetMeetingMismatch" }
        require(format == document.format) { "targetFormatMismatch" }
        require(suggestedFileName == document.suggestedFileName) { "targetNameMismatch" }
    }

    override fun toString(): String =
        "MeetingDocumentTarget(meeting=$meetingId, format=$format, bytes=${document.byteCount})"
}

sealed interface MeetingDocumentDestinationResult {
    data class Ready(val target: MeetingDocumentTarget) : MeetingDocumentDestinationResult

    data object Cancelled : MeetingDocumentDestinationResult

    data class Rejected(val failure: MeetingExportFailure) : MeetingDocumentDestinationResult
}

sealed interface MeetingDocumentWriteResult {
    /** The provider accepted every byte and the read-back matched exactly. */
    data class Written(
        val bytes: Long,
        val sha256: String,
    ) : MeetingDocumentWriteResult

    data class Failed(val failure: MeetingExportFailure) : MeetingDocumentWriteResult
}

sealed interface MeetingShareResult {
    /**
     * The system chooser was handed to the OS. This never means a recipient
     * read, received or saved the text; the user still has to choose an app.
     */
    data object ChooserOpened : MeetingShareResult

    data class Failed(val failure: MeetingExportFailure) : MeetingShareResult
}

/** A snapshot of only the selected meeting's durable, user-visible fields. */
internal data class MeetingExportSnapshot(
    val meetingId: String,
    val title: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val notes: String,
    val revision: Long,
    val materialCount: Int,
    val recordingCount: Int,
    val importCount: Int,
    val segments: List<MeetingExportSegment>,
) {
    companion object {
        fun from(detail: MeetingDetail): MeetingExportSnapshot = MeetingExportSnapshot(
            meetingId = detail.id,
            title = detail.title,
            createdAtMillis = detail.createdAtMillis,
            updatedAtMillis = detail.updatedAtMillis,
            notes = detail.notes,
            revision = detail.revision,
            materialCount = detail.materials.size,
            recordingCount = detail.recordings.size,
            importCount = detail.imports.size,
            segments = detail.transcription.segments.map { segment ->
                MeetingExportSegment(
                    startMillis = segment.startMillis,
                    endMillis = segment.endMillis,
                    text = segment.text,
                    speaker = segment.speaker,
                )
            },
        )
    }
}

internal data class MeetingExportSegment(
    val startMillis: Long,
    val endMillis: Long,
    val text: String,
    val speaker: String?,
)
