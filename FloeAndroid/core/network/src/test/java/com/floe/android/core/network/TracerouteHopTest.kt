// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

/**
 * Typed traceroute hop grammar: a hop is what the probes actually observed
 * and nothing more. Out-of-bounds TTLs, mixed identities (an address on a
 * timed-out hop, an unreachable code on a reached hop), RTTs beyond the probe
 * budget and non-finite/negative RTTs are rejected — by the constructor for
 * authored rows and by the strict decoder for untrusted rows.
 *
 * AUTHORED SOURCE ONLY: Main owns compilation/execution in the unified batch.
 */
class TracerouteHopTest {

    @Test
    fun validHopsRoundTripThroughJson() {
        val reached = TracerouteHop(
            ttl = 3,
            status = TracerouteHopStatus.REACHED,
            address = "192.0.2.44",
            rttsMs = listOf(12.5, 11.0),
        )
        val decoded = TracerouteHop.fromJson(reached.toJson())
        assertNotNull(decoded)
        assertEquals(reached, decoded)

        val timedOut = TracerouteHop(ttl = 2, status = TracerouteHopStatus.TIMEOUT)
        assertEquals(timedOut, TracerouteHop.fromJson(timedOut.toJson()))

        val exceeded = TracerouteHop(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "198.51.100.1",
            rttsMs = listOf(4.25),
        )
        assertEquals(exceeded, TracerouteHop.fromJson(exceeded.toJson()))

        val unreachable = TracerouteHop(
            ttl = 5,
            status = TracerouteHopStatus.UNREACHABLE,
            address = "203.0.113.7",
            rttsMs = listOf(30.0),
            unreachableCode = 3,
        )
        assertEquals(unreachable, TracerouteHop.fromJson(unreachable.toJson()))
    }

    @Test
    fun rejectsOutOfBoundsTtlAndMalformedRows() {
        assertHopRejected(ttl = 0, status = TracerouteHopStatus.TIMEOUT)
        assertHopRejected(ttl = 31, status = TracerouteHopStatus.TIMEOUT)
        assertHopRejected(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "",
        )
        assertHopRejected(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            rttsMs = listOf(1.0, 2.0, 3.0, 4.0),
        )
        assertHopRejected(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "198.51.100.1",
            rttsMs = listOf(Double.NaN),
        )
        assertHopRejected(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "198.51.100.1",
            rttsMs = listOf(-0.5),
        )
        assertHopRejected(
            ttl = 1,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "198.51.100.1",
            rttsMs = listOf(Double.POSITIVE_INFINITY),
        )
    }

    @Test
    fun rejectsMixedIdentities() {
        // A timed-out hop cannot name an address or an unreachable code.
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.TIMEOUT,
            address = "198.51.100.1",
        )
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.TIMEOUT,
            unreachableCode = 3,
        )
        // A responding hop cannot carry an unreachable code.
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.TIME_EXCEEDED,
            address = "198.51.100.1",
            unreachableCode = 3,
        )
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.REACHED,
            address = "192.0.2.44",
            unreachableCode = 1,
        )
        // An unreachable hop needs both its address and its ICMP code.
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.UNREACHABLE,
            address = "203.0.113.7",
        )
        assertHopRejected(
            ttl = 2,
            status = TracerouteHopStatus.UNREACHABLE,
            unreachableCode = 3,
        )
    }

    @Test
    fun strictDecoderRejectsMalformedObservedRows() {
        assertNull(
            TracerouteHop.fromJson(
                JSONObject()
                    .put("ttl", 1)
                    .put("status", "teleported")
                    .put("address", "198.51.100.1"),
            ),
        )
        assertNull(
            TracerouteHop.fromJson(
                JSONObject()
                    .put("ttl", 1)
                    .put("status", "timeout")
                    .put("address", "198.51.100.1"),
            ),
        )
        assertNull(
            TracerouteHop.fromJson(
                JSONObject()
                    .put("ttl", 99)
                    .put("status", "timeExceeded")
                    .put("address", "198.51.100.1"),
            ),
        )
        assertNull(
            TracerouteHop.fromJson(
                JSONObject().put("ttl", 1).put("status", "reached"),
            ),
        )
        assertNull(
            TracerouteHop.fromJson(
                JSONObject()
                    .put("ttl", 1)
                    .put("status", "timeExceeded")
                    .put("address", "198.51.100.1")
                    .put("rttsMs", org.json.JSONArray().put(-1.0)),
            ),
        )
    }

    private fun assertHopRejected(
        ttl: Int,
        status: TracerouteHopStatus,
        address: String? = null,
        rttsMs: List<Double> = emptyList(),
        unreachableCode: Int? = null,
    ) {
        try {
            TracerouteHop(
                ttl = ttl,
                status = status,
                address = address,
                rttsMs = rttsMs,
                unreachableCode = unreachableCode,
            )
            fail("expected hop rejection for $status ttl=$ttl address=$address code=$unreachableCode")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
