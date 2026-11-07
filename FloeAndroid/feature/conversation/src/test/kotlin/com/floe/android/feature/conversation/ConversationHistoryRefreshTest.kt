// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationHistoryRefreshTest {
    @Test fun contentOnlyMatchesDoNotReplaceTheBaseListAndClearReloadsIt() {
        val host = RecordingHost()
        val holder = ConversationHistoryHolder(host)
        holder.applyBaseHistory(historyState())
        holder.setSearchQuery("needle")
        holder.applyContentSearch(historyState(
            items = listOf(holder.state.value!!.items[1]),
            contentSnippets = mapOf("conv-2" to "body needle"),
            searchEpoch = holder.currentSearchEpoch(),
        ))
        assertEquals(listOf("conv-2"), holder.visibleItems().map { it.id })
        holder.setSearchQuery("")
        assertEquals(listOf("conv-1", "conv-2", "conv-3"), holder.visibleItems().map { it.id })
        assertEquals(1, host.count("reloadHistory"))
    }

    @Test fun aCommittedListRefreshKeepsTheQueryFilterAndSelectedContentMatch() {
        val host = RecordingHost()
        val holder = ConversationHistoryHolder(host)
        holder.applyBaseHistory(historyState())
        holder.setSearchQuery("needle")
        val outside = ConversationListItemUi("outside", "Other title", "now", null, false, null)
        holder.applyContentSearch(historyState(
            items = listOf(outside), contentSnippets = mapOf("outside" to "needle"),
            searchEpoch = holder.currentSearchEpoch(),
        ))
        holder.setEditMode(true)
        holder.toggleSelect("outside")
        holder.applyBaseHistory(historyState())
        holder.refreshContentSearch()
        assertEquals("needle", holder.searchQuery)
        assertEquals(TaskManagementFilterUi.ACTIVE, holder.managementFilter)
        assertEquals(setOf("outside"), holder.selectedIds.value)
        assertTrue(holder.editModeActive)
        assertEquals("needle", holder.state.value!!.contentSnippets["outside"])
        assertEquals(listOf<Any?>("needle", holder.currentSearchEpoch()), host.lastArgs("requestContentSearch"))
        holder.applyContentSearch(historyState(
            items = emptyList(), contentSnippets = emptyMap(), searchEpoch = holder.currentSearchEpoch(),
        ))
        assertTrue(holder.visibleItems().isEmpty())
        assertTrue(holder.selectedIds.value.isEmpty())
    }

    @Test fun aStaleQueryPageCannotChangeRowsOrPruneTheCurrentSelection() {
        val holder = ConversationHistoryHolder(RecordingHost())
        holder.applyBaseHistory(historyState())
        holder.setSearchQuery("First")
        val oldEpoch = holder.currentSearchEpoch()
        holder.setSearchQuery("First updated")
        holder.toggleSelect("conv-1")
        val before = holder.state.value
        holder.applyHostState(historyState(items = emptyList(), searchEpoch = oldEpoch))
        assertSame(before, holder.state.value)
        assertEquals(setOf("conv-1"), holder.selectedIds.value)
    }

    @Test fun contentResultsRetainTheKnownArchiveIdentityAndFilter() {
        val holder = ConversationHistoryHolder(RecordingHost())
        holder.applyBaseHistory(historyState())
        holder.setManagementFilter(TaskManagementFilterUi.ARCHIVED)
        holder.setSearchQuery("needle")
        val hit = ConversationListItemUi("conv-9", "Archived", "now", null, false, null)
        holder.applyContentSearch(historyState(
            items = listOf(hit), contentSnippets = mapOf("conv-9" to "needle"),
            searchEpoch = holder.currentSearchEpoch(),
        ))
        assertEquals(listOf("conv-9"), holder.visibleItems(archivedFilter = true).map { it.id })
        assertFalse(holder.visibleItems().any { it.id == "conv-9" })
        assertEquals(TaskManagementFilterUi.ARCHIVED, holder.managementFilter)
    }

    @Test fun refusedSearchDoesNotLeaveTheLoadingStateLatched() {
        val host = object : ConversationUiCallbacks by RecordingHost() {
            override fun requestContentSearch(query: String, epoch: Long) = false
        }
        val holder = ConversationHistoryHolder(host)
        holder.applyBaseHistory(historyState())
        holder.setSearchQuery("needle")
        assertFalse(holder.state.value!!.isSearching)
    }

    @Test fun historyClearInvalidatesPendingSearchInsteadOfResurrectingItsRows() {
        val holder = ConversationHistoryHolder(RecordingHost())
        holder.applyBaseHistory(historyState())
        holder.setSearchQuery("needle")
        val oldEpoch = holder.currentSearchEpoch()
        holder.invalidateAfterHistoryClear()
        holder.applyContentSearch(historyState(
            contentSnippets = mapOf("conv-2" to "old needle"), searchEpoch = oldEpoch,
        ))
        assertTrue(holder.state.value!!.items.isEmpty())
        assertTrue(holder.state.value!!.archivedItems.isEmpty())
        assertTrue(holder.state.value!!.contentSnippets.isEmpty())
        assertEquals("needle", holder.searchQuery)
    }
}
