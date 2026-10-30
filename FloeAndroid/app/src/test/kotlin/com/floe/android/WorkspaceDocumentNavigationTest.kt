// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.feature.ide.IdeCompactLevel
import com.floe.android.feature.ide.IdePresenter
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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G07.1 document navigation regressions.
 *
 * The iOS reference (local checkout c5e7a3c1c41b766173f2d17d9516ef8f79ed62bc)
 * decides the surface per file kind in `WorkspaceFileRouter` and presents the
 * code workbench / typed document as a `fullScreenCover` from
 * `FileInspectorView.swift` L97-110, while the iPad inspector keeps its pane
 * and only the explicit expand control (L142-146, L256-287) opens the cover.
 *
 * These tests pin the Android mapping without Compose or a device:
 * 1. every iOS file kind keeps its own surface, so Office/PDF/image bytes can
 *    never enter the UTF-8 text editor;
 * 2. a phone opens a text document in the full-window cover and keeps the
 *    file list as the pane's root (`claimsPaneLevel = false`), while a tablet
 *    window keeps the in-pane editor plus an explicit full-window entry;
 * 3. the one presenter keeps drafts, pending transactions and undo lineage
 *    across that navigation, so closing/reopening never discards edits;
 * 4. a foreign, retired, temporary or blank request never presents, and a
 *    configuration change keeps the same document focused instead of
 *    reopening a different one.
 */
class WorkspaceDocumentNavigationTest {
    @org.junit.Test fun landscapeHandsetDoesNotBecomeTabletColumns() {
        org.junit.Assert.assertTrue(com.floe.android.design.FloeLayout.usesCompactNavigation(900f, 411f))
        org.junit.Assert.assertTrue(com.floe.android.feature.ide.IdeWorkspacePresentation.usesPhoneFileList(900f, 828f, 411f))
        org.junit.Assert.assertTrue(WorkspaceDocumentPresentation.presentsFullWindow(900f, WorkspaceDocumentSurface.CODE_EDITOR, 411f))
        org.junit.Assert.assertFalse(WorkspaceDocumentPresentation.offersExplicitFullWindow(900f, WorkspaceDocumentSurface.CODE_EDITOR, 411f))
        org.junit.Assert.assertFalse(com.floe.android.design.FloeLayout.usesCompactNavigation(1280f, 800f))
        org.junit.Assert.assertTrue(WorkspaceDocumentPresentation.offersExplicitFullWindow(1280f, WorkspaceDocumentSurface.CODE_EDITOR, 800f))
    }


    private val ownerScope get() = IdeOwnerScope("task-a", "ws-a", 7L)
    private val documentKey get() = IdeDocumentKey("task-a", "ws-a", "doc-1")

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

    private fun presenter(): Pair<FakeHost, IdePresenter> {
        val host = FakeHost()
        return host to IdePresenter(host).also { it.start() }
    }

    private fun tab(path: String = "notes/plan.md") =
        IdeTabDescriptor("doc-1", path.substringAfterLast('/'), path)

    private fun snapshot(path: String = "notes/plan.md", text: String = "abc") = IdeDocumentSnapshot(
        key = documentKey,
        revision = NativeRevision("r0"),
        generation = 0L,
        text = text,
        fileName = path.substringAfterLast('/'),
        relativePath = path,
        capabilities = IdeDocumentCapabilities(undo = true, redo = true, save = true, find = true),
    )

    private fun open(host: FakeHost, presenter: IdePresenter, path: String = "notes/plan.md") {
        presenter.openFile(path, claimsPaneLevel = false)
        host.receiver!!.onTabs(IdeTabsSnapshot(ownerScope, "doc-1", listOf(tab(path)), 1))
        host.receiver!!.onDocumentSnapshot(snapshot(path))
    }

    @Test
    fun routerKeepsEveryIOSFileKindOnItsTypedSurface() {
        // Text and code (the only surfaces allowed to read/write UTF-8).
        listOf("notes/plan.md", "README", "Makefile", "src/Main.kt", "data.json", "site/index.html")
            .forEach { assertEquals(it, WorkspaceDocumentSurface.CODE_EDITOR, WorkspaceDocumentRouter.surfaceFor(it)) }
        // Unknown extensions stay text-previewable exactly like iOS.
        assertEquals(WorkspaceDocumentSurface.CODE_EDITOR, WorkspaceDocumentRouter.surfaceFor("probe.xyz"))
        // Office, PDF and every other typed document.
        assertEquals(WorkspaceDocumentSurface.OFFICE, WorkspaceDocumentRouter.surfaceFor("reports/q3.docx"))
        assertEquals(WorkspaceDocumentSurface.PDF, WorkspaceDocumentRouter.surfaceFor("reports/q3.pdf"))
        assertEquals(WorkspaceDocumentSurface.IMAGE, WorkspaceDocumentRouter.surfaceFor("shots/frame.PNG"))
        assertEquals(WorkspaceDocumentSurface.MEDIA, WorkspaceDocumentRouter.surfaceFor("clips/demo.mp4"))
        assertEquals(WorkspaceDocumentSurface.CAD, WorkspaceDocumentRouter.surfaceFor("drawings/part.dxf"))
        assertEquals(WorkspaceDocumentSurface.ARCHIVE, WorkspaceDocumentRouter.surfaceFor("bundle.zip"))
        assertEquals(WorkspaceDocumentSurface.QUICK_LOOK, WorkspaceDocumentRouter.surfaceFor("lib/libcore.so"))
        // The routing is by extension only, never by directory or name.
        assertEquals(WorkspaceDocumentSurface.OFFICE, WorkspaceDocumentRouter.surfaceFor("a/b/c.xlsx"))
    }

