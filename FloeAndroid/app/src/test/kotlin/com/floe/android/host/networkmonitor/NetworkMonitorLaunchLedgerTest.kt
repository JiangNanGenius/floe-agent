// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import com.floe.android.core.networkmonitor.NetworkMonitorConfig
import com.floe.android.core.networkmonitor.NetworkMonitorOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic interleavings of the pending -> claimed -> active launch
 * lifecycle. No Android, coroutine, Service or engine is involved: this is
 * the exact state machine [NetworkMonitorHost] runs under its single lock.
 */
class NetworkMonitorLaunchLedgerTest {

    private val config = NetworkMonitorConfig()
    private val owner = NetworkMonitorOwner("owner-a")

    private fun reserved(
        ledger: NetworkMonitorLaunchLedger,
        launchId: String = "launch-a",
        sessionId: String = "session-a",
    ): NetworkMonitorLaunchLedger.Launch {
        val result = ledger.reserve(launchId, sessionId, config, owner)
        assertTrue(result is NetworkMonitorLaunchLedger.ReserveResult.Reserved)
        return (result as NetworkMonitorLaunchLedger.ReserveResult.Reserved).launch
    }

    private fun cancelled(result: NetworkMonitorLaunchLedger.CancelResult): NetworkMonitorLaunchLedger.Launch {
        assertTrue(result is NetworkMonitorLaunchLedger.CancelResult.Cancelled)
        return (result as NetworkMonitorLaunchLedger.CancelResult.Cancelled).launch
    }

    @Test
    fun pendingStopInvalidatesTheOpaqueTokenAndPublishesNoActiveSession() {
        val ledger = NetworkMonitorLaunchLedger()
        val launch = reserved(ledger)
        assertEquals(NetworkMonitorLaunchLedger.Phase.PENDING, ledger.current()?.phase)

        val stopped = cancelled(ledger.cancelExact(launch.sessionId))

        assertEquals(launch, stopped)
        assertNull(ledger.current())
        assertNull(ledger.claim(launch.launchId))
        assertFalse(ledger.authorizeEngineStart(launch))
        assertNull(ledger.activeSessionId())
    }

    @Test
    fun wrongSessionIdNeverCancelsThePendingLaunch() {
        val ledger = NetworkMonitorLaunchLedger()
        val launch = reserved(ledger)

        assertSame(
            NetworkMonitorLaunchLedger.CancelResult.None,
            ledger.cancelExact("session-other"),
        )
        assertEquals(launch, ledger.claim(launch.launchId))
    }

    @Test
    fun stopBetweenClaimAndEngineStartRefusesTheStaleStart() {
        val ledger = NetworkMonitorLaunchLedger()
        val launch = reserved(ledger)
        assertEquals(launch, ledger.claim(launch.launchId))
        assertEquals(NetworkMonitorLaunchLedger.Phase.CLAIMED, ledger.current()?.phase)
        assertTrue(ledger.authorizeEngineStart(launch))

        // Exact Stop lands in the foreground/notification window, before the
        // Service reaches engine.start.
        cancelled(ledger.cancelExact(launch.sessionId))

        assertFalse(ledger.authorizeEngineStart(launch))
        assertFalse(ledger.activate(launch))
        assertNull(ledger.activeSessionId())
    }

    @Test
    fun rootRetirementCancelsPendingAndClaimedLaunchesBeforeReturning() {
        val pending = NetworkMonitorLaunchLedger()
        val pendingLaunch = reserved(pending, "launch-pending", "session-pending")
        val pendingRetirement = pending.retire()
        assertEquals(listOf(pendingLaunch), pendingRetirement.cancelled)
        assertNull(pendingRetirement.activeSessionId)
        assertNull(pending.claim(pendingLaunch.launchId))

        val claimed = NetworkMonitorLaunchLedger()
        val claimedLaunch = reserved(claimed, "launch-claimed", "session-claimed")
        assertEquals(claimedLaunch, claimed.claim(claimedLaunch.launchId))
        val claimedRetirement = claimed.retire()
        assertEquals(listOf(claimedLaunch), claimedRetirement.cancelled)
        assertNull(claimedRetirement.activeSessionId)
        assertFalse(claimed.authorizeEngineStart(claimedLaunch))
    }

