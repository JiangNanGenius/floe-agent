// SPDX-License-Identifier: MPL-2.0
//
// Renders one meeting snapshot into a lightweight document (DOCX/PDF) export.
// This is the Android boundary: PDF pages are drawn by the platform
// PdfDocument, DOCX is the pure [MeetingDocumentOffice] writer. The exported
// artifact is a one-way document for the user to open elsewhere — not a
// professional editor project and never a re-importable meeting record.
package com.floe.android.host.meetingexchange

import java.time.ZoneId

internal object MeetingDocumentExport {
    fun render(
        snapshot: MeetingExportSnapshot,
        format: MeetingExportFormat,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ): MeetingExportDocument {
        require(!format.isText) { "textFormatsUseTheTextRenderer" }
        // The same honest content bound as the text formats: a caller-fabricated
        // oversized record is refused before a large document is materialized.
        val contentChars = snapshot.notes.length +
            snapshot.segments.sumOf { it.text.length } + snapshot.title.length
        if (contentChars > MeetingExportFormatter.MAX_EXPORT_CHARS) {
            throw MeetingExportSizeException()
        }
        val title = MeetingExportFormatter.displayTitle(snapshot.title, labels.untitledMeeting)
        val paragraphs = MeetingOfficeContent.paragraphs(snapshot, labels, zoneId)
        val bytes = when (format) {
            MeetingExportFormat.DOCX -> MeetingDocumentOffice.docx(paragraphs)
            MeetingExportFormat.PDF ->
                MeetingPdfExport.render(MeetingPdfLayoutBuilder.build(snapshot, labels, zoneId))
            else -> throw MeetingExportSizeException()
        }
        if (bytes.isEmpty() || bytes.size.toLong() > MeetingExportFormatter.MAX_EXPORT_BYTES) {
            throw MeetingExportSizeException()
        }
        return MeetingExportDocument(
            meetingId = snapshot.meetingId,
            meetingRevision = snapshot.revision,
            title = title,
            format = format,
            suggestedFileName = MeetingExportFormatter.fileName(
                title, snapshot.createdAtMillis, format, labels, zoneId,
            ),
            text = "",
            binary = bytes,
            byteCount = bytes.size.toLong(),
            hasNotes = snapshot.notes.isNotBlank(),
            hasTranscript = snapshot.segments.any { it.text.isNotBlank() },
        )
    }
}
