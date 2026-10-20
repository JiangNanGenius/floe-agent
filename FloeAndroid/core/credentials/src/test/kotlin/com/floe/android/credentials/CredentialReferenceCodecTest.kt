// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialReferenceCodecTest {
    @Test
    fun acceptsBoundedOpaqueReferences() {
        listOf(
            "a",
            "provider.openai.api-key",
            "git:github.token",
            "uuid-1234_ABCD",
            "x".repeat(CredentialLimits.MAX_REFERENCE_CHARS),
        ).forEach { reference ->
            assertEquals(reference, CredentialReferenceCodec.requireReference(reference))
        }
    }

    @Test
    fun rejectsTraversalControlsAndOversizeReferences() {
        listOf(
            "",
            ".hidden",
            "..",
            "../secret",
            "a/b",
            "a\\b",
            "a b",
            "a\u0000b",
            "référence",
            "x".repeat(CredentialLimits.MAX_REFERENCE_CHARS + 1),
        ).forEach { reference ->
            assertThrows(CredentialStoreException.InvalidReference::class.java) {
                CredentialReferenceCodec.requireReference(reference)
            }
        }
    }

    @Test
    fun rejectsInvalidNamespaces() {
        listOf("", ".ns", "../ns", "ns/one", "ns one", "é", "n".repeat(CredentialLimits.MAX_NAMESPACE_CHARS + 1))
            .forEach { namespace ->
                assertThrows(CredentialStoreException.InvalidNamespace::class.java) {
                    CredentialReferenceCodec.requireNamespace(namespace)
                }
            }
    }

    @Test
    fun recordIdsAndAliasesAreOpaqueAndNamespaceBound() {
        val first = CredentialReferenceCodec.recordId("qa.one", "provider.alpha")
        val secondNamespace = CredentialReferenceCodec.recordId("qa.two", "provider.alpha")
        val secondReference = CredentialReferenceCodec.recordId("qa.one", "provider.beta")

        assertEquals(64, first.length)
        assertTrue(first.all { it in '0'..'9' || it in 'a'..'f' })
        assertFalse(first.contains("provider"))
        assertFalse(first.contains("qa.one"))
        assertNotEquals(first, secondNamespace)
        assertNotEquals(first, secondReference)
        assertEquals(first, CredentialReferenceCodec.recordId("qa.one", "provider.alpha"))

        val alias = CredentialReferenceCodec.keyAlias("qa.one", "provider.alpha")
        assertTrue(alias.startsWith("${CredentialReferenceCodec.ALIAS_DOMAIN}."))
        assertFalse(alias.contains("provider"))
        assertEquals("${CredentialReferenceCodec.ALIAS_DOMAIN}.$first", alias)
    }

    @Test
    fun aadIsDeterministicLengthFramedAndFieldBound() {
        val baseline = CredentialAad.encode("qa.one", "provider.alpha")
        assertArrayEquals(baseline, CredentialAad.encode("qa.one", "provider.alpha"))
        assertFalse(baseline.contentEquals(CredentialAad.encode("qa.one", "provider.beta")))
        assertFalse(baseline.contentEquals(CredentialAad.encode("qa.two", "provider.alpha")))
        // "qa.one" + "provider.alpha" must not equal a different split.
        assertFalse(CredentialAad.encode("qa", "one.provider.alpha").contentEquals(baseline))
        assertFalse(CredentialAad.encode("qa.one.provider", "alpha").contentEquals(baseline))
        assertTrue(baseline.size < 512)
    }
}
