// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class LanSpeedRequestParserTest {
    private val operationID = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun parsesLanDiscoverDefaultsAndExplicitServiceTypes() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.lanDiscover",
                JSONObject().put("serviceTypes", JSONArray().put("_HTTP._TCP").put("_ipp._tcp")),
            ),
        )
        assertEquals(NetworkMethod.LAN_DISCOVER, parsed.method)
        assertEquals(NetworkLimits.DEFAULT_LAN_TIMEOUT_MS, parsed.timeoutMs)
        assertEquals(listOf("_http._tcp", "_ipp._tcp"), parsed.lan?.serviceTypes)
        assertEquals(NetworkLimits.DEFAULT_LAN_DISCOVERY_MS, parsed.lan?.discoveryDurationMs)
        assertEquals(false, parsed.lan?.includeAttributes)
        assertEquals("lan:mdns", parsed.target)
    }

    @Test
    fun parsesBoundedSubnetAndPorts() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.lanDiscover",
                JSONObject()
                    .put("subnetCidr", "192.168.1.0/30")
                    .put("ports", JSONArray().put(80).put(443))
                    .put("tcpConnectTimeoutMs", 250)
                    .put("tcpConcurrency", 4)
                    .put("timeoutMs", 5_000),
            ),
        )
        assertEquals(2, parsed.lan?.subnet?.addresses?.size)
        assertEquals(listOf(80, 443), parsed.lan?.ports)
        assertEquals(250, parsed.lan?.tcpConnectTimeoutMs)
        assertEquals(4, parsed.lan?.tcpConcurrency)
        assertEquals("lan:192.168.1.0/30", parsed.target)
    }

    @Test
    fun rejectsUnboundedOrAmbiguousLanRequests() {
        assertFails("invalidArguments", request("network.lanDiscover", JSONObject()))
        assertFails(
            "invalidArguments",
            request("network.lanDiscover", JSONObject().put("ports", JSONArray().put(80))),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.lanDiscover",
                JSONObject().put("subnetCidr", "8.8.8.0/24").put("ports", JSONArray().put(80)),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.lanDiscover",
                JSONObject()
                    .put("subnetCidr", "192.168.1.0/24")
                    .put("ports", JSONArray().put(80).put(443).put(631).put(8080).put(8443)),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.lanDiscover",
                JSONObject().put("serviceTypes", JSONArray().put("_http._tcp").put("_http._tcp")),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.lanDiscover",
                JSONObject().put(
                    "serviceTypes",
                    JSONArray().apply {
                        repeat(9) { put("_s$it._tcp") }
                    },
                ),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.lanDiscover",
                JSONObject().put("serviceTypes", JSONArray().put("_http._tcp")).put("timeoutMs", 1_000),
            ),
        )
    }

    @Test
    fun parsesSpeedTestDefaultsAndRedactsQuery() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.speedTest",
                JSONObject().put("downloadUrl", "https://example.com/payload?token=secret"),
            ),
        )
        assertEquals(NetworkMethod.SPEED_TEST, parsed.method)
        assertEquals(NetworkLimits.DEFAULT_SPEED_TIMEOUT_MS, parsed.timeoutMs)
        assertEquals(SpeedDirection.DOWNLOAD, parsed.speed?.direction)
        assertEquals("https://example.com/payload", parsed.speed?.downloadTarget?.redacted)
        assertEquals(NetworkLimits.DEFAULT_SPEED_BYTES, parsed.speed?.maxBytesPerDirection)
        assertEquals(NetworkLimits.DEFAULT_SPEED_DURATION_MS, parsed.speed?.durationBudgetMs)
        assertEquals(0, parsed.speed?.warmupBytes)
        assertEquals(false, parsed.speed?.allowMetered)
        assertFalse(parsed.target!!.contains("secret"))
    }

    @Test
    fun parsesUploadAndBothDirectionsOnlyWithExplicitEndpoints() {
        val upload = NetworkRequestParser.parse(
            request(
                "network.speedTest",
                JSONObject()
                    .put("direction", "upload")
                    .put("uploadUrl", "https://example.com/upload")
                    .put("durationBudgetMs", 2_000),
            ),
        )
        assertEquals(SpeedDirection.UPLOAD, upload.speed?.direction)
        assertNotNull(upload.speed?.uploadTarget)
        assertEquals(null, upload.speed?.downloadTarget)

        val both = NetworkRequestParser.parse(
            request(
                "network.speedTest",
                JSONObject()
                    .put("direction", "downloadAndUpload")
                    .put("downloadUrl", "https://example.com/d")
                    .put("uploadUrl", "https://example.com/u")
                    .put("durationBudgetMs", 10_000),
            ),
        )
        assertEquals(SpeedDirection.DOWNLOAD_AND_UPLOAD, both.speed?.direction)
        assertNotNull(both.speed?.downloadTarget)
        assertNotNull(both.speed?.uploadTarget)
    }

    @Test
    fun rejectsSpeedBudgetsOutsideFrozenBounds() {
        assertFails(
            "invalidArguments",
            request("network.speedTest", JSONObject().put("direction", "upload")),
        )
        assertFails(
            "invalidArguments",
            request("network.speedTest", JSONObject().put("direction", "download")),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.speedTest",
                JSONObject().put("downloadUrl", "https://example.com/p").put("maxBytesPerDirection", 1_024),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.speedTest",
                JSONObject().put("downloadUrl", "https://example.com/p").put("durationBudgetMs", 999),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.speedTest",
                JSONObject()
                    .put("downloadUrl", "https://example.com/p")
                    .put("maxBytesPerDirection", 65_536)
                    .put("warmupBytes", 65_536),
            ),
        )
        assertFails(
            "invalidArguments",
            request(
                "network.speedTest",
                JSONObject()
                    .put("direction", "downloadAndUpload")
                    .put("downloadUrl", "https://example.com/d")
                    .put("uploadUrl", "https://example.com/u")
                    .put("durationBudgetMs", 10_000)
                    .put("timeoutMs", 20_000),
            ),
        )
    }

    @Test
    fun speedTestAcceptsHttpForTypedUnsupportedAtExecution() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.speedTest",
                JSONObject().put("downloadUrl", "http://example.com/p"),
            ),
        )
        assertTrue(parsed.speed?.downloadTarget?.cleartext == true)
    }

    private fun request(method: String, arguments: JSONObject): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", method)
        .put("arguments", arguments)
        .toString()

    private fun assertFails(code: String, input: String) {
        try {
            NetworkRequestParser.parse(input)
            fail("expected parse failure $code")
        } catch (failure: RequestParseException) {
            assertEquals(code, failure.code)
            assertTrue(failure.message?.isNotBlank() == true)
        }
    }
}
