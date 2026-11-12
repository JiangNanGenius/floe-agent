// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.linuxruntime.supervision.JobState
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Author-written (NOT executed by this source stage) post112 FS01/FS12
 * settlement regression: a stop/cancel is only a REQUEST until the runtime
 * proves the real terminal. Local ownership must never be reported settled
 * from a stop request, a timer, an error string or an aggregate counter.
 */
class RuntimeOwnerSettlement113Test {

    private fun action(
        state: JobState,
        finished: Boolean = false,
        terminalPresent: Boolean = false,
        deadlinePassed: Boolean = false,
        stopRequested: Boolean = false,
    ) = LinuxRuntimeOperations.nextReconcileAction(
        state = state, finished = finished, terminalPresent = terminalPresent,
        deadlinePassed = deadlinePassed, stopRequested = stopRequested)

    @Test
    fun stopRequestedRunningOnlyRequestsTheRealStop() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.REQUEST_STOP,
            action(JobState.RUNNING, stopRequested = true))
    }

    @Test
    fun deadlineEnforcesTheRealStopNeverARelease() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.ENFORCE_DEADLINE,
            action(JobState.RUNNING, deadlinePassed = true))
    }

    @Test
    fun cancellingWithoutAProvenTerminalKeepsWaiting() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.WAIT,
            action(JobState.CANCELLING))
    }

    @Test
    fun terminatedWithoutTerminalStillNeedsTheMissingProof() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.SETTLE,
            action(JobState.TERMINATED, terminalPresent = false))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.SETTLE,
            action(JobState.LEASE_RETAINED, terminalPresent = false))
    }

    @Test
    fun onlyARealTerminalAllowsTheDesignedCompletionRetry() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.RETRY_FINISH,
            action(JobState.TERMINATED, terminalPresent = true))
        assertEquals(LinuxRuntimeOperations.ReconcileAction.RETRY_FINISH,
            action(JobState.LEASE_RETAINED, terminalPresent = true))
    }

    @Test
    fun alreadyFinishedIsDoneAndNeverReopened() {
        assertEquals(LinuxRuntimeOperations.ReconcileAction.DONE,
            action(JobState.CANCELLING, finished = true))
    }
}
