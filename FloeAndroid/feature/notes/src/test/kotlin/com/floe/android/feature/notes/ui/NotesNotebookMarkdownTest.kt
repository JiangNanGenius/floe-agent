// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.ui.presentation.NotesNotebookMarkdown
import com.floe.android.feature.notes.ui.presentation.escapeMarkdownPlainText
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Notebook Markdown is a real document format: authored Markdown structure is
 * preserved, plain text is escaped so it cannot restructure the document, and
 * non-text content is reported truthfully without private resource paths.
 */
class NotesNotebookMarkdownTest {

    private fun text(
        id: String,
        value: String,
        y: Double = 20.0,
        x: Double = 20.0,
        markdown: Boolean = false,
    ) = NoteElement(
        id = id,
        kind = NoteElementKind.TEXT,
        frame = NoteRect(x = x, y = y, width = 400.0, height = 80.0),
        text = value,
        fontSize = 18.0,
        textFormat = if (markdown) "markdown" else null,
    )

    private fun document(
        pages: List<NotePage>,
        title: String = "My Note",
        kind: NoteDocumentKind = NoteDocumentKind.NOTEBOOK,
    ) = NoteDocument(
        id = "doc-1",
        kind = kind,
        title = title,
        revision = 3,
        pages = pages,
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    @Test
    fun `emits a titled page hierarchy in document order`() {
        val second = NotePage(
            id = "p2",
            elements = listOf(text("e2", "Second page body")),
        )
        val first = NotePage(
            id = "p1",
            elements = listOf(text("e1", "First page body")),
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(first, second)))
        assertTrue(markdown.startsWith("# My Note\n\n## Page 1\n\nFirst page body"))
        assertTrue(markdown.contains("## Page 2\n\nSecond page body"))
        assertTrue(markdown.indexOf("## Page 1") < markdown.indexOf("## Page 2"))
    }

    @Test
    fun `an ordered subset keeps stable page numbers and excludes other pages`() {
        val first = NotePage(id = "p1", elements = listOf(text("e1", "First body")))
        val second = NotePage(id = "p2", elements = listOf(text("e2", "Second body")))
        val third = NotePage(id = "p3", elements = listOf(text("e3", "Third body")))
        val markdown = NotesNotebookMarkdown.build(
            document(listOf(first, second, third)),
            listOf(third, first),
        )
        assertTrue(markdown.contains("## Page 3"))
        assertTrue(markdown.contains("## Page 1"))
        assertFalse(markdown.contains("## Page 2"))
        assertFalse(markdown.contains("Second body"))
        assertTrue(markdown.indexOf("## Page 3") < markdown.indexOf("## Page 1"))
    }

    @Test
    fun `authored markdown structure is preserved verbatim`() {
        val body = """
            # Section

            - one
            - two

            [link](https://example.com)

            | a | b |
            | --- | --- |
            | 1 | 2 |
        """.trimIndent()
        val markdown = NotesNotebookMarkdown.build(
            document(listOf(NotePage(id = "p1", elements = listOf(text("e1", body, markdown = true))))),
        )
        assertTrue(markdown.contains("# Section"))
        assertTrue(markdown.contains("- one\n- two"))
        assertTrue(markdown.contains("[link](https://example.com)"))
        assertTrue(markdown.contains("| a | b |"))
    }

    @Test
    fun `plain text is escaped so it cannot become markdown structure`() {
        val body = "# not a heading\n- not a list\n1. not ordered\n*not emphasis* [not](a link) | not | table |"
        val markdown = NotesNotebookMarkdown.build(
            document(listOf(NotePage(id = "p1", elements = listOf(text("e1", body))))),
        )
        assertTrue(markdown.contains("\\# not a heading"))
        assertTrue(markdown.contains("\\- not a list"))
        assertTrue(markdown.contains("1\\. not ordered"))
        assertTrue(markdown.contains("\\*not emphasis\\*"))
        assertTrue(markdown.contains("\\[not\\](a link)"))
        assertTrue(markdown.contains("\\| not \\| table \\|"))
        assertFalse(markdown.contains("\n# not a heading"))
    }

