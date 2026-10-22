package com.floe.android.runtimeipc

import org.junit.Assert.*
import org.junit.Test

class RuntimeIdentityTest {
    @Test fun allDistributionIdentitiesRemainSeparate() {
        for (core in listOf("com.floe.agent", "com.floe.agent.dev", "com.floe.agent.full", "com.floe.agent.full.dev")) {
            val pair = RuntimePackages.forCore(core)
            assertNotEquals(pair.core, pair.runtime)
            assertEquals(pair, RuntimePackages.forRuntime(pair.runtime))
            assertEquals("$core.permission.LINUX_RUNTIME", pair.permission)
        }
    }

    @Test fun arbitraryAndCrossRoleNamesCannotSelectAnotherComponent() {
        for (name in listOf("evil.package", "com.floe.agent.play", "com.floe.agent.runtime")) {
            assertThrows(SecurityException::class.java) { RuntimePackages.forCore(name) }
        }
        assertThrows(SecurityException::class.java) { RuntimePackages.forRuntime("com.floe.agent") }
    }

    @Test fun signatureAloneAndOwnUidAreInsufficient() {
        assertTrue(RuntimePeerVerifier.acceptsUid(11001, 11002, 11001, true))
        assertFalse(RuntimePeerVerifier.acceptsUid(11002, 11002, 11002, true))
        assertFalse(RuntimePeerVerifier.acceptsUid(11003, 11002, 11001, true))
        assertFalse(RuntimePeerVerifier.acceptsUid(11001, 11002, 11001, false))
    }
}