    @Test
    fun rootRetirementReturnsTheExactActiveSessionForJoin() {
        val ledger = NetworkMonitorLaunchLedger()
        val launch = reserved(ledger)
        ledger.claim(launch.launchId)
        assertTrue(ledger.activate(launch))

        val retirement = ledger.retire()

        assertTrue(retirement.cancelled.isEmpty())
        assertEquals(launch.sessionId, retirement.activeSessionId)
        assertEquals(
            NetworkMonitorLaunchLedger.CancelResult.Active(launch),
            ledger.cancelExact(launch.sessionId),
        )
        // A repeated retirement keeps the same join target instead of
        // dropping it after the first call.
        assertEquals(launch.sessionId, ledger.retire().activeSessionId)
    }

    @Test
    fun activeCancellationIsExactAndCompletionAllowsANewExplicitLaunch() {
        val ledger = NetworkMonitorLaunchLedger()
        val first = reserved(ledger, "launch-1", "session-1")
        ledger.claim(first.launchId)
        ledger.activate(first)

        assertSame(NetworkMonitorLaunchLedger.CancelResult.None, ledger.cancelExact("session-other"))
        assertEquals("session-1", ledger.activeSessionId())
        assertEquals(
            NetworkMonitorLaunchLedger.CancelResult.Active(first),
            ledger.cancelExact("session-1"),
        )
        assertFalse(ledger.completeActive("session-other"))
        assertTrue(ledger.completeActive("session-1"))

        val second = reserved(ledger, "launch-2", "session-2")
        assertTrue(second.generation > first.generation)
        assertNull(ledger.claim(first.launchId))
        assertEquals(second, ledger.claim(second.launchId))
    }

    @Test
    fun staleCancelledGenerationCannotStartAfterANewLaunchIsReserved() {
        val ledger = NetworkMonitorLaunchLedger()
        val stale = reserved(ledger, "launch-old", "session-old")
        ledger.claim(stale.launchId)
        cancelled(ledger.cancelExact(stale.sessionId))

        val current = reserved(ledger, "launch-new", "session-new")
        ledger.claim(current.launchId)

        assertFalse(ledger.authorizeEngineStart(stale))
        assertFalse(ledger.activate(stale))
        assertFalse(ledger.abandon(stale))
        assertTrue(ledger.authorizeEngineStart(current))
        assertTrue(ledger.activate(current))
    }

    @Test
    fun notificationRevocationCancelsOnlyAnUnstartedLaunch() {
        val ledger = NetworkMonitorLaunchLedger()
        val pending = reserved(ledger)
        ledger.claim(pending.launchId)
        assertEquals(pending, ledger.cancelUnstarted())
        assertNull(ledger.current())

        val activeLedger = NetworkMonitorLaunchLedger()
        val active = reserved(activeLedger, "launch-active", "session-active")
        activeLedger.claim(active.launchId)
        activeLedger.activate(active)
        assertNull(activeLedger.cancelUnstarted())
        assertEquals(active.sessionId, activeLedger.activeSessionId())
    }

    @Test
    fun secondReserveReusesThePendingOrClaimedLaunchInsteadOfMintingANewToken() {
        val ledger = NetworkMonitorLaunchLedger()
        val first = reserved(ledger)

        val pendingAgain = ledger.reserve("launch-other", "session-other", config, owner)
        assertTrue(pendingAgain is NetworkMonitorLaunchLedger.ReserveResult.Existing)
        assertEquals(first, (pendingAgain as NetworkMonitorLaunchLedger.ReserveResult.Existing).launch)

        ledger.claim(first.launchId)
        val claimedAgain = ledger.reserve("launch-other", "session-other", config, owner)
        assertTrue(claimedAgain is NetworkMonitorLaunchLedger.ReserveResult.Existing)
        assertEquals(
            NetworkMonitorLaunchLedger.Phase.CLAIMED,
            (claimedAgain as NetworkMonitorLaunchLedger.ReserveResult.Existing).phase,
        )
    }

