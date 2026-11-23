// SPDX-License-Identifier: MPL-2.0
//
// Android-free page layout for the lightweight PDF document export. The same
// snapshot always produces the same pages and lines, which keeps the renderer
// deterministic and makes the layout unit-testable without a device: the test
// opens nothing, it verifies the exact text that will be drawn. CJK and Latin
// glyphs use different width estimates so mixed transcripts wrap honestly.
package com.floe.android.host.meetingexchange

import java.time.ZoneId

internal data class MeetingPdfLine(
    val text: String,
    val textSize: Float,
    val bold: Boolean,
)

internal data class MeetingPdfPage(val lines: List<MeetingPdfLine>)

internal data class MeetingPdfLayout(
    val pages: List<MeetingPdfPage>,
    val pageWidth: Int,
    val pageHeight: Int,
) {
    init {
        require(pages.isNotEmpty()) { "pdfLayoutEmpty" }
    }
}

internal object MeetingPdfLayoutBuilder {
    const val PAGE_WIDTH = 595
    const val PAGE_HEIGHT = 842
    const val MARGIN_X = 56f
    const val MARGIN_TOP = 64f
    const val MARGIN_BOTTOM = 64f
    const val TITLE_SIZE = 22f
    const val HEADING_SIZE = 14f
    const val BODY_SIZE = 11f
    const val LINE_HEIGHT_FACTOR = 1.4f

    private const val MAX_PAGES = 400

    fun build(
        snapshot: MeetingExportSnapshot,
        labels: MeetingExportLabels,
        zoneId: ZoneId,
    ): MeetingPdfLayout {
        val paragraphs = MeetingOfficeContent.paragraphs(snapshot, labels, zoneId)
        val usableWidth = PAGE_WIDTH - 2 * MARGIN_X
        val usableHeight = PAGE_HEIGHT - MARGIN_TOP - MARGIN_BOTTOM
        val pages = ArrayList<MeetingPdfPage>()
        var current = ArrayList<MeetingPdfLine>()

        fun flush() {
            if (current.isNotEmpty()) {
                pages += MeetingPdfPage(current)
                current = ArrayList()
            }
        }

        var usedHeight = 0f
        paragraphs.forEach { paragraph ->
            val size = when (paragraph.style) {
                MeetingOfficeParagraphStyle.TITLE -> TITLE_SIZE
                MeetingOfficeParagraphStyle.HEADING -> HEADING_SIZE
                MeetingOfficeParagraphStyle.BODY -> BODY_SIZE
            }
            val bold = paragraph.style != MeetingOfficeParagraphStyle.BODY
            val lineHeight = size * LINE_HEIGHT_FACTOR
            val wrapped = wrap(paragraph.text, size, usableWidth)
            wrapped.forEach { line ->
                if (usedHeight + lineHeight > usableHeight) {
                    if (pages.size + 1 >= MAX_PAGES) throw MeetingExportSizeException()
                    flush()
                    usedHeight = 0f
                }
                current += MeetingPdfLine(line, size, bold)
                usedHeight += lineHeight
            }
        }
        flush()
        return MeetingPdfLayout(
            pages = pages,
            pageWidth = PAGE_WIDTH,
            pageHeight = PAGE_HEIGHT,
        )
    }

    /**
     * Wraps one paragraph to the usable width. Latin text wraps on word
     * boundaries; an overlong word and CJK text wrap by character. The full
     * paragraph content is preserved across the wrapped lines (no truncation).
     */
    internal fun wrap(text: String, textSize: Float, usableWidth: Float): List<String> {
        if (text.isEmpty()) return listOf("")
        val maxWidth = usableWidth.coerceAtLeast(textSize)
        val lines = ArrayList<String>()
        var current = StringBuilder()
        var currentWidth = 0f
        var lastSpaceIndex = -1

        fun charWidth(char: Char): Float = when {
            char.isISOControl() -> 0f
            char.code < 0x2E80 -> textSize * 0.52f
            else -> textSize
        }

        fun breakLine() {
            lines += current.toString().trimEnd()
            current = StringBuilder()
            currentWidth = 0f
            lastSpaceIndex = -1
        }

        text.forEachIndexed { index, char ->
            if (char == '\n') {
                breakLine()
                return@forEachIndexed
            }
            val width = charWidth(char)
            if (currentWidth + width > maxWidth && current.isNotEmpty()) {
                val space = current.lastIndexOf(' ')
                if (space > 0) {
                    val overflow = current.substring(space + 1)
                    lines += current.substring(0, space).trimEnd()
                    current = StringBuilder(overflow)
                    currentWidth = overflow.sumOf { charWidth(it).toDouble() }.toFloat()
                    current.append(char)
                    currentWidth += width
                } else {
                    breakLine()
                    current.append(char)
                    currentWidth = width
                }
            } else {
                current.append(char)
                currentWidth += width
            }
            if (char == ' ') lastSpaceIndex = index
        }
        if (current.isNotEmpty() || lines.isEmpty()) {
            lines += current.toString().trimEnd()
        }
        return lines
    }
}
