// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceLaunchScopeTokensTest {
    private val tokens = DeviceLaunchScopeTokens(ByteArray(32) { 7 })
    private val scope = DeviceLaunchScopeTokens.Scope("task/run", 9, "ACCESSIBILITY", "fence:3", 2, 4,
        setOf("com.example.a", "com.example.b"))

    @Test fun `token is stable and opaque for unchanged authorized scope`() {
        val token = tokens.token(scope)
        assertEquals(32, token.length)
        assertTrue(tokens.matches(scope.copy(packages = scope.packages.reversed().toSet()), token))
        assertFalse(token.contains("com.example"))
    }

    @Test fun `different owner epoch backend grant or revocation invalidate the token`() {
        val token = tokens.token(scope)
        listOf(scope.copy(owner = "other/run"), scope.copy(epoch = 10),
            scope.copy(backend = "ADB"), scope.copy(session = "fence:4"),
            scope.copy(controlRevision = 3), scope.copy(targetRevision = 6),
            scope.copy(packages = setOf("com.example.a"))).forEach {
            assertFalse(tokens.matches(it, token))
        }
        assertFalse(tokens.matches(scope, "bad"))
        assertFalse(DeviceLaunchScopeTokens(ByteArray(32) { 8 }).matches(scope, token))
    }
}
