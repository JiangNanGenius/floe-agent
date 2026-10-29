// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfPasswordVaultTest {

    @Test
    fun passwordNeverStringifiesAndIsZeroedOnClose() {
        val password = PdfPassword.ofString("correct horse")!!
        assertEquals("PdfPassword(redacted, length=13)", password.toString())
        password.use { chars ->
            assertEquals(13, chars.size)
            assertEquals('c', chars[0])
        }
        password.close()
        assertTrue(password.isEmpty)
        var threw = false
        try {
            password.use { }
        } catch (_: IllegalStateException) {
            threw = true
        }
        assertTrue(threw)
        var borrowThrew = false
        try {
            password.borrowSecret()
        } catch (_: IllegalStateException) {
            borrowThrew = true
        }
        assertTrue(borrowThrew)
    }

    @Test
    fun borrowSecretIsTheOwnedBufferAndRefusedAfterClose() {
        val password = PdfPassword.ofString("secret")!!
        val borrowed = password.borrowSecret()
        assertArrayEquals("secret".toCharArray(), borrowed)
        // Borrowing never copies: the holder's buffer is the one handed to the binder.
        borrowed[0] = 'S'
        password.use { assertEquals('S', it[0]) }
        password.close()
        borrowed.fill('\u0000')
    }

    @Test
    fun emptyOrOversizedPasswordsAreRefused() {
        assertNull(PdfPassword.ofString(""))
        assertNull(PdfPassword.ofString("x".repeat(PdfPassword.MAX_PASSWORD_CHARS + 1)))
        assertNull(PdfPassword.of(CharArray(0)))
    }

    @Test
    fun capabilityMatchesTheVerifiedPublicSdkSurface() {
        // API 28-30: no public password constructor at all.
        val legacy = PdfPasswordSupport.capability(28, pdfModulePresent = false)
        assertTrue(legacy is PdfPasswordCapability.ApiTooLow)
        assertEquals(31, (legacy as PdfPasswordCapability.ApiTooLow).requiredApi)
        // API 31-34: PdfRendererPreV is a Mainline framework-pdf module class.
        assertTrue(PdfPasswordSupport.capability(33, pdfModulePresent = true) is PdfPasswordCapability.NativeSupported)
        assertTrue(PdfPasswordSupport.capability(33, pdfModulePresent = false) is PdfPasswordCapability.BackendHasNoPasswordChannel)
        // API 35+: the public PdfRenderer(fd, LoadParams) constructor exists.
        assertTrue(PdfPasswordSupport.capability(35, pdfModulePresent = false) is PdfPasswordCapability.NativeSupported)
        assertTrue(PdfPasswordSupport.capability(37, pdfModulePresent = false) is PdfPasswordCapability.NativeSupported)
        assertTrue(PdfPasswordSupport.PUBLIC_SDK_PASSWORD_SETTER_PRESENT)
    }

    @Test
    fun policyNeverClaimsAnUnlockWithoutTheRenderer() {
        val password = PdfPassword.ofString("secret")!!
        val supported = PdfPasswordSupport.attemptUnlock(password, encrypted = true, apiLevel = 37, pdfModulePresent = false)
        assertFalse(supported.opened)
        assertNull(supported.refusal)
        assertTrue("the real open must decide", supported.requiresRendererAttempt)
        assertTrue(supported.originalPreserved)
        password.close()
    }

    @Test
    fun oldDevicesAndMissingPasswordsAreTypedRefusals() {
        val unsupported = PdfPasswordSupport.attemptUnlock(
            PdfPassword.ofString("secret")!!,
            encrypted = true,
            apiLevel = 28,
            pdfModulePresent = false,
        )
        assertEquals(PdfUnlockRefusal.API_LEVEL_TOO_LOW, unsupported.refusal)
        assertTrue(unsupported.originalPreserved)

        val moduleMissing = PdfPasswordSupport.attemptUnlock(
            PdfPassword.ofString("secret")!!,
            encrypted = true,
            apiLevel = 33,
            pdfModulePresent = false,
        )
        assertEquals(PdfUnlockRefusal.NO_PASSWORD_CHANNEL, moduleMissing.refusal)

        val missing = PdfPasswordSupport.attemptUnlock(null, encrypted = true, apiLevel = 37, pdfModulePresent = false)
        assertEquals(PdfUnlockRefusal.MISSING_PASSWORD, missing.refusal)
        assertTrue(missing.originalPreserved)

        val notEncrypted = PdfPasswordSupport.attemptUnlock(null, encrypted = false, apiLevel = 37, pdfModulePresent = false)
        assertTrue(notEncrypted.opened)
        assertTrue(notEncrypted.originalPreserved)
        assertNotNull(PdfPassword.ofString("ok"))
    }
}
