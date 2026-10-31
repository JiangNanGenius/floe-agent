// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlFenceTest {
    @Test
    fun claimCreatesTicketAndSameOwnerIsIdempotent() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(owner))
        val first = fence.ticket(owner)
        assertNotNull(first)
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(owner))
        val second = fence.ticket(owner)
        assertEquals(first, second)
        assertEquals(PhoneControlFence.Verdict.Open, fence.validate(first!!))
    }

    @Test
    fun crossRunCannotClaimOrValidateAnotherRunTicket() {
        val fence = PhoneControlFence()
        val first = testOwner(run = "33333333-3333-3333-3333-333333333333")
        val second = testOwner(run = "44444444-4444-4444-4444-444444444444")
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(first))
        val ticket = fence.ticket(first)!!
        assertEquals(PhoneControlFence.Claim.ForeignRun, fence.claim(second))
        assertNull(fence.ticket(second))
        assertEquals(
            PhoneControlFence.Verdict.ForeignRun,
            fence.validate(ticket.copy(owner = second)),
        )
    }

    @Test
    fun pageGenerationInvalidatesRefsButNotTheRun() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.claim(owner)
        val ticket = fence.ticket(owner)!!
        fence.onPageChanged()
        assertEquals(PhoneControlFence.Verdict.StalePage, fence.validate(ticket))
        assertNotNull(fence.ticket(owner))
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(owner))
    }

    @Test
    fun stopBlocksNewActionsAndInvalidatesInFlightGeneration() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.claim(owner)
        val ticket = fence.ticket(owner)!!
        fence.block(PhoneControlBlocker.STOPPED)
        assertEquals(
            PhoneControlFence.Verdict.Blocked(PhoneControlBlocker.STOPPED),
            fence.validate(ticket),
        )
        assertNull(fence.ticket(owner))
        assertEquals(
            PhoneControlFence.Claim.Blocked(PhoneControlBlocker.STOPPED),
            fence.claim(owner),
        )
        assertEquals(PhoneControlBlocker.STOPPED, fence.state().blocker)
        assertNull(fence.state().owner)
    }

    @Test
    fun laterLockDoesNotDowngradeAUserStopIntoAnUnlockableFence() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.claim(owner)
        fence.block(PhoneControlBlocker.STOPPED)
        fence.block(PhoneControlBlocker.LOCKED)
        assertEquals(PhoneControlBlocker.STOPPED, fence.state().blocker)
        assertEquals(false, fence.clear(PhoneControlBlocker.LOCKED))
        assertEquals(PhoneControlFence.Claim.Ok, fence.arm(owner))
        assertEquals(null, fence.state().blocker)
    }

    @Test
    fun userTouchIsClearedOnlyByExplicitArm() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.claim(owner)
        fence.block(PhoneControlBlocker.USER_TOUCH)
        assertEquals(
            PhoneControlFence.Claim.Blocked(PhoneControlBlocker.USER_TOUCH),
            fence.claim(owner),
        )
        assertEquals(PhoneControlFence.Claim.Ok, fence.arm(owner))
        assertNull(fence.state().blocker)
        assertEquals(owner, fence.state().owner)
    }

    @Test
    fun lockIsNotClearedByArmButClearsOnActualUnlock() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.block(PhoneControlBlocker.LOCKED)
        assertEquals(
            PhoneControlFence.Claim.Blocked(PhoneControlBlocker.LOCKED),
            fence.arm(owner),
        )
        assertTrue(fence.clear(PhoneControlBlocker.LOCKED))
        assertEquals(PhoneControlFence.Claim.Ok, fence.arm(owner))
        assertNull(fence.state().blocker)
    }

    @Test
    fun releaseInvalidatesTheEndedRunAndAllowsANewRun() {
        val fence = PhoneControlFence()
        val ended = testOwner(run = "55555555-5555-5555-5555-555555555555")
        val next = testOwner(run = "66666666-6666-6666-6666-666666666666")
        fence.claim(ended)
        val ticket = fence.ticket(ended)!!
        assertTrue(fence.release(ended))
        assertEquals(PhoneControlFence.Verdict.ForeignRun, fence.validate(ticket))
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(next))
        assertEquals(next, fence.state().owner)
    }

    @Test
    fun revokedServiceMustReconnectBeforeAnyOtherClaim() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.block(PhoneControlBlocker.SERVICE_REVOKED)
        assertEquals(
            PhoneControlFence.Claim.Blocked(PhoneControlBlocker.SERVICE_REVOKED),
            fence.arm(owner),
        )
        assertTrue(fence.clear(PhoneControlBlocker.SERVICE_REVOKED))
        assertEquals(PhoneControlFence.Claim.Ok, fence.claim(owner))
    }

    @Test
    fun everyFenceTransitionBumpsGeneration() {
        val fence = PhoneControlFence()
        val owner = testOwner()
        fence.claim(owner)
        val first = fence.state().fenceGeneration
        fence.release(owner)
        val second = fence.state().fenceGeneration
        fence.block(PhoneControlBlocker.TAKEN_OVER)
        val third = fence.state().fenceGeneration
        assertTrue(second > first)
        assertTrue(third > second)
    }
}
