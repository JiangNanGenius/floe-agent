// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.ui.api.CanvasAssetImport
import com.floe.android.feature.canvas.ui.api.CanvasEditorPorts
import com.floe.android.feature.canvas.ui.api.CanvasSourceCreate
import com.floe.android.feature.canvas.ui.presentation.CanvasFailureKind
import com.floe.android.feature.canvas.ui.state.CanvasWorkspaceSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasWorkspaceSessionTest {
    private val ports = object : CanvasEditorPorts {
        override val sourceCreate = CanvasSourceCreate { _, _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
        override val assetImport = CanvasAssetImport { _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
    }

    private fun summary(host: FakeCanvasHost) = CanvasProjectSummary(
        id = host.projectID,
        name = host.name,
        revision = host.revision,
        updatedAt = "2026-11-01T00:00:00Z",
        schemaVersion = 7,
        documentCount = 1,
        corrupt = false,
        writable = true,
    )

    @Test
    fun createUndoRedoRoundTripCommitsNativePatches() = runBlocking {
        val host = FakeCanvasHost()
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        assertEquals(host.projectID, editor.canvasID)

        editor.createNode("text", "Hello")
        yield()
        assertEquals("create", host.patches.last().patch.operations.single().kind)
        assertEquals(1, editor.project.documents.single().nodes.size)
        assertTrue(editor.canUndo)

        editor.undo()
        yield()
        assertEquals("delete", host.patches.last().patch.operations.single().kind)
        assertTrue(editor.project.documents.single().nodes.isEmpty())
        assertTrue(editor.canRedo)

        editor.redo()
        yield()
        assertEquals("create", host.patches.last().patch.operations.single().kind)
        assertEquals(1, editor.project.documents.single().nodes.size)
        assertFalse(editor.canRedo)
    }

    @Test
    fun revisionConflictStopsFurtherEditsUntilReload() = runBlocking {
        val host = FakeCanvasHost()
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        host.patchFailure = CreativeException("revisionConflict", "test")
        editor.createNode("text", "first")
        yield()
        assertEquals(CanvasFailureKind.REVISION_CONFLICT, editor.failure?.kind)
        assertTrue(editor.needsReload)
        val patchesAfterConflict = host.patches.size
        editor.createNode("text", "second")
        yield()
        assertEquals(patchesAfterConflict, host.patches.size)

        host.patchFailure = null
        editor.reload()
        yield()
        assertFalse(editor.needsReload)
        editor.createNode("text", "third")
        yield()
        assertEquals(patchesAfterConflict + 1, host.patches.size)
    }

    @Test
    fun lateOpenAfterShutdownIsClosedAndNeverInstalled() = runBlocking {
        val host = FakeCanvasHost()
        host.openGate = CompletableDeferred()
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        assertNull(session.editor)
        session.shutdown()
        host.openGate?.complete(Unit)
        yield()
        assertNull(session.editor)
        assertTrue(host.closed.isNotEmpty())
    }

    @Test
    fun closingOldEditorCannotCloseReplacementToken() = runBlocking {
        val host = FakeCanvasHost()
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val first = requireNotNull(session.editor)
        val firstToken = first.sessionToken
        session.closeEditor(first)
        yield()
        assertNull(session.editor)

        session.open(summary(host))
        yield()
        val second = requireNotNull(session.editor)
        assertNotEquals(firstToken, second.sessionToken)
        // A duplicate/late close of the retired controller must not retire B.
        assertFalse(first.retire())
        assertEquals(second.sessionToken, host.activeToken)
    }

    @Test
    fun deleteClearsUndoHistoryAndClosesExactToken() = runBlocking {
        val host = FakeCanvasHost()
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        editor.createNode("stickyNote", "note")
        yield()
        assertTrue(editor.canUndo)
        editor.deleteSelected()
        yield()
        assertFalse(editor.canUndo)
        assertFalse(editor.canRedo)
        assertTrue(editor.project.documents.single().nodes.isEmpty())
        val token = editor.sessionToken
        session.closeEditor(editor)
        yield()
        assertEquals(token, host.closed.last().second)
        assertNull(session.editor)
    }

    @Test
    fun statusNotAvailableNeverShowsAFakeLibrary() = runBlocking {
        val host = FakeCanvasHost()
        host.availability = com.floe.android.feature.canvas.CreativeAvailability.NeedsCoreUpdate
        val session = CanvasWorkspaceSession(host, ports, scope = this)
        session.refresh(initial = true)
        yield()
        assertTrue(session.projects.isEmpty())
        assertTrue(session.showAvailabilityState)
        assertEquals(
            com.floe.android.feature.canvas.CreativeAvailability.NeedsCoreUpdate,
            session.availability,
        )
    }
}
