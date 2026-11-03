// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingFailure
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingPort
import com.floe.android.feature.workbench.ui.api.MediaAgentOwnerContext
import com.floe.android.feature.workbench.ui.api.MediaAgentTaskReceipt
import com.floe.android.feature.workbench.ui.api.MediaAgentTaskRequest
import com.floe.android.feature.workbench.ui.api.MediaAssetImport
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaSourceCreate
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaAgentBindingTest {
    private val ports = object : MediaEditorPorts {
        override val sourceCreate = MediaSourceCreate { _, _, _, _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
        override val assetImport = MediaAssetImport { _, _, _, _, _, _, _ ->
            throw CreativeException("unsupportedOperation", "test")
        }
    }

    private fun summary(host: FakeWorkbenchHost) = MediaProjectSummary(
        id = host.projectID,
        name = host.projectName,
        kind = host.kind,
        revision = host.revision,
        updatedAt = "2026-11-01T00:00:00Z",
        ownerKind = "standalone",
        assetCount = host.assets.size,
        layerCount = host.layers.size,
        corrupt = false,
        writable = true,
        provenanceWarning = false,
    )

    @Test
    fun explicitAskAiCarriesTheExactOwnerProjectRevisionAndInstruction() = runBlocking {
        val host = FakeWorkbenchHost()
        var recorded: MediaAgentTaskRequest? = null
        val port = object : MediaAgentBindingPort {
            override suspend fun askAi(request: MediaAgentTaskRequest): MediaAgentTaskReceipt {
                recorded = request
                return MediaAgentTaskReceipt(
                    taskID = "task-created", bindingID = "binding-1")
            }
        }
        val session = MediaWorkspaceSession(
            host = host,
            ports = ports,
            scope = this,
            agentBinding = port,
            agentOwner = MediaAgentOwnerContext("task-owner", "workspace-1"),
        )
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        val revision = editor.revision
        session.askAi(editor, "brighten the title")
        repeat(4) { yield() }

        val request = requireNotNull(recorded)
        assertEquals(host.projectID, request.projectID)
        assertEquals(revision, request.projectRevision)
        assertEquals("task-owner", request.ownerTaskID)
        assertEquals("workspace-1", request.ownerWorkspaceID)
        assertEquals("brighten the title", request.instruction)
        assertTrue(request.selectionOpID.isNotBlank())
        assertEquals("task-created", session.agentTaskID)
        assertNull(session.editor)
        assertFalse(session.agentBusy)
    }

    @Test
    fun bindingRefusalKeepsTheEditorAndDoesNotInventATask() = runBlocking {
        val host = FakeWorkbenchHost()
        val port = object : MediaAgentBindingPort {
            override suspend fun askAi(request: MediaAgentTaskRequest): MediaAgentTaskReceipt {
                throw MediaAgentBindingFailure("projectAlreadyBound")
            }
        }
        val session = MediaWorkspaceSession(
            host = host,
            ports = ports,
            scope = this,
            agentBinding = port,
        )
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        session.askAi(editor, "")
        repeat(4) { yield() }

        assertEquals(editor, session.editor)
        assertEquals("projectAlreadyBound", session.agentFailure)
        assertNull(session.agentTaskID)
        assertFalse(session.agentBusy)
    }

    @Test
    fun missingBindingOwnerIsHonestlyUnavailable() = runBlocking {
        val host = FakeWorkbenchHost()
        val session = MediaWorkspaceSession(host, ports, scope = this)
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        session.askAi(editor, "edit")
        yield()
        assertEquals("bindingUnavailable", session.agentFailure)
        assertEquals(editor, session.editor)
        assertFalse(session.agentAvailable)
    }

    @Test
    fun manualEditingStillCreatesNoTaskOrBinding() = runBlocking {
        val host = FakeWorkbenchHost()
        var calls = 0
        val port = object : MediaAgentBindingPort {
            override suspend fun askAi(request: MediaAgentTaskRequest): MediaAgentTaskReceipt {
                calls += 1
                return MediaAgentTaskReceipt("task", "binding")
            }
        }
        val session = MediaWorkspaceSession(
            host = host,
            ports = ports,
            scope = this,
            agentBinding = port,
        )
        session.open(summary(host))
        yield()
        val editor = requireNotNull(session.editor)
        editor.addTextLayer("Hello", 48.0, "#000000")
        yield()
        assertEquals(0, calls)
        assertNull(session.agentTaskID)
    }
}
