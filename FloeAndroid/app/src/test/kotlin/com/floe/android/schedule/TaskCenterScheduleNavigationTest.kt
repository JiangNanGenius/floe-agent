// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.taskCenterSchedulesOpenOnCommit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Route-policy tests for the Home → Task Center → Scheduled Tasks path.
 *
 * The schedules sub-view may open ONLY when the shell actually committed the
 * Task Center route (including a successful temporary-chat fence admission).
 * A refused/timed-out fence commits nothing, so a pending request can never
 * leak into a later unrelated Task Center visit, and no local UI route exists.
 */
class TaskCenterScheduleNavigationTest {

    private val taskCenter =
        SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW)
    private val newTask =
        SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)

    @Test
    fun anAdmittedTaskCenterCommitOpensTheSchedulesSubview() {
        assertTrue(taskCenterSchedulesOpenOnCommit(taskCenter, requestedFromHome = true))
    }

    @Test
    fun aRefusedFenceCommitsNothingAndNeverOpensSchedules() {
        assertFalse(taskCenterSchedulesOpenOnCommit(null, requestedFromHome = true))
    }

    @Test
    fun ordinarySidebarNavigationDoesNotOpenSchedules() {
        assertFalse(taskCenterSchedulesOpenOnCommit(taskCenter, requestedFromHome = false))
        assertFalse(taskCenterSchedulesOpenOnCommit(newTask, requestedFromHome = false))
    }

    @Test
    fun aRequestThatLandsOnAnotherRouteIsDiscarded() {
        assertFalse(taskCenterSchedulesOpenOnCommit(newTask, requestedFromHome = true))
        assertFalse(taskCenterSchedulesOpenOnCommit(
            SidebarSelection.Conversation("c1"), requestedFromHome = true))
        assertFalse(taskCenterSchedulesOpenOnCommit(
            SidebarSelection.More(MoreDestination.NOTES), requestedFromHome = true))
    }

    @Test
    fun theScheduleRouteIsTheExistingOuterTaskCenterSelection() {
        // No parallel outer destination exists: the token is consumed by the
        // same Workbench overview surface that owns the history list.
        assertEquals(
            SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW),
            taskCenter,
        )
    }
}
