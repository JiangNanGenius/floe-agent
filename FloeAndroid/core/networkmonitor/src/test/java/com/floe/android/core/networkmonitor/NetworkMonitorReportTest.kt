// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkMonitorReportTest {
    @Test
    fun diagnosticReportKeepsActualTlsFactsAndRedactsFingerprintByDefault() {
        val fingerprint = "cd".repeat(32)
        val raw = JSONObject().put("version", 1).put("source", "phone")
            .put("operationID", UUID.randomUUID().toString()).put("method", "network.http")
            .put("status", "ok").put("measuredAt", "2026-10-30T11:00:00Z")
            .put("target", "https://private.example.test/?token=secret")
            .put("network", JSONObject().put("available", true))
            .put("observations", JSONObject().put("statusCode", 200).put("tls", JSONObject()
                .put("protocol", "TLSv1.3").put("peerCertificates", JSONObject()
                    .put("revocationChecked", false).put("certificates", org.json.JSONArray().put(JSONObject()
                        .put("sha256", fingerprint).put("subject", "CN=hidden-certificate.example.test").put("notAfter", "2026-11-01T00:00:00Z")))))).toString()
        val meta = NetworkMonitorDeviceMetadata("Android 13", "test")
        val redacted = NetworkMonitorReportRenderer.renderDiagnostic(raw, false, meta)
        val detailed = NetworkMonitorReportRenderer.renderDiagnostic(raw, true, meta)
        assertFalse(redacted.json.contains(fingerprint))
        assertFalse(redacted.markdown.contains("private.example.test"))
        assertFalse(redacted.json.contains("hidden-certificate.example.test"))
        assertTrue(detailed.json.contains("hidden-certificate.example.test"))
        assertFalse(detailed.json.contains("token=secret"))
        assertTrue(detailed.json.contains(fingerprint))
        assertTrue(redacted.json.contains("TLSv1.3"))
        assertEquals("floe.network-diagnostic-report.v1", JSONObject(redacted.json).getString("schema"))
        assertFalse(JSONObject(redacted.json).has("session"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun diagnosticReportRejectsNonPhoneOrUnboundInput() {
        NetworkMonitorReportRenderer.renderDiagnostic("{}", false,
            NetworkMonitorDeviceMetadata("Android 13", "test"))
    }

    @Test
    fun certificateFingerprintIsAnOptInReportIdentifier() {
        val key = "tls.peerCertificates.certificates.0.sha256"
        val fingerprint = "ab".repeat(32)
        assertEquals("[redacted-network-identifier]", NetworkMonitorRedactor.value(key, fingerprint, false))
        assertEquals(fingerprint, NetworkMonitorRedactor.value(key, fingerprint, true))
        assertEquals("SHA256withRSA", NetworkMonitorRedactor.value("tls.signatureAlgorithm", "SHA256withRSA", false))
        assertEquals("2026-11-01T00:00:00Z", NetworkMonitorRedactor.value("tls.notAfter", "2026-11-01T00:00:00Z", false))
    }

    @Test
    fun defaultAndDetailedReportsBoundSensitiveDataWithoutDroppingFailures() {
        val operationID = UUID.randomUUID().toString()
        val raw = JSONObject()
            .put("version", 1)
            .put("operationID", operationID)
            .put("method", "network.status")
            .put("source", "phone")
            .put("status", "error")
            .put("measuredAt", "2026-10-30T01:02:03Z")
            .put("target", "printer.local")
            .put("network", JSONObject()
                .put("available", true)
                .put("handle", "101")
                .put("wifi", JSONObject().put("ssid", "HomeSSID").put("bssid", "AA:BB:CC:DD:EE:FF"))
                .put("linkAddresses", org.json.JSONArray().put("192.168.1.8/24")))
            .put("observations", JSONObject()
                .put("errorCode", "operationFailed")
                .put("message", "localhost 192.168.1.8 _http._tcp https://user:pass@example.com/path?token=abc#fragment")
                .put("authorization", "Bearer very-secret")
                .put("bytesReceived", 128))
            .toString()
        val observation = NetworkMonitorObservationParser.parse(
            raw = raw,
            sequence = 1,
            expectedOperationID = operationID,
            expectedMethod = "network.status",
            fallbackMeasuredAtEpochMillis = 0,
            startedAtElapsedNanos = 10_000_000,
            finishedAtElapsedNanos = 25_000_000,
        )
        val failed = NetworkMonitorObservationParser.failure(
            2, UUID.randomUUID().toString(), "network.ping", "2026-10-30T01:02:04Z",
            "operationFailed", 30_000_000, 40_000_000,
        )
        val snapshot = snapshot(listOf(observation, failed))
        val metadata = NetworkMonitorDeviceMetadata("Android 16", "0.1.0-alpha.17")

        val defaultReport = NetworkMonitorReportRenderer.render(snapshot, false, metadata)
        val defaultText = defaultReport.json + defaultReport.markdown
        listOf("HomeSSID", "AA:BB:CC:DD:EE:FF", "192.168.1.8", "printer.local", "very-secret", "user:pass", "token=abc", "_http._tcp")
            .forEach { sensitive -> assertFalse("default leaked $sensitive", defaultText.contains(sensitive)) }
        assertFalse(defaultText.contains("failed localhost"))
        assertTrue(defaultText.contains("operationFailed"))
        assertTrue(defaultText.contains("\"status\": \"error\""))
        assertTrue(defaultText.contains("Android 16"))
        assertFalse(defaultText.contains("root-owner-secret"))

        val detailedReport = NetworkMonitorReportRenderer.render(snapshot, true, metadata)
        val detailedText = detailedReport.json + detailedReport.markdown
        assertTrue(detailedText.contains("HomeSSID"))
        assertTrue(detailedText.contains("192.168.1.8"))
        assertTrue(detailedText.contains("https://example.com/path"))
        listOf("very-secret", "user:pass", "token=abc", "fragment", "root-owner-secret")
            .forEach { secret -> assertFalse("detailed leaked $secret", detailedText.contains(secret)) }
    }

    @Test
    fun parserRejectsCrossOperationAndMalformedNestedResults() {
        val operationID = UUID.randomUUID().toString()
        val wrong = JSONObject()
            .put("version", 1)
            .put("operationID", UUID.randomUUID().toString())
            .put("method", "network.status")
            .put("source", "phone")
            .put("status", "ok")
            .put("measuredAt", "2026-10-30T01:02:03Z")
            .toString()
        val parsed = NetworkMonitorObservationParser.parse(
            wrong.toString(), 1, operationID, "network.status", 0, 0, 1,
        )
        assertEquals("error", parsed.status)
        assertEquals("invalidResponse", parsed.details.text["errorCode"])
        assertEquals(0, parsed.actualNetwork.numbers.size)
    }

    private fun snapshot(observations: List<NetworkMonitorObservation>): NetworkMonitorSessionSnapshot {
        val consumed = observations.sumOf { it.rawBytes }
        return NetworkMonitorSessionSnapshot(
            sessionId = UUID.randomUUID().toString(),
            config = NetworkMonitorConfig(),
            owner = NetworkMonitorOwner("root-owner-secret"),
            startedAtEpochMillis = 1_793_344_000_000,
            startedAtElapsedNanos = 100,
            endedAtEpochMillis = 1_793_344_001_000,
            endedAtElapsedNanos = 1_100,
            deadlineAtElapsedNanos = 10_000,
            observations = observations,
            totalObservationCount = observations.size.toLong(),
            droppedObservationCount = 0,
            consumedRawBytes = consumed.toLong(),
            retainedRawBytes = consumed.toLong(),
            endReason = NetworkMonitorEndReason.USER_STOP,
            failed = false,
        )
    }
}