    @Test
    fun onlyTheCodeEditorSurfaceMayReadDocumentBytesAsText() {
        WorkspaceDocumentSurface.values().forEach { surface ->
            assertEquals(surface == WorkspaceDocumentSurface.CODE_EDITOR, surface.opensInCodeEditor)
        }
    }

    @Test
    fun phonePresentsTextDocumentsFullWindowWhileTabletKeepsThePane() {
        // A real phone window (portrait 411dp) opens the full-window cover.
        assertTrue(WorkspaceDocumentPresentation.isPhoneWindow(411f))
        assertTrue(WorkspaceDocumentPresentation.presentsFullWindow(411f, WorkspaceDocumentSurface.CODE_EDITOR))
        // The 430dp inspector pane on a tablet window is NOT a phone, even
        // though the pane is narrower than a phone display.
        assertFalse(WorkspaceDocumentPresentation.isPhoneWindow(1280f))
        assertFalse(WorkspaceDocumentPresentation.presentsFullWindow(1280f, WorkspaceDocumentSurface.CODE_EDITOR))
        // An unknown window (debug/component host) never guesses phone mode.
        assertFalse(WorkspaceDocumentPresentation.presentsFullWindow(null, WorkspaceDocumentSurface.CODE_EDITOR))
        // The 360dp phone boundary resolves the same way as 411dp.
        assertTrue(WorkspaceDocumentPresentation.presentsFullWindow(360f, WorkspaceDocumentSurface.CODE_EDITOR))
    }

    @Test
    fun tabletsGetAnExplicitFullWindowEntryAndPhonesDoNotNeedOne() {
        // Tablet inspector: the in-pane editor stays, and only the explicit
        // expand control promotes the SAME document.
        assertTrue(WorkspaceDocumentPresentation.offersExplicitFullWindow(1280f, WorkspaceDocumentSurface.CODE_EDITOR))
        assertTrue(WorkspaceDocumentPresentation.offersExplicitFullWindow(744f, WorkspaceDocumentSurface.CODE_EDITOR))
        // Phones already open the cover directly.
        assertFalse(WorkspaceDocumentPresentation.offersExplicitFullWindow(411f, WorkspaceDocumentSurface.CODE_EDITOR))
        // Only an open text/code document can be promoted; a typed document
        // already owns its explicit surface, and no document means no entry.
        assertFalse(WorkspaceDocumentPresentation.offersExplicitFullWindow(1280f, WorkspaceDocumentSurface.PDF))
        assertFalse(WorkspaceDocumentPresentation.offersExplicitFullWindow(1280f, null))
        // Without actual window evidence the presentation keeps its
        // pre-existing (tablet-like) layout, so the explicit entry is still
        // offered instead of guessing phone mode from nothing.
        assertTrue(WorkspaceDocumentPresentation.offersExplicitFullWindow(null, WorkspaceDocumentSurface.CODE_EDITOR))
    }

    @Test
    fun officeKeepsItsOwnViewerAndEveryOtherDocumentGetsAnExplicitSurface() {
        // Office is already a separate full-screen Activity on every window;
        // wrapping it again would present two windows for one document.
        assertFalse(WorkspaceDocumentPresentation.presentsFullWindow(411f, WorkspaceDocumentSurface.OFFICE))
        assertFalse(WorkspaceDocumentPresentation.presentsFullWindow(1280f, WorkspaceDocumentSurface.OFFICE))
        // Typed documents never fall back to a squeezed text column.
        listOf(
            WorkspaceDocumentSurface.PDF,
            WorkspaceDocumentSurface.IMAGE,
            WorkspaceDocumentSurface.MEDIA,
            WorkspaceDocumentSurface.CAD,
            WorkspaceDocumentSurface.ARCHIVE,
            WorkspaceDocumentSurface.QUICK_LOOK,
        ).forEach { surface ->
            assertTrue(surface.name, WorkspaceDocumentPresentation.presentsFullWindow(1280f, surface))
            assertTrue(surface.name, WorkspaceDocumentPresentation.presentsFullWindow(411f, surface))
        }
    }

