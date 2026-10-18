// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure semantics worth pinning: the send gate (blank draft, IME composed
 * text, missing provider), the RAM draft store contract, and the locked
 * sidebar route order. No Compose runtime required.
 */
class ComposerStateTest {

    private val noProvider = ComposerAvailability(providerConfigured = false)
    private val withProvider = ComposerAvailability(providerConfigured = true)

    @Test fun blankDraftNeverSends() {
        assertFalse(ComposerSendPolicy.canSend(draftBlank = true, compositionActive = false, availability = withProvider))
    }

    @Test fun composedTextNeverSends() {
        assertFalse(ComposerSendPolicy.canSend(draftBlank = false, compositionActive = true, availability = withProvider))
    }

    @Test fun missingProviderDisablesSend() {
        assertFalse(ComposerSendPolicy.canSend(draftBlank = false, compositionActive = false, availability = noProvider))
    }

    @Test fun plainDraftWithProviderSends() {
        assertTrue(ComposerSendPolicy.canSend(draftBlank = false, compositionActive = false, availability = withProvider))
    }

    @Test fun processingAttachmentsBlockSend() {
        val busy = ComposerAvailability(providerConfigured = true, attachmentsProcessing = true)
        assertFalse(ComposerSendPolicy.canSend(draftBlank = false, compositionActive = false, availability = busy))
    }

    @Test fun compositionDetectionFollowsMarkedRange() {
        assertFalse(ComposerSendPolicy.compositionActive(TextFieldValue("hello")))
        val composing = TextFieldValue("hello你", selection = androidx.compose.ui.text.TextRange(8), composition = androidx.compose.ui.text.TextRange(5, 8))
        assertTrue(ComposerSendPolicy.compositionActive(composing))
    }

    @Test fun draftStoreKeepsConsumesAndDefaults() {
        val store = FloeDraftStore()
        assertEquals("", store.draft(FloeDraftStore.HOME_DRAFT))
        store.update(FloeDraftStore.HOME_DRAFT, "draft me")
        assertEquals("draft me", store.draft(FloeDraftStore.HOME_DRAFT))
        store.consume(FloeDraftStore.HOME_DRAFT)
        assertEquals("", store.draft(FloeDraftStore.HOME_DRAFT))
    }

    @Test fun fixedSidebarRoutesMatchLockedIosOrder() {
        assertEquals(
            listOf(
                SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK),
                SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
                SidebarSelection.More(MoreDestination.NOTES),
                SidebarSelection.More(MoreDestination.CREATIVE),
                SidebarSelection.More(MoreDestination.SKILLS),
            ),
            fixedSidebarRoutes,
        )
    }

    @Test fun moreDestinationOrderIsLocked() {
        assertEquals(
            listOf(
                MoreDestination.NOTES, MoreDestination.CREATIVE, MoreDestination.RUNS, MoreDestination.SETUP_GUIDE,
                MoreDestination.PROVIDERS, MoreDestination.AUXILIARY_MODELS, MoreDestination.SKILLS,
                MoreDestination.MEMORY, MoreDestination.SETTINGS, MoreDestination.DIAGNOSTICS,
            ),
            MoreDestination.entries.toList(),
        )
        assertEquals(List(MoreDestination.entries.size) { MoreDestination.entries[it].order }, List(MoreDestination.entries.size) { it })
    }
}
