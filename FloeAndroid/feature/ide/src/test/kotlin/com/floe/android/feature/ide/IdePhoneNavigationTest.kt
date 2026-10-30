// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeDocumentCapabilities
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeOwnerScope
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeTabDescriptor
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phone file-list-first navigation regressions (G07.1).
 *
 * The accepted iOS flow roots the phone inspector at the file list, pushes the
 * editor on selection, and returns to the list on Back. These tests pin the
 * presentation rules that keep that flow from resurrecting a persisted
 * selection or crossing a task/workspace boundary, while preserving the one
 * editor authority for dirty buffers, undo lineage and recovery.
 *
 * The tablet distinction is also pinned: a 430dp pane inside a tablet window
 * must keep the existing compact editor root, so phone mode is resolved from
 * the actual window rather than the measured child width.
 */
class IdePhoneNavigationTest {

    private val owner get() = IdeOwnerScope("task-a", "ws-a", 7L)
    private val key get() = IdeDocumentKey("task-a", "ws-a", "doc-1")

    private inner class FakeHost(
        override var bindingGeneration: Long = 7L,
        override val taskId: String = "task-a",
        override val workspaceId: String = "ws-a",
    ) : IdeHost {
        var receiver: IdeReceiver? = null
        val commands = ArrayList<IdeCommandRequest>()
        val edits = ArrayList<IdeEditTransaction>()

        override fun attach(receiver: IdeReceiver): () -> Unit {
            this.receiver = receiver
            return { this.receiver = null }
        }

        override fun submitEdit(transaction: IdeEditTransaction) {
            edits += transaction
        }

        override fun sendCommand(command: IdeCommandRequest) {
            commands += command
        }
    }

    private fun fixture(
        taskId: String = "task-a",
        workspaceId: String = "ws-a",
        generation: Long = 7L,
    ): Fixture {
        val host = FakeHost(bindingGeneration = generation, taskId = taskId, workspaceId = workspaceId)
        return Fixture(host, IdePresenter(host).also { it.start() })
    }

    private inner class Fixture(val host: FakeHost, val presenter: IdePresenter)

    private fun tab(id: String = "doc-1", path: String = "probe.py") =
        IdeTabDescriptor(id, path.substringAfterLast('/'), path)

    private fun snapshot(
        documentKey: IdeDocumentKey? = null,
        text: String = "abc",
        revision: String = "r0",
        generation: Long = 0L,
    ): IdeDocumentSnapshot {
        val actualKey = documentKey ?: key
        return IdeDocumentSnapshot(
            key = actualKey,
            revision = NativeRevision(revision),
            generation = generation,
            text = text,
            fileName = actualKey.documentId,
            relativePath = actualKey.documentId,
            capabilities = IdeDocumentCapabilities(
                undo = true, redo = true, save = true, find = true, replace = true, diff = true,
            ),
        )
    }

