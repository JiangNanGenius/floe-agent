// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessPolicyTest {

    @Test
    fun pairingAndUsbThresholdsAreExplicit() {
        assertFalse(AccessPolicy.pairingSupported(29))
        assertTrue(AccessPolicy.pairingSupported(30))
        assertTrue(AccessPolicy.pairingSupported(33))
        assertTrue(AccessPolicy.supportsUsbBootstrap(28))
        assertTrue(AccessPolicy.supportsUsbBootstrap(29))
        assertFalse(AccessPolicy.supportsUsbBootstrap(30))
    }

    @Test
    fun modeUidBindingIsStrict() {
        assertTrue(AccessPolicy.modeAllowsUid("adb", 2000))
        assertFalse(AccessPolicy.modeAllowsUid("adb", 0))
        assertFalse(AccessPolicy.modeAllowsUid("adb", 1000))
        assertTrue(AccessPolicy.modeAllowsUid("root", 0))
        assertFalse(AccessPolicy.modeAllowsUid("root", 2000))
        assertFalse(AccessPolicy.modeAllowsUid("bogus", 2000))
        assertEquals(2000, AccessPolicy.uidForMode("adb"))
        assertEquals(0, AccessPolicy.uidForMode("root"))
        assertNull(AccessPolicy.uidForMode("bogus"))
    }

    @Test
    fun rootIsDefaultOffAndRequiresAnObservedUidZero() {
        assertEquals(AccessPolicy.RootStartDecision.Off, AccessPolicy.rootStartDecision(false, true, 0))
        assertEquals(
            AccessPolicy.RootStartDecision.GrantNotFound,
            AccessPolicy.rootStartDecision(true, false, 0),
        )
        assertEquals(
            AccessPolicy.RootStartDecision.GrantNotFound,
            AccessPolicy.rootStartDecision(true, true, null),
        )
        assertEquals(
            (AccessPolicy.RootStartDecision.Refused("not_uid0")),
            AccessPolicy.rootStartDecision(true, true, 2000),
        )
        assertEquals(
            (AccessPolicy.RootStartDecision.Refused("not_uid0")),
            AccessPolicy.rootStartDecision(true, true, 1000),
        )
        assertEquals(
            AccessPolicy.RootStartDecision.StartAllowed,
            AccessPolicy.rootStartDecision(true, true, 0),
        )
    }

    @Test
    fun callerMustShareAppIdAndUser() {
        assertTrue(AccessPolicy.callerAllowed(10_123, 5, 10_123))
        assertFalse(AccessPolicy.callerAllowed(10_124, 5, 10_123))
        assertFalse(AccessPolicy.callerAllowed(110_123, 5, 10_123))
        assertFalse(AccessPolicy.callerAllowed(10_123, 0, 10_123))
        assertFalse(AccessPolicy.callerAllowed(2000, 5, 10_123))
    }

    @Test
    fun versionAndSigningIdentityAreExact() {
        val digest = "a".repeat(64)
        assertTrue(AccessPolicy.versionCompatible(24, 24))
        assertFalse(AccessPolicy.versionCompatible(24, 25))
        assertFalse(AccessPolicy.versionCompatible(0, 24))
        assertTrue(AccessPolicy.signingMatches(digest, digest.uppercase()))
        assertFalse(AccessPolicy.signingMatches(digest, "b".repeat(64)))
        assertFalse(AccessPolicy.signingMatches("a".repeat(63), digest))
    }

    @Test
    fun protectedPackagesAndPathsCannotBeManaged() {
        val own = setOf("com.floe.agent.full")
        assertTrue(ProtectedTargets.isProtectedPackage("com.floe.agent.full", own))
        assertTrue(ProtectedTargets.isProtectedPackage("com.floe.agent.full.debug", own))
        assertTrue(ProtectedTargets.isProtectedPackage("com.android.systemui", own))
        assertTrue(ProtectedTargets.isProtectedPackage("com.android.settings", own))
        assertFalse(ProtectedTargets.isProtectedPackage("com.example.notes", own))

        assertTrue(ProtectedTargets.isProtectedPath("/data/data/com.floe.agent.full/files", own))
        assertTrue(ProtectedTargets.isProtectedPath("/data/user/0/com.floe.agent.full/db", own))
        assertFalse(ProtectedTargets.isProtectedPath("/sdcard/Download/Floe/file.txt", own))
        assertFalse(ProtectedTargets.isProtectedPath("/data/local/tmp/floe-system/x", own))

        assertEquals(
            "protected_target",
            ProtectedTargets.canManagePackage("com.floe.agent.full", 0, own, true, "force_stop"),
        )
        assertEquals(
            "management_disabled",
            ProtectedTargets.canManagePackage("com.example.notes", 0, own, false, "force_stop"),
        )
        assertEquals(
            "protected_target",
            ProtectedTargets.canManagePackage("com.android.systemui", 0, own, true, "force_stop"),
        )
        assertNull(ProtectedTargets.canManagePackage("com.example.notes", 0, own, true, "force_stop"))
        assertEquals(
            "operation",
            ProtectedTargets.canManagePackage("com.example.notes", 0, own, true, "delete"),
        )
    }

    @Test
    fun siblingRuntimePackageAndDataCannotBeManagedOrOpened() {
        val appHost = setOf("com.floe.agent.full")
        val runtimeHost = setOf("com.floe.agent.runtime.full")

        // Package management must deny the whole Floe family from either
        // hosting identity, including the sibling runtime and debug channels.
        for (own in listOf(appHost, runtimeHost)) {
            for (target in FloePackageFamily.SHIPPED_PACKAGES) {
                assertTrue("$own -> $target", ProtectedTargets.isProtectedPackage(target, own))
                assertEquals(
                    "$own -> $target",
                    "protected_target",
                    ProtectedTargets.canManagePackage(target, 0, own, true, "force_stop"),
                )
            }
        }
        assertFalse(ProtectedTargets.isProtectedPackage("com.floe.agentx", appHost))
        assertFalse(ProtectedTargets.isProtectedPackage("com.example.notes", appHost))
        assertNull(
            ProtectedTargets.canManagePackage("com.example.notes", 0, appHost, true, "force_stop"),
        )

        for (path in listOf(
            "/data/data/com.floe.agent.runtime.full",
            "/data/user/0/com.floe.agent.runtime.full.dev/files",
            "/data/user_de/10/com.floe.agent.runtime.full",
            "/mnt/expand/1234-ABCD/app/com.floe.agent.full",
            "/storage/emulated/0/Android/data/com.floe.agent.runtime.full/files",
            "/sdcard/Android/media/com.floe.agent.dev/note.txt",
        )) {
            assertTrue(path, ProtectedTargets.isProtectedPath(path, appHost))
            assertTrue(path, ProtectedTargets.isProtectedPath(path, runtimeHost))
        }
        assertTrue(
            ProtectedTargets.containsProtectedSubtree("/data/user/0", runtimeHost),
        )
        assertFalse(
            ProtectedTargets.containsProtectedSubtree("/sdcard/Download/Floe", appHost),
        )
    }

    @Test
    fun cancellationAlwaysWinsOverSuccess() {
        assertEquals("cancelled", AccessPolicy.resultCode(cancelled = true, stale = false, code = null))
        assertEquals("stale", AccessPolicy.resultCode(cancelled = false, stale = true, code = null))
        assertEquals("ok", AccessPolicy.resultCode(cancelled = false, stale = false, code = "ok"))
        assertNull(AccessPolicy.resultCode(cancelled = false, stale = false, code = null))
    }
}
