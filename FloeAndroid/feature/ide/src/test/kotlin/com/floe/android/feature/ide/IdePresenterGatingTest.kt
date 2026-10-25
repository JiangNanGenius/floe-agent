// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeCloseDecision
import com.floe.android.feature.ide.api.IdeCommandPayload
import com.floe.android.feature.ide.api.IdeCommandReply
import com.floe.android.feature.ide.api.IdeCommandRequest
import com.floe.android.feature.ide.api.IdeCompletionItem
import com.floe.android.feature.ide.api.IdeCompletionSnapshot
import com.floe.android.feature.ide.api.IdeContentFragment
import com.floe.android.feature.ide.api.IdeContentRef
import com.floe.android.feature.ide.api.IdeDiagnostic
import com.floe.android.feature.ide.api.IdeDiagnosticSeverity
import com.floe.android.feature.ide.api.IdeDiagnosticSnapshot
import com.floe.android.feature.ide.api.IdeDocumentCapabilities
import com.floe.android.feature.ide.api.IdeDocumentKey
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeEditOrigin
import com.floe.android.feature.ide.api.IdeEditTransaction
import com.floe.android.feature.ide.api.IdeErrorCode
import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.api.IdeFindResult
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.api.IdeOpenReason
import com.floe.android.feature.ide.api.IdeOwnerScope
import com.floe.android.feature.ide.api.IdeReceiver
import com.floe.android.feature.ide.api.IdeReplyOutcome
import com.floe.android.feature.ide.api.IdeReplaceScope
import com.floe.android.feature.ide.api.IdeSearchHit
import com.floe.android.feature.ide.api.IdeTabDescriptor
import com.floe.android.feature.ide.api.IdeTabsSnapshot
import com.floe.android.feature.ide.api.IdeTextSelection
import com.floe.android.feature.ide.api.IdeTreeChildrenEvent
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Transaction gating + fencing tests for the IDE presenter. These prove the
 * presentation-layer rules that keep the native side authoritative: versioned
 * transactions only, stale replies dropped, rejected writes never assumed
 * success, ownership invalidation fences late callbacks, composition defers
 * adoption, and streamed bodies assemble without truncation.
 */
class IdePresenterGatingTest {

    private val owner get() = IdeOwnerScope("task", "ws", 7L)
    private val key get() = IdeDocumentKey("task", "ws", "doc-1")

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

    private fun snapshotWith(text: String, revision: String = "r0", generation: Long = 0L) =
        IdeDocumentSnapshot(
            key = key,
            revision = NativeRevision(revision),
            generation = generation,
            text = text,
            fileName = "a.txt",
            relativePath = "a.txt",
            capabilities = IdeDocumentCapabilities(
                undo = true, redo = true, save = true, find = true, replace = true, diff = true,
            ),
        )

    private inner class Fixture {
        val host = FakeHost()
        val presenter = IdePresenter(host)

        init {
            presenter.start()
        }
    }

    @Test
    fun startRequestsTreeRootWithOwnerFence() {
        val f = Fixture()
        val tree = f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().single()
        assertEquals(null, tree.parentRelativePath)
        assertEquals("task", tree.owner.taskId)
        assertEquals(7L, tree.owner.bindingGeneration)
    }

