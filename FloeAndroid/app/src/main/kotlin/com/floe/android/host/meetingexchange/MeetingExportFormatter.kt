// SPDX-License-Identifier: MPL-2.0
//
// Pure, Android-free document rendering. The same snapshot and labels always
// produce the same text and file name. Missing notes or a missing transcript
// are rendered as explicit statements, never as invented transcript lines.
package com.floe.android.host.meetingexchange

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Rendering limits are checked before a large document is handed onward. */
internal class MeetingExportSizeException : Exception("exportTooLarge")

internal object MeetingExportFormatter {
    /**
     * The meeting store already bounds notes at 1,000,000 characters and
     * transcript text at roughly 4,000,000 characters. 6,000,000 leaves room
     * for headings/metadata and rejects a caller-fabricated oversized record
     * before a multi-megabyte document is materialized.
     */
    const val MAX_EXPORT_CHARS = 6_000_000

    /** Honest output cap; a larger meeting is refused instead of truncated. */
    const val MAX_EXPORT_BYTES = 24L * 1024L * 1024L

    private const val MAX_STEM_UTF8_BYTES = 120
    private const val MAX_DISPLAY_TITLE_CHARS = 200
    private const val MAX_SPEAKER_CHARS = 80

    private val timestampFormat: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss xxx", Locale.ROOT)
    private val dateTagFormat: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd", Locale.ROOT)
    private val whitespace = Regex("\\s+")

    fun format(
        snapshot: MeetingExportSnapshot,
        format: MeetingExportFormat,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ): MeetingExportDocument {
        val title = displayTitle(snapshot.title, labels.untitledMeeting)
        val notes = snapshot.notes
        val hasNotes = notes.isNotBlank()
        val segments = snapshot.segments.filter { it.text.isNotBlank() }
        val hasTranscript = segments.isNotEmpty()
        val builder = BoundedText(MAX_EXPORT_CHARS)

        when (format) {
            MeetingExportFormat.TXT ->
                appendTxt(builder, snapshot, title, notes, hasNotes, segments, labels, zoneId)
            MeetingExportFormat.MARKDOWN ->
                appendMarkdown(builder, snapshot, title, notes, hasNotes, segments, labels, zoneId)
            else ->
                // Document formats render through MeetingDocumentExport; this
                // text path never sees them.
                throw MeetingExportSizeException()
        }

        val text = builder.build()
        val byteCount = text.toByteArray(Charsets.UTF_8).size.toLong()
        if (byteCount <= 0L || byteCount > MAX_EXPORT_BYTES) {
            throw MeetingExportSizeException()
        }
        return MeetingExportDocument(
            meetingId = snapshot.meetingId,
            meetingRevision = snapshot.revision,
            title = title,
            format = format,
            suggestedFileName = fileName(title, snapshot.createdAtMillis, format, labels, zoneId),
            text = text,
            binary = null,
            byteCount = byteCount,
            hasNotes = hasNotes,
            hasTranscript = hasTranscript,
        )
    }

    /**
     * Safe display-name stem plus a local creation date and the format suffix.
     * The title is user content: separators, controls, bidirectional overrides
     * and Windows/Android-reserved punctuation are removed before the name is
     * handed to the system picker. The UTF-8 stem is capped so a long CJK or
     * emoji title cannot exceed a normal filesystem name limit.
     */
    fun fileName(
        title: String,
        createdAtMillis: Long,
        format: MeetingExportFormat,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ): String {
        val stem = safeStem(title, labels.untitledMeeting)
        val date = Instant.ofEpochMilli(createdAtMillis.coerceAtLeast(0L))
            .atZone(zoneId)
            .format(dateTagFormat)
        return "$stem-$date.${format.extension}"
    }

    fun formatTimestamp(millis: Long, zoneId: ZoneId): String =
        Instant.ofEpochMilli(millis.coerceAtLeast(0L))
            .atZone(zoneId)
            .format(timestampFormat)

    /** A stable clock label without locale-dependent digits. */
    fun formatClock(millis: Long): String {
        val totalSeconds = millis.coerceAtLeast(0L) / 1_000L
        val hours = totalSeconds / 3_600L
        val minutes = (totalSeconds % 3_600L) / 60L
        val seconds = totalSeconds % 60L
        return "${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}"
    }