    private fun openEditorWithDocument(f: Fixture, text: String = "abc") {
        f.presenter.openFile("probe.py")
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshot(text = text))
    }

    @Test
    fun phoneRootStartsAtFileListEvenWhenNativeTabsReplayAnActiveDocument() {
        val f = fixture()
        assertEquals(IdeCompactLevel.FILE_LIST, f.presenter.state.value.compactLevel)

        // Re-attach/persisted selection replay: the native workspace still
        // reports its active tab and body. That is editor STATE, not a
        // navigation instruction.
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshot())

        val state = f.presenter.state.value
        assertEquals(IdeCompactLevel.FILE_LIST, state.compactLevel)
        assertEquals(key, state.activeDocumentKey)
        assertEquals("abc", state.mirrorText)
    }

    @Test
    fun selectingFilePushesEditorAndBackKeepsDirtyBufferForReentry() {
        val f = fixture()
        openEditorWithDocument(f)

        assertEquals(IdeCompactLevel.EDITOR, f.presenter.state.value.compactLevel)

        f.presenter.toggleBottomPane(true)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        val edited = f.presenter.state.value
        assertEquals("abc!", edited.mirrorText)
        assertEquals(1, edited.pendingTransactionCount)
        assertTrue(edited.bottomPaneOpen)
        assertTrue(f.presenter.hasUnsettledEdits())

        f.presenter.showCompactFileList()

        val list = f.presenter.state.value
        assertEquals(IdeCompactLevel.FILE_LIST, list.compactLevel)
        // Leaving the editor level closes its own attached pane, but the
        // unconfirmed keystroke, tab and recovery projection all survive.
        assertFalse(list.bottomPaneOpen)
        assertEquals("abc!", list.mirrorText)
        assertEquals(1, list.pendingTransactionCount)
        assertEquals(edited.activeDocumentKey, list.activeDocumentKey)
        assertTrue(f.presenter.hasUnsettledEdits())
        assertEquals(1, f.presenter.recoveryProjections().size)

        // Selecting the same file again returns to the SAME projection; it is
        // not a second editor or a reset document.
        f.presenter.openFile("probe.py")
        val reentered = f.presenter.state.value
        assertEquals(IdeCompactLevel.EDITOR, reentered.compactLevel)
        assertEquals("abc!", reentered.mirrorText)
        assertEquals(1, reentered.pendingTransactionCount)
    }

    @Test
    fun lateTabsAndSnapshotAfterBackCannotReopenTheEditor() {
        val f = fixture()
        openEditorWithDocument(f)
        f.presenter.showCompactFileList()
        assertEquals(IdeCompactLevel.FILE_LIST, f.presenter.state.value.compactLevel)

        // A persisted-selection replay (or a late OPEN reply's refreshTabs)
        // arrives after Back. It may update the retained document projection,
        // but it must never move the phone chrome back into the editor.
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 2))
        f.host.receiver!!.onDocumentSnapshot(snapshot(text = "abc", revision = "r1", generation = 1))

        val state = f.presenter.state.value
        assertEquals(IdeCompactLevel.FILE_LIST, state.compactLevel)
        assertEquals(key, state.activeDocumentKey)
        assertEquals("r1", state.snapshot?.revision?.opaque)
    }

    @Test
    fun workspaceSwitchStartsAtItsOwnFileListAndRejectsOldCallbacks() {
        val first = fixture(taskId = "task-a", workspaceId = "ws-a", generation = 7L)
        openEditorWithDocument(first)
        assertEquals(IdeCompactLevel.EDITOR, first.presenter.state.value.compactLevel)

        val second = fixture(taskId = "task-b", workspaceId = "ws-b", generation = 8L)
        assertEquals(IdeCompactLevel.FILE_LIST, second.presenter.state.value.compactLevel)

        // Late callbacks from the previous task/workspace are fenced by the
        // presenter owner scope and cannot populate or navigate this one.
        second.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 3))
        second.host.receiver!!.onDocumentSnapshot(snapshot())

        val state = second.presenter.state.value
        assertEquals(IdeCompactLevel.FILE_LIST, state.compactLevel)
        assertNull(state.activeDocumentKey)
        assertTrue(state.tabs.isEmpty())
        assertEquals(IdeCompactLevel.EDITOR, first.presenter.state.value.compactLevel)
    }

    @Test
    fun policyDistinguishesPhoneFromTabletPaneAndKeepsTabletBackSemantics() {
        // A 360dp phone with the 92% overlay pane.
        assertTrue(IdeWorkspacePresentation.isPhoneWindow(360f))
        assertTrue(IdeWorkspacePresentation.usesPhoneFileList(360f, 331.2f))
        // The 430dp inspector column on a tablet window is NOT a phone.
        assertFalse(IdeWorkspacePresentation.isPhoneWindow(1280f))
        assertFalse(IdeWorkspacePresentation.usesPhoneFileList(1280f, 430f))
        // iPad-mini-class portrait window keeps the split/compact-pane rules.
        assertFalse(IdeWorkspacePresentation.usesPhoneFileList(744f, 430f))
        // Without actual window evidence no phone mode is guessed from the
        // child width (debug previews / component hosts).
        assertFalse(IdeWorkspacePresentation.usesPhoneFileList(null, 360f))
        assertFalse(IdeWorkspacePresentation.isPhoneWindow(600f))

        // Back on the phone list leaves the workspace; Back in the phone
        // editor returns to the list. Tablet panes keep dismiss semantics.
        assertTrue(IdeWorkspacePresentation.backReturnsToTask(true, IdeCompactLevel.FILE_LIST))
        assertFalse(IdeWorkspacePresentation.backReturnsToTask(true, IdeCompactLevel.EDITOR))
        assertTrue(IdeWorkspacePresentation.backReturnsToTask(false, IdeCompactLevel.EDITOR))
        assertTrue(IdeWorkspacePresentation.backReturnsToTask(false, IdeCompactLevel.FILE_LIST))
    }
}
