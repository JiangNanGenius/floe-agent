// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import com.floe.android.runlifecycle.RunNotificationReturn
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class OwnedNotificationNavigationTest {
    private fun admit(routes: TaskCenterNotificationRoutes, id: String = UUID.randomUUID().toString()): String {
        assertTrue(routes.admit(RunNotificationReturn.ACTION, "app", "app", id))
        return id
    }
    @Test fun `foreign action component and invalid request cannot navigate`() {
        val routes = TaskCenterNotificationRoutes()
        assertFalse(routes.admit("other", "app", "app", UUID.randomUUID().toString()))
        assertFalse(routes.admit(RunNotificationReturn.ACTION, "other", "app", UUID.randomUUID().toString()))
        assertFalse(routes.admit(RunNotificationReturn.ACTION, "app", "app", "/files/task"))
        assertNull(routes.pending.value)
    }
    @Test fun `Activity redelivery cannot replay a consumed notification`() {
        val routes = TaskCenterNotificationRoutes()
        val id = admit(routes)
        routes.dismiss(id)
        assertFalse(routes.admit(RunNotificationReturn.ACTION, "app", "app", id))
        assertNull(routes.pending.value)
        admit(routes)
        assertNotNull(routes.pending.value)
    }
    @Test fun `old refusal cannot consume a newer notification`() {
        val routes = TaskCenterNotificationRoutes()
        val old = admit(routes)
        val newer = admit(routes)
        routes.dismiss(old)
        assertEquals(newer, routes.pending.value!!.id)
    }
    @Test fun `pending request expires rather than navigating after an indefinite fence`() {
        var now = 100L
        val routes = TaskCenterNotificationRoutes { now }
        admit(routes)
        val request = routes.pending.value!!
        now += 300_001L
        assertFalse(routes.isCurrent(request))
    }
}