    private fun appendTxt(
        builder: BoundedText,
        snapshot: MeetingExportSnapshot,
        title: String,
        notes: String,
        hasNotes: Boolean,
        segments: List<MeetingExportSegment>,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ) {
        builder.line(title)
        builder.line("=".repeat(title.length.coerceIn(3, 60)))
        builder.line()
        builder.line("${labels.created}: ${formatTimestamp(snapshot.createdAtMillis, zoneId)}")
        builder.line("${labels.updated}: ${formatTimestamp(snapshot.updatedAtMillis, zoneId)}")
        builder.line("${labels.materials}: ${snapshot.materialCount}")
        builder.line("${labels.recordings}: ${snapshot.recordingCount}")
        builder.line("${labels.imports}: ${snapshot.importCount}")
        builder.line()
        builder.line(labels.notesHeading)
        builder.line("-".repeat(labels.notesHeading.length.coerceIn(3, 40)))
        builder.line(if (hasNotes) notes else labels.noNotes)
        builder.line()
        builder.line(labels.transcriptHeading)
        builder.line("-".repeat(labels.transcriptHeading.length.coerceIn(3, 40)))
        if (segments.isEmpty()) {
            builder.line(labels.noTranscript)
        } else {
            segments.forEach { segment ->
                val speaker = speakerLabel(segment.speaker, labels.speakerFallback)
                val start = formatClock(segment.startMillis)
                val end = formatClock(segment.endMillis.coerceAtLeast(segment.startMillis))
                builder.line("[$start – $end] $speaker: ${segment.text}")
            }
        }
    }

    private fun appendMarkdown(
        builder: BoundedText,
        snapshot: MeetingExportSnapshot,
        title: String,
        notes: String,
        hasNotes: Boolean,
        segments: List<MeetingExportSegment>,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ) {
        builder.line("# $title")
        builder.line()
        builder.line("- **${labels.created}:** ${formatTimestamp(snapshot.createdAtMillis, zoneId)}")
        builder.line("- **${labels.updated}:** ${formatTimestamp(snapshot.updatedAtMillis, zoneId)}")
        builder.line("- **${labels.materials}:** ${snapshot.materialCount}")
        builder.line("- **${labels.recordings}:** ${snapshot.recordingCount}")
        builder.line("- **${labels.imports}:** ${snapshot.importCount}")
        builder.line()
        builder.line("## ${labels.notesHeading}")
        builder.line()
        builder.line(if (hasNotes) notes else labels.noNotes)
        builder.line()
        builder.line("## ${labels.transcriptHeading}")
        builder.line()
        if (segments.isEmpty()) {
            builder.line(labels.noTranscript)
        } else {
            segments.forEach { segment ->
                val speaker = speakerLabel(segment.speaker, labels.speakerFallback)
                val start = formatClock(segment.startMillis)
                val end = formatClock(segment.endMillis.coerceAtLeast(segment.startMillis))
                builder.line("- `[$start – $end]` **$speaker:** ${segment.text}")
            }
        }
    }

    internal fun displayTitle(raw: String, fallback: String): String {
        val cleaned = raw
            .map { if (it.isDisplayControl()) ' ' else it }
            .joinToString("")
            .replace(whitespace, " ")
            .trim()
            .take(MAX_DISPLAY_TITLE_CHARS)
            .trim()
        return cleaned.ifBlank { fallback }
    }

    internal fun speakerLabel(raw: String?, fallback: String): String {
        val cleaned = raw
            ?.map { if (it.isDisplayControl()) ' ' else it }
            ?.joinToString("")
            ?.replace(whitespace, " ")
            ?.trim()
            ?.take(MAX_SPEAKER_CHARS)
            ?.trim()
        return cleaned?.ifBlank { fallback } ?: fallback
    }

    private fun safeStem(raw: String, fallback: String): String {
        val cleaned = raw
            .map { if (it.isUnsafeFileNameChar()) ' ' else it }
            .joinToString("")
            .replace(whitespace, " ")
            .trim()
            .trim('.', ' ')
        val bounded = truncateUtf8(cleaned.ifBlank { fallback }, MAX_STEM_UTF8_BYTES)
            .trim()
            .trim('.', ' ')
        return bounded.ifBlank { "meeting" }
    }

    private fun Char.isUnsafeFileNameChar(): Boolean =
        isDisplayControl() ||
            this == '/' || this == '\\' || this == ':' || this == '*' ||
            this == '?' || this == '"' || this == '<' || this == '>' || this == '|'

    private fun Char.isDisplayControl(): Boolean =
        isISOControl() || isBidiControl() || this == '\u2028' || this == '\u2029' || this == '\u0085'

    private fun Char.isBidiControl(): Boolean =
        this in '\u202A'..'\u202E' || this in '\u2066'..'\u2069'

    private fun truncateUtf8(text: String, maxBytes: Int): String {
        var bytes = 0
        var end = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val chars = Character.charCount(codePoint)
            val size = when {
                codePoint < 0x80 -> 1
                codePoint < 0x800 -> 2
                codePoint < 0x10000 -> 3
                else -> 4
            }
            if (bytes + size > maxBytes) break
            bytes += size
            index += chars
            end = index
        }
        return text.substring(0, end)
    }

    private fun pad2(value: Long): String = value.toString().padStart(2, '0')

    /** Bounds total characters and refuses instead of silently truncating. */
    private class BoundedText(private val limit: Int) {
        private val builder = StringBuilder()

        fun line(value: String = "") {
            append(value)
            append("\n")
        }

        fun append(value: String) {
            if (value.length > limit || builder.length > limit - value.length) {
                throw MeetingExportSizeException()
            }
            builder.append(value)
        }

        fun build(): String = builder.toString()
    }
}
