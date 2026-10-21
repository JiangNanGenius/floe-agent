// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.feature.conversation.TemporarySessionRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G02 shell selection-persistence contract: the saved-state key carries
 * ONLY durable/ordinary selections; a live temporary surface is RAM truth
 * owned by the application-scoped runtime host (survives rotation, dies
 * with the process). A genuine UNKEPT process death must therefore restore
 * Home/ordinary — never reinterpret the lost temporary id as a blank
 * ordinary chat — while a genuinely Kept conversation still reopens as an
 * ordinary conversation from its remapped durable id.
 */
class ShellSelectionRestoreTest {

    private val newTask = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)

    @Test
    fun unkeptColdRestoreWithoutRamTemporaryLandsOnHome() {
        // Process death while a temporary chat owned the surface: the
        // persisted key never carried the temporary id (durable-only
        // contract), so the fresh process restores Home. No blank ordinary
        // chat is reconstructed for the lost route.
        assertEquals(newTask, restoredShellSelection(newTask.key, null))
    }

    @Test
    fun recreationWithLiveRamTemporaryReadoptsTheTemporarySurface() {
        // Same process (rotation/background/lock/view reconstruction): the
        // host RAM still owns the temporary session, so the temporary
        // surface is restored even though the persisted key stayed Home.
        assertEquals(
            SidebarSelection.Conversation("tc1"),
            restoredShellSelection(newTask.key, "tc1"),
        )
    }

    @Test
    fun keptSameIdOrdinarySelectionStillRestoresAcrossProcessDeath() {
        // A committed Keep persists the remapped real durable id under the
        // ordinary conversation key; a later cold restore reopens THAT
        // saved conversation (ordinary controls, no Temporary badge).
        val kept = SidebarSelection.Conversation("TC1")
        assertEquals(kept, restoredShellSelection(kept.key, null))
    }

    @Test
    fun liveTemporarySelectionIsNeverPersistedWhileDurableSelectionIs() {
        assertTrue(isLiveTemporarySelection(SidebarSelection.Conversation("tc1"), "tc1"))
        assertFalse(isLiveTemporarySelection(SidebarSelection.Conversation("tc1"), "other"))
        // After the Keep removed the RAM registration the SAME id is
        // durable truth and must reach saved state (reproducible reopen).
        assertFalse(isLiveTemporarySelection(SidebarSelection.Conversation("tc1"), null))
        assertFalse(isLiveTemporarySelection(newTask, "tc1"))
        assertFalse(
            isLiveTemporarySelection(
                SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW), "tc1"),
        )
    }

    @Test
    fun liveRamTemporaryWinsOverTheOlderDurableKeyOnRecreation() {
        // Started a temporary from an ordinary conversation surface: the
        // persisted key still names that durable conversation, but the
        // live RAM temporary owns the visible surface until it genuinely
        // ends/Keeps.
        assertEquals(
            SidebarSelection.Conversation("tc2"),
            restoredShellSelection("c:TC1", "tc2"),
        )
    }

    @Test
    fun malformedSavedKeyFailsClosedToHome() {
        assertEquals(newTask, restoredShellSelection("nonsense", null))
    }

    @Test
    fun keptPromotionPersistsDurableSelectionOnlyForTheExactCurrentOrigin() {
        val origin = TemporarySessionRef(
            conversationId = "tc1",
            sessionEpoch = 3L,
            incarnationId = "inc-1",
            nativeRootEpoch = 1L,
        )
        // The exact still-visible origin surface adopts the durable id.
        assertTrue(
            keptPromotionAppliesToVisibleOrigin(
                SidebarSelection.Conversation("tc1"), 3L, origin,
            ),
        )
        // The SAME logical conversation id under a replaced session epoch is
        // a different surface: the stale adoption must not persist or route.
        assertFalse(
            keptPromotionAppliesToVisibleOrigin(
                SidebarSelection.Conversation("tc1"), 4L, origin,
            ),
        )
        assertFalse(
            keptPromotionAppliesToVisibleOrigin(
                SidebarSelection.Conversation("tc1"), null, origin,
            ),
        )
        // Genuine leave (Home or another conversation) drops the adoption;
        // the committed rows stay reachable through history instead.
        assertFalse(keptPromotionAppliesToVisibleOrigin(newTask, 3L, origin))
        assertFalse(
            keptPromotionAppliesToVisibleOrigin(
                SidebarSelection.Conversation("other"), 3L, origin,
            ),
        )
    }
}
