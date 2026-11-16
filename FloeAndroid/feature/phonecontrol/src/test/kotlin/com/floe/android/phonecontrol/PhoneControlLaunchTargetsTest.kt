// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PhoneControlLaunchTargetsTest {
    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())
    private val principal = PhoneControlPrincipal(owner, 3, setOf("com.example.alpha", "com.example.beta", "com.floe.agent.full"))
    private fun grant(packages: Set<String>) = PhoneControlGrant(owner, 3, packages, true, false)

    @Test fun `only actual grant intersection and ordinary launch policy are returned`() {
        val actual = PhoneControlLaunchTargets.allowed(principal, grant(setOf("com.example.beta", "com.floe.agent.full", "com.example.other")))
        assertEquals(setOf("com.example.beta"), actual)
    }

    @Test fun `stale or malformed authorization never yields targets`() {
        assertNull(PhoneControlLaunchTargets.allowed(principal, grant(setOf("com.example.beta")).copy(epoch = 4)))
        assertNull(PhoneControlLaunchTargets.allowed(principal, grant(setOf("invalid package"))))
    }
}
