// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkObservationJsonTest {
    @Test
    fun rendersFrozenEnvelopeWithNetworkAndMissingPermissions() {
        val snapshot = NetworkSnapshot(
            available = true,
            handle = "0x1234",
            transports = listOf("wifi"),
            capabilities = listOf("internet", "validated"),
            interfaceName = "wlan0",
            mtu = 1500,
            dnsServers = listOf("192.168.1.1"),
            privateDnsActive = true,
            vpn = false,
            limitations = listOf("Wi-Fi identifiers may be redacted."),
        )
        val text = NetworkObservationJson.envelope(
            operationID = "123e4567-e89b-12d3-a456-426614174000",
            methodWire = "network.dnsLookup",
            status = ObservationStatus.OK,
            measuredAt = "2026-10-30T01:02:03Z",
            snapshot = snapshot,
            target = "example.com",
            observations = JSONObject().put("addresses", jsonArray(listOf("93.184.216.34"))),
            limitations = listOf("Resolver cache age is not exposed."),
            cacheAgeMs = null,
            missingPermissions = listOf("android.permission.ACCESS_FINE_LOCATION"),
        )
        val json = JSONObject(text)
        assertEquals(1, json.getInt("version"))
        assertEquals("phone", json.getString("source"))
        assertEquals("ok", json.getString("status"))
        assertEquals("2026-10-30T01:02:03Z", json.getString("measuredAt"))
        assertEquals("example.com", json.getString("target"))
        assertEquals("0x1234", json.getJSONObject("network").getString("handle"))
        assertTrue(json.getJSONObject("network").getBoolean("available"))
        assertEquals(1, json.getJSONArray("missingPermissions").length())
        assertTrue(json.getJSONArray("limitations").length() >= 2)
        assertFalse(json.has("cacheAgeMs"))
    }

    @Test
    fun includesCacheAgeWhenPresentAndOmitsOptionalFields() {
        val text = NetworkObservationJson.envelope(
            operationID = "op",
            methodWire = "network.wifiScan",
            status = ObservationStatus.PARTIAL,
            measuredAt = "2026-10-30T01:02:03Z",
            snapshot = NetworkSnapshot(available = false),
            target = null,
            observations = JSONObject().put("accessPoints", jsonArray(emptyList())),
            limitations = emptyList(),
            cacheAgeMs = 12_345,
            missingPermissions = emptyList(),
        )
        val json = JSONObject(text)
        assertEquals(12_345L, json.getLong("cacheAgeMs"))
        assertFalse(json.has("target"))
        assertFalse(json.has("missingPermissions"))
        assertFalse(json.getJSONObject("network").getBoolean("available"))
    }

    @Test
    fun truncatesOversizedObservationsHonestly() {
        val huge = JSONObject().put("blob", "x".repeat(NetworkLimits.MAX_OUTPUT_BYTES + 1024))
        val text = NetworkObservationJson.envelope(
            operationID = "op",
            methodWire = "network.status",
            status = ObservationStatus.OK,
            measuredAt = "2026-10-30T01:02:03Z",
            snapshot = NetworkSnapshot(available = true),
            target = null,
            observations = huge,
            limitations = listOf("Original limitation."),
            cacheAgeMs = null,
            missingPermissions = emptyList(),
        )
        assertTrue(text.toByteArray(Charsets.UTF_8).size <= NetworkLimits.MAX_OUTPUT_BYTES)
        val json = JSONObject(text)
        assertTrue(json.getJSONObject("observations").getBoolean("truncated"))
        assertEquals("outputLimit", json.getJSONObject("observations").getString("reason"))
    }

    @Test
    fun errorEnvelopeIsPlainAndBounded() {
        val text = NetworkObservationJson.errorEnvelope(
            operationID = "op",
            methodWire = "network.status",
            status = ObservationStatus.ERROR,
            measuredAt = "2026-10-30T01:02:03Z",
            code = "invalidRequest",
            message = "request is not a valid JSON object",
            snapshot = NetworkSnapshot(available = false),
        )
        val json = JSONObject(text)
        assertEquals("error", json.getString("status"))
        assertEquals("invalidRequest", json.getJSONObject("observations").getString("errorCode"))
        assertEquals("request is not a valid JSON object", json.getJSONObject("observations").getString("message"))
    }
}