    @Test
    fun fullWindowOpenKeepsTheFileListRootAndTheSameDraft() {
        val (host, presenter) = presenter()
        open(host, presenter)

        // The cover's open intent must not claim the pane's editor level: the
        // pane stays rooted at the file list that Back returns to.
        assertEquals(IdeCompactLevel.FILE_LIST, presenter.state.value.compactLevel)
        assertEquals("abc", presenter.state.value.mirrorText)

        presenter.applyProjectionEdit(documentKey, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        presenter.toggleBottomPane(true)
        val edited = presenter.state.value
        assertEquals("abc!", edited.mirrorText)
        assertEquals(1, edited.pendingTransactionCount)
        assertTrue(presenter.hasUnsettledEdits())
        assertEquals(1, presenter.recoveryProjections().size)

        // Reopening the same document from the list (the user comes back to
        // it) reuses the SAME projection; nothing is evicted or reset. The
        // explicit open intent alone must not touch the projection.
        presenter.openFile("notes/plan.md", claimsPaneLevel = false)
        val reopened = presenter.state.value
        assertEquals("abc!", reopened.mirrorText)
        assertEquals(1, reopened.pendingTransactionCount)
        assertEquals(IdeCompactLevel.FILE_LIST, reopened.compactLevel)
        assertTrue(presenter.hasUnsettledEdits())
    }

    @Test
    fun staleForeignOrTemporaryDocumentRequestsNeverPresent() {
        val request = WorkspaceDocumentRequest("task-a", "ws-a", "notes/plan.md", WorkspaceDocumentSurface.CODE_EDITOR, 1L)
        assertTrue(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", "ws-a", ownerCurrent = true, temporary = false))
        // A task switch: the old task's document must not launch.
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-b", "ws-a", ownerCurrent = true, temporary = false))
        // A workspace switch under the same task id.
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", "ws-b", ownerCurrent = true, temporary = false))
        // A retired native root / replaced binding.
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", "ws-a", ownerCurrent = false, temporary = false))
        // Temporary chats stay blocked.
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", "ws-a", ownerCurrent = true, temporary = true))
        // A missing owner or blank path never presents anything.
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, null, "ws-a", ownerCurrent = true, temporary = false))
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", null, ownerCurrent = true, temporary = false))
        assertFalse(WorkspaceDocumentPresentation.requestIsCurrent(
            request.copy(path = "  "), "task-a", "ws-a", ownerCurrent = true, temporary = false,
        ))
    }

    @Test
    fun rotationKeepsTheSameDocumentInsteadOfReopeningAnotherOne() {
        // The request is rememberSaveable in the pane: after a configuration
        // change the exact same identity is restored and remains current...
        val request = WorkspaceDocumentRequest("task-a", "ws-a", "notes/plan.md", WorkspaceDocumentSurface.CODE_EDITOR, 4L)
        assertTrue(WorkspaceDocumentPresentation.requestIsCurrent(request, "task-a", "ws-a", ownerCurrent = true, temporary = false))
        // ...and the editor already holds that document, so the restored
        // cover must not re-dispatch another open (which would race the live
        // snapshot and reset the viewport).
        assertFalse(WorkspaceDocumentPresentation.needsReopen("notes/plan.md", false, request.path))
        // Only a cover with no live document (process restore / eviction)
        // issues the explicit open again, and to the same path.
        assertTrue(WorkspaceDocumentPresentation.needsReopen(null, false, request.path))
        assertTrue(WorkspaceDocumentPresentation.needsReopen("other.md", false, request.path))
        // A rotation during the load must not dispatch a second open.
        assertFalse(WorkspaceDocumentPresentation.needsReopen(null, true, request.path))
    }

    @Test
    fun closingAndReopeningTheCoverNeverDiscardsEdits() {
        val (host, presenter) = presenter()
        open(host, presenter)
        presenter.applyProjectionEdit(documentKey, IdeUtf16Range(3, 3), "?", IdeEditOrigin.USER_TYPING)
        assertTrue(presenter.hasUnsettledEdits())

        // Closing the cover only clears navigation chrome; it issues no
        // close/discard command and keeps every projection.
        presenter.showCompactFileList()
        assertEquals(1, presenter.state.value.pendingTransactionCount)
        assertEquals("abc?", presenter.state.value.mirrorText)
        assertTrue(presenter.hasUnsettledEdits())
        assertTrue(presenter.recoveryProjections().isNotEmpty())

        // No discard/close command was sent to the host by that navigation.
        assertTrue(host.commands.none { it is IdeCommandRequest.CloseDocument })
    }
}
