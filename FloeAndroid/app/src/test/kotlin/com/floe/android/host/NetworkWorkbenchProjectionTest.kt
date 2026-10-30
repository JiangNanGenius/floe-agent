// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.network.LanDiscoveryInput
import com.floe.android.feature.network.NetworkExecuteCommand
import com.floe.android.feature.network.SpeedTestDirection
import com.floe.android.feature.network.SpeedTestInput
import org.junit.Assert.*
import org.junit.Test

class NetworkWorkbenchProjectionTest {
    @Test fun mismatchedReceiptCannotRenderAsCurrentMeasurement() {
        val json = """{"version":1,"operationID":"old","method":"network.wifiScan","status":"ok"}"""
        assertThrows(IllegalArgumentException::class.java) {
            NetworkWorkbenchProjection.decode("network.wifiScan", "current", json, false)
        }
    }
    @Test fun missingRssiIsNotRenderedAsZeroSignal() {
        val result = NetworkWorkbenchProjection.decode("network.wifiScan", "one", """
            {"version":1,"operationID":"one","method":"network.wifiScan","status":"partial",
             "cacheAgeMs":42000,"observations":{"accessPoints":[{"ssid":"Sample","frequencyMHz":2412,"channel":1}]},
             "limitations":["cached"]}
        """.trimIndent(), false)
        assertNull(result.accessPoints.single().signalDbm)
        assertEquals(42000L, result.cacheAgeMs)
        assertTrue(result.limitations.isNotEmpty())
    }
    @Test fun payloadIsExcludedFromOrdinaryResultRows() {
        val result = NetworkWorkbenchProjection.decode("network.http", "one", """
            {"version":1,"operationID":"one","method":"network.http","status":"ok",
             "observations":{"statusCode":200,"body":"private content","payload":"private content"}}
        """.trimIndent(), true)
        assertTrue(result.facts.any { it.label == "HTTP 状态" && it.value == "200" })
        assertFalse(result.facts.any { it.value.contains("private content") })
    }

    @Test fun lanRequestSerializesTypedArraysBooleansAndBudget() {
        val input = LanDiscoveryInput(
            serviceTypes = listOf("_http._tcp", "_ipp._tcp"),
            discoveryDurationMs = 4_000,
            includeAttributes = true,
            subnetCidr = "192.168.1.0/24",
            ports = listOf(80, 631),
            tcpConnectTimeoutMs = 500,
            tcpConcurrency = 16,
        )
        val args = requireNotNull(NetworkWorkbenchRequests.arguments(NetworkExecuteCommand.LanDiscovery(input)))
        assertEquals("_http._tcp", args.getJSONArray("serviceTypes").getString(0))
        assertEquals("_ipp._tcp", args.getJSONArray("serviceTypes").getString(1))
        assertEquals(80, args.getJSONArray("ports").getInt(0))
        assertEquals(631, args.getJSONArray("ports").getInt(1))
        assertTrue(args.getBoolean("includeAttributes"))
        assertEquals(4_000, args.getInt("discoveryDurationMs"))
        assertEquals(500, args.getInt("tcpConnectTimeoutMs"))
        assertEquals(16, args.getInt("tcpConcurrency"))
        assertEquals("192.168.1.0/24", args.getString("subnetCidr"))
        assertEquals(22_000, args.getInt("timeoutMs"))
        assertFalse(args.has("host"))
        assertFalse(args.has("url"))
    }

    @Test fun speedRequestSerializesExactIntegerBudgetAndNoDefaultEndpoint() {
        val input = SpeedTestInput(
            direction = SpeedTestDirection.BOTH,
            downloadUrl = "https://example.com/download",
            uploadUrl = "https://example.com/upload",
            maxBytesPerDirection = 8 * 1024 * 1024,
            durationBudgetMs = 14_000,
            allowMetered = true,
        )
        val args = requireNotNull(NetworkWorkbenchRequests.arguments(NetworkExecuteCommand.SpeedTest(input)))
        assertEquals("downloadAndUpload", args.getString("direction"))
        assertEquals("https://example.com/download", args.getString("downloadUrl"))
        assertEquals("https://example.com/upload", args.getString("uploadUrl"))
        assertEquals(8_388_608, args.getInt("maxBytesPerDirection"))
        assertEquals(14_000, args.getInt("durationBudgetMs"))
        assertEquals(0, args.getInt("warmupBytes"))
        assertTrue(args.getBoolean("allowMetered"))
        assertEquals(29_500, args.getInt("timeoutMs"))

        val downloadOnly = requireNotNull(
            NetworkWorkbenchRequests.arguments(
                NetworkExecuteCommand.SpeedTest(
                    SpeedTestInput(downloadUrl = "https://example.com/payload"),
                ),
            ),
        )
        assertFalse(downloadOnly.has("uploadUrl"))
        assertEquals("download", downloadOnly.getString("direction"))
    }

    @Test fun invalidTypedInputsDoNotBecomeRequests() {
        assertNull(
            NetworkWorkbenchRequests.arguments(
                NetworkExecuteCommand.LanDiscovery(LanDiscoveryInput()),
            ),
        )
        assertNull(
            NetworkWorkbenchRequests.arguments(
                NetworkExecuteCommand.SpeedTest(SpeedTestInput()),
            ),
        )
    }

    @Test fun userStopKeepsOwnershipUntilTheTypedResponseIsDelivered() {
        val ledger = NetworkOperationLedger()
        assertTrue(ledger.begin("id-1"))
        assertFalse("second operation cannot start while id-1 owns the run", ledger.begin("id-2"))
        assertTrue(ledger.requestStop("id-1"))
        assertFalse("a repeated stop is not a second request", ledger.requestStop("id-1"))
        assertTrue(ledger.fallbackEligible("id-1"))
        assertTrue(ledger.accepts("id-1"))
        assertTrue(ledger.markDelivered("id-1"))
        assertFalse("a delivered partial result must not be replaced by the fallback", ledger.fallbackEligible("id-1"))
        assertTrue(ledger.finish("id-1"))
        assertFalse(ledger.busy)
        assertNull(ledger.operationID)
    }

    @Test fun fenceDropsLateAndForeignResponses() {
        val ledger = NetworkOperationLedger()
        assertTrue(ledger.begin("owner-id"))
        assertEquals("owner-id", ledger.fence())
        assertFalse(ledger.busy)
        assertFalse(ledger.accepts("owner-id"))
        assertFalse(ledger.markDelivered("owner-id"))
        assertFalse(ledger.finish("owner-id"))
        assertTrue(ledger.begin("next-id"))
        assertFalse(ledger.accepts("owner-id"))
        assertTrue(ledger.accepts("next-id"))
        assertFalse(ledger.markDelivered("foreign-id"))
        assertTrue(ledger.accepts("next-id"))
    }

    @Test fun jsonArgumentsAreNotStringifiedByAccident() {
        val args = requireNotNull(
            NetworkWorkbenchRequests.arguments(
                NetworkExecuteCommand.Simple(
                    com.floe.android.feature.network.NetworkPage.WIFI,
                    mapOf("refresh" to "true", "port" to "443"),
                ),
            ),
        )
        assertTrue(args.get("refresh") is Boolean)
        assertTrue(args.get("port") is Int)
        assertNull(args.opt("missing"))
    }
}
