// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HttpObservationBuilderTest {
    @Test
    fun finalPeerMetadataIsPreservedWithoutInventingRevocationOrEarlierHopCertificates() {
        val target = NetworkTargetPolicy.parseHttpTarget("https://example.com/")
        val peer = JSONObject().put("inspectedCount", 1).put("analysis", "peerMetadataOnly")
            .put("revocationChecked", false).put("certificates", org.json.JSONArray())
        val finalHop = HttpHop(target, 200, null, "TLS_AES_128_GCM_SHA256", null, 0,
            certificateObservation = peer)
        val response = HttpObservationBuilder.build(target,
            HttpChainResult(ObservationStatus.OK, listOf(finalHop), target, null), 1)
        val tls = response.observations.getJSONObject("tls")
        assertTrue(tls.getBoolean("certificateChainAnalyzed"))
        assertEquals("peerMetadataOnly", tls.getJSONObject("peerCertificates").getString("analysis"))
        assertFalse(tls.getJSONObject("peerCertificates").getBoolean("revocationChecked"))
        assertEquals("platformDefault", tls.getString("trust"))
    }

    @Test
    fun redactsLocationHeadersAndReportsActualPhases() {
        val initial = NetworkTargetPolicy.parseHttpTarget("https://example.com/start")
        val finalTarget = NetworkTargetPolicy.parseHttpTarget("https://example.com/next?token=secret")
        val redirect = HttpHop(
            target = initial,
            statusCode = 302,
            location = "https://example.com/next?token=secret",
            cipherSuite = "TLS_AES_128_GCM_SHA256",
            contentType = "text/plain",
            contentLength = 0,
            headers = mapOf("location" to "https://example.com/next?token=secret"),
            tlsProtocol = "TLSv1.3",
            dnsMs = 4,
            tcpConnectMs = 5,
            tlsHandshakeMs = 6,
            responseHeadersMs = 7,
            totalMs = 22,
        )
        val final = HttpHop(
            target = finalTarget,
            statusCode = 200,
            location = "https://example.com/final?token=secret",
            cipherSuite = "TLS_AES_128_GCM_SHA256",
            contentType = "text/plain",
            contentLength = 12,
            headers = mapOf(
                "location" to "https://example.com/final?token=secret",
                "content-type" to "text/plain",
                "server" to "example",
            ),
            tlsProtocol = "TLSv1.3",
            dnsMs = 1,
            tcpConnectMs = 2,
            tlsHandshakeMs = 3,
            responseHeadersMs = 4,
            totalMs = 10,
        )
        val result = HttpObservationBuilder.build(
            initial = initial,
            chain = HttpChainResult(
                status = ObservationStatus.OK,
                hops = listOf(redirect, final),
                finalTarget = finalTarget,
                stoppedReason = null,
            ),
            probeTotalMs = 123,
        )
        val observations = result.observations
        assertEquals("https://example.com/start", observations.getString("requestedUrl"))
        assertEquals("https://example.com/next", observations.getString("finalUrl"))
        assertEquals(200, observations.getInt("statusCode"))
        assertEquals(123L, observations.getLong("probeTotalMs"))
        assertEquals(1, observations.getInt("redirectCount"))
        assertFalse(observations.getJSONObject("responseHeaders").has("location"))
        assertFalse(observations.toString().contains("token=secret"))
        assertEquals(
            "https://example.com/next",
            observations.getJSONArray("redirects").getJSONObject(0).getString("redirectedTo"),
        )
        assertEquals(1L, observations.getJSONObject("phaseTimings").getLong("dnsMs"))
        assertEquals(2L, observations.getJSONObject("phaseTimings").getLong("tcpConnectMs"))
        assertEquals(3L, observations.getJSONObject("phaseTimings").getLong("tlsHandshakeMs"))
        assertEquals(4L, observations.getJSONObject("phaseTimings").getLong("responseHeadersMs"))
        assertEquals(10L, observations.getJSONObject("phaseTimings").getLong("totalMs"))
        assertEquals("TLSv1.3", observations.getJSONObject("tls").getString("protocol"))
        assertEquals("TLS_AES_128_GCM_SHA256", observations.getJSONObject("tls").getString("cipherSuite"))
        assertFalse(observations.getJSONObject("tls").getBoolean("certificateChainAnalyzed"))
        assertEquals("platformDefault", observations.getJSONObject("tls").getString("hostnameVerification"))
        assertTrue(observations.getJSONArray("phaseTimingsNote").length() >= 4)
        assertTrue(result.limitations.any { it.contains("pinned to a verified address") })
    }

    @Test
    fun propagatesPermissionAndStoppedReasonWithoutRawTarget() {
        val initial = NetworkTargetPolicy.parseHttpTarget("https://example.com/start")
        val result = HttpObservationBuilder.build(
            initial = initial,
            chain = HttpChainResult(
                status = ObservationStatus.PERMISSION_REQUIRED,
                hops = emptyList(),
                finalTarget = initial,
                stoppedReason = "localNetworkPermissionRequired",
                limitations = listOf("Local target."),
                missingPermissions = listOf("android.permission.ACCESS_LOCAL_NETWORK"),
            ),
            probeTotalMs = 1,
        )
        assertEquals(ObservationStatus.PERMISSION_REQUIRED, result.status)
        assertEquals(listOf("android.permission.ACCESS_LOCAL_NETWORK"), result.missingPermissions)
        assertEquals("localNetworkPermissionRequired", result.observations.getString("stoppedReason"))
        assertEquals("https://example.com/start", result.target)
        assertFalse(result.observations.has("responseHeaders"))
    }
}
