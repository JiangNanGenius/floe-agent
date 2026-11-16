// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.DeviceApprovalAction
import com.floe.android.host.DeviceApprovalIdentity
import com.floe.android.phonecontrol.PhoneControlApprovalTarget
import com.floe.android.phonecontrol.PhoneControlBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class DeviceApprovalDigestTest {
    @Test fun `digest binds owner page target label and scope without rendering label`() {
        val identity = DeviceApprovalIdentity(UUID.randomUUID(), UUID.randomUUID(), 9, 10,
            "call", "generation", "descriptor")
        val action = DeviceApprovalAction("obs", "node", "click", null, null)
        val target = PhoneControlApprovalTarget("example.app", "Button", PhoneControlBounds(1, 2, 3, 4),
            "confirm", 7, 0, 4, 5)
        fun digest(i: DeviceApprovalIdentity = identity, a: DeviceApprovalAction = action,
                   t: PhoneControlApprovalTarget = target, revision: Long = 3, scope: Long = 8) =
            DeviceApprovalDigest.compute(i, a, t, revision, scope)
        val original = digest()
        assertTrue(original.matches(Regex("[0-9a-f]{64}")))
        assertEquals(original, digest())
        assertNotEquals(original, digest(i = identity.copy(runID = UUID.randomUUID())))
        assertNotEquals(original, digest(a = action.copy(nodeRef = "other")))
        assertNotEquals(original, digest(t = target.copy(label = "cancel")))
        assertNotEquals(original, digest(t = target.copy(pageGeneration = 6)))
        assertNotEquals(original, digest(scope = 10))
        assertNotEquals(original, digest(revision = 4))
        assertTrue(!target.toString().contains("confirm"))
    }
}
