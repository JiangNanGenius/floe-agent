// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class TlsCertificateObservationTest {
    private fun fixture(): X509Certificate = CertificateFactory.getInstance("X.509")
        .generateCertificate(ByteArrayInputStream(Base64.getDecoder().decode(FIXTURE))) as X509Certificate

    @Test fun actualDerFingerprintValidityAndPeerIdentityWithoutKeyMaterial() {
        val cert = fixture()
        val result = TlsCertificateObservation.capture(arrayOf(cert), cert.notBefore.time + 1000)
        val leaf = result.getJSONArray("certificates").getJSONObject(0)
        assertTrue(leaf.getBoolean("validAtObservation"))
        assertFalse(leaf.getBoolean("expired"))
        val digest = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
        assertEquals(digest.joinToString("") { "%02x".format(it.toInt() and 255) }, leaf.getString("sha256"))
        assertEquals("RSA", leaf.getString("publicKeyAlgorithm"))
        assertEquals("peerMetadataOnly", result.getString("analysis"))
        assertFalse(result.getBoolean("revocationChecked"))
        assertTrue(result.toString().contains("floe-qa.example.test"))
        assertFalse(result.toString().contains("PUBLIC KEY"))
    }
    @Test fun notYetValidAndExpiredAreEvaluatedAtCapturedTime() {
        val cert = fixture()
        fun leaf(at: Long) = TlsCertificateObservation.capture(arrayOf(cert), at)
            .getJSONArray("certificates").getJSONObject(0)
        assertTrue(leaf(cert.notBefore.time - 1).getBoolean("notYetValid"))
        assertFalse(leaf(cert.notBefore.time - 1).getBoolean("validAtObservation"))
        assertTrue(leaf(cert.notAfter.time + 1).getBoolean("expired"))
        assertFalse(leaf(cert.notAfter.time + 1).getBoolean("validAtObservation"))
        assertTrue(leaf(cert.notBefore.time).getBoolean("validAtObservation"))
        assertTrue(leaf(cert.notAfter.time).getBoolean("validAtObservation"))
    }
    @Test fun chainIsBoundedAndEmptyChainDoesNotInventCertificates() {
        val cert = fixture()
        val bounded = TlsCertificateObservation.capture(Array<Certificate>(9) { cert }, cert.notBefore.time)
        assertEquals(9, bounded.getInt("presentedCount"))
        assertEquals(8, bounded.getInt("inspectedCount"))
        assertTrue(bounded.getBoolean("truncated"))
        val empty = TlsCertificateObservation.capture(emptyArray(), 0)
        assertEquals(0, empty.getInt("inspectedCount"))
        assertEquals(0, empty.getJSONArray("certificates").length())
    }
    companion object {
        // Public synthetic self-signed certificate only; generation key was discarded.
        private const val FIXTURE = "MIICsjCCAZoCAQEwDQYJKoZIhvcNAQELBQAwHzEdMBsGA1UEAwwUZmxvZS1xYS5leGFtcGxlLnRlc3QwHhcNMjYxMDMwMTEzOTI2WhcNMjYxMTAxMTEzOTI2WjAfMR0wGwYDVQQDDBRmbG9lLXFhLmV4YW1wbGUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMCEmF5wowl9TOOQyut+jmQmvYCsGITSfCIAc1q9sQDUaD/cGCjb0GuUmEU46Ry6Yrh6dSGZIwQsFHzN2cs+1m6eHXpNE9AP8gtIz15H3umQugNqZE2lwSXvH2mSXVg02dWHHQ5Fa6THLPsGXv+QFd8tEeHyu38WGfYgp62WYKbNCm9RYuzAv8I+sJ6rUZitNJJHp5CKkF9o4KmsiXu5HXmzcJ/D+n4zkKxk+4Eb7BXE6AVBPCEqWgYdy9kWez56QYMBtJtacrWfqiRCOOMfUKmGAeeFzvxJ0UfFaAD/kpdHI6NAINMiDsioJg9GBFt04f0yOf07AHlkIQInPKPt7hMCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAA/U8ajsR9gDRv/pJR55lIhslDC97XfzbxBx/YjbP6vnxG1+b8pkmaJQv7dxfOAQOnxXZLBQYpwtXsacI5qNxLFqnww3k3K/5mqfH0yTJn6GCcizWQzp+mK9wSY1liEc5Rk68VRoq2oKBv8JJAlnsbDlBeUyUmExWr/pke9aV6bHceIPV9xzIYB6o6T7UJ3HsVL0keIn4JEK04RPZMWy4DWSejEO7VU87PGxOFdxDfsV9kOzIg5DSmItq8X599N5sLK7TGw3/zUnWJ7QNFtbIa9/0nCMlkPfxKQV3hRWJR5V8C+zpZVIX1L5r/zqjAc5tkMPY6gJJqiBlWScj6FDQMA=="
    }
}
