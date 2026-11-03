// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.*
import org.junit.Test

class RuntimeEnvironmentTransactionFenceTest {
    @Test fun originalPositiveOwnershipKeepsAdmissionFenced() {
        val fence = RuntimeEnvironmentTransactionFence()
        fence.reserve("request-a")
        fence.settleIfUnowned { it == "request-a" }
        assertTrue(fence.active)
        assertEquals("request-a", fence.requestID)
    }
    @Test fun onlyActualSettlementClearsTheNegativeFence() {
        val fence = RuntimeEnvironmentTransactionFence()
        fence.reserve("request-a")
        fence.settleIfUnowned { false }
        assertFalse(fence.active)
    }
    @Test fun lateOldCompletionCannotClearANewerReservation() {
        val fence = RuntimeEnvironmentTransactionFence()
        fence.reserve("request-a")
        fence.settleIfUnowned {
            // Force the race: another settlement clears A and the next
            // original admission publishes B before A's old callback returns.
            fence.settleIfUnowned { false }
            fence.reserve("request-b")
            false
        }
        assertEquals("request-b", fence.requestID)
        assertTrue(fence.active)
    }
    @Test fun duplicateReservationNeverReplacesTheCurrentOwner() {
        val fence = RuntimeEnvironmentTransactionFence()
        fence.reserve("request-a")
        assertThrows(IllegalStateException::class.java) { fence.reserve("request-b") }
        assertEquals("request-a", fence.requestID)
    }
}
