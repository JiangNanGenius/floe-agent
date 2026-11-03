// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import java.util.Locale

/**
 * User-visible labels for the generated Markdown. The App supplies localized
 * resources; the defaults keep direct callers/tests deterministic and are the
 * same meaning in English.
 */
public data class NotesMarkdownLabels(
    public val pageHeadingFormat: String = "Page %1\$d",
    public val emptyPage: String = "No text content on this page.",
    public val imageOmitted: String =
        "Image not included in Markdown. Use PDF, Page Image, or the editable note to keep it.",
    public val shapeOmitted: String =
        "Drawing shape not included in Markdown. Use PDF or Page Image to keep it.",
    public val inkOmitted: String =
        "Handwriting on this page is not included in Markdown. Use PDF or Page Image to keep it.",
    public val backgroundImageOmitted: String =
        "This page’s background image is not included in Markdown. Use PDF or Page Image to keep it.",
    public val pdfPageOmitted: String =
        "This page’s PDF content is not included in Markdown. Use PDF or Page Image to keep it.",
    public val pdfVisualOmitted: String =
        "This page’s PDF formatting and images are not included in Markdown. Use PDF or Page Image to keep them.",
    public val extractedTextHeading: String = "Text extracted from this page’s source",
    public val recognizedTextHeading: String = "Recognized text from this page",
)

/**
 * Real notebook Markdown export, distinct from the mind-map outline and from
 * plain text.
 *
 * Stored text elements are the authority: Markdown-formatted elements keep
 * their authored structure (headings, lists, links, tables, code) verbatim,
 * while plain text elements are escaped so their characters cannot
 * accidentally become Markdown blocks/inline syntax. Elements are emitted in
 * page reading order (top-to-bottom, then left-to-right, stable on ties).
 *
 * Non-text content is never fabricated and never emits a private file path:
 * images, shapes, page ink and PDF/background pages produce an explicit,
 * actionable limitation line naming an existing format that preserves them.
 * Stored page extraction/OCR text is included only when it actually exists;
 * the export never invents recognized text.
 */
public object NotesNotebookMarkdown {

    public fun build(
        document: NoteDocument,
        labels: NotesMarkdownLabels = NotesMarkdownLabels(),
    ): String = build(document, document.pages, labels)

    /**
     * Build only [pages] in the caller's order. Page headings retain the
     * page's stable document number, so an ordered subset such as
     * `[page-3, page-1]` cannot be mistaken for pages 1 and 2. The default
     * overload above is the whole document.
     */
    public fun build(
        document: NoteDocument,
        pages: List<NotePage>,
        labels: NotesMarkdownLabels = NotesMarkdownLabels(),
    ): String {
        require(document.kind == NoteDocumentKind.NOTEBOOK) {
            "Markdown document export requires a notebook"
        }
        val output = StringBuilder()
        output.append("# ").append(escapeMarkdownPlainText(document.title).replace('\n', ' ')).append("\n\n")
        val numbers = document.pages.mapIndexed { index, page -> page.id to index + 1 }.toMap()
        pages.forEachIndexed { ordinal, page ->
            val number = numbers[page.id] ?: (ordinal + 1)
            output.append("## ").append(pageHeading(labels, number)).append("\n\n")
            val blocks = pageBlocks(document, page, labels)
            if (blocks.isEmpty()) {
                output.append('_').append(labels.emptyPage).append('_').append("\n\n")
            } else {
                blocks.forEach { block ->
                    output.append(block.trimEnd('\n')).append("\n\n")
                }
            }
        }
        return output.toString().trimEnd() + "\n"
    }

    private fun pageHeading(labels: NotesMarkdownLabels, number: Int): String =
        runCatching { String.format(Locale.getDefault(), labels.pageHeadingFormat, number) }
            .getOrDefault("Page $number")

