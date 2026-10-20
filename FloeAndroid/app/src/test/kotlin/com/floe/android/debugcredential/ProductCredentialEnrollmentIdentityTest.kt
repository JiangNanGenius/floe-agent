// SPDX-License-Identifier: MPL-2.0
package com.floe.android.debugcredential

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Cross-language identity proof for the debug product-credential enrollment.
 *
 * The Kotlin helper MUST mint the SAME account + opaque reference as the
 * Swift product path (`ConfigSecretIdentity.providerAccount` and
 * `SecretGatewayNaming.opaqueReference`). The fixed UUID deliberately
 * contains A-F hex letters so a lowercase/uppercase mistake cannot be hidden
 * by an all-digit fixture; the Swift side asserts the same constants in
 * FloeAndroidCoreTests/G02CredentialAccountCanonicalizationTests.
 */
class ProductCredentialEnrollmentIdentityTest {

    private val providerId = "7f3c1a52-9d4e-4c11-8a2b-2f6c8e5d1b70"
    private val canonicalAccount = "provider.7F3C1A52-9D4E-4C11-8A2B-2F6C8E5D1B70"
    private val canonicalReference =
        "ref:v1:2f65616838e9ebb2a3aa6dae6425a80dcc827e8aa0301e63552a4f21218d797c"

    @Test
    fun accountMatchesSwiftCanonicalUppercaseUuid() {
        assertEquals(canonicalAccount,
            ProductCredentialEnrollment.providerAccount(providerId))
        // Already-canonical uppercase input is idempotent.
        assertEquals(canonicalAccount,
            ProductCredentialEnrollment.providerAccount(
                canonicalAccount.removePrefix("provider.")))
        // A malformed id is refused instead of minting a wrong account.
        assertThrows(IllegalArgumentException::class.java) {
            ProductCredentialEnrollment.providerAccount("not-a-uuid")
        }
    }

    @Test
    fun referenceMatchesSwiftOpaqueReference() {
        assertEquals(canonicalReference,
            ProductCredentialEnrollment.opaqueReference(
                ProductCredentialEnrollment.NAMESPACE, canonicalAccount))
    }

    @Test
    fun namespaceIsTheProductGatewayNamespace() {
        assertEquals("keychainAccount", ProductCredentialEnrollment.NAMESPACE)
    }
}
