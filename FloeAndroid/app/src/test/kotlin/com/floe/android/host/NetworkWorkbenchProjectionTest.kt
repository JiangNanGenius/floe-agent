// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

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
}
