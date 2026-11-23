// SPDX-License-Identifier: MPL-2.0
//
// Shared, Android-free meeting document structure for the lightweight document
// exports (DOCX/PDF). The SAME snapshot always produces the same ordered
// paragraphs, so the two renderers stay consistent with each other and with
// the tagged text exports. Missing notes or a missing transcript stay explicit
// statements; nothing is invented.
package com.floe.android.host.meetingexchange

import java.time.ZoneId

internal enum class MeetingOfficeParagraphStyle { TITLE, HEADING, BODY }

internal data class MeetingOfficeParagraph(
    val text: String,
    val style: MeetingOfficeParagraphStyle,
)

internal object MeetingOfficeContent {
    fun paragraphs(
        snapshot: MeetingExportSnapshot,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ): List<MeetingOfficeParagraph> {
        val title = MeetingExportFormatter.displayTitle(snapshot.title, labels.untitledMeeting)
        val notes = snapshot.notes
        val hasNotes = notes.isNotBlank()
        val segments = snapshot.segments.filter { it.text.isNotBlank() }
        val result = ArrayList<MeetingOfficeParagraph>()
        result += MeetingOfficeParagraph(title, MeetingOfficeParagraphStyle.TITLE)
        result += MeetingOfficeParagraph(
            "${labels.created}: ${MeetingExportFormatter.formatTimestamp(snapshot.createdAtMillis, zoneId)}",
            MeetingOfficeParagraphStyle.BODY,
        )
        result += MeetingOfficeParagraph(
            "${labels.updated}: ${MeetingExportFormatter.formatTimestamp(snapshot.updatedAtMillis, zoneId)}",
            MeetingOfficeParagraphStyle.BODY,
        )
        result += MeetingOfficeParagraph(
            "${labels.materials}: ${snapshot.materialCount} · " +
                "${labels.recordings}: ${snapshot.recordingCount} · " +
                "${labels.imports}: ${snapshot.importCount}",
            MeetingOfficeParagraphStyle.BODY,
        )
        result += MeetingOfficeParagraph("", MeetingOfficeParagraphStyle.BODY)
        result += MeetingOfficeParagraph(labels.notesHeading, MeetingOfficeParagraphStyle.HEADING)
        if (hasNotes) {
            notes.lineSequence().forEach { line ->
                result += MeetingOfficeParagraph(line, MeetingOfficeParagraphStyle.BODY)
            }
        } else {
            result += MeetingOfficeParagraph(labels.noNotes, MeetingOfficeParagraphStyle.BODY)
        }
        result += MeetingOfficeParagraph("", MeetingOfficeParagraphStyle.BODY)
        result += MeetingOfficeParagraph(labels.transcriptHeading, MeetingOfficeParagraphStyle.HEADING)
        if (segments.isEmpty()) {
            result += MeetingOfficeParagraph(labels.noTranscript, MeetingOfficeParagraphStyle.BODY)
        } else {
            segments.forEach { segment ->
                val speaker = MeetingExportFormatter.speakerLabel(segment.speaker, labels.speakerFallback)
                val start = MeetingExportFormatter.formatClock(segment.startMillis)
                val end = MeetingExportFormatter.formatClock(segment.endMillis.coerceAtLeast(segment.startMillis))
                result += MeetingOfficeParagraph(
                    "[$start – $end] $speaker: ${segment.text}",
                    MeetingOfficeParagraphStyle.BODY,
                )
            }
        }
        return result
    }
}
