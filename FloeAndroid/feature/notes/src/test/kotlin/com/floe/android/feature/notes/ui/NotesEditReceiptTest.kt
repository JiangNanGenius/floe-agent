// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.presentation.NotesEditReceipt
import com.floe.android.feature.notes.ui.presentation.NotesRequestBudget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The native `document.apply` receipt is keyed by request ID. Chunk suffixes
 * must identify content, not Java hashCode: a collision would make a real
 * chunk look like a replay of another and it would never be applied.
 */
class NotesEditReceiptTest {

    @Test
    fun `different chunks with colliding hashCode get different SHA-256 receipts`() {
        val first = listOf(NotesEdit.Rename("Aa"))
        val second = listOf(NotesEdit.Rename("BB"))
        // Classic String collision: the old `chunk.hashCode()` suffix collided.
        assertEquals(first.hashCode(), second.hashCode())

        assertNotEquals(NotesEditReceipt.digest(first), NotesEditReceipt.digest(second))
        assertNotEquals(NotesEditReceipt.suffix(first), NotesEditReceipt.suffix(second))
    }

    @Test
    fun `receipt is stable across reconstruction and recovery re-chunking`() {
        val edits = listOf(
            NotesEdit.Rename("Aa"),
            NotesEdit.Rename("BB"),
            NotesEdit.Tags(listOf("one", "two")),
        )
        val chunks = NotesRequestBudget.split(edits, budget = 1)
        assertEquals(3, chunks.size)

        // Serializing/reconstructing the same chunk (or splitting the same
        // remaining suffix after an interruption) must keep the receipt.
        val rebuilt = chunks[1].map { it }
        assertEquals(NotesEditReceipt.digest(chunks[1]), NotesEditReceipt.digest(rebuilt))

        val remaining = edits.drop(chunks[0].size)
        val rechunked = NotesRequestBudget.split(remaining, budget = 1)
        assertEquals(NotesEditReceipt.digest(chunks[1]), NotesEditReceipt.digest(rechunked[0]))
        assertEquals(NotesEditReceipt.digest(chunks[2]), NotesEditReceipt.digest(rechunked[1]))
    }

    @Test
    fun `map field order does not change a node receipt`() {
        val first = MindMapNode(
            id = "node-1",
            title = "Topic",
            style = linkedMapOf("b" to "2", "a" to "1"),
        )
        val second = first.copy(style = linkedMapOf("a" to "1", "b" to "2"))
        assertEquals(
            NotesEditReceipt.digest(listOf(NotesEdit.UpsertNode(first))),
            NotesEditReceipt.digest(listOf(NotesEdit.UpsertNode(second))),
        )
    }

    @Test
    fun `order and text changes are not hidden by the canonical encoder`() {
        val a = listOf(NotesEdit.Rename("Aa"), NotesEdit.Favorite(true))
        val reordered = listOf(NotesEdit.Favorite(true), NotesEdit.Rename("Aa"))
        val changed = listOf(NotesEdit.Rename("Aa"), NotesEdit.Favorite(false))
        assertNotEquals(NotesEditReceipt.digest(a), NotesEditReceipt.digest(reordered))
        assertNotEquals(NotesEditReceipt.digest(a), NotesEditReceipt.digest(changed))
        assertTrue(NotesEditReceipt.digest(a).matches(Regex("^[0-9a-f]{64}$")))
    }
}
