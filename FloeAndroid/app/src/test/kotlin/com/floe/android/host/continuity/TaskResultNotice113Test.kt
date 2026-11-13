// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.continuity

import com.floe.android.host.notification.RunTerminalDeliveryFence
import com.floe.android.host.notification.RunTerminalNoticeKind
import com.floe.android.host.notification.RunTerminalNoticePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskResultNotice113Test {
    @Test fun durableOutcomesStayDistinctAndSuspensionIsNotFailure() {
        assertEquals(RunTerminalNoticeKind.COMPLETED, RunTerminalNoticePolicy.kindFor(
            "completed", "completed", true, false))
        assertEquals(RunTerminalNoticeKind.FAILED, RunTerminalNoticePolicy.kindFor(
            "failed", "failed", true, false))
        assertEquals(RunTerminalNoticeKind.CANCELLED, RunTerminalNoticePolicy.kindFor(
            "cancelled", "cancelled", true, false))
        assertEquals(RunTerminalNoticeKind.SUSPENDED, RunTerminalNoticePolicy.kindFor(
            "checkpointed", "suspended", true, false))
        assertEquals(RunTerminalNoticeKind.SUSPENDED, RunTerminalNoticePolicy.kindFor(
            "interrupted", null, null, false))
        assertNull(RunTerminalNoticePolicy.kindFor(
            "idle", "none", false, false))
        assertNull(RunTerminalNoticePolicy.kindFor(
            "preparing", "none", false, false))
    }

    @Test fun liveOrRetryingOwnerAndNonDurableRowNeverAnnounceFailure() {
        assertNull(RunTerminalNoticePolicy.kindFor(
            "failed", "failed", true, liveOwner = true))
        assertNull(RunTerminalNoticePolicy.kindFor(
            "failed", "failed", durableTerminal = false, liveOwner = false))
        assertNull(RunTerminalNoticePolicy.kindFor(
            "streamingModel", "none", false, false))
        assertEquals(RunTerminalNoticeKind.WAITING, RunTerminalNoticePolicy.kindFor(
            "waitingApproval", "waiting", false, liveOwner = true))
        assertNull(RunTerminalNoticePolicy.kindFor(
            "waitingApproval", "waiting", false, liveOwner = false))
    }

    @Test fun policyAllowsTerminalFailureCancellationAndSuspensionExactly() {
        assertTrue(RunTerminalNoticePolicy.policyAllows(null, RunTerminalNoticeKind.COMPLETED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("terminal", RunTerminalNoticeKind.COMPLETED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("terminal", RunTerminalNoticeKind.FAILED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("critical", RunTerminalNoticeKind.FAILED))
        assertFalse(RunTerminalNoticePolicy.policyAllows("critical", RunTerminalNoticeKind.COMPLETED))
        assertFalse(RunTerminalNoticePolicy.policyAllows("critical", RunTerminalNoticeKind.CANCELLED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("stages", RunTerminalNoticeKind.CANCELLED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("stages", RunTerminalNoticeKind.SUSPENDED))
        assertFalse(RunTerminalNoticePolicy.policyAllows("off", RunTerminalNoticeKind.FAILED))
        assertTrue(RunTerminalNoticePolicy.policyAllows("critical", RunTerminalNoticeKind.WAITING))
        assertTrue(RunTerminalNoticePolicy.policyAllows("stages", RunTerminalNoticeKind.WAITING))
        assertFalse(RunTerminalNoticePolicy.policyAllows("terminal", RunTerminalNoticeKind.WAITING))
        // A corrupt stored value fails closed instead of guessing a policy.
        assertFalse(RunTerminalNoticePolicy.policyAllows("unknown", RunTerminalNoticeKind.FAILED))
    }

    @Test fun foregroundPresentationUsesTheInThreadStateNotADuplicateAlert() {
        assertFalse(RunTerminalNoticePolicy.shouldPost(
            RunTerminalNoticeKind.COMPLETED, "stages", appIsForeground = true))
        assertTrue(RunTerminalNoticePolicy.shouldPost(
            RunTerminalNoticeKind.COMPLETED, "stages", appIsForeground = false))
        assertFalse(RunTerminalNoticePolicy.shouldPost(
            RunTerminalNoticeKind.FAILED, "off", appIsForeground = false))
    }

    @Test fun staleActivationCannotDeliverOrWithdrawANewerNotice() {
        val fence = RunTerminalDeliveryFence()
        fence.arm("conversation", "run", generation = 2)
        assertFalse(fence.isArmed("conversation", "run", generation = 1))
        assertTrue(fence.isArmed("conversation", "run", generation = 2))
        // A stale callback discarding generation 1 must not consume gen 2.
        fence.discard("conversation", "run", generation = 1)
        assertTrue(fence.isArmed("conversation", "run", generation = 2))
        // A real retry/replacement supersedes the old activation.
        fence.discard("conversation", "run")
        assertFalse(fence.isArmed("conversation", "run", generation = 2))
        fence.arm("conversation", "run", generation = 3)
        assertTrue(fence.isArmed("conversation", "run", generation = 3))
        fence.markWaitingNotice("conversation", "run")
        assertTrue(fence.consumeWaitingNotice("conversation", "run"))
        assertFalse(fence.consumeWaitingNotice("conversation", "run"))
        // A new task invocation/navigation retires its whole family.
        fence.discardConversation("conversation")
        assertFalse(fence.isArmed("conversation", "run", generation = 3))
    }
}
