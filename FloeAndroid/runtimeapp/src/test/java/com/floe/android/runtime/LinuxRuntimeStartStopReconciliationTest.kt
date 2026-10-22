// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.linuxruntime.supervision.JobState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * G03-R3 runtime-start repair — AUTHORED NOT RUN regressions (Main's grouped
 * JVM batch executes). Pure decision cores only: org.json and Android are
 * deliberately absent, the same constraint the existing
 * [RuntimeWorkspacePreflightGuardTest] documents.
 *
 * Pins the two behavioural contracts this batch changes on the runtime side:
 *
 *  1. [LinuxRuntimeOperations.shellCancelScope] — the session-less
 *     `shell.cancel` grammar. The kernel explicitly routes an urgent
 *     `{requestID}` cancel whose id equals its own pendingShellID (candidate
 *     05: that exact shape then threw inside validateCancellation BEFORE
 *     stopOwnedWork could arm cancelPreparation, so the notification Stop
 *     could never cancel a start still in recover/materialize/import and the
 *     wake/FGS ownership was retained indefinitely). The repair accepts ONLY
 *     the exact in-flight start request id (target-scoped; never a broad
 *     runtime cancel) and keeps the started-session grammar byte-for-byte.
 *
 *  2. [LinuxRuntimeOperations.nextReconcileAction] — the bounded OWNED
 *     release reconciliation. A transient terminal-proof miss or a failed
 *     (retryable per the frozen native lease contract) authority hand-back
 *     used to be a permanent dead end: nothing ever retried
 *     settleLease/finish, so the held lease made every later shell.start
 *     refuse as busy (exit=125 runtime_not_started) while the Core lease kept
 *     the wake lock. The decision may only CHOOSE the designed entries; it
 *     never releases anything on a budget or an absent child at one sample.
 */
class LinuxRuntimeStartStopReconciliationTest {

    // MARK: 1 — session-less shell.cancel grammar

    @Test fun startedSessionGrammarArmsOnlyForExactLeaseId() {
        assertEquals("session", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-1", requestID = null,
            heldLeaseID = "lease-1", pendingStartID = null))
        // A foreign or mismatched session never arms (unchanged refusal).
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-2", requestID = null,
            heldLeaseID = "lease-1", pendingStartID = "req-9"))
        // With no held lease the started grammar cannot address anything.
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-1", requestID = null,
            heldLeaseID = null, pendingStartID = null))
    }

    @Test fun pendingStartGrammarArmsOnlyForExactInFlightRequestId() {
        // The repair: kernel-paired session-less stop of THIS service's own
        // in-flight start arms the real cancellation gates.
        assertEquals("pendingStart", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "req-1",
            heldLeaseID = null, pendingStartID = "req-1"))
        // Also valid AFTER the lease was acquired but before the session id
        // ever surfaced (the candidate-05 window: held lease, no session).
        assertEquals("pendingStart", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "req-1",
            heldLeaseID = "lease-1", pendingStartID = "req-1"))
        // A foreign request id is refused (target-scoped, never broad).
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "req-2",
            heldLeaseID = null, pendingStartID = "req-1"))
        // Once no start is in flight the session-less shape addresses
        // nothing and must refuse.
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "req-1",
            heldLeaseID = null, pendingStartID = null))
    }

    @Test fun anyOtherCancellationShapeRefuses() {
        // Empty and mixed/extra key sets are exactly the shapes the old
        // strict fields() check refused; they stay refused.
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = emptySet(), sessionID = null, requestID = null,
            heldLeaseID = "lease-1", pendingStartID = "req-1"))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID", "requestID"), sessionID = "lease-1", requestID = "req-1",
            heldLeaseID = "lease-1", pendingStartID = "req-1"))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("leaseID"), sessionID = null, requestID = null,
            heldLeaseID = "lease-1", pendingStartID = "req-1"))
    }

    // MARK: 2 — bounded owned release reconciliation decision

    @Test fun realReleaseAlwaysWinsTheDecision() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.DONE,
            LinuxRuntimeOperations.nextReconcileAction(JobState.RUNNING,
                finished = true, terminalPresent = false, deadlinePassed = true))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.DONE,
            LinuxRuntimeOperations.nextReconcileAction(JobState.TERMINATED,
                finished = true, terminalPresent = true, deadlinePassed = false))
    }

    @Test fun terminatedOrRetainedWithTerminalRetriesTheRealHandBack() {
        // finish() failed at the RETRYABLE authority hand-back: the terminal
        // is real, only the release must be retried.
        assertEquals(LinuxRuntimeOperations.ReconcileAction.RETRY_FINISH,
            LinuxRuntimeOperations.nextReconcileAction(JobState.TERMINATED,
                finished = false, terminalPresent = true, deadlinePassed = false))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.RETRY_FINISH,
            LinuxRuntimeOperations.nextReconcileAction(JobState.LEASE_RETAINED,
                finished = false, terminalPresent = true, deadlinePassed = false))
    }

    @Test fun pendingProofChoosesSettleNeverAFakeRelease() {
        // No delivered terminal: only settleLease (root reap re-poll +
        // whole-runtime-UID census) may produce the proof.
        assertEquals(LinuxRuntimeOperations.ReconcileAction.SETTLE,
            LinuxRuntimeOperations.nextReconcileAction(JobState.LEASE_RETAINED,
                finished = false, terminalPresent = false, deadlinePassed = true))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.SETTLE,
            LinuxRuntimeOperations.nextReconcileAction(JobState.TERMINATED,
                finished = false, terminalPresent = false, deadlinePassed = false))
    }

    @Test fun runningKeepsTheEngineDeadlineEnforced() {
        // A transport-read break must not silently disable the engine
        // deadline; and WAIT before it — never a budgeted release.
        assertEquals(LinuxRuntimeOperations.ReconcileAction.WAIT,
            LinuxRuntimeOperations.nextReconcileAction(JobState.RUNNING,
                finished = false, terminalPresent = false, deadlinePassed = false))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.ENFORCE_DEADLINE,
            LinuxRuntimeOperations.nextReconcileAction(JobState.RUNNING,
                finished = false, terminalPresent = false, deadlinePassed = true))
    }

    @Test fun requestedStopRemainsEnforcedAfterThePumpBreaks() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.REQUEST_STOP,
            LinuxRuntimeOperations.nextReconcileAction(JobState.RUNNING,
                finished = false, terminalPresent = false, deadlinePassed = false,
                stopRequested = true))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.WAIT,
            LinuxRuntimeOperations.nextReconcileAction(JobState.CANCELLING,
                finished = false, terminalPresent = false, deadlinePassed = true,
                stopRequested = true))
    }

    @Test fun cancellingStaysWithTheStopOwner() {
        // CANCELLING already has a real stop in flight on another path; the
        // reconciler waits instead of racing a second transport stop.
        assertEquals(LinuxRuntimeOperations.ReconcileAction.WAIT,
            LinuxRuntimeOperations.nextReconcileAction(JobState.CANCELLING,
                finished = false, terminalPresent = false, deadlinePassed = true))
    }
}
