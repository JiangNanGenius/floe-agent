// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.runtimeipc.ShellStopReason
import org.junit.Assert.*
import org.junit.Test

class RuntimeTimeoutStopReasonTest {
    private fun resolve(
        keys: Set<String> = setOf("sessionID", "stopReason"),
        reason: String? = "timeout",
        session: String? = "A",
        request: String? = null,
        held: Collection<String> = listOf("A", "B"),
        live: Collection<String> = listOf("A", "B"),
    ) = LinuxRuntimeOperations.resolveStop(
        operation = "shell.cancel", keys = keys, requestID = request, sessionID = session,
        installID = null, preflightID = null, heldLeaseIDs = held,
        pendingStartIDs = listOf("start-A"), runningStartIDs = listOf("start-B"),
        stopReason = reason, runningSessionIDs = live,
    )

    @Test fun deadlineResolvesOnlyItsLiveSessionAndRetainsItsCause() {
        val actual = resolve()
        assertEquals(LinuxRuntimeOperations.StopTarget.SESSION, actual.target)
        assertEquals("A", actual.id)
        assertEquals(ShellStopReason.TIMEOUT, actual.reason)
    }

    @Test fun legacyUserStopShapeStaysSupported() {
        val actual = resolve(keys = setOf("sessionID"), reason = null)
        assertEquals(LinuxRuntimeOperations.StopTarget.SESSION, actual.target)
        assertEquals(ShellStopReason.USER_STOP, actual.reason)
    }

    @Test fun settledOrPreSpawnDeadlineCannotStopAnotherHeldSession() {
        assertEquals(LinuxRuntimeOperations.StopTarget.NONE, resolve(held = listOf("B")).target)
        assertEquals(LinuxRuntimeOperations.StopTarget.NONE, resolve(live = listOf("B")).target)
    }

    @Test fun unknownOrMissingReasonsAreRefused() {
        for (bad in listOf(null, "", "all", "cancelled", "TIMEOUT")) {
            assertEquals(LinuxRuntimeOperations.StopTarget.NONE, resolve(reason = bad).target)
        }
    }

    @Test fun mixedTargetsAndPendingStartDeadlineAreRefused() {
        assertEquals(LinuxRuntimeOperations.StopTarget.NONE,
            resolve(keys = setOf("sessionID", "requestID", "stopReason"), request = "start-A").target)
        assertEquals(LinuxRuntimeOperations.StopTarget.NONE,
            resolve(keys = setOf("requestID", "stopReason"), request = "start-A", session = null).target)
        assertEquals(LinuxRuntimeOperations.StopTarget.NONE,
            resolve(keys = setOf("sessionID", "stopReason", "extra")).target)
    }

    @Test fun admissionAndExecutionAgreeOnDeadlineGrammar() {
        assertEquals("session", LinuxRuntimeOperations.shellCancelScope(
            setOf("sessionID", "stopReason"), "A", null, listOf("A"), emptyList(),
            stopReason = "timeout", runningSessionIDs = listOf("A")))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            setOf("sessionID", "stopReason"), "A", null, listOf("A"), emptyList(),
            stopReason = "timeout", runningSessionIDs = emptyList()))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            setOf("sessionID", "stopReason"), "A", null, listOf("A"), emptyList(),
            stopReason = "foreign", runningSessionIDs = listOf("A")))
    }
}
