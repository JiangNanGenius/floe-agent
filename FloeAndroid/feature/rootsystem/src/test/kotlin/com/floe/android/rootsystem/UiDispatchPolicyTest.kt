// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.UiDispatchOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Exercises the exact dispatch-state policy used by the real Android bridge.
 * ACCEPTED means framework acceptance; a throw or a partial gesture is always
 * UNKNOWN and requires a real readback, never a replay.
 */
class UiDispatchPolicyTest {

    @Test fun unconfirmedOrQueuedReleaseRetainsTheExactOwner() {
        for (state in listOf("release=queued", "release=unconfirmed")) {
            var owned = true
            val result = UiInputLeasePolicy.release(
                stillOwned = { owned },
                attempt = { state },
                clearOwnership = { owned = false },
            )
            assertEquals(state, result)
            assertTrue(owned)
        }
    }

    @Test fun aThrowingReleaseRetainsTheOwnerForCleanup() {
        var owned = true
        val result = UiInputLeasePolicy.release(
            stillOwned = { owned },
            attempt = { throw IllegalStateException("synthetic input failure") },
            clearOwnership = { owned = false },
        )
        assertEquals("release=unconfirmed", result)
        assertTrue(owned)
    }

    @Test fun confirmedReleaseSettlesOnlyItsOwnLease() {
        var owner: String? = "old"
        val result = UiInputLeasePolicy.release(
            stillOwned = { owner == "old" },
            attempt = { "release=confirmed" },
            clearOwnership = { owner = null },
        )
        assertEquals("release=confirmed", result)
        assertEquals(null, owner)
    }

    @Test fun aLateConfirmationCannotClearTheSuccessorLease() {
        var owner: String? = "old"
        UiInputLeasePolicy.release(
            stillOwned = { owner == "old" },
            attempt = { owner = "successor"; "release=confirmed" },
            clearOwnership = { owner = null },
        )
        assertEquals("successor", owner)
    }

    @Test fun acceptedSemanticActionNeverFallsBack() {
        val decision = UiDispatchPolicy.action(UiActionAttempt.ACCEPTED)
        assertEquals(UiDispatchOutcome.ACCEPTED, decision.dispatch)
        assertFalse(decision.fallbackAllowed)
    }

    @Test fun provedSemanticRejectionMayFallbackExactlyOnce() {
        val decision = UiDispatchPolicy.action(UiActionAttempt.REJECTED)
        assertEquals(UiDispatchOutcome.NOT_DISPATCHED, decision.dispatch)
        assertTrue(decision.fallbackAllowed)
    }

    @Test fun thrownSemanticActionIsUnknownAndMayNotFallback() {
        val decision = UiDispatchPolicy.action(UiActionAttempt.THREW)
        assertEquals(UiDispatchOutcome.UNKNOWN, decision.dispatch)
        assertFalse(decision.fallbackAllowed)
    }

    @Test fun firstEventRejectedProvesNothingWasSent() {
        val decision = UiDispatchPolicy.input(listOf(UiInputSend.REJECTED))
        assertEquals(UiDispatchOutcome.NOT_DISPATCHED, decision.dispatch)
        assertFalse(decision.releaseRequired)
    }

    @Test fun firstEventThrowIsUnknownAndReleases() {
        val decision = UiDispatchPolicy.input(listOf(UiInputSend.THREW))
        assertEquals(UiDispatchOutcome.UNKNOWN, decision.dispatch)
        assertTrue(decision.releaseRequired)
        assertTrue(decision.partial)
    }

    @Test fun acceptedDownThenRejectedUpIsAnHonestUnknown() {
        val decision = UiDispatchPolicy.input(
            listOf(UiInputSend.ACCEPTED, UiInputSend.REJECTED),
        )
        assertEquals(UiDispatchOutcome.UNKNOWN, decision.dispatch)
        assertTrue(decision.releaseRequired)
    }

    @Test fun acceptedDownThenThrownUpIsAnHonestUnknown() {
        val decision = UiDispatchPolicy.input(
            listOf(UiInputSend.ACCEPTED, UiInputSend.THREW),
        )
        assertEquals(UiDispatchOutcome.UNKNOWN, decision.dispatch)
        assertTrue(decision.releaseRequired)
    }

    @Test fun acceptedDownThenCancelRequiresRelease() {
        val decision = UiDispatchPolicy.input(
            listOf(UiInputSend.ACCEPTED),
            cancelledBeforeCompletion = true,
        )
        assertEquals(UiDispatchOutcome.UNKNOWN, decision.dispatch)
        assertTrue(decision.releaseRequired)
    }

    @Test fun everyEventAcceptedIsAccepted() {
        val decision = UiDispatchPolicy.input(
            listOf(
                UiInputSend.ACCEPTED,
                UiInputSend.ACCEPTED,
                UiInputSend.ACCEPTED,
            ),
        )
        assertEquals(UiDispatchOutcome.ACCEPTED, decision.dispatch)
        assertFalse(decision.releaseRequired)
    }

    @Test fun noAttemptedEventIsNotDispatched() {
        val decision = UiDispatchPolicy.input(emptyList())
        assertEquals(UiDispatchOutcome.NOT_DISPATCHED, decision.dispatch)
        assertFalse(decision.releaseRequired)
    }

    @Test fun cancellationBeforeTheFirstEventIsNotDispatched() {
        val decision = UiDispatchPolicy.input(
            emptyList(),
            cancelledBeforeCompletion = true,
        )
        assertEquals(UiDispatchOutcome.NOT_DISPATCHED, decision.dispatch)
        assertFalse(decision.releaseRequired)
    }

    @Test fun theSameRequestAndOwnerMayReleaseHeldInput() {
        assertTrue(
            UiInputLeasePolicy.matches(
                activeToken = "task:run:7:grant|call:adbui:act",
                activeRequestId = "call:adbui:act",
                requestId = "call:adbui:act",
                ownerToken = "task:run:7:grant|call:adbui:act",
            ),
        )
    }

    @Test fun anOlderOwnerCannotReleaseASuccessorInput() {
        assertFalse(
            UiInputLeasePolicy.matches(
                activeToken = "successor:run:8:grant2|call2:adbui:act",
                activeRequestId = "call2:adbui:act",
                requestId = "call2:adbui:act",
                ownerToken = "task:run:7:grant|call:adbui:act",
            ),
        )
    }

    @Test fun aDifferentRequestIdCannotBeReleased() {
        assertFalse(
            UiInputLeasePolicy.matches(
                activeToken = "task:run:7:grant|call2:adbui:swipe",
                activeRequestId = "call2:adbui:swipe",
                requestId = "call:adbui:act",
                ownerToken = null,
            ),
        )
    }

    @Test fun theLegacyCancellationStillNeedsTheExactRequestId() {
        assertTrue(
            UiInputLeasePolicy.matches(
                activeToken = "task:run:7:grant|call:adbui:act",
                activeRequestId = "call:adbui:act",
                requestId = "call:adbui:act",
                ownerToken = null,
            ),
        )
    }
}
