// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeCommandPayload
import com.floe.android.feature.ide.api.IdeCommandReply
import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeDocumentCapabilities
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeOwnerScope
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeRecoverySource
import com.floe.android.feature.ide.api.IdeReplyOutcome
import com.floe.android.feature.ide.api.IdeTabDescriptor
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeTextSelection
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Selection-ownership and stale-lineage regressions for the IDE presenter,
 * reproducing the ACTUAL rapid select-all-replace ordering observed on a
 * real editor (device-proven 2026-10-25): Sora replaces a full selection
 * with one DELETE event followed by per-character INSERT events, selection
 * reports interleave with the queued chain, and a host stale reply can land
 * mid-chain. Proves:
 *  - a stale reply whose native body is byte-identical to the chain base is
 *    a lineage-only move: the user's unacknowledged edits are re-stamped
 *    and resubmitted (no dropped keystrokes, no editor rewind command, no
 *    rejected tail), while native CAS still gates every application;
 *  - a genuinely changed body keeps the full flush/reject/recoverable-tail
 *    authority path, and the rewind no longer re-asserts the stale native
 *    selection echo over the renderer's latest caret report (the echo made
 *    the next keystroke replace the whole adopted body and resurfaced as a
 *    stale "N selected" header after every view reconstruction);
 *  - caret-authoritative native adoptions (undo/reopen/replace/resolve)
 *    still win over older local reports.
 */
class IdePresenterSelectionOwnershipTest {

    private val owner get() = IdeOwnerScope("task", "ws", 7L)
    private val key get() = IdeDocumentKey("task", "ws", "doc-1")

    /** The exact 20-byte saved baseline of the observed repro. */
    private val baselineBody = "EXTERNAL_C04_SECOND\n"

    /** The exact 41-byte draft the observed repro expected to survive. */
    private val expectedDraft = "print(\"C05_IDE_RUN_OK\")\n# LOCAL_C05_DRAFT"

    private inner class FakeHost(
        override var bindingGeneration: Long = 7L,
        override val taskId: String = "task",
        override val workspaceId: String = "ws",
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

    private fun snapshotWith(
        text: String?,
        revision: String = "r0",
        generation: Long = 0L,
        selection: IdeTextSelection? = null,
    ) = IdeDocumentSnapshot(
        key = key,
        revision = NativeRevision(revision),
        generation = generation,
        text = text,
        fileName = "probe.py",
        relativePath = "probe.py",
        capabilities = IdeDocumentCapabilities(
            undo = true, redo = true, save = true, find = true, replace = true, diff = true,
        ),
        selection = selection,
        caretUtf16 = selection?.endUtf16,
    )

    private fun tab(id: String = "doc-1", name: String = "probe.py") =
        IdeTabDescriptor(id, name, name)

    private inner class Fixture {
        val host = FakeHost()
        val presenter = IdePresenter(host)

        init {
            presenter.start()
        }
    }

    /** Open the settled 20B document exactly like the observed session. */
    private fun openBaseline(f: Fixture, selection: IdeTextSelection? = null) {
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith(baselineBody, "r0", 0, selection))
    }

