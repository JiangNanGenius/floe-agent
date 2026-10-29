// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InkDocumentTest {

    private fun doc() = InkDocument(
        "note-1",
        InkPageGeometry("page-a", 612f, 792f),
    )

    private fun brush() = InkBrushSpec.pen(0xFF112233.toInt(), 2f)

    private fun commit(doc: InkDocument, id: Long, x: Float = 100f, y: Float = 120f): InkStroke? {
        assertTrue(doc.beginStroke(id, brush(), id))
        assertTrue(
            doc.appendStrokeInput(
                id,
                byteArrayOf(1, 2, 3, 4),
                InkBox.around(x, y, 4f),
            ),
        )
        return doc.finishStroke(id)
    }

    @Test
    fun finishCommitsAndUndoRedoRestoresExactLists() {
        val document = doc()
        val stroke = commit(document, 1)
        assertNotNull(stroke)
        assertEquals(1, document.strokeCount)
        assertEquals(1L, document.revision)
        assertTrue(document.canUndo)
        assertTrue(document.undo())
        assertEquals(0, document.strokeCount)
        assertTrue(document.canRedo)
        assertTrue(document.redo())
        assertEquals(stroke, document.strokes.single())
    }

    @Test
    fun cancelPendingLeavesNoCommitAndNoUndoEntry() {
        val document = doc()
        assertTrue(document.beginStroke(7, brush(), 0))
        assertTrue(document.appendStrokeInput(7, byteArrayOf(9, 9), InkBox.around(10f, 10f, 2f)))
        assertTrue(document.cancelStroke(7))
        assertEquals(0, document.strokeCount)
        assertEquals(0L, document.revision)
        assertFalse(document.canUndo)
        assertNull(document.finishStroke(7))
    }

    @Test
    fun emptyOrOversizedInputRefusesToCommit() {
        val document = doc()
        assertTrue(document.beginStroke(8, brush(), 0))
        assertNull(document.finishStroke(8))
        assertEquals(0, document.strokeCount)

        val other = doc()
        assertTrue(other.beginStroke(9, brush(), 0))
        val tooBig = ByteArray(com.floe.android.core.notesmedia.media.InkFormat.MAX_INPUT_BYTES_PER_STROKE + 1)
        assertFalse(other.appendStrokeInput(9, tooBig, InkBox.around(0f, 0f, 1f)))
        assertNull(other.finishStroke(9))
        assertEquals(0, other.strokeCount)
    }

    @Test
    fun strokeGroupUndoCoalescesOperationsIntoOneStep() {
        val document = doc()
        document.beginGroup()
        commit(document, 1)
        commit(document, 2)
        document.endGroup()
        assertEquals(2, document.strokeCount)
        assertTrue(document.undo())
        assertEquals(0, document.strokeCount)
        assertTrue(document.redo())
        assertEquals(2, document.strokeCount)
    }

    @Test
    fun selectionMoveUpdatesTransformNotInputs() {
        val document = doc()
        commit(document, 1, 100f, 100f)
        commit(document, 2, 300f, 300f)
        assertTrue(document.setSelection(setOf(1L)))
        assertEquals(setOf(1L), document.selectedStrokeIds)
        assertTrue(document.moveSelection(10f, -5f))
        val moved = document.strokes.first { it.id == 1L }
        assertEquals(10f, moved.transform.e, 0.001f)
        assertEquals(-5f, moved.transform.f, 0.001f)
        // Stored bounds are untouched; only the transform moves the stroke.
        // Stored bounds include half the brush width (stroke coverage).
        assertEquals(95f, moved.bounds.left, 0.001f)
        assertTrue(document.undo())
        assertEquals(0f, document.strokes.first { it.id == 1L }.transform.e, 0.001f)
    }

    @Test
    fun selectionRestyleAndDeleteAreUndoable() {
        val document = doc()
        commit(document, 1)
        commit(document, 2)
        document.setSelection(setOf(1L, 2L))
        assertTrue(document.restyleSelection(InkBrushSpec.highlighter(0xFFFFAA00.toInt(), 10f)))
        assertEquals(InkBrushSpec.FAMILY_HIGHLIGHTER, document.strokes[0].brush.familyId)
        assertTrue(document.deleteSelection())
        assertEquals(0, document.strokeCount)
        assertTrue(document.undo())
        assertEquals(2, document.strokeCount)
    }

    @Test
    fun marqueeAndHitTestUseTransformedBounds() {
        val document = doc()
        commit(document, 1, 100f, 100f)
        val hits = document.selectInBox(InkBox(80f, 80f, 130f, 130f))
        assertEquals(setOf(1L), hits)
        assertNull(document.hitTest(InkBox(500f, 500f, 510f, 510f)))
        assertNotNull(document.hitTest(InkBox(99f, 99f, 101f, 101f)))
    }

    @Test
    fun snapshotRestoreResetsHistoryAndRoundTrips() {
        val document = doc()
        commit(document, 1)
        val snapshot = document.snapshot()
        val restored = InkDocument.fromSnapshot(snapshot)
        assertEquals(snapshot, restored.snapshot())
        assertFalse(restored.canUndo)
        assertEquals(1, restored.strokeCount)
    }

    @Test
    fun undoHistoryIsBounded() {
        val document = doc()
        for (id in 1L..120L) {
            commit(document, id)
        }
        var undos = 0
        while (document.undo()) undos++
        assertTrue(undos <= InkDocument.MAX_UNDO_ENTRIES)
        assertEquals(120 - undos, document.strokeCount)
    }

    @Test
    fun dotStrokeWithZeroSizeBoundsIsStillCommitted() {
        val document = doc()
        assertTrue(document.beginStroke(1, brush(), 0))
        assertTrue(document.appendStrokeInput(1, byteArrayOf(5), InkBox.EMPTY))
        val stroke = document.finishStroke(1)
        assertNotNull(stroke)
        assertEquals(1, document.strokeCount)
    }
}