    @Test
    fun `elements are emitted in reading order not list order`() {
        val page = NotePage(
            id = "p1",
            elements = listOf(
                text("bottom", "bottom text", y = 500.0),
                text("top", "top text", y = 20.0),
                text("left", "left text", y = 100.0, x = 10.0),
                text("right", "right text", y = 100.0, x = 300.0),
            ),
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(page)))
        assertTrue(markdown.indexOf("top text") < markdown.indexOf("left text"))
        assertTrue(markdown.indexOf("left text") < markdown.indexOf("right text"))
        assertTrue(markdown.indexOf("right text") < markdown.indexOf("bottom text"))
    }

    @Test
    fun `image shape ink and background omissions are explicit and path free`() {
        val page = NotePage(
            id = "p1",
            backgroundResourceID = "private/resource/background-hash",
            drawingResourceID = "private/resource/ink-hash",
            elements = listOf(
                NoteElement(
                    id = "image-1",
                    kind = NoteElementKind.IMAGE,
                    frame = NoteRect(x = 10.0, y = 10.0, width = 100.0, height = 100.0),
                    resourceID = "private/resource/image-hash",
                ),
                NoteElement(
                    id = "shape-1",
                    kind = NoteElementKind.RECTANGLE,
                    frame = NoteRect(x = 10.0, y = 200.0, width = 100.0, height = 60.0),
                ),
            ),
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(page)))
        assertTrue(markdown.contains("Image not included in Markdown"))
        assertTrue(markdown.contains("Drawing shape not included in Markdown"))
        assertTrue(markdown.contains("Handwriting on this page is not included in Markdown"))
        assertTrue(markdown.contains("background image is not included in Markdown"))
        assertFalse(markdown.contains("private/resource"))
        assertFalse(markdown.contains(".png"))
    }

    @Test
    fun `stored page text and recognized text are included but never invented`() {
        val withText = NotePage(
            id = "p1",
            extractedText = "Extracted source text",
            ocrText = "Recognized words",
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(withText)))
        assertTrue(markdown.contains("Text extracted from this page’s source"))
        assertTrue(markdown.contains("Extracted source text"))
        assertTrue(markdown.contains("Recognized text from this page"))
        assertTrue(markdown.contains("Recognized words"))

        val withoutText = NotePage(id = "p2")
        val second = NotesNotebookMarkdown.build(document(listOf(withoutText)))
        assertFalse(second.contains("Recognized text from this page"))
        assertFalse(second.contains("Text extracted from this page’s source"))
    }

    @Test
    fun `pdf page with stored text still reports omitted visual content`() {
        val page = NotePage(
            id = "p1",
            pdfPageIndex = 0,
            backgroundResourceID = "pdf-resource",
            extractedText = "Extracted PDF text",
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(page)))
        assertTrue(markdown.contains("Extracted PDF text"))
        assertTrue(markdown.contains("PDF formatting and images are not included in Markdown"))
    }

    @Test
    fun `pdf page without stored text names the existing alternate formats`() {
        val page = NotePage(
            id = "p1",
            pdfPageIndex = 0,
            backgroundResourceID = "pdf-resource",
        )
        val markdown = NotesNotebookMarkdown.build(document(listOf(page)))
        assertTrue(markdown.contains("PDF content is not included in Markdown"))
        assertFalse(markdown.contains("pdf-resource"))
    }

    @Test
    fun `empty page is represented without inventing text`() {
        val markdown = NotesNotebookMarkdown.build(document(listOf(NotePage(id = "p1"))))
        assertTrue(markdown.contains("## Page 1"))
        assertTrue(markdown.contains("No text content on this page."))
    }

    @Test
    fun `plain text escaping leaves ordinary prose readable`() {
        val escaped = escapeMarkdownPlainText("A normal sentence, with punctuation: 100% ready.")
        assertTrue(escaped.contains("A normal sentence, with punctuation: 100% ready."))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `mind map documents are not exported through the notebook builder`() {
        val map = document(
            pages = listOf(NotePage(id = "p1")),
            kind = NoteDocumentKind.MIND_MAP,
        )
        NotesNotebookMarkdown.build(map)
    }
}
