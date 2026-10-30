// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TcpProbeSummaryTest {
    @Test
    fun successfulFirstConnectDoesNotCarryTimeoutText() {
        val limitations = TcpProbeSummary.limitations(
            connected = true,
            attempted = 1,
            resolvedCount = 2,
        )
        assertFalse(limitations.any { it.contains("timeout budget ended", ignoreCase = true) })
        assertTrue(limitations.any { it.contains("handshake completed", ignoreCase = true) })
    }

    @Test
    fun successfulLaterConnectRetainsEarlierAttemptTextWithoutTimeoutText() {
        val limitations = TcpProbeSummary.limitations(
            connected = true,
            attempted = 2,
            resolvedCount = 2,
        )
        assertFalse(limitations.any { it.contains("timeout budget ended", ignoreCase = true) })
        assertTrue(limitations.any { it.contains("later address succeeded", ignoreCase = true) })
    }

    @Test
    fun timeoutTextAppearsOnlyWhenBudgetEndedBeforeAllAddresses() {
        val timedOut = TcpProbeSummary.limitations(
            connected = false,
            attempted = 1,
            resolvedCount = 2,
        )
        assertTrue(timedOut.any { it.contains("timeout budget ended", ignoreCase = true) })

        val allAttempted = TcpProbeSummary.limitations(
            connected = false,
            attempted = 2,
            resolvedCount = 2,
        )
        assertFalse(allAttempted.any { it.contains("timeout budget ended", ignoreCase = true) })
    }

    @Test
    fun statusClassificationMatchesExistingContract() {
        assertEquals(
            ObservationStatus.OK,
            TcpProbeSummary.status(true, 1, sawTimeout = false, sawRefused = false, sawError = false),
        )
        assertEquals(
            ObservationStatus.TIMEOUT,
            TcpProbeSummary.status(false, 0, sawTimeout = false, sawRefused = false, sawError = false),
        )
        assertEquals(
            ObservationStatus.TIMEOUT,
            TcpProbeSummary.status(false, 1, sawTimeout = true, sawRefused = false, sawError = false),
        )
        assertEquals(
            ObservationStatus.OK,
            TcpProbeSummary.status(false, 1, sawTimeout = false, sawRefused = true, sawError = false),
        )
        assertEquals(
            ObservationStatus.ERROR,
            TcpProbeSummary.status(false, 1, sawTimeout = false, sawRefused = true, sawError = true),
        )
    }
}
