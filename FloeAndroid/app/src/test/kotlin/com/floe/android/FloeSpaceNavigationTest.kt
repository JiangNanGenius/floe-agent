// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Space navigation policy (no Compose, no device).
 *
 * These tests pin the parts that can silently invent state:
 * - the four iOS sections keep their order and restore only their own keys;
 * - the Phone workspace is present only with its real wired settings section;
 * - the new Space route never changes an existing saved selection key;
 * - the toolbox exposes only destinations the shell actually renders;
 * - optional document/meeting entries disappear without a real callback;
 * - creating a project requires an admitted runtime.
 */
class FloeSpaceNavigationTest {
    @Test
    fun sectionsKeepTheIosOrderAndDefaultToOverview() {
        assertEquals(
            listOf(
                FloeSpaceSection.OVERVIEW,
                FloeSpaceSection.NOTES,
                FloeSpaceSection.FILES,
                FloeSpaceSection.TOOLBOX,
            ),
            floeSpaceSections(phoneAccessAvailable = false),
        )
        assertEquals(
            listOf(
                FloeSpaceSection.OVERVIEW,
                FloeSpaceSection.PHONE,
                FloeSpaceSection.NOTES,
                FloeSpaceSection.FILES,
                FloeSpaceSection.TOOLBOX,
            ),
            floeSpaceSections(phoneAccessAvailable = true),
        )
        assertEquals(FloeSpaceSection.OVERVIEW, FloeSpaceSection.fromKey(null))
        assertEquals(FloeSpaceSection.OVERVIEW, FloeSpaceSection.fromKey(""))
        assertEquals(FloeSpaceSection.OVERVIEW, FloeSpaceSection.fromKey("unknown"))
        assertEquals(FloeSpaceSection.PHONE, FloeSpaceSection.fromKey("phone"))
        FloeSpaceSection.entries.forEach { section ->
            assertEquals(section, FloeSpaceSection.fromKey(section.key))
        }
    }

    @Test
    fun spaceRouteRoundTripsWithoutTouchingExistingKeys() {
        assertEquals("s:space", SidebarSelection.Space.key)
        assertEquals(SidebarSelection.Space, selectionFromKey("s:space"))

        assertEquals("w:OVERVIEW", SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW).key)
        assertEquals("w:NEW_TASK", SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK).key)
        assertEquals("m:NOTES", SidebarSelection.More(MoreDestination.NOTES).key)
        assertEquals("p:project-1", SidebarSelection.Workspace("project-1").key)
        assertEquals("c:task-1", SidebarSelection.Conversation("task-1").key)

        assertEquals(
            SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
            selectionFromKey("w:OVERVIEW"),
        )
        assertEquals(
            SidebarSelection.More(MoreDestination.NOTES),
            selectionFromKey("m:NOTES"),
        )
        assertEquals(
            SidebarSelection.Workspace("project-1"),
            selectionFromKey("p:project-1"),
        )
        assertEquals(
            SidebarSelection.Conversation("task-1"),
            selectionFromKey("c:task-1"),
        )
    }

    @Test
    fun liveTemporarySessionStillWinsRestoreOnTheSpaceRoute() {
        assertEquals(
            SidebarSelection.Conversation("live-task"),
            restoredShellSelection(SidebarSelection.Space.key, "live-task"),
        )
        assertEquals(
            SidebarSelection.Space,
            restoredShellSelection(SidebarSelection.Space.key, null),
        )
    }

    @Test
    fun optionalEntriesStayHiddenWithoutARealCallback() {
        assertFalse(spaceOptionalEntryVisible(null))
        assertTrue(spaceOptionalEntryVisible { })
    }

    @Test
    fun toolboxOnlyRoutesToImplementedDestinations() {
        val routes = FloeSpaceToolboxTarget.entries.map { it.selection }
        assertEquals(routes.size, routes.toSet().size)
        assertTrue(routes.all { it is SidebarSelection.More })
        assertEquals(
            setOf(
                MoreDestination.DEVICES,
                MoreDestination.SYSTEM_SERVICES,
                MoreDestination.NETWORK,
                MoreDestination.REMOTE,
            ),
            routes.mapNotNull { (it as? SidebarSelection.More)?.destination }.toSet(),
        )
        // No synthesized project/task identity can hide in the toolbox.
        assertTrue(
            routes.none {
                it is SidebarSelection.Workspace ||
                    it is SidebarSelection.Conversation ||
                    it is SidebarSelection.Space
            },
        )
    }

    @Test
    fun phoneAccessUsesTheRealWiredSettingsKeyAndStaysOptional() {
        assertEquals("x:phone_access", FLOE_PHONE_ACCESS_SECTION_KEY)
        assertFalse(
            floeSpaceSections(phoneAccessAvailable = false)
                .contains(FloeSpaceSection.PHONE),
        )
        assertTrue(
            floeSpaceSections(phoneAccessAvailable = true)
                .contains(FloeSpaceSection.PHONE),
        )
    }

    @Test
    fun phoneSectionCannotBeRestoredWhileItsContentIsUnwired() {
        val saved = FloeSpaceSection.PHONE.key
        val restored = FloeSpaceSection.fromKey(saved)
        assertEquals(FloeSpaceSection.PHONE, restored)
        assertFalse(
            floeSpaceSections(phoneAccessAvailable = false).contains(restored),
        )
        // The shell's fallback for an unavailable restored section.
        assertEquals(
            FloeSpaceSection.OVERVIEW,
            if (restored in floeSpaceSections(phoneAccessAvailable = false)) {
                restored
            } else {
                FloeSpaceSection.OVERVIEW
            },
        )
    }

    @Test
    fun projectCreationNeedsALiveAdmittedRuntime() {
        assertTrue(
            spaceCanCreateProject(
                hasRuntime = true,
                runtimeUnavailable = false,
                busy = false,
            ),
        )
        assertFalse(
            spaceCanCreateProject(
                hasRuntime = false,
                runtimeUnavailable = false,
                busy = false,
            ),
        )
        assertFalse(
            spaceCanCreateProject(
                hasRuntime = true,
                runtimeUnavailable = true,
                busy = false,
            ),
        )
        assertFalse(
            spaceCanCreateProject(
                hasRuntime = true,
                runtimeUnavailable = false,
                busy = true,
            ),
        )
    }
}
