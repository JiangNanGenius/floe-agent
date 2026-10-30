// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NetworkRequestParserTest {
    private val operationID = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun parsesStatusAndWifiDefaults() {
        val status = NetworkRequestParser.parse(request("network.status"))
        assertEquals(NetworkMethod.STATUS, status.method)
        assertEquals(NetworkLimits.DEFAULT_STATUS_TIMEOUT_MS, status.timeoutMs)

        val wifi = NetworkRequestParser.parse(request("network.wifiScan"))
        assertEquals(NetworkMethod.WIFI_SCAN, wifi.method)
        assertEquals(false, wifi.refresh)
        assertEquals(NetworkLimits.DEFAULT_WIFI_TIMEOUT_MS, wifi.timeoutMs)
    }

    @Test
    fun parsesDnsPingTcpAndHttpArguments() {
        val dns = NetworkRequestParser.parse(
            request(
                "network.dnsLookup",
                JSONObject().put("host", "example.com").put("recordType", "AAAA").put("timeoutMs", 1),
            ),
        )
        assertEquals("example.com", dns.host)
        assertEquals(DnsRecordType.AAAA, dns.recordType)
        assertEquals(NetworkLimits.MIN_TIMEOUT_MS, dns.timeoutMs)

        val ping = NetworkRequestParser.parse(
            request(
                "network.ping",
                JSONObject().put("host", "example.com").put("count", 99).put("timeoutMs", 999_999),
            ),
        )
        assertEquals(NetworkLimits.MAX_PING_COUNT, ping.count)
        assertEquals(NetworkLimits.MAX_TIMEOUT_MS, ping.timeoutMs)

        val tcp = NetworkRequestParser.parse(
            request(
                "network.tcpProbe",
                JSONObject().put("host", "example.com").put("port", 443),
            ),
        )
        assertEquals(443, tcp.port)
        assertEquals(NetworkLimits.DEFAULT_TCP_TIMEOUT_MS, tcp.timeoutMs)

        val http = NetworkRequestParser.parse(
            request(
                "network.http",
                JSONObject().put("url", "https://example.com/a?q=secret").put("maxRedirects", 99),
            ),
        )
        assertEquals(NetworkLimits.MAX_REDIRECTS, http.maxRedirects)
        assertEquals("https://example.com/a", http.httpTarget?.redacted)
        assertEquals(NetworkLimits.DEFAULT_HTTP_TIMEOUT_MS, http.timeoutMs)
    }

    @Test
    fun clampsSmallTimingAndRedirectValues() {
        val dns = NetworkRequestParser.parse(
            request("network.dnsLookup", JSONObject().put("host", "example.com").put("timeoutMs", 1)),
        )
        assertEquals(NetworkLimits.MIN_TIMEOUT_MS, dns.timeoutMs)
        val ping = NetworkRequestParser.parse(
            request("network.ping", JSONObject().put("host", "example.com").put("count", 0)),
        )
        assertEquals(1, ping.count)
        val http = NetworkRequestParser.parse(
            request("network.http", JSONObject().put("url", "https://example.com").put("maxRedirects", -5)),
        )
        assertEquals(0, http.maxRedirects)
    }

    @Test
    fun rejectsMalformedAndOversizedRequests() {
        assertParseFails("requestTooLarge", "x".repeat(NetworkLimits.MAX_REQUEST_BYTES + 1))

        val wrongVersion = JSONObject()
            .put("version", 2)
            .put("operationID", operationID)
            .put("method", "network.status")
        assertParseFails("unsupportedVersion", wrongVersion.toString())

        val wrongOperation = JSONObject()
            .put("version", 1)
            .put("operationID", "not-a-uuid")
            .put("method", "network.status")
        assertParseFails("invalidOperationID", wrongOperation.toString())

        assertParseFails("unsupportedMethod", request("network.unknown"))
    }

    @Test
    fun rejectsInvalidArguments() {
        assertParseFails("invalidArguments", request("network.dnsLookup", JSONObject()))
        assertParseFails(
            "invalidArguments",
            request("network.dnsLookup", JSONObject().put("host", "example.com").put("recordType", "TXT")),
        )
        assertParseFails(
            "invalidArguments",
            request("network.ping", JSONObject().put("host", "example.com").put("count", "four")),
        )
        assertParseFails(
            "invalidArguments",
            request("network.tcpProbe", JSONObject().put("host", "example.com").put("port", 0)),
        )
        assertParseFails(
            "invalidArguments",
            request("network.tcpProbe", JSONObject().put("host", "example.com").put("port", 70_000)),
        )
        assertParseFails(
            "invalidTarget",
            request("network.http", JSONObject().put("url", "https://user:pass@example.com/")),
        )
        assertParseFails(
            "invalidTarget",
            request("network.dnsLookup", JSONObject().put("host", "bad host")),
        )
        assertParseFails(
            "invalidArguments",
            JSONObject()
                .put("version", 1)
                .put("operationID", operationID)
                .put("method", "network.status")
                .put("arguments", JSONArray())
                .toString(),
        )
    }

    @Test
    fun refusesMissingPortForTcpProbe() {
        assertParseFails(
            "invalidArguments",
            request("network.tcpProbe", JSONObject().put("host", "example.com")),
        )
    }

    private fun request(method: String, arguments: JSONObject = JSONObject()): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", method)
        .put("arguments", arguments)
        .toString()

    private fun assertParseFails(code: String, input: String) {
        try {
            NetworkRequestParser.parse(input)
            fail("expected parse failure $code")
        } catch (failure: RequestParseException) {
            assertEquals(code, failure.code)
            assertTrue(failure.message?.isNotBlank() == true)
        }
    }
}
