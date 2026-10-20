// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.design.FloeDraftStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Home -> temporary-session draft transfer is a privacy boundary:
 * only the EXACT text the admitted session took is consumed, and a newer
 * Home edit is never clobbered by a late admission callback.
 */
class HomeDraftTransferTest {
    @Test
    fun exactTransferredTextIsConsumed() {
        val store = FloeDraftStore()
        store.update(FloeDraftStore.HOME_DRAFT, "secret temporary prompt")
        assertTrue(
            HomeDraftTransfer.consumeTransferred(
                store, "secret temporary prompt", isOriginCurrent = true),
        )
        assertEquals("", store.draft(FloeDraftStore.HOME_DRAFT))
    }

    @Test
    fun newerHomeEditSurvivesALateTransfer() {
        val store = FloeDraftStore()
        store.update(FloeDraftStore.HOME_DRAFT, "newer ordinary draft")
        assertFalse(
            HomeDraftTransfer.consumeTransferred(
                store, "old temporary prompt", isOriginCurrent = true),
        )
        assertEquals("newer ordinary draft", store.draft(FloeDraftStore.HOME_DRAFT))
    }

    @Test
    fun emptyAdmittedTemporaryEntryConsumesOnlyAnEmptyHomeDraft() {
        val store = FloeDraftStore()
        store.update(FloeDraftStore.HOME_DRAFT, "")
        assertTrue(HomeDraftTransfer.consumeTransferred(
            store, "", isOriginCurrent = true))
        assertEquals("", store.draft(FloeDraftStore.HOME_DRAFT))
    }
    @Test
    fun serializedAccessorsMirrorTheSameHomeDraft() {
        val store = FloeDraftStore()
        HomeDraftTransfer.update(store, "typed on the UI thread")
        assertEquals("typed on the UI thread", HomeDraftTransfer.draft(store))
        assertEquals("typed on the UI thread", store.draft(FloeDraftStore.HOME_DRAFT))
        assertTrue(
            HomeDraftTransfer.consumeTransferred(
                store, "typed on the UI thread", isOriginCurrent = true),
        )
        assertEquals("", HomeDraftTransfer.draft(store))
    }

    @Test
    fun staleOriginatingHomeCannotConsumeEvenMatchingText() {
        val store = FloeDraftStore()
        store.update(FloeDraftStore.HOME_DRAFT, "same text")
        assertFalse(
            HomeDraftTransfer.consumeTransferred(
                store, "same text", isOriginCurrent = false),
        )
        assertEquals("same text", store.draft(FloeDraftStore.HOME_DRAFT))
    }

}
