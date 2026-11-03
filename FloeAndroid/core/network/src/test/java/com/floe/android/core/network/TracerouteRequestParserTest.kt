// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/**
 * Frozen `network.traceroute` request-v1 parsing. Timing/count values clamp
 * exactly like the ping method; a structurally invalid host (scheme, path,
 * whitespace, control bytes) is refused, never normalized into a probe. Old
 * valid requests for every existing method keep parsing unchanged.
 *
 * AUTHORED SOURCE ONLY: Main owns compilation/execution in the unified batch.
 */
class TracerouteRequestParserTest {
    private val operationID = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun parsesDefaultsAndKeepsHostTarget() {
        val parsed = NetworkRequestParser.parse(
            request("network.traceroute", JSONObject().put("host", "example.com")),
        )
        assertEquals(NetworkMethod.TRACEROUTE, parsed.method)
        assertEquals("example.com", parsed.host)
        assertEquals("example.com", parsed.target)
        assertEquals(NetworkLimits.DEFAULT_TRACEROUTE_TIMEOUT_MS, parsed.timeoutMs)
        assertEquals(NetworkLimits.DEFAULT_TRACEROUTE_HOPS, parsed.traceroute!!.maxHops)
        assertEquals(
            NetworkLimits.DEFAULT_TRACEROUTE_PROBES_PER_HOP,
            parsed.traceroute!!.probesPerHop,
        )
        assertEquals(
            NetworkLimits.DEFAULT_TRACEROUTE_PROBE_TIMEOUT_MS,
            parsed.traceroute!!.probeTimeoutMs,
        )
    }

    @Test
    fun clampsTimingAndCountValuesToContractBounds() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.traceroute",
                JSONObject()
                    .put("host", "example.com")
                    .put("maxHops", 999)
                    .put("probesPerHop", 0)
                    .put("probeTimeoutMs", 1)
                    .put("timeoutMs", 999_999),
            ),
        )
        assertEquals(NetworkLimits.MAX_TRACEROUTE_HOPS, parsed.traceroute!!.maxHops)
        assertEquals(NetworkLimits.MIN_TRACEROUTE_PROBES_PER_HOP, parsed.traceroute!!.probesPerHop)
        assertEquals(
            NetworkLimits.MIN_TRACEROUTE_PROBE_TIMEOUT_MS,
            parsed.traceroute!!.probeTimeoutMs,
        )
        assertEquals(NetworkLimits.MAX_TIMEOUT_MS, parsed.timeoutMs)

        val lowered = NetworkRequestParser.parse(
            request(
                "network.traceroute",
                JSONObject()
                    .put("host", "example.com")
                    .put("maxHops", -4)
                    .put("probesPerHop", 99),
            ),
        )
        assertEquals(NetworkLimits.MIN_TRACEROUTE_HOPS, lowered.traceroute!!.maxHops)
        assertEquals(NetworkLimits.MAX_TRACEROUTE_PROBES_PER_HOP, lowered.traceroute!!.probesPerHop)
    }

    @Test
    fun acceptsExplicitValidBudget() {
        val parsed = NetworkRequestParser.parse(
            request(
                "network.traceroute",
                JSONObject()
                    .put("host", "192.0.2.10")
                    .put("maxHops", 30)
                    .put("probesPerHop", 3)
                    .put("probeTimeoutMs", 5_000)
                    .put("timeoutMs", 30_000),
            ),
        )
        assertEquals(30, parsed.traceroute!!.maxHops)
        assertEquals(3, parsed.traceroute!!.probesPerHop)
        assertEquals(5_000, parsed.traceroute!!.probeTimeoutMs)
        assertEquals(30_000, parsed.timeoutMs)
    }

    @Test
    fun refusesSchemePathInjectionAndControlCharactersInHost() {
        assertTracerouteParseFails("invalidTarget", JSONObject().put("host", "https://example.com"))
        assertTracerouteParseFails("invalidTarget", JSONObject().put("host", "example.com/path"))
        assertTracerouteParseFails("invalidTarget", JSONObject().put("host", "exa mple.com"))
        assertTracerouteParseFails("invalidTarget", JSONObject().put("host", "exam\u0000ple.com"))
        assertTracerouteParseFails("invalidTarget", JSONObject().put("host", "user@example.com"))
        assertTracerouteParseFails("invalidArguments", JSONObject())
    }

    @Test
    fun refusesNonIntegerBudgetFields() {
        assertTracerouteParseFails(
            "invalidArguments",
            JSONObject().put("host", "example.com").put("maxHops", "many"),
        )
        assertTracerouteParseFails(
            "invalidArguments",
            JSONObject().put("host", "example.com").put("probesPerHop", 1.5),
        )
        assertTracerouteParseFails(
            "invalidArguments",
            JSONObject().put("host", "example.com").put("probeTimeoutMs", true),
        )
    }

    @Test
    fun oldPingRequestsKeepParsingUnchanged() {
        val ping = NetworkRequestParser.parse(
            request("network.ping", JSONObject().put("host", "example.com")),
        )
        assertEquals(NetworkMethod.PING, ping.method)
        assertEquals(4, ping.count)
        org.junit.Assert.assertNull(ping.traceroute)
    }

    private fun assertTracerouteParseFails(code: String, arguments: JSONObject) {
        try {
            NetworkRequestParser.parse(request("network.traceroute", arguments))
            fail("expected refusal $code")
        } catch (failure: RequestParseException) {
            assertEquals(code, failure.code)
        }
    }

    private fun request(method: String, arguments: JSONObject): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", method)
        .put("arguments", arguments)
        .toString()
}
