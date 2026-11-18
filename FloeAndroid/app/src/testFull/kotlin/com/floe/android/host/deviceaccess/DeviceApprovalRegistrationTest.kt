// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.DeviceApprovalIdentity
import com.floe.android.host.DeviceApprovalOverlayCallbacks
import com.floe.android.phonecontrol.PhoneControlOwner
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DeviceApprovalRegistrationTest {
    private val callbacks = object : DeviceApprovalOverlayCallbacks {
        override fun onVisibilityChanged(identity: DeviceApprovalIdentity, presentationId: String, visible: Boolean) = Unit
        override fun onDecision(identity: DeviceApprovalIdentity, presentationId: String, allow: Boolean) = Unit
    }
    private fun identity() = DeviceApprovalIdentity(UUID.randomUUID(), UUID.randomUUID(), 7, 3,
        "call", "generation", "descriptor")

    @Test fun `late work and cancellation cannot remove a replacement registration`() {
        val queue = DeviceApprovalRegistration()
        val id = identity()
        val old = DeviceApprovalRegistration.Entry(id, callbacks)
        val replacement = DeviceApprovalRegistration.Entry(id, callbacks)
        queue.register(old)
        queue.register(replacement)
        assertFalse(queue.isCurrent(old))
        queue.cancelEntry(old)
        assertTrue(queue.isCurrent(replacement))
        assertSame(replacement, queue.cancel(id))
        assertNull(queue.current())
    }

    @Test fun `stop and dismissal are restricted to their exact owner and identity`() {
        val queue = DeviceApprovalRegistration()
        val id = identity()
        val entry = DeviceApprovalRegistration.Entry(id, callbacks)
        queue.register(entry)
        assertNull(queue.cancel(identity()))
        queue.cancelOwner(PhoneControlOwner(id.taskID, UUID.randomUUID()))
        assertSame(entry, queue.current())
        queue.cancelOwner(PhoneControlOwner(id.taskID, id.runID))
        assertNull(queue.current())
    }
}
