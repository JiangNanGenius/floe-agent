// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NetworkTargetPolicyTest {
    @Test
    fun normalizesBracketedAndTrailingDotHosts() {
        assertEquals("example.com", NetworkTargetPolicy.normalizeHost(" example.com. "))
        assertEquals("::1", NetworkTargetPolicy.normalizeHost("[::1]"))
    }

    @Test
    fun acceptsHostnameAndLiteralSyntax() {
        assertEquals("example.com", NetworkTargetPolicy.validateHostSyntax("example.com"))
        assertEquals("_service._tcp.example.com", NetworkTargetPolicy.validateHostSyntax("_service._tcp.example.com"))
        assertEquals("::1", NetworkTargetPolicy.validateHostSyntax("::1"))
        // A scoped link-local literal keeps its zone identifier: dropping it
        // would make later socket/ping use of fe80::/10 targets unusable.
        assertEquals("fe80::1%wlan0", NetworkTargetPolicy.validateHostSyntax("fe80::1%wlan0"))
    }

    @Test
    fun rejectsMalformedHosts() {
        listOf("", "bad host", "a..b", "-bad.example", "example..com", "a".repeat(64) + ".com").forEach { host ->
            try {
                NetworkTargetPolicy.validateHostSyntax(host)
                fail("expected invalid host: $host")
            } catch (_: TargetSyntaxException) {
                // expected
            }
        }
    }

    @Test
    fun classifiesAddressesWithoutResolution() {
        assertEquals(AddressClass.PRIVATE, NetworkTargetPolicy.literalAddressClass("10.1.2.3"))
        assertEquals(AddressClass.LOOPBACK, NetworkTargetPolicy.literalAddressClass("127.0.0.1"))
        assertEquals(AddressClass.LINK_LOCAL, NetworkTargetPolicy.literalAddressClass("169.254.1.1"))
        assertEquals(AddressClass.METADATA, NetworkTargetPolicy.literalAddressClass("169.254.169.254"))
        assertEquals(AddressClass.UNSPECIFIED, NetworkTargetPolicy.literalAddressClass("0.0.0.0"))
        assertEquals(AddressClass.MULTICAST, NetworkTargetPolicy.literalAddressClass("224.0.0.1"))
        assertEquals(AddressClass.RESERVED, NetworkTargetPolicy.literalAddressClass("240.0.0.1"))
        assertEquals(AddressClass.METADATA, NetworkTargetPolicy.literalAddressClass("100.100.100.200"))
        assertEquals(AddressClass.METADATA, NetworkTargetPolicy.literalAddressClass("fd00:ec2::254"))
        assertEquals(AddressClass.MULTICAST, NetworkTargetPolicy.literalAddressClass("ff02::1"))
        assertNull(NetworkTargetPolicy.literalAddressClass("example.com"))
    }

    @Test
    fun metadataNamesAndAddressesAreDenied() {
        assertTrue(NetworkTargetPolicy.isMetadataHostname("metadata.google.internal"))
        assertTrue(NetworkTargetPolicy.isMetadataHostname("metadata"))
        assertFalse(NetworkTargetPolicy.isMetadataHostname("example.com"))
        try {
            NetworkTargetPolicy.checkHostPolicy("metadata.google.internal")
            fail("metadata host must be denied")
        } catch (_: TargetPolicyException) {
            // expected
        }
        try {
            NetworkTargetPolicy.checkHostPolicy("169.254.169.254")
            fail("metadata address must be denied")
        } catch (_: TargetPolicyException) {
            // expected
        }
    }

    @Test
    fun resolvedAddressPolicyReportsLocalAndDeniesSpecialRanges() {
        assertFalse(NetworkTargetPolicy.checkResolvedAddresses("example.com", listOf("93.184.216.34")))
        assertTrue(NetworkTargetPolicy.checkResolvedAddresses("example.com", listOf("192.168.1.2")))
        try {
            NetworkTargetPolicy.checkResolvedAddresses("example.com", listOf("93.184.216.34", "169.254.169.254"))
            fail("any metadata address must deny the whole target")
        } catch (_: TargetPolicyException) {
            // expected
        }
        try {
            NetworkTargetPolicy.checkResolvedAddresses("example.com", emptyList())
            fail("empty resolution must fail")
        } catch (_: TargetPolicyException) {
            // expected
        }
    }

    @Test
    fun parsesHttpsAndRedactsQuery() {
        val target = NetworkTargetPolicy.parseHttpTarget("https://example.com:8443/a/b?q=secret#frag")
        assertEquals("https", target.scheme)
        assertEquals("example.com", target.host)
        assertEquals(8443, target.port)
        assertEquals("/a/b", target.path)
        assertEquals("q=secret", target.query)
        assertEquals("https://example.com:8443/a/b", target.redacted)
        assertFalse(target.cleartext)
    }

    @Test
    fun rejectsUserinfoAndBadPorts() {
        try {
            NetworkTargetPolicy.parseHttpTarget("https://user:pass@example.com/")
            fail("userinfo must be rejected")
        } catch (_: TargetSyntaxException) {
            // expected
        }
        try {
            NetworkTargetPolicy.parseHttpTarget("https://example.com:0/")
            fail("port zero must be rejected")
        } catch (_: TargetSyntaxException) {
            // expected
        }
        try {
            NetworkTargetPolicy.parseHttpTarget("not a url")
            fail("relative URL must be rejected")
        } catch (_: TargetSyntaxException) {
            // expected
        }
    }

    @Test
    fun marksCleartextAndUnsupportedSchemes() {
        val cleartext = NetworkTargetPolicy.parseHttpTarget("http://example.com/path")
        assertTrue(cleartext.cleartext)
        val ftp = NetworkTargetPolicy.parseHttpTarget("ftp://example.com/path")
        try {
            NetworkTargetPolicy.checkHttpTargetPolicy(ftp)
            fail("non-HTTP scheme must be rejected by the HTTPS diagnostic policy")
        } catch (_: TargetPolicyException) {
            // expected
        }
    }

    @Test
    fun revalidatesRedirectTargets() {
        val base = NetworkTargetPolicy.parseHttpTarget("https://example.com/start")
        val relative = base.resolveRedirect("/next")
        assertEquals("https://example.com/next", relative.redacted)

        val cleartext = base.resolveRedirect("http://example.com/next")
        assertTrue(cleartext.cleartext)

        val metadata = base.resolveRedirect("https://169.254.169.254/latest/meta-data")
        try {
            NetworkTargetPolicy.checkHttpTargetPolicy(metadata)
            fail("metadata redirect must be denied")
        } catch (_: TargetPolicyException) {
            // expected
        }

        try {
            base.resolveRedirect("https://user:pass@example.com/next")
            fail("userinfo redirect must be rejected")
        } catch (_: TargetSyntaxException) {
            // expected
        }
    }
}
