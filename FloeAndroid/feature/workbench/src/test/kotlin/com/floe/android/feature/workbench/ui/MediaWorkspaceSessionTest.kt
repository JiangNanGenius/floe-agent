// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.ui.api.MediaAssetImport
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaSourceCreate
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaWorkspaceSessionTest {
    private val ports = object : MediaEditorPorts {
        override val sourceCreate = MediaSourceCreate { _, _, _, _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
        override val assetImport = MediaAssetImport { _, _, _, _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
    }

    private fun summary(host: FakeWorkbenchHost, ownerKind: String = "standalone") =
        MediaProjectSummary(
            id = host.projectID,
            name = host.projectName,
            kind = host.kind,
            revision = host.revision,
            updatedAt = "2026-11-01T00:00:00Z",
            ownerKind = ownerKind,
            assetCount = host.assets.size,
            layerCount = host.layers.size,
            corrupt = false,
            writable = true,
            provenanceWarning = false,
        )

    @Test
    fun addTextLayerCommitsNativeCommandAndUndoRedoUseNativeReceipts() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        assertEquals(host.projectID, editor.projectID)

        editor.addTextLayer("Hello", 64.0, "#000000")
        yield()
        val command = host.applies.last().single()
        assertTrue(command is MediaEditCommand.AddImageLayer)
        assertEquals(1, editor.project.imageLayers.size)
        assertTrue(editor.canUndo)

        editor.undo()
        yield()
        assertEquals(1, host.undoRequests.size)
        assertFalse(editor.canUndo)
        assertTrue(editor.canRedo)

        editor.redo()
        yield()
        assertEquals(1, host.redoRequests.size)
        assertTrue(editor.canUndo)
    }

    @Test
    fun revisionConflictStopsFurtherCommandsUntilReload() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        host.applyFailure = CreativeException("revisionConflict", "test")
        editor.addTextLayer("first")
        yield()
        assertEquals(MediaFailureKind.REVISION_CONFLICT, editor.failure?.kind)
        assertTrue(editor.needsReload)
        val count = host.applies.size
        editor.addTextLayer("second")
        yield()
        assertEquals(count, host.applies.size)

        host.applyFailure = null
        editor.reload()
        yield()
        assertFalse(editor.needsReload)
        editor.addTextLayer("third")
        yield()
        assertEquals(count + 1, host.applies.size)
    }

    @Test
    fun originOwnedProjectIsNotOpenedWithoutTheRealContext() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(summary(host, ownerKind = "files"))
        yield()
        assertNull(session.editor)
        assertEquals(MediaFailureKind.ORIGIN_REQUIRED, session.failure?.kind)
        assertTrue(host.opened.isEmpty())
    }

    @Test
    fun lateOpenAfterShutdownIsClosedAndNeverInstalled() = runBlocking {
        val host = FakeWorkbenchHost()
        host.openGate = CompletableDeferred()
        val session = MediaWorkspaceSession(host, ports, scope = this)
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
    fun closeUsesExactEditorTokenOnly() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        val token = editor.sessionToken
        session.closeEditor(editor)
        yield()
        assertNull(session.editor)
        assertEquals(token, host.closed.last().second)
        assertNull(host.activeToken)
    }

    @Test
    fun explicitAppOwnedStorageIsPassedOnceWithoutProbingAnotherRoot() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        val workspaceID = "77777777-7777-7777-7777-777777777777"
        val origin = CreativeOriginContext(
            kind = CreativeOriginContext.WORKSPACE,
            ownerID = workspaceID,
        )
        session.open(
            summary = summary(host, ownerKind = "workspace").copy(ownerID = workspaceID),
            origin = origin,
            storage = CreativeStorageLayer.AppOwned,
            editCopy = true,
        )
        yield()
        val editor = requireNotNull(session.editor)
        assertEquals(CreativeStorageLayer.AppOwned, editor.storage)
        assertEquals(1, host.openRequests.size)
        assertEquals(CreativeStorageLayer.AppOwned, host.openRequests.single().second)
        assertEquals(CreativeOriginContext.WORKSPACE, host.openRequests.single().third?.kind)
        assertTrue(editor.editCopy)
    }

    @Test
    fun explicitWorkspaceStorageIsPassedUnchanged() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        val workspaceID = "77777777-7777-7777-7777-777777777777"
        session.open(
            summary = summary(host, ownerKind = "workspace").copy(ownerID = workspaceID),
            origin = CreativeOriginContext(
                kind = CreativeOriginContext.WORKSPACE,
                ownerID = workspaceID,
            ),
            storage = CreativeStorageLayer.Workspace(workspaceID),
        )
        yield()
        val editor = requireNotNull(session.editor)
        assertEquals(
            CreativeStorageLayer.Workspace(workspaceID),
            editor.storage,
        )
        assertEquals(1, host.openRequests.size)
        assertEquals(
            CreativeStorageLayer.Workspace(workspaceID),
            host.openRequests.single().second,
        )
        assertFalse(editor.editCopy)
    }

    @Test
    fun workspaceProjectWithoutExplicitStorageIsNotSilentlyInferred() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(
            summary(host, ownerKind = "workspace")
                .copy(ownerID = "77777777-7777-7777-7777-777777777777"),
        )
        yield()
        assertNull(session.editor)
        assertEquals(MediaFailureKind.ORIGIN_REQUIRED, session.failure?.kind)
        assertTrue(host.openRequests.isEmpty())
    }

    @Test
    fun originOwnedRenameIsRefusedWithoutAnExplicitContext() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.rename(summary(host, ownerKind = "files"), "Renamed")
        yield()
        assertEquals(MediaFailureKind.ORIGIN_REQUIRED, session.failure?.kind)
        assertEquals("Project", host.projectName)
    }

    @Test
    fun unavailableStatusShowsNoFakeLibrary() = runBlocking {
        val host = FakeWorkbenchHost()
        host.availability = com.floe.android.feature.canvas.CreativeAvailability.WaitingForRuntime
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.refresh(initial = true)
        yield()
        assertTrue(session.projects.isEmpty())
        assertTrue(session.showAvailabilityState)
    }
}