    @Test
    fun firstSyncIsFullLoadThenKeep() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.presenter.activateTab("doc-1")
        assertEquals(IdeSyncPlan.ReplaceFull("hello"), f.presenter.syncPlanFor("doc-1", "", false))
        assertEquals(IdeSyncPlan.Keep, f.presenter.syncPlanFor("doc-1", "hello", false))
    }

    @Test
    fun editEmitsVersionedTransactionAgainstBaselineRevision() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val txn = f.host.edits.single()
        assertEquals(NativeRevision("r0"), txn.expectedRevision)
        assertEquals(IdeUtf16Range(1, 1), txn.range)
        assertEquals("b", txn.replacement)
        assertEquals(owner, txn.owner)
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        // Mirror advanced immediately for the projection, revision still r0.
        assertEquals("abc", f.presenter.state.value.mirrorText)
        assertEquals(NativeRevision("r0"), f.presenter.state.value.snapshot?.revision)
    }

    @Test
    fun nativeEditAckEnablesUndoWhileUnprovenLocalInputDoesNot() {
        val f = Fixture()
        val caps = IdeDocumentCapabilities(undo = false, redo = false, save = true)
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc").copy(capabilities = caps))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        f.presenter.requestUndo()
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Undo })
        val txn = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(txn.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"), caps.copy(undo = true))))
        assertEquals("abc!", f.presenter.state.value.mirrorText)
        assertTrue(f.presenter.state.value.snapshot!!.capabilities.undo)
        assertFalse(f.presenter.state.value.snapshot!!.capabilities.redo)
        f.presenter.requestUndo()
        f.presenter.requestRedo()
        assertEquals(1, f.host.commands.filterIsInstance<IdeCommandRequest.Undo>().size)
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Redo })
    }

    @Test
    fun capabilityAckKeepsQueuedKeystrokesAndRejectsWrongOwner() {
        val f = Fixture()
        val caps = IdeDocumentCapabilities(undo = false, redo = false, save = true)
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc").copy(capabilities = caps))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(4, 4), "?", IdeEditOrigin.USER_TYPING)
        val txn = f.host.edits.single()
        val ack = IdeReplyOutcome.Acknowledged(NativeRevision("r1"), caps.copy(undo = true))
        f.host.receiver!!.onCommandReply(IdeCommandReply(txn.transactionId,
            owner.copy(bindingGeneration = 8L), key, ack))
        assertFalse(f.presenter.state.value.snapshot!!.capabilities.undo)
        assertEquals(2, f.presenter.state.value.pendingTransactionCount)
        f.host.receiver!!.onCommandReply(IdeCommandReply(txn.transactionId, owner, key, ack))
        assertEquals("abc!?", f.presenter.state.value.mirrorText)
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        assertTrue(f.presenter.state.value.snapshot!!.capabilities.undo)
        assertEquals(NativeRevision("r1"), f.host.edits.last().expectedRevision)
    }

    @Test
    fun ackAdvancesRevisionAndEmitsChainedExpectedRevision() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val txn1 = f.host.edits[0]
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(txn1.transactionId, owner, key, IdeReplyOutcome.Acknowledged(NativeRevision("r1"))),
        )
        assertEquals(NativeRevision("r1"), f.presenter.state.value.snapshot?.revision)
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        assertEquals(NativeRevision("r1"), f.host.edits[1].expectedRevision)
    }

    @Test
    fun rapidEditsChainNativeRevisionsAndIgnoreUnknownAck() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        assertEquals(1, f.host.edits.size)
        f.host.receiver!!.onCommandReply(
            IdeCommandReply("never-sent", owner, key, IdeReplyOutcome.Acknowledged(NativeRevision("r99"))),
        )
        assertEquals(2, f.presenter.state.value.pendingTransactionCount)
        assertEquals(NativeRevision("r0"), f.presenter.state.value.snapshot?.revision)
        val first = f.host.edits.single()
        f.presenter.requestSave()
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(first.transactionId, owner, key, IdeReplyOutcome.Acknowledged(NativeRevision("r1"))),
        )
        val second = f.host.edits[1]
        assertEquals(NativeRevision("r1"), second.expectedRevision)
        assertEquals(IdeUtf16Range(3, 3), second.range)
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(second.transactionId, owner, key, IdeReplyOutcome.Acknowledged(NativeRevision("r2"))),
        )
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertEquals(1, f.host.commands.filterIsInstance<IdeCommandRequest.Save>().size)
        assertEquals("abc!", f.presenter.state.value.mirrorText)
    }

    @Test
    fun longNativeDelayCompactsTailWithoutLosingUnicodeOrSavingAPrefix() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith(""))
        val desired = StringBuilder()
        repeat(400) { index ->
            val value = if (index % 3 == 0) "汉🙂" else "x"
            val at = desired.length
            desired.append(value)
            f.presenter.applyProjectionEdit(key, IdeUtf16Range(at, at), value, IdeEditOrigin.USER_IME_COMMIT)
            assertTrue(f.presenter.state.value.pendingTransactionCount <= 32)
        }
        assertEquals(1, f.host.edits.size)
        repeat(100) { f.presenter.requestSave() }
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
        var nativeText = ""
        var settled = 0
        while (f.presenter.state.value.pendingTransactionCount > 0) {
            val transaction = f.host.edits[settled]
            assertEquals(NativeRevision("r$settled"), transaction.expectedRevision)
            nativeText = nativeText.replaceRange(transaction.range.startUtf16,
                transaction.range.endUtf16, transaction.replacement)
            settled++
            f.host.receiver!!.onCommandReply(IdeCommandReply(transaction.transactionId, owner, key,
                IdeReplyOutcome.Acknowledged(NativeRevision("r$settled"))))
            assertEquals(nativeText, f.presenter.state.value.snapshot?.text)
        }
        assertEquals(desired.toString(), nativeText)
        assertEquals(desired.toString(), f.presenter.state.value.mirrorText)
        assertEquals(1, f.host.commands.filterIsInstance<IdeCommandRequest.Save>().size)
    }

    @Test
    fun rejectedCompactedTailRestoresAgainstExactAcceptedHeadBody() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("a"))
        repeat(100) { index ->
            f.presenter.applyProjectionEdit(key, IdeUtf16Range(index + 1, index + 1), "x", IdeEditOrigin.USER_TYPING)
        }
        val desired = f.presenter.state.value.mirrorText
        val head = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"))))
        assertEquals("ax", f.presenter.state.value.snapshot?.text)
        val rejected = f.host.edits[1]
        f.host.receiver!!.onCommandReply(IdeCommandReply(rejected.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written")))
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ax", "r1"))
        f.presenter.restoreRejectedEdits()
        assertEquals(desired, f.presenter.state.value.mirrorText)
        assertEquals(NativeRevision("r1"), f.host.edits.last().expectedRevision)
    }

    @Test
    fun ownerDrainFencesNewInputButSettlesAlreadyDispatchedText() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val head = f.host.edits.single()
        f.presenter.setInputAdmission(false)
        assertFalse(f.presenter.state.value.inputAdmissionOpen)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        f.presenter.requestSave()
        assertEquals("abc", f.presenter.state.value.mirrorText)
        assertTrue(f.presenter.hasUnsettledEdits())
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"))))
        assertFalse(f.presenter.hasUnsettledEdits())
        assertEquals("abc", f.presenter.state.value.snapshot?.text)
        f.presenter.setInputAdmission(true)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        assertEquals(NativeRevision("r1"), f.host.edits.last().expectedRevision)
    }

    @Test
    fun pendingBackgroundTabCannotLookDrainedWhenActiveTabIsClean() {
        val f = Fixture()
        val otherKey = key.copy(documentId = "doc-2")
        val tabs = listOf(tab(), tab().copy(documentId = "doc-2"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", tabs, 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("a"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "x", IdeEditOrigin.USER_TYPING)
        val head = f.host.edits.single()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("clean").copy(key = otherKey))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-2", tabs, 2))
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertTrue(f.presenter.hasUnsettledEdits())
        f.host.receiver!!.onCommandReply(IdeCommandReply(head.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"))))
        assertFalse(f.presenter.hasUnsettledEdits())
    }

    @Test
    fun staleRevisionFlushesChainAndAdoptsAuthoritative() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        // A stale first edit flushes its unsent tail and deferred Save. None
        // may be applied against a different native body's ranges.
        assertEquals(1, f.host.edits.size)
        f.presenter.requestSave()
        val first = f.host.edits.single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(first.transactionId, owner, key, IdeReplyOutcome.StaleRevision(snapshotWith("xyz", "r9", generation = 9))),
        )
        val state = f.presenter.state.value
        assertEquals(0, state.pendingTransactionCount)
        assertEquals("xyz", state.mirrorText)
        assertEquals(NativeRevision("r9"), state.snapshot?.revision)
        assertEquals(1, f.host.edits.size)
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
        // The rejected local tail is offered for an explicit user restore,
        // never silently assumed applied.
        assertTrue(state.hasRejectedEdits)
    }

    @Test
    fun failedTransactionFlushesChainAndRequestsResync() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val txn = f.host.edits.single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(txn.transactionId, owner, key, IdeReplyOutcome.Failed(IdeErrorCode.IO, "disk busy")),
        )
        val state = f.presenter.state.value
        assertEquals(0, state.pendingTransactionCount)
        assertNotNull(state.syncError)
        assertTrue(state.hasRejectedEdits)
        // A resync open was requested so the host re-pushes the draft truth.
        assertTrue(f.host.commands.any { it is IdeCommandRequest.OpenFile && it.reason == IdeOpenReason.TAB_RESTORE })
    }

    @Test
    fun restoreRejectedEditsReappliesAsGatedTransaction() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val txn = f.host.edits.single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(txn.transactionId, owner, key, IdeReplyOutcome.Failed(IdeErrorCode.IO, "disk busy")),
        )
        // After the resync snapshot arrives back at "ac", the user restores.
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac", "r0"))
        f.presenter.restoreRejectedEdits()
        assertEquals(2, f.host.edits.size)
        assertEquals("abc", f.presenter.state.value.mirrorText)
        assertFalse(f.presenter.state.value.hasRejectedEdits)
    }

    @Test
    fun rejectedRestoreRebasesCompleteTextAfterAnotherNativeChange() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val rejected = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(rejected.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith("xyz", "r1", 1))))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("whole different base", "r2", 2))
        f.presenter.restoreRejectedEdits()
        val restore = f.host.edits.last()
        assertEquals("abc", "whole different base".replaceRange(restore.range.startUtf16,
            restore.range.endUtf16, restore.replacement))
        assertEquals(NativeRevision("r2"), restore.expectedRevision)
        assertEquals("abc", f.presenter.state.value.mirrorText)
    }

    @Test
    fun rejectedTailSurvivesStreamedNativeResyncAndWaitsForCompleteBody() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val rejected = f.host.edits.single()
        val ref = IdeContentRef("after-git", key, NativeRevision("r9"), totalUtf16 = 6,
            fragmentUtf16 = 3, transport = "effect-page")
        f.host.receiver!!.onCommandReply(IdeCommandReply(rejected.transactionId, owner, key,
            IdeReplyOutcome.StaleRevision(snapshotWith("", "r9", 9).copy(text = null, contentRef = ref))))
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        f.presenter.restoreRejectedEdits()
        assertEquals(1, f.host.edits.size)
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        f.host.receiver!!.onContentFragment(IdeContentFragment(ref, 0, "oth", isLast = false))
        f.presenter.restoreRejectedEdits()
        assertEquals(1, f.host.edits.size)
        f.host.receiver!!.onContentFragment(IdeContentFragment(ref, 3, "er!", isLast = true))
        f.presenter.restoreRejectedEdits()
        val restore = f.host.edits.last()
        assertEquals("abc", "other!".replaceRange(restore.range.startUtf16,
            restore.range.endUtf16, restore.replacement))
        assertEquals(NativeRevision("r9"), restore.expectedRevision)
        assertFalse(f.presenter.state.value.hasRejectedEdits)
    }

    @Test
    fun rejectedRestoreBeforeResyncDoesNotMistakeTheOptimisticMirrorForNativeText() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val rejected = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(rejected.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written")))
        f.presenter.restoreRejectedEdits()
        assertEquals(2, f.host.edits.size)
        val restore = f.host.edits.last()
        assertEquals("abc", "ac".replaceRange(restore.range.startUtf16, restore.range.endUtf16, restore.replacement))
        assertEquals("abc", f.presenter.state.value.mirrorText)
    }

    @Test
    fun recoveryExportsExactRejectedTextWithStableRetryIdentityAndRefusesChangedProof() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "中🙂", IdeEditOrigin.USER_TYPING)
        val edit = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(edit.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written")))
        val row = f.presenter.recoveryProjections().single()
        assertEquals("a中🙂c", row.text)
        assertEquals(row.recoveryId, f.presenter.recoveryProjections().single().recoveryId)
        assertFalse(f.presenter.acknowledgeRecoveredProjection(row.copy(text = "partial")))
        assertTrue(f.presenter.hasUnsettledEdits())
        assertTrue(f.presenter.acknowledgeRecoveredProjection(row))
        assertFalse(f.presenter.hasUnsettledEdits())
        assertEquals("ac", f.presenter.state.value.mirrorText)
    }

    @Test
    fun preservingRejectedBranchCannotClearANewerPendingTypingChain() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "b", IdeEditOrigin.USER_TYPING)
        val first = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(first.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written")))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(2, 2), "!", IdeEditOrigin.USER_TYPING)
        val rows = f.presenter.recoveryProjections()
        val rejected = rows.single { it.text == "abc" }
        val pending = rows.single { it.text == "ac!" }
        assertTrue(rejected.recoveryId != pending.recoveryId)
        assertTrue(f.presenter.acknowledgeRecoveredProjection(rejected))
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        assertTrue(f.presenter.hasUnsettledEdits())
        val second = f.host.edits.last()
        f.host.receiver!!.onCommandReply(IdeCommandReply(second.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"))))
        assertEquals("ac!", f.presenter.state.value.snapshot?.text)
        assertFalse(f.presenter.hasUnsettledEdits())
    }

    @Test
    fun consecutiveRejectedBranchesKeepBothExactTextsAndFenceFurtherTyping() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(1, 1), "中🙂", IdeEditOrigin.USER_TYPING)
        val first = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(first.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written")))
        val firstRecovery = f.presenter.recoveryProjections().single()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(2, 2), "!", IdeEditOrigin.USER_TYPING)
        val second = f.host.edits.last()
        f.host.receiver!!.onCommandReply(IdeCommandReply(second.transactionId, owner, key,
            IdeReplyOutcome.Failed(IdeErrorCode.IO, "not written again")))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("ac"))
        val recoveries = f.presenter.recoveryProjections()
        assertEquals(setOf("a中🙂c", "ac!"), recoveries.map { it.text }.toSet())
        assertEquals(firstRecovery.recoveryId, recoveries.single { it.text == "a中🙂c" }.recoveryId)
        assertFalse(f.presenter.state.value.inputAdmissionOpen)
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(2, 2), "lost?", IdeEditOrigin.USER_TYPING)
        assertEquals(2, f.host.edits.size)
        assertTrue(f.presenter.acknowledgeRecoveredProjection(firstRecovery))
        assertEquals("ac!", f.presenter.recoveryProjections().single().text)
        assertTrue(f.presenter.acknowledgeRecoveredProjection(f.presenter.recoveryProjections().single()))
        assertFalse(f.presenter.hasUnsettledEdits())
        assertTrue(f.presenter.state.value.inputAdmissionOpen)
    }

    @Test
    fun composingTextBlocksStopAcknowledgementUntilFinishedOrExplicitlyDiscarded() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("中文"))
        f.presenter.setComposing("doc-1", true)
        assertTrue(f.presenter.hasUnsettledEdits())
        val row = f.presenter.recoveryProjections().single()
        assertTrue(row.composing)
        assertFalse(f.presenter.acknowledgeRecoveredProjection(row))
        assertTrue(f.presenter.discardRecoveryProjection(row))
        assertFalse(f.presenter.hasUnsettledEdits())
        assertEquals("中文", f.presenter.state.value.mirrorText)
    }

    @Test
    fun compositionDefersAuthoritativeAdoptionAndSync() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        f.presenter.setComposing("doc-1", true)
        // A newer native snapshot arrives while the IME window is open.
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("external", "r1", generation = 1))
        // While composing, the projection must not be reset over marked text.
        assertEquals(IdeSyncPlan.Keep, f.presenter.syncPlanFor("doc-1", "helloX", true))
        // And the presenter never adopts into the mirror yet.
        assertEquals("hello", f.presenter.state.value.mirrorText)
        // Composition window closes → adoption flushes.
        f.presenter.setComposing("doc-1", false)
        assertEquals("external", f.presenter.state.value.mirrorText)
        assertEquals(IdeSyncPlan.ReplaceFull("external"), f.presenter.syncPlanFor("doc-1", "helloX", false))
    }

    @Test
    fun releaseFencesEveryLaterCallback() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        val lateReceiver = f.host.receiver!!
        f.presenter.release()
        assertNull(f.host.receiver)
        lateReceiver.onDocumentSnapshot(snapshotWith("gone", "r1"))
        lateReceiver.onTabs(IdeTabsSnapshot(owner, null, emptyList(), 2))
        // State remains frozen at the release boundary: late pushes ignored.
        assertEquals("hello", f.presenter.state.value.mirrorText)
        assertEquals(NativeRevision("r0"), f.presenter.state.value.snapshot?.revision)
    }

    @Test
    fun ownerGenerationMismatchIsDropped() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        val staleOwner = IdeOwnerScope("task", "ws", 6L)
        f.host.receiver!!.onTabs(IdeTabsSnapshot(staleOwner, "doc-1", listOf(tab()), 1))
        // Old-generation tabs are ignored; the view keeps the current binding.
        assertEquals(7L, f.presenter.state.value.bindingGeneration)
        assertTrue(f.presenter.state.value.tabs.isEmpty())
    }

    @Test
    fun taskMismatchIsDropped() {
        val f = Fixture()
        val foreign = IdeDocumentKey("other-task", "ws", "doc-1")
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("x").copy(key = foreign))
        assertNull(f.presenter.state.value.mirrorText)
    }

    @Test
    fun closedTabDropsDocumentStateAndLateAckIsInert() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        val txnId = f.host.edits.single().transactionId
        // Host closes the tab (native authority).
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, null, emptyList(), 3))
        assertEquals(0, f.presenter.state.value.tabs.size)
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(txnId, owner, key, IdeReplyOutcome.Acknowledged(NativeRevision("r1"))),
        )
        // The late ack finds no document and cannot resurrect it.
        assertEquals(0, f.presenter.state.value.tabs.size)
    }

    @Test
    fun dirtyCloseGoesThroughDecisionRequest() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab(dirty = true)), 1))
        f.presenter.requestCloseTab("doc-1")
        assertNotNull(f.presenter.state.value.closeRequest)
        f.presenter.resolveCloseRequest(IdeCloseDecision.SAVE)
        assertTrue(f.host.commands.any { it is IdeCommandRequest.CloseDocument && it.decision == IdeCloseDecision.SAVE })
    }

    @Test
    fun cleanTabClosesDirectly() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab(dirty = false)), 1))
        f.presenter.requestCloseTab("doc-1")
        assertNull(f.presenter.state.value.closeRequest)
        assertTrue(f.host.commands.any { it is IdeCommandRequest.CloseDocument })
    }

    @Test
    fun findStaleResultRetriesOnceThenSurfacesHonestly() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        f.presenter.updateFindQuery("ell")
        val find1 = f.host.commands.filterIsInstance<IdeCommandRequest.Find>().last()
        // Host answers for an OLD revision → presenter re-requests once.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(find1.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.FIND, find = IdeFindResult(key, NativeRevision("old"), "ell", false, false, listOf(IdeUtf16Range(1, 4)))),
            )),
        )
        assertEquals(2, f.host.commands.filterIsInstance<IdeCommandRequest.Find>().size)
        val find2 = f.host.commands.filterIsInstance<IdeCommandRequest.Find>().last()
        // Second stale answer → honest stale error, no infinite retry.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(find2.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.FIND, find = IdeFindResult(key, NativeRevision("old"), "ell", false, false, listOf(IdeUtf16Range(1, 4)))),
            )),
        )
        val state = f.presenter.state.value
        assertEquals("stale", state.find.error)
        assertEquals(2, f.host.commands.filterIsInstance<IdeCommandRequest.Find>().size)
    }

    @Test
    fun findFreshResultAppliesSelectionRequest() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        f.presenter.updateFindQuery("ell")
        val find = f.host.commands.filterIsInstance<IdeCommandRequest.Find>().single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(find.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.FIND, find = IdeFindResult(key, NativeRevision("r0"), "ell", false, false, listOf(IdeUtf16Range(1, 4)))),
            )),
        )
        val state = f.presenter.state.value
        assertEquals(1, state.find.hitCount)
        assertEquals(IdeUtf16Range(1, 4), state.editorSelectionRequest)
        assertEquals(1, state.editorSelectionRequestVersion)
    }

    @Test
    fun replaceCurrentOnlyWithFreshHitAndRevision() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello", "r0"))
        f.presenter.updateFindQuery("ell")
        f.presenter.replaceCurrent() // no results yet → no command
        assertTrue(f.host.commands.filterIsInstance<IdeCommandRequest.Replace>().isEmpty())
        val find = f.host.commands.filterIsInstance<IdeCommandRequest.Find>().single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(find.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.FIND, find = IdeFindResult(key, NativeRevision("r0"), "ell", false, false, listOf(IdeUtf16Range(1, 4)))),
            )),
        )
        f.presenter.updateFindReplacement("EL")
        f.presenter.replaceCurrent()
        val replace = f.host.commands.filterIsInstance<IdeCommandRequest.Replace>().single()
        assertEquals(IdeReplaceScope.CURRENT, replace.scope)
        assertEquals(NativeRevision("r0"), replace.expectedRevision)
    }

    @Test
    fun replaceForwardsActualWholeWordIntentToHost() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello world hello", "r0"))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.presenter.updateFindQuery("hello")
        f.presenter.setFindWholeWord(true)
        val find2 = f.host.commands.filterIsInstance<IdeCommandRequest.Find>().last()
        assertTrue(find2.wholeWord)
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(find2.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(
                    kind = IdeCommandPayload.Kind.FIND,
                    find = IdeFindResult(key, NativeRevision("r0"), "hello", false, true, listOf(IdeUtf16Range(0, 5), IdeUtf16Range(12, 17))),
                ),
            )),
        )
        f.presenter.updateFindReplacement("hi")
        f.presenter.replaceCurrent()
        val current = f.host.commands.filterIsInstance<IdeCommandRequest.Replace>().single()
        assertEquals(IdeReplaceScope.CURRENT, current.scope)
        assertTrue("host must not guess whole-word", current.wholeWord)
        f.presenter.replaceAll()
        val all = f.host.commands.filterIsInstance<IdeCommandRequest.Replace>().last()
        assertEquals(IdeReplaceScope.ALL, all.scope)
        assertTrue(all.wholeWord)
        assertEquals(NativeRevision("r0"), all.expectedRevision)
    }

    @Test
    fun staleTreeChildrenAndSearchNeverOverwriteNewerResults() {
        val f = Fixture()
        val tree = f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().single()
        val gen = tree.requestGeneration
        // Apply the newer generation first.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(tree.requestId, owner, null, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.TREE_CHILDREN, treeChildren = IdeTreeChildrenEvent(owner, null, gen, listOf(file("new.kt")))),
            )),
        )
        assertEquals(listOf("new.kt"), f.presenter.state.value.tree.rows.map { it.file.name })
        // An older-generation reply for the same parent must be ignored.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply("other", owner, null, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.TREE_CHILDREN, treeChildren = IdeTreeChildrenEvent(owner, null, gen - 1, listOf(file("old.kt")))),
            )),
        )
        assertEquals(listOf("new.kt"), f.presenter.state.value.tree.rows.map { it.file.name })

        f.presenter.setTreeSearchQuery("ab")
        val search = f.host.commands.filterIsInstance<IdeCommandRequest.RequestWorkspaceSearch>().single()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(search.requestId, owner, null, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.WORKSPACE_SEARCH, search = com.floe.android.feature.ide.api.IdeWorkspaceSearchResult(owner, "ab", search.queryGeneration, listOf(hit("abc.kt")))),
            )),
        )
        assertEquals(1, f.presenter.state.value.tree.searchHits.size)
        // Same query but OLDER generation arriving late → ignored.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply("late", owner, null, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.WORKSPACE_SEARCH, search = com.floe.android.feature.ide.api.IdeWorkspaceSearchResult(owner, "ab", search.queryGeneration - 1, listOf(hit("zzz.kt"), hit("yyy.kt")))),
            )),
        )
        assertEquals(1, f.presenter.state.value.tree.searchHits.size)
        // A different (older) query's result arriving late → ignored.
        f.host.receiver!!.onCommandReply(
            IdeCommandReply("late2", owner, null, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.WORKSPACE_SEARCH, search = com.floe.android.feature.ide.api.IdeWorkspaceSearchResult(owner, "a", search.queryGeneration, listOf(hit("q.kt")))),
            )),
        )
        assertEquals(1, f.presenter.state.value.tree.searchHits.size)
    }

    @Test
    fun completionAndDiagnosticsRejectStaleRevisionSameDocument() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        val caps = IdeDocumentCapabilities(completion = true)
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0").copy(capabilities = caps))
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(1, 1), 0)
        val request = f.host.commands.filterIsInstance<IdeCommandRequest.RequestCompletion>().single()
        // Stale revision rejected.
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, request.requestId, NativeRevision("r-old"), IdeTextSelection(1, 1), listOf(comp("nope"))),
        )
        assertTrue(f.presenter.hostCompletionItems("doc-1", NativeRevision("r0"), 1).isEmpty())
        // Wrong request identity rejected.
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, "forged", NativeRevision("r0"), IdeTextSelection(1, 1), listOf(comp("nope"))),
        )
        assertTrue(f.presenter.hostCompletionItems("doc-1", NativeRevision("r0"), 1).isEmpty())
        // Fresh revision + current request accepted.
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, request.requestId, NativeRevision("r0"), IdeTextSelection(1, 1), listOf(comp("yes"))),
        )
        assertEquals("yes", f.presenter.hostCompletionItems("doc-1", NativeRevision("r0"), 1).single().label)

        // Diagnostics: stale revision rejected, fresh accepted.
        f.host.receiver!!.onDiagnostics(IdeDiagnosticSnapshot(key, NativeRevision("r-stale"), listOf(diag(1, "old"))))
        assertTrue(f.presenter.state.value.diagnostics.isEmpty())
        f.host.receiver!!.onDiagnostics(IdeDiagnosticSnapshot(key, NativeRevision("r0"), listOf(diag(2, "fresh"))))
        assertEquals(1, f.presenter.state.value.diagnostics.size)
    }

    @Test
    fun streamedBodyAssemblesWithoutTruncation() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        val ref = IdeContentRef("h1", key, NativeRevision("r0"), totalUtf16 = 8, fragmentUtf16 = 5, transport = "effect-page")
        f.host.receiver!!.onDocumentSnapshot(snapshotWith(text = "", revision = "r0").copy(text = null, contentRef = ref))
        // Loading state while streaming; no partial success.
        assertTrue(f.presenter.state.value.documentLoading)
        assertNull(f.presenter.state.value.mirrorText)
        val fragReq = f.host.commands.filterIsInstance<IdeCommandRequest.RequestContentFragment>().single()
        assertEquals(0, fragReq.startUtf16)
        f.host.receiver!!.onContentFragment(IdeContentFragment(ref, 0, "hello-", isLast = false))
        // Still incomplete.
        assertTrue(f.presenter.state.value.documentLoading)
        f.host.receiver!!.onContentFragment(IdeContentFragment(ref, 6, "world", isLast = true))
        assertEquals("hello-world", f.presenter.state.value.mirrorText)
        assertFalse(f.presenter.state.value.documentLoading)
    }

    @Test
    fun outOfOrderFragmentTriggersReRequest() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        val ref = IdeContentRef("h1", key, NativeRevision("r0"), totalUtf16 = 8, fragmentUtf16 = 4, transport = "effect-page")
        f.host.receiver!!.onDocumentSnapshot(snapshotWith(text = "", revision = "r0").copy(text = null, contentRef = ref))
        f.host.receiver!!.onContentFragment(IdeContentFragment(ref, 4, "tail", isLast = true))
        // Too-early fragment: presenter re-requests from the true offset.
        val requests = f.host.commands.filterIsInstance<IdeCommandRequest.RequestContentFragment>()
        assertEquals(2, requests.size)
        assertEquals(0, requests[1].startUtf16)
    }

    @Test
    fun saveOutcomeAdvancesRevisionAndSurfacesConflictPayload() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.requestSave()
        val save = f.host.commands.filterIsInstance<IdeCommandRequest.Save>().single()
        assertTrue(f.presenter.state.value.saveInFlight)
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(save.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE, save = com.floe.android.feature.ide.api.IdeSaveOutcome(NativeRevision("r1"))),
            )),
        )
        assertFalse(f.presenter.state.value.saveInFlight)
        assertEquals(NativeRevision("r1"), f.presenter.state.value.snapshot?.revision)
        // Now a conflicting save.
        f.presenter.requestSave()
        val save2 = f.host.commands.filterIsInstance<IdeCommandRequest.Save>().last()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(save2.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE, save = com.floe.android.feature.ide.api.IdeSaveOutcome(
                    NativeRevision("r1"),
                    conflict = com.floe.android.feature.ide.api.IdeConflictPayload(key, "base", "mine", "theirs", NativeRevision("r2")),
                )),
            )),
        )
        val conflict = f.presenter.state.value.conflict!!
        assertEquals("mine", conflict.localDraftText)
        assertEquals("theirs", conflict.remoteText)
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_LOCAL, "mine")
        assertTrue(f.host.commands.any { it is IdeCommandRequest.ResolveConflict })
    }

    @Test
    fun capabilityGatingBlocksDisabledCommands() {
        val f = Fixture()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0").copy(capabilities = IdeDocumentCapabilities()))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.presenter.activateTab("doc-1")
        f.presenter.requestUndo()
        f.presenter.requestRedo()
        f.presenter.requestRun()
        f.presenter.requestOpenPreview()
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Undo })
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Redo })
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Run })
        assertTrue(f.host.commands.none { it is IdeCommandRequest.OpenPreview })
    }

    @Test
    fun rapidTabSwitchKeepsEachProjectionAndFencesOlderDocEdits() {
        val f = Fixture()
        val keyA = key
        val keyB = IdeDocumentKey("task", "ws", "doc-2")
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("AAA", "ra"))
        f.host.receiver!!.onDocumentSnapshot(
            snapshotWith("BBB", "rb").copy(key = keyB, fileName = "b.txt", relativePath = "b.txt"),
        )
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab(), tab("doc-2", "b.txt")), 1))
        f.presenter.activateTab("doc-1")
        f.presenter.applyProjectionEdit(keyA, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        f.presenter.activateTab("doc-2")
        // doc-1 keeps its projection mirror (unsaved text survives switches).
        assertEquals(IdeSyncPlan.Keep, f.presenter.syncPlanFor("doc-1", "AAA!", false))
        assertEquals(IdeSyncPlan.ReplaceFull("BBB"), f.presenter.syncPlanFor("doc-2", "AAA!", false))
        // An edit attributed to doc-1 while doc-2 is active still chains on doc-1's own baseline.
        f.presenter.applyProjectionEdit(keyA, IdeUtf16Range(4, 4), "?", IdeEditOrigin.USER_TYPING)
        val first = f.host.edits.single()
        assertEquals(keyA, first.documentKey)
        f.host.receiver!!.onCommandReply(IdeCommandReply(first.transactionId, owner, keyA,
            IdeReplyOutcome.Acknowledged(NativeRevision("ra1"))))
        val doc1Edits = f.host.edits.filter { it.documentKey.documentId == "doc-1" }
        assertEquals(2, doc1Edits.size)
        assertEquals(NativeRevision("ra1"), doc1Edits.last().expectedRevision)
        assertEquals(NativeRevision("rb"), f.presenter.state.value.snapshot?.revision)
    }

    @Test
    fun pushedBaselineDoesNotEraseInFlightTextAndNewLineagePreservesRejectedTail() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("base", "r0"))
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(4, 4), "!", IdeEditOrigin.USER_TYPING)
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("base", "r0"))
        assertEquals("base!", f.presenter.state.value.mirrorText)
        assertEquals(1, f.presenter.state.value.pendingTransactionCount)
        f.presenter.requestSave()
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("external", "r9", 9))
        assertEquals("external", f.presenter.state.value.mirrorText)
        assertEquals(0, f.presenter.state.value.pendingTransactionCount)
        assertTrue(f.presenter.state.value.hasRejectedEdits)
        assertTrue(f.host.commands.none { it is IdeCommandRequest.Save })
    }

    @Test
    fun updateSelectionDeduplicatesAndCarriesOwner() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(1, 1), 0)
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(1, 1), 0)
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(2, 2), 0)
        val updates = f.host.commands.filterIsInstance<IdeCommandRequest.UpdateSelection>()
        assertEquals(2, updates.size)
        assertEquals(owner, updates.first().owner)
    }

    private fun tab(id: String = "doc-1", name: String = "a.txt", dirty: Boolean = false) =
        IdeTabDescriptor(id, name, name, dirty = dirty)

    private fun file(name: String) = IdeFileRow(name, name, false)

    private fun hit(path: String) = IdeSearchHit(path, null, 0, "ctx")

    private fun comp(label: String) = IdeCompletionItem(label, label)

    private fun diag(id: Long, msg: String) =
        IdeDiagnostic(id, IdeUtf16Range(0, 1), IdeDiagnosticSeverity.WARNING, msg)

    @Test
    fun acceptedCompletionBumpsVersionAndRejectedOnesDoNot() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        val caps = IdeDocumentCapabilities(completion = true)
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0").copy(capabilities = caps))
        f.presenter.reportEditorSelection("doc-1", IdeTextSelection(1, 1), 0)
        val request = f.host.commands.filterIsInstance<IdeCommandRequest.RequestCompletion>().single()
        assertEquals(0, f.presenter.state.value.completionVersion)
        // Fenced-out arrivals must not re-trigger the editor completion pass.
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, "forged", NativeRevision("r0"), IdeTextSelection(1, 1), listOf(comp("no"))))
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, request.requestId, NativeRevision("r-old"), IdeTextSelection(1, 1), listOf(comp("no2"))))
        assertEquals(0, f.presenter.state.value.completionVersion)
        // The fresh accepted arrival bumps the version exactly once.
        f.host.receiver!!.onCompletion(
            IdeCompletionSnapshot(key, request.requestId, NativeRevision("r0"), IdeTextSelection(1, 1), listOf(comp("yes"))))
        assertEquals(1, f.presenter.state.value.completionVersion)
    }

    @Test
    fun refusedRunBecomesVisibleSyncError() {
        val f = Fixture()
        val caps = IdeDocumentCapabilities(run = true)
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("hello").copy(capabilities = caps))
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.presenter.activateTab("doc-1")
        f.presenter.requestRun()
        val run = f.host.commands.filterIsInstance<IdeCommandRequest.Run>().single()
        assertNull(f.presenter.state.value.syncError)
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(run.requestId, owner, run.documentKey,
                IdeReplyOutcome.Failed(IdeErrorCode.HOST_UNAVAILABLE, "runtimeBusy")),
        )
        assertNotNull(f.presenter.state.value.syncError)
    }

    @Test
    fun resolveConflictSuccessDismissesModalAndFreshensTreeForNewCopy() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.activateTab("doc-1")
        f.host.receiver!!.onCommandReply(
            IdeCommandReply("save-c", owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE, save = com.floe.android.feature.ide.api.IdeSaveOutcome(
                    NativeRevision("r1"),
                    conflict = com.floe.android.feature.ide.api.IdeConflictPayload(key, "base", "mine", "theirs", NativeRevision("r2")),
                )),
            )),
        )
        assertNotNull(f.presenter.state.value.conflict)
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_BOTH, "mine")
        val resolve = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().single()
        // A FAILED resolve never dismisses the modal (no optimistic UI).
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(resolve.requestId, owner, resolve.documentKey,
                IdeReplyOutcome.Failed(IdeErrorCode.HOST_UNAVAILABLE, "nope")),
        )
        assertNotNull(f.presenter.state.value.conflict)
        val treesBefore = f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().size
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_BOTH, "mine")
        val resolve2 = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().last()
        // The accepted fork snapshot under a NEW docID dismisses the modal AND
        // re-requests the tree so the new copy appears without manual refresh.
        val forkKey = IdeDocumentKey("task", "ws", "doc-2")
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(resolve2.requestId, owner, resolve2.documentKey,
                IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                    snapshot = snapshotWith("forked", "rf").copy(key = forkKey)))),
        )
        assertNull(f.presenter.state.value.conflict)
        assertTrue(f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().size > treesBefore)
    }

    @Test
    fun staleSameDocResolveCannotDismissOrOverwriteANewerConflict() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.activateTab("doc-1")
        // The local draft is accepted natively before the save attempt.
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(3, 3), "!", IdeEditOrigin.USER_TYPING)
        val edit = f.host.edits.single()
        f.host.receiver!!.onCommandReply(IdeCommandReply(edit.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r1"))))
        assertEquals("abc!", f.presenter.state.value.mirrorText)
        // SAVE conflict A on doc-1: the guest changed the file externally.
        f.presenter.requestSave()
        val saveA = f.host.commands.filterIsInstance<IdeCommandRequest.Save>().last()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(saveA.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE,
                    save = com.floe.android.feature.ide.api.IdeSaveOutcome(NativeRevision("r1"),
                        conflict = com.floe.android.feature.ide.api.IdeConflictPayload(
                            key, "abc", "abc!", "external-A", NativeRevision("r2")))),
            )),
        )
        val conflictA = f.presenter.state.value.conflict!!
        // The user accepts a KEEP_LOCAL resolution; its reply is still in
        // flight when the SAME document produces a NEWER conflict B.
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_LOCAL, "abc!")
        val staleResolve = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().single()
        // Work continues on the draft: a further accepted keystroke…
        f.presenter.applyProjectionEdit(key, IdeUtf16Range(4, 4), "?", IdeEditOrigin.USER_TYPING)
        val edit2 = f.host.edits.last()
        f.host.receiver!!.onCommandReply(IdeCommandReply(edit2.transactionId, owner, key,
            IdeReplyOutcome.Acknowledged(NativeRevision("r3"))))
        // …and a second save surfaces the newer conflict on the same docID.
        f.presenter.requestSave()
        val saveB = f.host.commands.filterIsInstance<IdeCommandRequest.Save>().last()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(saveB.requestId, owner, key, IdeReplyOutcome.Executed(
                IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE,
                    save = com.floe.android.feature.ide.api.IdeSaveOutcome(NativeRevision("r3"),
                        conflict = com.floe.android.feature.ide.api.IdeConflictPayload(
                            key, "abc", "abc!?", "external-B", NativeRevision("r4")))),
            )),
        )
        val conflictB = f.presenter.state.value.conflict!!
        assertNotEquals(conflictA, conflictB) // Same docID, different conflict occurrence.
        val treesBefore = f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().size
        // The OLD resolve finally arrives as an accepted snapshot on the SAME
        // document with a no-longer-current body (native fork of the old
        // intent may exist; the UI intent moved on).
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(staleResolve.requestId, owner, staleResolve.documentKey,
                IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                    snapshot = snapshotWith("abc!", "r2-resolved")))),
        )
        val fenced = f.presenter.state.value
        assertEquals(conflictB, fenced.conflict) // the newer modal is NOT dismissed
        assertEquals("abc!?", fenced.mirrorText) // the current draft is NOT clobbered
        assertEquals(NativeRevision("r3"), fenced.snapshot?.revision)
        assertEquals(treesBefore, f.host.commands.filterIsInstance<IdeCommandRequest.ExpandTree>().size)
        // The fence is not sticky: the NEWER conflict's own successful
        // same-document resolution still dismisses and adopts.
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_LOCAL, "abc!?")
        val freshResolve = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().last()
        f.host.receiver!!.onCommandReply(
            IdeCommandReply(freshResolve.requestId, owner, freshResolve.documentKey,
                IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                    snapshot = snapshotWith("abc!?", "r5")))),
        )
        assertNull(f.presenter.state.value.conflict)
        assertEquals(NativeRevision("r5"), f.presenter.state.value.snapshot?.revision)
        assertEquals("abc!?", f.presenter.state.value.mirrorText)
    }
    @Test
    fun equalNewConflictAndNewerChoiceInvalidateOlderResolution() {
        val f = Fixture()
        f.host.receiver!!.onTabs(IdeTabsSnapshot(owner, "doc-1", listOf(tab()), 1))
        f.host.receiver!!.onDocumentSnapshot(snapshotWith("abc", "r0"))
        f.presenter.activateTab("doc-1")
        val conflict = com.floe.android.feature.ide.api.IdeConflictPayload(
            key, "base", "mine", "theirs", NativeRevision("r2"))
        fun showConflict(request: String) {
            f.host.receiver!!.onCommandReply(IdeCommandReply(request, owner, key,
                IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SAVE,
                    save = com.floe.android.feature.ide.api.IdeSaveOutcome(
                        NativeRevision("r0"), conflict = conflict.copy())))))
        }
        fun complete(request: IdeCommandRequest.ResolveConflict, text: String) {
            f.host.receiver!!.onCommandReply(IdeCommandReply(request.requestId, owner, key,
                IdeReplyOutcome.Executed(IdeCommandPayload(kind = IdeCommandPayload.Kind.SNAPSHOT,
                    snapshot = snapshotWith(text, "resolved")))))
        }
        showConflict("first-conflict")
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_LOCAL, "mine")
        val old = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().last()
        showConflict("new-equal-conflict") // Equal fields still describe a NEW occurrence.
        complete(old, "old-body")
        assertEquals(conflict, f.presenter.state.value.conflict)
        assertEquals("abc", f.presenter.state.value.mirrorText)
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.KEEP_LOCAL, "mine")
        val superseded = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().last()
        f.presenter.resolveConflict(com.floe.android.feature.ide.api.IdeConflictChoice.USE_REMOTE, "theirs")
        val latest = f.host.commands.filterIsInstance<IdeCommandRequest.ResolveConflict>().last()
        complete(superseded, "superseded-body")
        assertEquals(conflict, f.presenter.state.value.conflict)
        assertEquals("abc", f.presenter.state.value.mirrorText)
        complete(latest, "theirs")
        assertNull(f.presenter.state.value.conflict)
        assertEquals("theirs", f.presenter.state.value.mirrorText)
    }

}
