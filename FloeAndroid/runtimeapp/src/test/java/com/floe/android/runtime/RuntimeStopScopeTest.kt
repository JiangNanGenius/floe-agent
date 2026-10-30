// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * AUTHORED NOT RUN execution-time stop-scope regressions.
 *
 * Pins the bounded fix for the actual order `A PUMP_STOP_SESSION ->
 * A OPS_FINISH_RETURNED -> B PUMP_STOP_SESSION`:
 *
 *  * a cancellation validated while A was live may execute AFTER A settled;
 *    that target is then a NO-OP, never the old `heldLeases.values` broad
 *    cancel that marked B;
 *  * two distinct target stops resolve independently (the bounded stop lane
 *    delivers both);
 *  * only a null/global request resolves to ALL, and global cancellation is
 *    the sole path that may address every held lease.
 */
class RuntimeStopScopeTest {

    private fun resolve(
        operation: String?,
        keys: Set<String> = emptySet(),
        requestID: String? = null,
        sessionID: String? = null,
        installID: String? = null,
        preflightID: String? = null,
        held: Collection<String> = emptyList(),
        pending: Collection<String> = emptyList(),
        running: Collection<String> = emptyList(),
    ) = LinuxRuntimeOperations.resolveStop(
        operation = operation, keys = keys, requestID = requestID,
        sessionID = sessionID, installID = installID, preflightID = preflightID,
        heldLeaseIDs = held, pendingStartIDs = pending, runningStartIDs = running,
    )

    private fun assertScope(expected: LinuxRuntimeOperations.StopTarget, id: String? = null,
                            actual: LinuxRuntimeOperations.StopResolution) {
        assertEquals(expected, actual.target)
        assertEquals(id, actual.id)
    }

    @Test
    fun settledSessionTargetIsNoOpNeverBroadCancel() {
        // A was valid at admission; by execution it is gone while B is held.
        // The old receiver fell through to heldLeases.values and cancelled B.
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("shell.cancel", keys = setOf("sessionID"),
                sessionID = "session-A", held = setOf("session-B"),
                running = setOf("start-B")))
    }

    @Test
    fun liveSessionTargetResolvesExactlyThatSession() {
        assertScope(LinuxRuntimeOperations.StopTarget.SESSION, "session-A",
            resolve("shell.cancel", keys = setOf("sessionID"),
                sessionID = "session-A", held = setOf("session-A", "session-B")))
    }

    @Test
    fun twoDistinctLiveTargetsResolveIndependently() {
        // The same two live leases must produce two exact scopes; neither
        // resolves to ALL and neither depends on the other's settlement.
        assertScope(LinuxRuntimeOperations.StopTarget.SESSION, "session-A",
            resolve("shell.cancel", keys = setOf("sessionID"),
                sessionID = "session-A", held = setOf("session-A", "session-B")))
        assertScope(LinuxRuntimeOperations.StopTarget.SESSION, "session-B",
            resolve("shell.cancel", keys = setOf("sessionID"),
                sessionID = "session-B", held = setOf("session-A", "session-B")))
    }

    @Test
    fun pendingStartResolvesOnlyItsExactRequestId() {
        assertScope(LinuxRuntimeOperations.StopTarget.PENDING_START, "start-A",
            resolve("shell.cancel", keys = setOf("requestID"),
                requestID = "start-A", pending = setOf("start-A", "start-B")))
        // A foreign or settled start id is a no-op, never a broad cancel.
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("shell.cancel", keys = setOf("requestID"),
                requestID = "start-foreign", pending = setOf("start-A")))
    }

    @Test
    fun publishedRunningStartIdStillResolvesExactly() {
        // The foreground-permit lane addresses the admitted shell.start id
        // even after the start reply published the Running and removed the
        // pending map entry.
        assertScope(LinuxRuntimeOperations.StopTarget.PENDING_START, "start-A",
            resolve("shell.cancel", keys = setOf("requestID"),
                requestID = "start-A", running = setOf("start-A")))
    }

    @Test
    fun repeatedStaleTargetAfterSettlementIsNoOp() {
        // A second delivery of A's stop (queued lane / periodic permit
        // inspection) must not acquire B just because A is absent now.
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("shell.cancel", keys = setOf("sessionID"),
                sessionID = "session-A", held = setOf("session-B")))
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("shell.cancel", keys = setOf("requestID"),
                requestID = "start-A", running = setOf("start-B")))
    }

    @Test
    fun installCancellationIsExactAndAbsentOwnerIsNoOp() {
        assertScope(LinuxRuntimeOperations.StopTarget.INSTALL, "install-1",
            resolve("install.cancel", keys = setOf("requestID"),
                requestID = "install-1", installID = "install-1"))
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("install.cancel", keys = setOf("requestID"),
                requestID = "install-old", installID = "install-new"))
        // A settled/queued install owner is handled by the kernel's target
        // admission, never by cancelling unrelated held leases here.
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("install.cancel", keys = setOf("requestID"),
                requestID = "install-old", held = setOf("session-B")))
    }

    @Test
    fun preflightCancellationIsExactAndAbsentOwnerIsNoOp() {
        assertScope(LinuxRuntimeOperations.StopTarget.PREFLIGHT, "preflight-1",
            resolve("workspace.preflight.cancel", keys = setOf("requestID"),
                requestID = "preflight-1", preflightID = "preflight-1"))
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("workspace.preflight.cancel", keys = setOf("requestID"),
                requestID = "preflight-old", preflightID = "preflight-new"))
    }

    @Test
    fun mixedUnknownAndEmptyShapesAreNoOp() {
        for (keys in listOf(setOf("sessionID", "requestID"), setOf("leaseID"), emptySet<String>())) {
            assertScope(LinuxRuntimeOperations.StopTarget.NONE,
                actual = resolve("shell.cancel", keys = keys,
                    sessionID = "session-A", requestID = "start-A",
                    held = setOf("session-A"), pending = setOf("start-A")))
        }
    }

    @Test
    fun onlyTheSessionlessGlobalRequestResolvesToAll() {
        assertScope(LinuxRuntimeOperations.StopTarget.ALL, actual = resolve(operation = null))
        assertScope(LinuxRuntimeOperations.StopTarget.NONE,
            actual = resolve("status"))
    }
}
