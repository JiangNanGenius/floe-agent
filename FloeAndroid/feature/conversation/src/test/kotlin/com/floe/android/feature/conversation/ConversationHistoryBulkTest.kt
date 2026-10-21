// SPDX-License-Identifier: MPL-2.0
//
// History/bulk-management presentation tests (⇄ ConversationListViewModel
// search epoch + TaskBulkSelectionRules + ConversationBatchManagementView
// frozen confirmations/receipts). Host commands are recorded, never executed;
// every assertion is about presentation state and exact effect arguments.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationHistoryBulkTest {

    @Test fun lateSameIdRenameCannotCloseAReplacementEditor() {
        val (h, host) = holder()
        val item = h.state.value!!.items.first()
        h.requestRename(item)
        h.updateRenameTitle("First new name")
        assertTrue(h.confirmRename())
        val oldToken = host.lastArgs("renameConversation")!![2] as Long
        h.cancelRename()
        h.requestRename(item)
        h.updateRenameTitle("Second new name")
        assertTrue(h.confirmRename())
        val newToken = host.lastArgs("renameConversation")!![2] as Long
        assertTrue(oldToken != newToken)
        h.applyRenameOutcome(item.id, oldToken, true)
        assertEquals(newToken, h.pendingRename.value!!.requestToken)
        assertTrue(h.pendingRename.value!!.inFlight)
        h.applyRenameOutcome(item.id, newToken, true)
        assertNull(h.pendingRename.value)
    }

    @Test fun failedRenameKeepsTheActualDraftForExplicitRetry() {
        val (h, host) = holder()
        val item = h.state.value!!.items.first()
        h.requestRename(item)
        h.updateRenameTitle("中文 🖊️ draft")
        assertTrue(h.confirmRename())
        val token = host.lastArgs("renameConversation")!![2] as Long
        h.applyRenameOutcome(item.id, token, false)
        assertEquals("中文 🖊️ draft", h.pendingRename.value!!.title)
        assertTrue(h.pendingRename.value!!.failed)
        assertTrue(!h.pendingRename.value!!.inFlight)
    }

    private fun holder(host: RecordingHost = RecordingHost()): Pair<ConversationHistoryHolder, RecordingHost> {
        val h = ConversationHistoryHolder(host)
        h.applyHostState(historyState())
        return h to host
    }

    @Test
    fun selectionIsScopedToTheVisibleSlice() {
        val (h, _) = holder()
        h.toggleSelect("conv-1")
        assertEquals(setOf("conv-1"), h.selectedIds.value)

        h.toggleSelectAll()
        assertEquals(setOf("conv-1", "conv-2", "conv-3"), h.selectedIds.value)

        // A query hides two rows: pruning keeps only the visible selection.
        h.setSearchQuery("First")
        h.applyHostState(historyState(searchEpoch = 0))
        assertEquals(setOf("conv-1"), h.selectedIds.value)
    }

    @Test
    fun filterChangeClearsSelectionAndReceipt() {
        val (h, _) = holder()
        h.toggleSelect("conv-1")
        h.setManagementFilter(TaskManagementFilterUi.ARCHIVED)
        assertEquals(emptySet<String>(), h.selectedIds.value)
        assertNull(h.bulkReceipt.value)
        assertEquals(1, h.visibleItems(archivedFilter = true).size)
    }

    @Test
    fun archiveConfirmationFreezesExactTargetsAndRunningImpact() {
        val host = RecordingHost()
        val h = ConversationHistoryHolder(host)
        h.applyHostState(historyState(runningIds = setOf("conv-2")))
        h.setManagementFilter(TaskManagementFilterUi.ACTIVE)
        h.toggleSelect("conv-1")
        h.toggleSelect("conv-2")
        h.toggleSelect("conv-3")

        h.requestArchiveConfirmation()
        val frozen = h.confirmation.value!!
        assertEquals(TaskBulkOperationUi.ARCHIVE, frozen.operation)
        assertEquals(listOf("conv-1", "conv-2", "conv-3"), frozen.frozenIds)
        assertEquals(1, frozen.runningImpact)

        // The selection changes while the dialog is open; the confirmed
        // identities must NOT follow the live selection.
        h.cancelSelection()
        h.toggleSelect("conv-2")

        assertEquals(ConversationFlowResult.Accepted, h.confirmBulkFromDialog())
        val args = host.lastArgs("requestBulk")!!
        assertEquals(TaskBulkOperationUi.ARCHIVE, args[0])
        assertEquals(listOf("conv-1", "conv-2", "conv-3"), args[1])
        assertTrue(h.bulkInFlight)
    }

    @Test
    fun receiptKeepsUnresolvedSelectionsForTruthfulRetry() {
        val (h, _) = holder()
        h.setManagementFilter(TaskManagementFilterUi.ACTIVE)
        h.toggleSelect("conv-1")
        h.toggleSelect("conv-2")
        h.toggleSelect("conv-3")
        h.applyBulkReceipt(
            BulkReceiptUi(
                operation = TaskBulkOperationUi.ARCHIVE,
                results = listOf(
                    BulkItemResultUi("conv-1", "First", BulkItemOutcomeUi.Archived),
                    BulkItemResultUi("conv-2", "Second", BulkItemOutcomeUi.Unverified("read failed")),
                    BulkItemResultUi("conv-3", "Third", BulkItemOutcomeUi.Failed("busy")),
                ),
                wasCancelled = false,
            )
        )
        // Resolved items leave; unresolved stay selected.
        assertEquals(setOf("conv-2", "conv-3"), h.selectedIds.value)
        assertEquals(1, h.bulkReceipt.value!!.archivedCount)
        assertEquals(1, h.bulkReceipt.value!!.unverifiedCount)
        assertEquals(1, h.bulkReceipt.value!!.failedCount)
        assertEquals(2, h.bulkReceipt.value!!.unresolvedItems.size)
    }

    @Test
    fun searchEpochFencesStaleContentPages() {
        val host = RecordingHost()
        val h = ConversationHistoryHolder(host)
        h.applyHostState(historyState())

        h.setSearchQuery("alpha")
        val firstEpoch = host.lastArgs("requestContentSearch")!![1] as Long
        assertEquals(1L, firstEpoch)
        h.applyHostState(
            historyState(contentSnippets = mapOf("conv-2" to "…alpha…"), searchEpoch = firstEpoch)
        )
        assertEquals("…alpha…", h.state.value!!.contentSnippets["conv-2"])

        // A newer query owns a newer epoch; the old page must not land.
        h.setSearchQuery("beta")
        h.applyHostState(
            historyState(contentSnippets = mapOf("conv-3" to "…alpha…"), searchEpoch = firstEpoch)
        )
        assertTrue(h.state.value!!.contentSnippets.isEmpty())
    }

    @Test
    fun titleMatchingIsCaseInsensitiveAndContentHitsCount() {
        val (h, _) = holder()
        h.setSearchQuery("fIrSt")
        assertEquals(listOf("conv-1"), h.visibleItems(archivedFilter = false).map { it.id })

        h.setSearchQuery("nothing-in-titles")
        h.applyHostState(
            historyState(
                contentSnippets = mapOf("conv-3" to "match inside body"),
                searchEpoch = h.currentSearchEpoch(),
            )
        )
        assertEquals(listOf("conv-3"), h.visibleItems(archivedFilter = false).map { it.id })
    }

    @Test
    fun historyOpenIsADirectUserNavigationWithNullSource() {
        val host = RecordingHost()
        val h = ConversationHistoryHolder(host)
        h.applyHostState(historyState())

        h.openConversation("conv-2")

        val args = host.lastArgs("requestOpenConversation")!!
        assertNull(args[0])
        assertEquals("conv-2", args[1])
    }

    @Test
    fun singleDeletionDialogBindsTheFrozenRow() {
        val host = RecordingHost()
        val h = ConversationHistoryHolder(host)
        h.applyHostState(historyState())
        h.requestSingleDeletion("conv-3")

        h.confirmSingleDeletion()

        assertEquals(listOf<Any?>("conv-3"), host.lastArgs("deleteConversation"))
        assertNull(h.pendingDeletionId.value)
    }
}
