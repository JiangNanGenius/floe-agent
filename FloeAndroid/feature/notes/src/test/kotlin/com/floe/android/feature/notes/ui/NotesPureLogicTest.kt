// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.presentation.MindMapLayoutDirection
import com.floe.android.feature.notes.ui.presentation.MindMapLayoutEngine
import com.floe.android.feature.notes.ui.presentation.NotesElementGeometry
import com.floe.android.feature.notes.ui.presentation.NotesLibraryFilter
import com.floe.android.feature.notes.ui.presentation.NotesRequestBudget
import com.floe.android.feature.notes.ui.presentation.NotesResizeCorner
import com.floe.android.feature.notes.ui.presentation.NotesSortOrder
import com.floe.android.feature.notes.ui.presentation.coalesceEdits
import com.floe.android.feature.notes.ui.presentation.filterAndSortDocuments
import com.floe.android.feature.notes.ui.presentation.findTextMatches
import com.floe.android.feature.notes.ui.presentation.planElementTextReplacement
import com.floe.android.feature.notes.ui.presentation.planReplaceAll
import com.floe.android.feature.notes.ui.presentation.planTextInsertion
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesPureLogicTest {

    private fun page(id: String = "page-1", elements: List<NoteElement> = emptyList()) =
        NotePage(id = id, elements = elements)

    private fun document(
        pages: List<NotePage> = listOf(page()),
        nodes: List<MindMapNode> = emptyList(),
        connections: List<com.floe.android.feature.notes.MindMapConnection> = emptyList(),
        kind: NoteDocumentKind = NoteDocumentKind.NOTEBOOK,
    ) = NoteDocument(
        id = "doc-1",
        kind = kind,
        title = "Document",
        revision = 3,
        pages = pages,
        nodes = nodes,
        connections = connections,
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    private fun text(id: String, value: String, x: Double = 20.0, y: Double = 20.0) = NoteElement(
        id = id,
        kind = NoteElementKind.TEXT,
        frame = NoteRect(x, y, 240.0, 80.0),
        text = value,
        fontSize = 18.0,
    )

    @Test
    fun `resolves source slices and detaches only the edited element`() {
        val element = NoteElement(
            id = "e1",
            text = "",
            textSourceID = "source-1",
            textSlice = com.floe.android.feature.notes.NoteTextSlice(start = 6, count = 5),
        )
        val doc = document(pages = listOf(page(elements = listOf(element))))
            .copy(textSources = mapOf("source-1" to "hello world"))
        assertEquals("world", resolveElementText(doc, element))

        val plan = planReplaceAll(doc, "world", "there")
        assertEquals(1, plan.replaced)
        val edit = plan.edits.single() as NotesEdit.UpsertElement
        // Detaching keeps the element's visible slice, not the whole shared source.
        assertEquals("there", edit.element.text)
        assertNull(edit.element.textSourceID)
        assertNull(edit.element.textSlice)
    }

    @Test
    fun `find is case-insensitive by default and replace-all is one batch`() {
        val doc = document(pages = listOf(page(elements = listOf(text("e1", "Hello hello")))))
        assertEquals(2, findTextMatches(doc, "hello").size)
        assertEquals(1, findTextMatches(doc, "hello", matchCase = true).size)

        val plan = planReplaceAll(doc, "hello", "bye")
        assertEquals(2, plan.replaced)
        assertEquals(1, plan.edits.size)
        assertEquals("bye bye", (plan.edits.single() as NotesEdit.UpsertElement).element.text)
    }

    @Test
    fun `large text is split into multiple safe blocks without truncation`() {
        val doc = document()
        val text = buildString {
            repeat(300) { append("line ").append(it).append('\n') }
        }
        val plan = planTextInsertion(doc, "page-1", text, markdown = false, ids = countingIds())
        assertTrue(plan.split)
        assertTrue(plan.edits.size > 1)
        val inserted = plan.edits.filterIsInstance<NotesEdit.UpsertElement>()
            .joinToString("") { it.element.text + "\n" }
        assertTrue(inserted.contains("line 299"))
        assertTrue(inserted.replace("\n", "").length >= text.replace("\n", "").length - 4)
    }

    @Test
    fun `replacing an element with a large body keeps the original id and never drops text`() {
        val doc = document()
        val original = text("e1", "short")
        val huge = "x".repeat(5_000)
        val plan = planElementTextReplacement(doc, "page-1", original, huge, markdown = false, ids = countingIds())
        assertTrue(plan.split)
        val first = plan.edits.first() as NotesEdit.UpsertElement
        assertEquals("e1", first.element.id)
        assertTrue(first.element.text.length <= 1_200)
        assertTrue(plan.edits.size >= 4)
    }

    @Test
    fun `request budget splits batches and keeps order`() {
        val edits = (0 until 12).map { index ->
            NotesEdit.UpsertElement(
                pageID = "page-1",
                element = text("e$index", "y".repeat(2_000)),
            )
        }
        val chunks = NotesRequestBudget.split(edits, budget = NotesRequestBudget.SAFE_BATCH_BYTES)
        assertTrue(chunks.size > 1)
        assertEquals(edits.size, chunks.sumOf { it.size })
        assertEquals(edits.map { (it as NotesEdit.UpsertElement).element.id }, chunks.flatten().map {
            (it as NotesEdit.UpsertElement).element.id
        })
    }

    @Test
    fun `coalescing keeps the latest full-value edit and drops page children`() {
        val first = text("e1", "first")
        val second = text("e1", "second")
        val coalesced = coalesceEdits(
            listOf(
                NotesEdit.UpsertElement("page-1", first),
                NotesEdit.UpsertElement("page-1", second),
            ),
        )
        assertEquals(1, coalesced.size)
        assertEquals("second", (coalesced.single() as NotesEdit.UpsertElement).element.text)

        val deleteAfterEdit = coalesceEdits(
            listOf(
                NotesEdit.UpsertElement("page-1", first),
                NotesEdit.Drawing("page-1", "resource-1"),
                NotesEdit.DeletePage("page-1"),
            ),
        )
        assertEquals(1, deleteAfterEdit.size)
        assertTrue(deleteAfterEdit.single() is NotesEdit.DeletePage)
    }

    @Test
    fun `geometry hit-tests, clamps moves and resizes from a corner`() {
        val element = text("e1", "text")
        val target = page(elements = listOf(element))
        assertEquals("e1", NotesElementGeometry.hitTest(target, 30.0, 30.0)?.id)
        assertNull(NotesElementGeometry.hitTest(target, 500.0, 500.0))

        val moved = NotesElementGeometry.moveSelected(target, setOf("e1"), 1_000.0, -1_000.0)["e1"]!!
        assertEquals(target.width - element.frame.width, moved.x, 0.001)
        assertEquals(0.0, moved.y, 0.001)

        val resized = NotesElementGeometry.resize(
            page = target,
            frame = element.frame,
            corner = NotesResizeCorner.BOTTOM_RIGHT,
            deltaX = 1_000.0,
            deltaY = 1_000.0,
        )
        assertTrue(resized.x + resized.width <= target.width)
        assertTrue(resized.y + resized.height <= target.height)

        val reordered = NotesElementGeometry.reorder(
            page(elements = listOf(element, text("e2", "second"))),
            setOf("e1"),
            toFront = true,
        )
        assertEquals(listOf("e2", "e1"), reordered.elements.map { it.id })
    }

    @Test
    fun `mind map layout is deterministic, folds children and honours saved positions`() {
        val root = MindMapNode(id = "root", title = "Root")
        val childA = MindMapNode(id = "a", parentID = "root", title = "A", order = 0)
        val childB = MindMapNode(id = "b", parentID = "root", title = "B", order = 1)
        val grand = MindMapNode(id = "a1", parentID = "a", title = "A1", order = 0)
        val doc = document(nodes = listOf(root, childA, childB, grand), kind = NoteDocumentKind.MIND_MAP)

        val right = MindMapLayoutEngine.layout(doc, MindMapLayoutDirection.RIGHT)
        assertEquals(listOf("root", "a", "a1", "b"), right.visibleNodes.map { it.id })
        assertTrue(right.frames.getValue("a").x > right.frames.getValue("root").x)
        assertNotNull(right.edges.firstOrNull { it.from == "root" && it.to == "a" })

        val folded = MindMapLayoutEngine.layout(
            doc.copy(nodes = listOf(root.copy(isCollapsed = true), childA, childB, grand)),
            MindMapLayoutDirection.RIGHT,
        )
        assertEquals(listOf("root"), folded.visibleNodes.map { it.id })

        val free = MindMapLayoutEngine.layout(
            doc.copy(nodes = listOf(root.copy(position = MindMapPoint(500.0, 400.0)), childA, childB, grand)),
            MindMapLayoutDirection.RIGHT,
        )
        assertEquals(500.0, free.frames.getValue("root").x, 0.001)
        assertEquals(400.0, free.frames.getValue("root").y, 0.001)

        val down = MindMapLayoutEngine.layout(doc, MindMapLayoutDirection.DOWN)
        assertTrue(down.frames.getValue("a").y > down.frames.getValue("root").y)
        assertEquals(
            listOf("root" to 0, "a" to 1, "a1" to 2, "b" to 1),
            MindMapLayoutEngine.outline(doc).map { it.first.id to it.second },
        )
    }

    @Test
    fun `library filter respects recent, trash and notebook selection`() {
        val now = 2_000.0
        fun summary(id: String, favorite: Boolean = false, notebook: String? = null, deleted: Double? = null) =
            NoteDocumentSummary(
                id = id,
                kind = NoteDocumentKind.NOTEBOOK,
                notebookID = notebook,
                title = id,
                revision = 1,
                createdAt = 1.0,
                updatedAt = now,
                deletedAt = deleted,
                isFavorite = favorite,
            )
        val values = listOf(
            summary("a", favorite = true, notebook = "book"),
            summary("b", notebook = "book"),
            summary("c", deleted = 1.0),
        )
        assertEquals(
            listOf("b"),
            filterAndSortDocuments(values, listOf("b"), NotesLibraryFilter.RECENT, null, NotesSortOrder.UPDATED)
                .map { it.id },
        )
        assertEquals(
            listOf("c"),
            filterAndSortDocuments(values, emptyList(), NotesLibraryFilter.TRASH, null, NotesSortOrder.UPDATED)
                .map { it.id },
        )
        assertEquals(
            listOf("a"),
            filterAndSortDocuments(
                values, emptyList(), NotesLibraryFilter.FAVORITES, "book", NotesSortOrder.TITLE,
            ).map { it.id },
        )
    }

    @Test
    fun `large text split never breaks a surrogate pair or drops code points`() {
        val doc = document()
        val emoji = "\uD83D\uDE00"
        val text = "a".repeat(1_199) + emoji + "b".repeat(3_500)
        val plan = planTextInsertion(doc, "page-1", text, markdown = false, ids = countingIds())
        val chunks = plan.edits.filterIsInstance<NotesEdit.UpsertElement>().map { it.element.text }
        assertTrue(chunks.size > 1)
        chunks.forEach { chunk -> assertFalse(chunk.hasUnpairedSurrogate()) }
        assertTrue(chunks.joinToString("").contains(emoji))
        // No newlines in this fixture, so every UTF-16 code unit must survive.
        assertEquals(text.length, chunks.sumOf { it.length })
    }

    private fun String.hasUnpairedSurrogate(): Boolean {
        var index = 0
        while (index < length) {
            val value = this[index]
            when {
                Character.isHighSurrogate(value) -> {
                    if (index + 1 >= length || !Character.isLowSurrogate(this[index + 1])) return true
                    index += 2
                }
                Character.isLowSurrogate(value) -> return true
                else -> index += 1
            }
        }
        return false
    }

    private fun countingIds(): com.floe.android.feature.notes.ui.presentation.NotesIdSource {
        var value = 0
        return com.floe.android.feature.notes.ui.presentation.NotesIdSource { "id-${value++}" }
    }
}