    /**
     * The observed injection ordering: select-all report, then Sora's
     * replace (one DELETE of the selection, then per-character INSERTs),
     * each followed by the selection report the editor events produce.
     * Returns after [prefix] characters were typed over the selection.
     */
    private fun typeReplaceSelection(f: Fixture, prefix: String) {
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(0, baselineBody.length), 0)
        f.presenter.applyProjectionEdit(
            key, IdeUtf16Range(0, baselineBody.length), "", IdeEditOrigin.USER_DELETE)
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(0, 0), 0)
        for ((index, char) in prefix.withIndex()) {
            f.presenter.applyProjectionEdit(
                key, IdeUtf16Range(index, index), char.toString(), IdeEditOrigin.USER_TYPING)
            f.presenter.reportEditorSelection(
                "doc-1", IdeTextSelection(index + 1, index + 1), 0)
        }
    }

    /** Append [text] one character at a time at the growing caret, with reports. */
    private fun typeAppend(f: Fixture, text: String, startCaret: Int) {
        var caret = startCaret
        for (char in text) {
            f.presenter.applyProjectionEdit(
                key, IdeUtf16Range(caret, caret), char.toString(), IdeEditOrigin.USER_TYPING)
            caret++
            f.presenter.reportEditorSelection("doc-1", IdeTextSelection(caret, caret), 0)
        }
    }

    /**
     * Drain the submitted chain the way the native session does: every
     * transaction must arrive with the revision of the previous
     * acknowledgement (strict CAS lineage), is applied to the simulated
     * native body, and is acknowledged with a fresh revision. Returns the
     * final native body.
     */
    private fun drainEditsNatively(f: Fixture, body: String, startRevision: String, fromEditIndex: Int): String {
        var nativeBody = body
        var currentRevision = startRevision
        var revisionCounter = startRevision.removePrefix("r").toInt()
        var editIndex = fromEditIndex
        while (f.presenter.state.value.pendingTransactionCount > 0) {
            val txn = f.host.edits[editIndex]
            editIndex++
            assertEquals(
                "native CAS lineage must be continuous",
                NativeRevision(currentRevision), txn.expectedRevision)
            nativeBody = nativeBody.replaceRange(
                txn.range.startUtf16, txn.range.endUtf16, txn.replacement)
            revisionCounter++
            currentRevision = "r$revisionCounter"
            f.host.receiver!!.onCommandReply(IdeCommandReply(txn.transactionId, owner, key,
                IdeReplyOutcome.Acknowledged(NativeRevision(currentRevision))))
        }
        assertEquals("every submitted edit must have been settled", editIndex, f.host.edits.size)
        return nativeBody
    }

    @Test
    fun rapidReplaceRebasesIdenticalBodyStaleReplyWithoutDroppingKeystrokes() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        assertEquals("print(", f.presenter.state.value.mirrorText)
        assertEquals(7, f.presenter.state.value.pendingTransactionCount)
        val head = f.host.edits.single()
        assertEquals(IdeUtf16Range(0, 20), head.range)
        assertEquals(NativeRevision("r0"), head.expectedRevision)
        val resetsBefore = f.presenter.state.value.editorResetVersion
        val selectionsBefore = f.host.commands.filterIsInstance<IdeCommandRequest.UpdateSelection>().size

        // The host answers the head with a stale reply whose body is
        // BYTE-IDENTICAL to the chain base: only the opaque lineage moved.
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(
                snapshotWith(baselineBody, "r7", 7, IdeTextSelection(0, 20)))))

        val state = f.presenter.state.value
        // No keystroke is dropped, no tail is rejected, no rewind commanded.
        assertEquals("print(", state.mirrorText)
        assertEquals(7, state.pendingTransactionCount)
        assertFalse(state.hasRejectedEdits)
        assertTrue(state.inputAdmissionOpen)
        assertEquals(resetsBefore, state.editorResetVersion)
        assertEquals(NativeRevision("r7"), state.snapshot?.revision)
        assertEquals(baselineBody, state.snapshot?.text)
        assertEquals(IdeSyncPlan.Keep, f.presenter.syncPlanFor("doc-1", "print(", false))
        // The same user edit retries under a distinct request attempt;
        // no old reply can acknowledge it and nothing is fabricated applied.
        assertEquals(2, f.host.edits.size)
        val reHead = f.host.edits[1]
        assertNotEquals(head.transactionId, reHead.transactionId)
        assertEquals(NativeRevision("r7"), reHead.expectedRevision)
        assertEquals(7L, reHead.generation)
        assertEquals(IdeUtf16Range(0, 20), reHead.range)
        assertEquals("", reHead.replacement)
        // Selection reports stay deferred (superseded) while the chain runs.
        assertEquals(selectionsBefore,
            f.host.commands.filterIsInstance<IdeCommandRequest.UpdateSelection>().size)

        // The rest of the observed injection: remainder, Enter, comment.
        typeAppend(f, "\"C05_IDE_RUN_OK\")", 6)
        typeAppend(f, "\n", 23)
        typeAppend(f, "# LOCAL_C05_DRAFT", 24)

        val nativeBody = drainEditsNatively(f, baselineBody, "r7", fromEditIndex = 1)
        assertEquals(expectedDraft, nativeBody)
        assertEquals(expectedDraft, f.presenter.state.value.mirrorText)
        assertEquals(41, expectedDraft.toByteArray(Charsets.UTF_8).size)
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertFalse(f.presenter.hasUnsettledEdits())
        // The deferred caret report drains after the final acknowledgement.
        val lastSelection = f.host.commands.filterIsInstance<IdeCommandRequest.UpdateSelection>().last()
        assertEquals(IdeTextSelection(41, 41), lastSelection.selection)
    }

    @Test
    fun changedBodyStaleReplyKeepsFlushRejectAndNeverReassertsStaleSelection() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        val resetsBefore = f.presenter.state.value.editorResetVersion

        // A genuinely diverged native body keeps the full authority path.
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(
                snapshotWith("EXTERNALLY_REWRITTEN\n", "r5", 5, IdeTextSelection(0, 20)))))

        val state = f.presenter.state.value
        assertEquals(0, state.pendingTransactionCount)
        assertEquals("EXTERNALLY_REWRITTEN\n", state.mirrorText)
        assertTrue(state.hasRejectedEdits)
        assertTrue(resetsBefore < state.editorResetVersion)
        val rejected = f.presenter.recoveryProjections().single()
        assertEquals(IdeRecoverySource.REJECTED, rejected.source)
        assertEquals("print(", rejected.text)
        // The rewind must restore the renderer's latest caret, collapsed -
        // never the stale (0,20) echo whose re-selection made the next
        // keystroke replace the whole adopted body.
        assertEquals(IdeTextSelection(6, 6), f.presenter.restoreSelectionFor("doc-1"))
        assertNotEquals(IdeTextSelection(0, 20), f.presenter.restoreSelectionFor("doc-1"))
    }

    @Test
    fun healthyChainReconstructionRestoresLocalCaretNotStaleSnapshotEcho() {
        val f = Fixture()
        // Snapshot echo carries an old selection (0,20); the user then
        // types a healthy, fully acknowledged chain that never refreshes it.
        openBaseline(f, selection = IdeTextSelection(0, 20))
        typeReplaceSelection(f, "print(")
        val nativeBody = drainEditsNatively(f, baselineBody, "r0", fromEditIndex = 0)
        assertEquals("print(", nativeBody)
        // The acknowledged snapshot copies preserve the lagging echo...
        assertEquals(IdeTextSelection(0, 20), f.presenter.state.value.snapshot?.selection)
        // ...so reconstruction must restore the latest local report instead.
        assertEquals(IdeTextSelection(6, 6), f.presenter.restoreSelectionFor("doc-1"))
    }

    @Test
    fun caretAuthoritativeNativeAdoptionWinsOverOlderLocalReport() {
        val f = Fixture()
        openBaseline(f, selection = IdeTextSelection(0, 0))
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(5, 5), 0)
        assertEquals(IdeTextSelection(5, 5), f.presenter.restoreSelectionFor("doc-1"))
        // An undo/reopen-style executed snapshot moves the caret natively;
        // that authoritative selection outranks the older local report.
        f.presenter.requestUndo()
        val undo = f.host.commands.filterIsInstance<IdeCommandRequest.Undo>().single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(undo.requestId, owner, key,
            IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                snapshot = snapshotWith("EXTERN", "r1", 1, IdeTextSelection(2, 4))))))
        assertEquals(IdeTextSelection(2, 4), f.presenter.restoreSelectionFor("doc-1"))
        // A newer local report takes ownership back.
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(3, 3), 0)
        assertEquals(IdeTextSelection(3, 3), f.presenter.restoreSelectionFor("doc-1"))
    }

    @Test
    fun compositionDeferredStaleAdoptionKeepsLocalCaretOwnership() {
        val f = Fixture()
        openBaseline(f, selection = IdeTextSelection(0, 0))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(2, 2), 0)
        val head = f.host.edits.single()
        // A composition window defers the stale adoption; when it closes,
        // the deferred stale snapshot still must not outrank the caret the
        // renderer actually reported.
        f.presenter.setComposing("doc-1", true)
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(
                snapshotWith("xyz", "r9", 9, IdeTextSelection(0, 3)))))
        assertEquals("EbXTERNAL_C04_SECOND\n", f.presenter.state.value.mirrorText)
        f.presenter.setComposing("doc-1", false)
        assertEquals("xyz", f.presenter.state.value.mirrorText)
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        assertEquals(IdeTextSelection(2, 2), f.presenter.restoreSelectionFor("doc-1"))
    }

    @Test
    fun oldAttemptRepliesCannotRetireOrRetryTheRebasedHead() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val old = f.host.edits.single()
        val fresh = snapshotWith(baselineBody, "r7", 7)
        f.host.receiver!!.onCommandReply(IdeCommandReply(old.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(fresh)))
        val retry = f.host.edits.last()
        assertNotEquals(old.transactionId, retry.transactionId)
        f.host.receiver!!.onCommandReply(IdeCommandReply(old.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith(baselineBody, "r8", 8))))
        f.host.receiver!!.onCommandReply(IdeCommandReply(old.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r8"))))
        assertEquals(2, f.host.edits.size)
        assertEquals(7, f.presenter.state.value.pendingTransactionCount)
        assertEquals("print(", f.presenter.state.value.mirrorText)
        assertEquals(NativeRevision("r7"), f.presenter.state.value.snapshot?.revision)
        assertEquals("print(", drainEditsNatively(f, baselineBody, "r7", 1))
    }

    @Test
    fun staleWithoutLineageProgressStopsAndRetainsTheCompleteLocalTail() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith(baselineBody, "r0", 0))))
        assertEquals(1, f.host.edits.size)
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertEquals(baselineBody, f.presenter.state.value.mirrorText)
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        assertEquals("print(", f.presenter.recoveryProjections().single().text)
        // Repeated old replies are inert, rather than another retry loop.
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith(baselineBody, "r9", 9))))
        assertEquals(1, f.host.edits.size)
        assertEquals("print(", f.presenter.recoveryProjections().single().text)
    }

    @Test
    fun foreignAndOlderGenerationStaleSnapshotsNeverClaimTheCurrentHead() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        val foreign = snapshotWith(baselineBody, "r7", 7).copy(
            key = key.copy(workspaceId = "other-workspace"))
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(foreign)))
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith(baselineBody, "r-old", -1))))
        assertEquals(1, f.host.edits.size)
        assertEquals(7, f.presenter.state.value.pendingTransactionCount)
        assertEquals("print(", f.presenter.state.value.mirrorText)
        assertEquals(NativeRevision("r0"), f.presenter.state.value.snapshot?.revision)
        assertFalse(f.presenter.state.value.hasRejectedEdits)
    }

    @Test
    fun liveSaveStaleReplySettlesOnlyItsOwnRequestWhileTypingContinues() {
        val f = Fixture()
        openBaseline(f)
        f.presenter.requestSave()
        val save = f.host.commands.filterIsInstance<IdeCommandRequest.Save>().single()
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        val current = snapshotWith(baselineBody, "r7", 7)
        f.host.receiver!!.onCommandReply(IdeCommandReply(save.requestId, owner, key,
            IdeReplyOutcome.StaleRevision(current)))
        assertFalse(f.presenter.state.value.saveInFlight)
        assertEquals(1, f.host.edits.size)
        assertEquals(7, f.presenter.state.value.pendingTransactionCount)
        assertEquals("print(", f.presenter.state.value.mirrorText)
        // Only this edit's own refusal can authorize its fresh attempt.
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(current)))
        assertEquals(2, f.host.edits.size)
        assertNotEquals(head.transactionId, f.host.edits.last().transactionId)
    }

    @Test
    fun unchangedBodyReloadKeepsProjectionWithoutDuplicatingAnInflightEdit() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        val resets = f.presenter.state.value.editorResetVersion
        val fresh = snapshotWith(baselineBody, "r7", 7, IdeTextSelection(0, 20))
        f.host.receiver!!.onDocumentSnapshot(fresh)
        assertEquals(1, f.host.edits.size)
        assertEquals("print(", f.presenter.state.value.mirrorText)
        assertEquals(7, f.presenter.state.value.pendingTransactionCount)
        assertEquals(resets, f.presenter.state.value.editorResetVersion)
        assertFalse(f.presenter.state.value.hasRejectedEdits)
        assertEquals(IdeTextSelection(6, 6), f.presenter.restoreSelectionFor("doc-1"))
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(fresh)))
        assertEquals("print(", drainEditsNatively(f, baselineBody, "r7", 1))
    }

    @Test
    fun laterNativeSnapshotReplacesADeferredStaleCaretAuthority() {
        val f = Fixture()
        openBaseline(f)
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        f.presenter.setComposing("doc-1", true)
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith("STALE", "r8", 8, IdeTextSelection(0, 5)))))
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(2, 2), 0)
        f.host.receiver!!.onDocumentSnapshot(
            snapshotWith("HOST", "r9", 9, IdeTextSelection(1, 1)))
        f.presenter.setComposing("doc-1", false)
        assertEquals("HOST", f.presenter.state.value.mirrorText)
        assertEquals(IdeTextSelection(1, 1), f.presenter.restoreSelectionFor("doc-1"))
        assertEquals("print(", f.presenter.recoveryProjections().single().text)
    }

    @Test
    fun nativeUndoResultPreservesEditsTypedWhileTheCommandWasInflight() {
        val f = Fixture()
        openBaseline(f)
        f.presenter.requestUndo()
        val undo = f.host.commands.filterIsInstance<IdeCommandRequest.Undo>().single()
        typeReplaceSelection(f, "print(")
        val head = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(undo.requestId, owner, key,
            IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                snapshot = snapshotWith("UNDO_BODY", "r9", 9, IdeTextSelection(2, 2))))))
        assertEquals("UNDO_BODY", f.presenter.state.value.mirrorText)
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        assertEquals("print(", f.presenter.recoveryProjections().single().text)
        assertEquals(IdeTextSelection(2, 2), f.presenter.restoreSelectionFor("doc-1"))
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r-stale"))))
        assertEquals(NativeRevision("r9"), f.presenter.state.value.snapshot?.revision)
    }

    @Test
    fun obsoleteAndReleasedViewsHaveNoSelectionToRestore() {
        val f = Fixture()
        openBaseline(f)
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(3, 3), 0)
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-2",
            listOf(tab(), tab("doc-2", "other.py")), 2))
        assertNull(f.presenter.restoreSelectionFor("doc-1"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 3))
        assertEquals(IdeTextSelection(3, 3), f.presenter.restoreSelectionFor("doc-1"))
        f.presenter.release()
        assertNull(f.presenter.restoreSelectionFor("doc-1"))
    }
}
