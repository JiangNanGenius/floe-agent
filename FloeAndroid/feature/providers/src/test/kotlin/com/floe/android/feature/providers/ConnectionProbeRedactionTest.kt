// SPDX-License-Identifier: MPL-2.0
//
// Accepted steer g02-source-secret-print-and-endpoint-epoch-fix: the probe
// DTO's generated toString must never print the typed credential or header
// values. These are synthetic strings only; no real secret is involved.

package com.floe.android.feature.providers

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionProbeRedactionTest {

    @Test
    fun toStringNeverPrintsCredentialOrHeaderValues() {
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "https://api.example.invalid/v1",
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = mapOf("X-Trace" to "header-value-marker"),
            credentialDraft = "sk-synthetic-secret-marker",
            allowsPlainHttp = false,
            toolNameCompatibility = true,
        )

        val text = probe.toString()

        assertFalse("typed credential must never appear", text.contains("sk-synthetic-secret-marker"))
        assertFalse("header values must never appear", text.contains("header-value-marker"))
        assertTrue("credential presence is reported without the value", text.contains("<present:redacted>"))
        assertTrue("header count is reported instead of values", text.contains("nonSecretHeaderCount=1"))
        assertTrue(text.contains("wireProtocol=OPENAI_CHAT_COMPLETIONS"))
    }

    @Test
    fun absentCredentialIsReportedAsAbsent() {
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "https://api.example.invalid/v1",
            wireProtocol = WireProtocolUi.ANTHROPIC_MESSAGES,
            nonSecretHeaders = emptyMap(),
            credentialDraft = null,
            allowsPlainHttp = false,
            toolNameCompatibility = false,
        )

        val text = probe.toString()
        assertTrue(text.contains("credential=absent"))
        assertFalse(text.contains("redacted"))
    }

    @Test
    fun emptyCredentialIsAlsoAbsent() {
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "https://api.example.invalid",
            wireProtocol = WireProtocolUi.OPENAI_RESPONSES,
            nonSecretHeaders = emptyMap(),
            credentialDraft = "",
            allowsPlainHttp = true,
            toolNameCompatibility = false,
        )

        assertTrue(probe.toString().contains("credential=absent"))
    }
}
