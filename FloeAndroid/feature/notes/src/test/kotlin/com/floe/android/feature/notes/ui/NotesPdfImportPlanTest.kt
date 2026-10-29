// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.state.importedNotebookPageEdits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A fresh notebook carries one native placeholder page. A PDF import must
 * replace that page with the first PDF page, otherwise the editor shows a
 * blank cover plus the real pages (a one-page PDF becomes "Page 1 of 2").
 */
class NotesPdfImportPlanTest {
    private val resourceID = "3777e0ed-bd89-45d6-b15c-741cb258e074"

    private fun pdfPage(index: Int, id: String): NotePage = NotePage(
        id = id,
        width = 612.0,
        height = 792.0,
        backgroundResourceID = resourceID,
        pdfPageIndex = index,
    )

    private fun notebook(pages: List<NotePage>): NoteDocument = NoteDocument(
        id = "c06ad8af-3dd9-45ec-b0e8-933856a76fbf",
        kind = NoteDocumentKind.NOTEBOOK,
        title = "G06-preview",
        revision = 0,
        pages = pages,
        createdAt = 1.0,
        updatedAt = 1.0,
    )

    /** Applies only the page edits this plan is allowed to contain. */
    private fun applyPlan(document: NoteDocument, edits: List<NotesEdit>): NoteDocument {
        val pages = document.pages.toMutableList()
        for (edit in edits) {
            when (edit) {
                is NotesEdit.UpdatePage -> {
                    val index = pages.indexOfFirst { it.id == edit.page.id }
                    assertTrue("update target ${edit.page.id} must exist", index >= 0)
                    pages[index] = edit.page
                }
                is NotesEdit.InsertPage -> pages.add(edit.index, edit.page)
                else -> throw AssertionError("unexpected edit $edit")
            }
        }
        return document.copy(pages = pages, revision = document.revision + 1)
    }

    @Test
    fun onePagePdfReplacesThePlaceholderInsteadOfAddingAnEmptyCover() {
        val placeholderID = "151bb483-9095-4da2-a0a1-3e775c0e1164"
        val document = notebook(listOf(NotePage(id = placeholderID)))
        val plan = importedNotebookPageEdits(placeholderID, listOf(pdfPage(0, "ac395029-503b-4a84-a819-ff8dd80e7796")))

        assertEquals(1, plan.size)
        val update = plan.single() as NotesEdit.UpdatePage
        assertEquals(placeholderID, update.page.id)
        assertEquals(0, update.page.pdfPageIndex ?: -1)
        assertEquals(resourceID, update.page.backgroundResourceID)

        val applied = applyPlan(document, plan)
        assertEquals(1, applied.pages.size)
        assertEquals(placeholderID, applied.pages[0].id)
        assertEquals(0, applied.pages[0].pdfPageIndex ?: -1)
        assertEquals(612.0, applied.pages[0].width, 0.0)
        assertEquals(792.0, applied.pages[0].height, 0.0)
    }

    @Test
    fun multiPagePdfKeepsEveryPdfPageInOrderWithoutThePlaceholderCover() {
        val placeholderID = "placeholder"
        val document = notebook(listOf(NotePage(id = placeholderID)))
        val pdfPages = listOf(
            pdfPage(0, "pdf-0"),
            pdfPage(1, "pdf-1"),
            pdfPage(2, "pdf-2"),
        )
        val plan = importedNotebookPageEdits(placeholderID, pdfPages)

        assertEquals(3, plan.size)
        assertEquals(placeholderID, (plan[0] as NotesEdit.UpdatePage).page.id)
        assertEquals(1, (plan[1] as NotesEdit.InsertPage).index)
        assertEquals(2, (plan[2] as NotesEdit.InsertPage).index)

        val applied = applyPlan(document, plan)
        assertEquals(listOf(placeholderID, "pdf-1", "pdf-2"), applied.pages.map { it.id })
        assertEquals(listOf(0, 1, 2), applied.pages.map { it.pdfPageIndex ?: -1 })
        assertTrue(applied.pages.none { it.id == "pdf-0" })
    }

    @Test
    fun absolutePagePositionsSurviveBoundedChunking() {
        val placeholderID = "placeholder"
        val document = notebook(listOf(NotePage(id = placeholderID)))
        val pdfPages = (0 until 45).map { index -> pdfPage(index, "pdf-$index") }
        val plan = importedNotebookPageEdits(placeholderID, pdfPages)

        val applied = plan.chunked(40).fold(document) { current, chunk ->
            applyPlan(current, chunk)
        }

        assertEquals(45, applied.pages.size)
        assertEquals(placeholderID, applied.pages.first().id)
        assertEquals((0 until 45).toList(), applied.pages.map { it.pdfPageIndex ?: -1 })
        assertEquals("pdf-44", applied.pages.last().id)
    }

    @Test
    fun noPlaceholderInsertsFromTheStart() {
        val document = notebook(emptyList())
        val plan = importedNotebookPageEdits(null, listOf(pdfPage(0, "pdf-0"), pdfPage(1, "pdf-1")))

        assertEquals(2, plan.size)
        assertEquals(0, (plan[0] as NotesEdit.InsertPage).index)
        assertEquals(1, (plan[1] as NotesEdit.InsertPage).index)
        assertEquals(2, applyPlan(document, plan).pages.size)
    }
}
