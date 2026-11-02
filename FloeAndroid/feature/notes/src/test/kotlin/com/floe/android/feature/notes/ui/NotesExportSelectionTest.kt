// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.ui.presentation.NotesExportSelection
import com.floe.android.feature.notes.ui.presentation.NotesExportSelectionFailure
import com.floe.android.feature.notes.ui.presentation.NotesExportSelectionResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Export page selection is the identity/order boundary between the user's
 * page list and the renderer. These regressions pin the iOS-compatible
 * semantics: whole document by default, explicit ordered subsets, and a
 * refusal (never a silent drop/reorder/dedup) for invalid or stale input.
 */
class NotesExportSelectionTest {

    private fun page(id: String) = NotePage(id = id)

    private fun document(
        pages: List<NotePage> = listOf(page("p1"), page("p2"), page("p3")),
        revision: Int = 7,
        kind: NoteDocumentKind = NoteDocumentKind.NOTEBOOK,
    ) = NoteDocument(
        id = "doc-1",
        kind = kind,
        title = "Export fixture",
        revision = revision,
        pages = pages,
        createdAt = 1.0,
        updatedAt = 2.0,
    )

    @Test
    fun `null selection exports the whole document in document order`() {
        val result = NotesExportSelection.resolve(document(), null, expectedRevision = 7)
        val pages = (result as NotesExportSelectionResult.Ready).pages
        assertEquals(listOf("p1", "p2", "p3"), pages.map { it.id })
    }

    @Test
    fun `explicit selection keeps the requested order`() {
        val result = NotesExportSelection.resolve(document(), listOf("p3", "p1"), expectedRevision = 7)
        val pages = (result as NotesExportSelectionResult.Ready).pages
        assertEquals(listOf("p3", "p1"), pages.map { it.id })
    }

    @Test
    fun `empty explicit selection is refused instead of becoming the whole document`() {
        val result = NotesExportSelection.resolve(document(), emptyList(), expectedRevision = 7)
        assertEquals(
            NotesExportSelectionFailure.EMPTY_SELECTION,
            (result as NotesExportSelectionResult.Refused).failure,
        )
    }

    @Test
    fun `duplicate page ids are refused without deduplication`() {
        val result = NotesExportSelection.resolve(document(), listOf("p1", "p1"), expectedRevision = 7)
        assertEquals(
            NotesExportSelectionFailure.DUPLICATE_PAGE,
            (result as NotesExportSelectionResult.Refused).failure,
        )
    }

    @Test
    fun `unknown blank and out of range page ids are refused`() {
        listOf(
            listOf("p1", "missing"),
            listOf("p1", ""),
            listOf("p1", "p4"),
        ).forEach { ids ->
            val result = NotesExportSelection.resolve(document(), ids, expectedRevision = 7)
            assertEquals(
                NotesExportSelectionFailure.UNKNOWN_PAGE,
                (result as NotesExportSelectionResult.Refused).failure,
            )
        }
    }

    @Test
    fun `stale revision is refused before any page identity is read`() {
        val result = NotesExportSelection.resolve(document(revision = 8), listOf("p1"), expectedRevision = 7)
        assertEquals(
            NotesExportSelectionFailure.STALE_REVISION,
            (result as NotesExportSelectionResult.Refused).failure,
        )
    }

    @Test
    fun `more than the bounded page count is refused`() {
        val pages = (0..NotesExportSelection.MAX_PAGES).map { page("p$it") }
        val result = NotesExportSelection.resolve(document(pages = pages), null, expectedRevision = 7)
        assertEquals(
            NotesExportSelectionFailure.TOO_MANY_PAGES,
            (result as NotesExportSelectionResult.Refused).failure,
        )
    }

    @Test
    fun `a document without pages has nothing to export`() {
        val result = NotesExportSelection.resolve(document(pages = emptyList()), null, expectedRevision = 7)
        assertEquals(
            NotesExportSelectionFailure.NO_PAGES,
            (result as NotesExportSelectionResult.Refused).failure,
        )
    }

    @Test
    fun `selection is bounded when expected revision is not supplied`() {
        val result = NotesExportSelection.resolve(document(), listOf("p2"))
        assertTrue(result is NotesExportSelectionResult.Ready)
        assertEquals(listOf("p2"), (result as NotesExportSelectionResult.Ready).pages.map { it.id })
    }
}