    @Test
    fun serviceDestructionAbandonsOnlyTheExactClaimedGeneration() {
        val ledger = NetworkMonitorLaunchLedger()
        val first = reserved(ledger, "launch-1", "session-1")
        ledger.claim(first.launchId)

        val foreign = first.copy(launchId = "launch-foreign", generation = first.generation + 1)
        assertFalse(ledger.abandon(foreign))
        assertTrue(ledger.abandon(first))
        assertNull(ledger.claim(first.launchId))
    }
}

/**
 * Root-generation gate used by RuntimeHost. It must stay closed across a
 * repeated drain whose JNI epoch readback became null, then reopen only for a
 * genuinely different live epoch.
 */
class NetworkMonitorLaunchAdmissionTest {

    @Test
    fun retiredEpochIsRefusedUntilADifferentLiveNativeRootEpochExists() {
        val gate = NetworkMonitorLaunchAdmission()
        assertFalse(gate.wasEverArmed())
        assertTrue(gate.isAdmitted(41L))
        gate.arm(41L)
        assertTrue(gate.wasEverArmed())

        assertFalse(gate.isAdmitted(41L))
        assertFalse(gate.isAdmitted(null))
        assertFalse(gate.isAdmitted(0L))
        assertTrue(gate.isArmed())

        assertTrue(gate.isAdmitted(42L))
        assertFalse(gate.isArmed())
        assertTrue(gate.wasEverArmed())
        assertTrue(gate.isAdmitted(42L))
    }

    @Test
    fun repeatedDrainWithNullReadbackDoesNotReopenTheOldGeneration() {
        val gate = NetworkMonitorLaunchAdmission()
        gate.arm(41L)
        gate.arm(null)

        assertFalse(gate.isAdmitted(null))
        assertFalse(gate.isAdmitted(41L))
        assertTrue(gate.isAdmitted(42L))
    }

    @Test
    fun eachNewRetirementRequiresTheNextGeneration() {
        val gate = NetworkMonitorLaunchAdmission()
        gate.arm(41L)
        assertTrue(gate.isAdmitted(42L))

        gate.arm(42L)
        assertFalse(gate.isAdmitted(42L))
        assertTrue(gate.isAdmitted(43L))
    }

    @Test
    fun armingAgainWhileClosedUpdatesTheGenerationBeingRetired() {
        val gate = NetworkMonitorLaunchAdmission()
        gate.arm(41L)
        // The old root was replaced by 42 before this drain began; retiring 42
        // must now require 43, not merely "not 41".
        gate.arm(42L)

        assertFalse(gate.isAdmitted(42L))
        assertTrue(gate.isAdmitted(43L))
    }

    /**
     * End-to-end interleaving at the pure level: a root drain returns only
     * after the pending token is invalidated, and the old generation stays
     * closed so a late Service intent/claim cannot start measurement.
     */
    @Test
    fun rootDrainInvalidatesThePendingTokenAndKeepsTheRetiredEpochClosed() {
        val gate = NetworkMonitorLaunchAdmission()
        val ledger = NetworkMonitorLaunchLedger()
        val config = NetworkMonitorConfig()
        val owner = NetworkMonitorOwner("owner-root")
        val launch = (ledger.reserve("launch-root", "session-root", config, owner) as NetworkMonitorLaunchLedger.ReserveResult.Reserved).launch

        gate.arm(41L)
        val retirement = ledger.retire()

        assertEquals(listOf(launch), retirement.cancelled)
        assertNull(retirement.activeSessionId)
        assertNull(ledger.claim(launch.launchId))
        assertFalse(gate.isAdmitted(41L))
        assertTrue(gate.isAdmitted(42L))
    }
}
