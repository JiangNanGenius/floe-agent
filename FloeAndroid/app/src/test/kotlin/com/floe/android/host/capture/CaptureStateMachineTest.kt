// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureConfig
import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureFailure
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureOwner
import com.floe.android.core.networkcapture.CapturePhase
import com.floe.android.core.networkcapture.CaptureState
import com.floe.android.core.networkcapture.CaptureStateMachine
import com.floe.android.core.networkcapture.CaptureStats
import com.floe.android.core.networkcapture.CaptureStopProof
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureStateMachineTest {

    private val owner = CaptureOwner(
        ownerId = "test-owner",
        nativeEpoch = 7,
        workspaceId = UUID.randomUUID().toString(),
    )
    private val machine = CaptureStateMachine()
    private val sessionId = UUID.randomUUID().toString()

    private fun running(): CaptureState {
        var state = machine.begin(
            CaptureState(), owner, CaptureMode.VPN, sessionId, "launch", requiresConsent = true,
        )
        state = machine.markStarting(state)
        return machine.markRunning(state, 1_000L)
    }

    @Test
    fun stopIsNotTerminalUntilProofAndDrainAreSupplied() {
        var state = running()
        state = machine.requestStop(state, CaptureEndReason.USER_STOP, 2_000L)
        assertEquals(CapturePhase.STOPPING, state.phase)
        assertTrue(state.stopRequested)
        state = machine.markFinalizing(state)
        val incomplete = CaptureStopProof(
            stopRequested = true,
            forwardersStopped = true,
            dataPlaneThreadStopped = false,
            sinkDrained = false,
            vpnFdClosed = true,
            foregroundServiceStopped = true,
        )
        assertThrows(IllegalArgumentException::class.java) {
            machine.complete(state, null, "raw", CaptureStats(), emptyList(), incomplete, 3_000L)
        }
        val complete = incomplete.copy(dataPlaneThreadStopped = true, sinkDrained = true)
        val done = machine.complete(
            state, UUID.randomUUID().toString(), "raw", CaptureStats(capturedPackets = 4),
            listOf("test"), complete, 3_000L,
        )
        assertEquals(CapturePhase.COMPLETED, done.phase)
        assertEquals(3_000L, done.endedAtMillis)
        assertEquals(4L, done.stats.capturedPackets)
    }

    @Test
    fun cancelBeforeStartNeverPretendsACaptureRan() {
        var state = machine.begin(
            CaptureState(), owner, CaptureMode.VPN, sessionId, "launch", requiresConsent = true,
        )
        state = machine.requestStop(state, CaptureEndReason.USER_CANCELLED, 2_000L)
        assertEquals(CapturePhase.CANCELLED, state.phase)
        assertTrue(state.isTerminal)
        assertTrue(state.stopRequested)
    }

    @Test
    fun countersCannotRegress() {
        val state = running()
        val first = machine.updateStats(state, CaptureStats(capturedPackets = 2, capturedBytes = 40))
        assertThrows(IllegalArgumentException::class.java) {
            machine.updateStats(first, CaptureStats(capturedPackets = 1, capturedBytes = 20))
        }
    }

    @Test
    fun firstStopReasonWins() {
        var state = running()
        state = machine.requestStop(state, CaptureEndReason.USER_STOP, 2_000L)
        state = machine.requestStop(state, CaptureEndReason.VPN_REVOKED, 3_000L)
        assertEquals(CaptureEndReason.USER_STOP, state.endReason)
    }

    @Test
    fun failureAfterTerminalIsIgnored() {
        val state = machine.begin(
            CaptureState(), owner, CaptureMode.VPN, sessionId, "launch", requiresConsent = true,
        )
        val cancelled = machine.requestStop(state, CaptureEndReason.USER_CANCELLED, 1L)
        val failed = machine.fail(cancelled, CaptureFailure("late"), null, atMillis = 2L)
        assertEquals(CapturePhase.CANCELLED, failed.phase)
    }

    @Test
    fun configRejectsOutOfBoundsAndIPv6Routes() {
        assertThrows(IllegalArgumentException::class.java) {
            CaptureConfig(
                owner = owner,
                mode = CaptureMode.VPN,
                detailed = false,
                maxDurationMillis = CaptureLimits.MAX_DURATION_MILLIS + 1,
                maxBytes = CaptureLimits.MAX_BYTES,
                maxPackets = CaptureLimits.MAX_PACKETS,
            )
        }
    }
}
