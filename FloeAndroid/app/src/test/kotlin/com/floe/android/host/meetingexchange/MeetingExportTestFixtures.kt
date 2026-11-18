// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingMaterialKind
import com.floe.android.host.meeting.MeetingMaterialStatus
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import java.time.ZoneId
import kotlinx.coroutines.runBlocking

internal object MeetingExportTestFixtures {
    val LABELS = MeetingExportLabels(
        created = "Created",
        updated = "Updated",
        materials = "Materials",
        recordings = "Recordings",
        imports = "Imports",
        notesHeading = "Notes",
        transcriptHeading = "Transcript",
        noNotes = "No notes were saved for this meeting.",
        noTranscript = "No transcript is available for this meeting.",
        speakerFallback = "Speaker",
        untitledMeeting = "Meeting",
    )

    val UTC: ZoneId = ZoneId.of("UTC")

    const val MEETING_ID = "11111111-1111-1111-1111-111111111111"
    const val OTHER_MEETING_ID = "22222222-2222-2222-2222-222222222222"

    fun detail(
        id: String = MEETING_ID,
        title: String = "Weekly review",
        notes: String = "",
        segments: List<MeetingTranscriptSegment> = emptyList(),
        createdAtMillis: Long = 1_700_000_000_000L,
        updatedAtMillis: Long = createdAtMillis,
        materials: List<MeetingMaterial> = emptyList(),
        recordings: List<MeetingMaterial> = materials.filter { it.kind == MeetingMaterialKind.RECORDING },
        imports: List<MeetingMaterial> = materials.filter { it.kind != MeetingMaterialKind.RECORDING },
        revision: Long = 1L,
        transcriptionRevision: Long = 0L,
    ): MeetingDetail = MeetingDetail(
        id = id,
        title = title,
        createdAtMillis = createdAtMillis,
        updatedAtMillis = updatedAtMillis,
        notes = notes,
        notesRevision = 0L,
        revision = revision,
        transcription = MeetingTranscription(
            revision = transcriptionRevision,
            segments = segments,
        ),
        materials = materials,
        recordings = recordings,
        imports = imports,
    )

    fun segment(
        startMillis: Long = 0L,
        endMillis: Long = 0L,
        text: String,
        speaker: String? = null,
    ): MeetingTranscriptSegment = MeetingTranscriptSegment(
        id = "segment-$startMillis-$text".take(80),
        startMillis = startMillis,
        endMillis = endMillis,
        text = text,
        speaker = speaker,
    )

    fun material(
        id: String,
        kind: MeetingMaterialKind = MeetingMaterialKind.RECORDING,
        displayName: String = "Recording",
        durationMillis: Long = 60_000L,
    ): MeetingMaterial = MeetingMaterial(
        id = id,
        meetingId = MEETING_ID,
        kind = kind,
        displayName = displayName,
        order = 1L,
        createdAtMillis = 1_700_000_000_000L,
        durationMillis = durationMillis,
        sizeBytes = 1_024L,
        status = MeetingMaterialStatus.COMPLETED,
        isPlayable = true,
        mimeType = "audio/mp4",
        incompleteReason = null,
    )

    fun document(
        detail: MeetingDetail,
        format: MeetingExportFormat = MeetingExportFormat.TXT,
    ): MeetingExportDocument {
        val result = runBlocking {
            MeetingExportService(
                readMeeting = { detail },
                labels = LABELS,
                zoneId = UTC,
            ).prepare(detail.id, format)
        }
        check(result is MeetingExportPreparationResult.Ready) { "preparation failed" }
        return result.document
    }

    fun request(
        document: MeetingExportDocument,
    ): MeetingDocumentRequest = MeetingDocumentExchange.request(document)

    fun target(
        document: MeetingExportDocument,
        uri: String = "content://test.provider/document/1",
    ): MeetingDocumentTarget = MeetingDocumentTarget(
        requestId = "request-1",
        meetingId = document.meetingId,
        format = document.format,
        uri = uri,
        suggestedFileName = document.suggestedFileName,
        document = document,
    )
}