    private fun pageBlocks(
        document: NoteDocument,
        page: NotePage,
        labels: NotesMarkdownLabels,
    ): List<String> {
        val blocks = ArrayList<String>()
        val extracted = page.extractedText?.takeIf { it.isNotBlank() }
        val recognized = page.ocrText?.takeIf { it.isNotBlank() && it != extracted }
        if (extracted != null) {
            blocks += "### " + labels.extractedTextHeading + "\n\n" + escapeMarkdownPlainText(extracted)
        }
        if (recognized != null) {
            blocks += "### " + labels.recognizedTextHeading + "\n\n" + escapeMarkdownPlainText(recognized)
        }
        val ordered = page.elements.withIndex().sortedWith(
            compareBy(
                { it.value.frame.y },
                { it.value.frame.x },
                { it.index },
            ),
        )
        ordered.forEach { (_, element) ->
            val block = when (element.kind) {
                NoteElementKind.TEXT -> textBlock(document, element)
                NoteElementKind.IMAGE -> limitation(labels.imageOmitted)
                NoteElementKind.RECTANGLE,
                NoteElementKind.ELLIPSE,
                NoteElementKind.LINE,
                NoteElementKind.ARROW,
                -> limitation(labels.shapeOmitted)
            }
            if (block.isNotBlank()) blocks += block
        }
        if (page.drawingResourceID != null) {
            blocks += limitation(labels.inkOmitted)
        }
        if (page.pdfPageIndex != null) {
            if (extracted == null && recognized == null) {
                blocks += limitation(labels.pdfPageOmitted)
            } else {
                blocks += limitation(labels.pdfVisualOmitted)
            }
        } else if (page.backgroundResourceID != null) {
            blocks += limitation(labels.backgroundImageOmitted)
        }
        return blocks
    }

    private fun textBlock(document: NoteDocument, element: NoteElement): String {
        val text = resolveElementText(document, element)
        if (text.isBlank()) return ""
        return if (element.isMarkdown) {
            // Authored Markdown is the stored document content: preserve its
            // headings/lists/links/tables instead of flattening or double-escaping it.
            text.trimEnd('\n')
        } else {
            escapeMarkdownPlainText(text)
        }
    }

    private fun limitation(label: String): String = "_" + label + "_"
}

/**
 * Escapes plain text so it renders as the same characters in Markdown. Inline
 * punctuation that starts emphasis/code/links/images/HTML/tables is escaped,
 * and line-start block markers (ATX heading, bullet, block quote, setext
 * rule, ordered-list marker, fence) cannot restructure the exported document.
 * Newlines and all other text are preserved.
 */
public fun escapeMarkdownPlainText(text: String): String {
    val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
    return normalized.split('\n').joinToString("\n") { line -> escapeMarkdownLine(line) }
}

private fun escapeMarkdownLine(line: String): String {
    val inline = StringBuilder(line.length + 8)
    for (character in line) {
        when (character) {
            '\\' -> inline.append("\\\\")
            '`' -> inline.append("\\`")
            '*' -> inline.append("\\*")
            '_' -> inline.append("\\_")
            '[' -> inline.append("\\[")
            ']' -> inline.append("\\]")
            '<' -> inline.append("\\<")
            '>' -> inline.append("\\>")
            '|' -> inline.append("\\|")
            '~' -> inline.append("\\~")
            '&' -> inline.append("&amp;")
            else -> inline.append(character)
        }
    }
    val escaped = inline.toString()
    // CommonMark allows up to three leading spaces before a block marker.
    val leading = escaped.takeWhile { it == ' ' }.length.coerceAtMost(3)
    val rest = escaped.substring(leading)
    if (rest.isEmpty()) return escaped
    val first = rest[0]
    if (first == '#' || first == '-' || first == '+' || first == '=') {
        return escaped.substring(0, leading) + "\\" + escaped.substring(leading)
    }
    val ordered = Regex("^(\\d{1,9})([.)])").find(rest)
    if (ordered != null) {
        val markerIndex = leading + ordered.groupValues[1].length
        return escaped.substring(0, markerIndex) + "\\" + escaped.substring(markerIndex)
    }
    return escaped
}
