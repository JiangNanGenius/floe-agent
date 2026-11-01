// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SystemOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingAndSigningPolicyTest {

    @Test
    fun pairingCodeIsSixDigitsAndWiped() {
        assertEquals("123456", PairingPolicy.sanitize("12a34 5678"))
        assertTrue(PairingPolicy.canSubmit("000000"))
        assertFalse(PairingPolicy.canSubmit("12345"))
        assertFalse(PairingPolicy.canSubmit("12345a"))
        val code = PairingPolicy.sanitizeToCharArray("654321")
        PairingPolicy.wipe(code)
        assertTrue(code.all { it == '\u0000' })
        assertFalse(PairingPolicy.shouldPairOnStart())
        assertEquals("pair_required", PairingPolicy.statusAfterStart(false, false))
        assertEquals("paired", PairingPolicy.statusAfterStart(true, false))
        assertEquals("service_alive", PairingPolicy.statusAfterStart(true, true))
        assertEquals("service_alive_pairing_cleared", PairingPolicy.statusAfterForget(true))
        assertEquals("pair_required", PairingPolicy.statusAfterForget(false))
    }

    @Test
    fun signingDigestIsOrderIndependentAndStable() {
        val pairA = java.security.KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val pairB = java.security.KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val certA = moe.shizuku.pairing.SelfSignedCertificate.create(pairA)
        val certB = moe.shizuku.pairing.SelfSignedCertificate.create(pairB)

        val digestA = SigningDigest.of(arrayOf(certA))
        val digestB = SigningDigest.of(arrayOf(certB))
        assertEquals(64, digestA.length)
        assertTrue(digestA != digestB)
        assertEquals(
            SigningDigest.of(arrayOf(certA, certB)),
            SigningDigest.of(arrayOf(certB, certA)),
        )
        assertTrue(SigningDigest.of(arrayOf(certA)) != SigningDigest.of(arrayOf(certA, certB)))
    }

    @Test
    fun grantShapeAndLifetimeAreBounded() {
        val registry = GrantRegistry(clock = { 1_000L })
        val base = GrantRequest(
            grantId = "g",
            taskId = "t",
            runId = "r",
            epoch = 1,
            expiresAtMillis = 2_000,
            scopes = listOf(ScopeRoot("s", "/sdcard/Download/Floe", false)),
            operations = setOf(SystemOperation.FILE_READ),
            packageManagementAllowed = false,
        )
        assertTrue(registry.register(base) is GrantRegistry.Registration.Ok)
        val tooLong = base.copy(grantId = "g2", expiresAtMillis = 1_000 + 6 * 60 * 60 * 1000L + 1)
        assertEquals(
            "grant_lifetime",
            (registry.register(tooLong) as GrantRegistry.Registration.Rejected).code,
        )
        val badScope = base.copy(
            grantId = "g3",
            scopes = listOf(ScopeRoot("", "/sdcard/Download/Floe", true)),
        )
        assertEquals(
            "grant_shape",
            (registry.register(badScope) as GrantRegistry.Registration.Rejected).code,
        )
    }
}
