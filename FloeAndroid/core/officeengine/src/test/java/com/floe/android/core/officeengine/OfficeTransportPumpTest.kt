// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM source for the service-owned background transport pump
 * (page-transport85). The pump keeps a READY mount's pinned mobile transport
 * genuinely healthy during ordinary model/approval waits with REAL protocol
 * data (one wsd `ping` → `pong rendercount=` round per interval — the only
 * downlink that resets the page's `lastDataTimestamp`, global.js:1731-1742),
 * and bounds the PAGE side to one pending poll so a hidden/frozen renderer
 * can never accumulate the injection flood that walked the pinned throttle
 * ladder to its cap and armed the fatal 30 s close (the C15 wake kill).
 *
 * Async-identity contract (Main late critical review 2026-10-28): every
 * injection carries a never-reused seq and its heartbeat round id; stale
 * execution/settle callbacks from a superseded injection or a previous
 * view/socket generation are deterministic no-ops — they can never mark a
 * newer round executed, complete it, or clear the newer gate. The one-
 * outstanding-injection bound is never relaxed.
 */
class OfficeTransportPumpTest {

    private val interval = 10_000L
    private var seqCounter = 0L

    private fun pump() = OfficeTransportPump(intervalMs = interval)
    private fun nextSeq() = ++seqCounter

    @Test
    fun firstTickAfterIntervalOpensExactlyOneHeartbeatRound() {
        val pump = pump()
        assertEquals(0L, pump.currentRoundId())
        // Elapsed-realtime semantics: the first tick at/after one interval
        // opens the first round immediately.
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(5_000))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        assertNotEquals(0L, round)
        // Model the Service's immediate HEARTBEAT -> issue wiring; the probe
        // is now outstanding toward a frozen renderer.
        pump.onInjectionIssued(nextSeq(), round)
        // The round is open: no second heartbeat may ever be produced while
        // it is — this is the bound for a frozen renderer.
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(20_000))
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(1_000_000))
        assertTrue(pump.isRoundOpen())
        assertEquals(round, pump.currentRoundId())
    }

    @Test
    fun frozenRendererAccumulatesAtMostOneRoundAndOnePendingPoll() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val seq = nextSeq()
        pump.onInjectionIssued(seq, pump.currentRoundId())
        assertTrue(pump.pollOutstanding())
        // A hidden window of arbitrary length: every tick is idle, the gate
        // stays closed, and no further ping/probe can be produced.
        repeat(100) { tick ->
            assertEquals(
                "tick $tick",
                OfficeTransportPump.TickDecision.IDLE,
                pump.onTick(10_000 + (tick + 1) * interval),
            )
            assertTrue(pump.pollOutstanding())
        }
        // Wake: the queued injection executes; its poll reaches the host —
        // the arrival completes the round and releases the gate.
        pump.onProbeExecuted(seq)
        pump.onPollServed(600_000)
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
        // The next interval opens a fresh round (the pump is self-healing).
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(605_000))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(610_000))
    }

    @Test
    fun preExecutionArrivalFromAnOldXhrCannotReleaseTheFrozenGate() {
        // The pinned page may have up to four XHRs from BEFORE this injection.
        // Their host arrival is not proof that the current queued JavaScript
        // ran; releasing here would reopen the hidden-renderer injection flood.
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        val seq = nextSeq()
        pump.onInjectionIssued(seq, round)
        pump.onPollServed(10_100) // old pre-freeze XHR, current probe NOT executed
        assertTrue(pump.pollOutstanding())
        assertTrue(pump.isRoundOpen())
        assertEquals(round, pump.currentRoundId())
        repeat(20) { tick ->
            assertEquals(
                OfficeTransportPump.TickDecision.IDLE,
                pump.onTick(20_000 + tick * interval),
            )
        }
        // The current injection's own execution makes a later non-failure
        // poll arrival meaningful; only now may the gate/round complete.
        assertTrue(pump.onProbeExecuted(seq))
        pump.onPollServed(300_000)
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
    }

    @Test
    fun staleExecutionCannotReplaceTheCurrentSettleOwner() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val first = nextSeq()
        pump.onInjectionIssued(first, pump.currentRoundId())
        assertTrue(pump.onProbeExecuted(first))
        pump.onPollServed(10_100)
        val current = nextSeq()
        pump.onInjectionIssued(current, 0L)
        // Service uses this Boolean to avoid cancelling/replacing the current
        // settle task when an old evaluateJavascript callback arrives late.
        assertFalse(pump.onProbeExecuted(first))
        pump.onProbeSettled(first, 10_200)
        assertTrue(pump.pollOutstanding())
        assertTrue(pump.onProbeExecuted(current))
        pump.onProbeSettled(current, 10_700)
        assertFalse(pump.pollOutstanding())
    }

    @Test
    fun executedProbeWithoutArrivalSettlesAndUnsticksTheGate() {
        // The pinned doSend() early-returns at `msgInflight >= 4` (frozen
        // in-flight polls not yet drained): the probe EXECUTED but produced
        // no poll, so no arrival will ever come for it. The bounded settle
        // window completes the round and clears the gate — holding it would
        // stall every later delivery.
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        val seq = nextSeq()
        pump.onInjectionIssued(seq, round)
        pump.onProbeExecuted(seq)
        assertTrue(pump.pollOutstanding())
        pump.onProbeSettled(seq, 12_000)
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(22_000))
    }

    @Test
    fun staleCallbacksFromASupersededGenerationMutateNothing() {
        // Main late critical review, required deterministic case 1: an
        // old-view execution callback arriving AFTER reset + a new round
        // must not mark the new round executed, and its settle must not
        // clear the NEW outstanding injection.
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val firstRound = pump.currentRoundId()
        val staleSeq = nextSeq()
        pump.onInjectionIssued(staleSeq, firstRound)
        // View/socket generation change (attach/detach): all bookkeeping of
        // the old generation is dropped.
        pump.reset()
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
        // A new round opens with a NEW identity and its own injection.
        assertTrue(pump.requestRound())
        val newRound = pump.currentRoundId()
        assertNotEquals(firstRound, newRound)
        val newSeq = nextSeq()
        pump.onInjectionIssued(newSeq, newRound)
        // The stale execution + settle arrive late: deterministic no-ops.
        pump.onProbeExecuted(staleSeq)
        pump.onProbeSettled(staleSeq, 11_000)
        assertTrue(pump.pollOutstanding())
        assertTrue(pump.isRoundOpen())
        assertEquals(newRound, pump.currentRoundId())
        // The current injection's own matched lifecycle still works.
        pump.onProbeExecuted(newSeq)
        pump.onProbeSettled(newSeq, 12_000)
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
    }

    @Test
    fun oldSettleAfterNewerExecutionCannotClearTheNewerGate() {
        // Main late critical review, required deterministic case 2: a
        // probeExecuted flag without round/injection identity would let an
        // old settle act on a newer injection. With identity matching: the
        // old settle is a no-op, a settle WITHOUT the matching execution is
        // a no-op, and only the exact injection's own settled execution
        // releases its gate.
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val firstRound = pump.currentRoundId()
        val firstSeq = nextSeq()
        pump.onInjectionIssued(firstSeq, firstRound)
        pump.onProbeExecuted(firstSeq)
        pump.onPollServed(10_400) // arrival completes round 1, clears the gate
        assertFalse(pump.isRoundOpen())
        // A newer injection (ordinary traffic or a drain probe) is issued.
        val newerSeq = nextSeq()
        pump.onInjectionIssued(newerSeq, 0L)
        assertTrue(pump.pollOutstanding())
        // The OLD injection's settle timer fires late: no-op.
        pump.onProbeSettled(firstSeq, 10_900)
        assertTrue(pump.pollOutstanding())
        // A settle for the NEWER injection BEFORE it executed: also a no-op
        // (execution identity is required, not just issuance identity).
        pump.onProbeSettled(newerSeq, 11_000)
        assertTrue(pump.pollOutstanding())
        // Its own matched execution + settle releases exactly it.
        pump.onProbeExecuted(newerSeq)
        pump.onProbeSettled(newerSeq, 11_600)
        assertFalse(pump.pollOutstanding())
    }

    @Test
    fun nonRoundInjectionSettleNeverCompletesAnOpenRound() {
        // A drain/ordinary injection (roundId 0) that executed without an
        // arrival releases ONLY its own gate; an open heartbeat round whose
        // own probe was gated (never issued) stays open until a real
        // arrival — its pong delivery has not happened yet.
        val pump = pump()
        val ordinarySeq = nextSeq()
        pump.onInjectionIssued(ordinarySeq, 0L) // ordinary triggerSend injection
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        assertNotEquals(0L, round)
        // The round's probe is gated (ordinary injection outstanding) → not
        // issued. The ordinary injection executes and settles:
        pump.onProbeExecuted(ordinarySeq)
        pump.onProbeSettled(ordinarySeq, 10_600)
        assertFalse(pump.pollOutstanding())
        assertTrue(pump.isRoundOpen()) // round untouched by a foreign settle
        assertEquals(round, pump.currentRoundId())
        // The next tick must arm the ALREADY-PINGED round's missing probe,
        // without another ping; otherwise the open round would wedge forever.
        assertEquals(OfficeTransportPump.TickDecision.PROBE, pump.onTick(10_700))
        val roundSeq = nextSeq()
        pump.onInjectionIssued(roundSeq, round)
        assertTrue(pump.onProbeExecuted(roundSeq))
        pump.onPollServed(11_000)
        assertFalse(pump.isRoundOpen())
    }

    @Test
    fun arrivalCompletesRoundAndLaterSettleIsNoop() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        val seq = nextSeq()
        pump.onInjectionIssued(seq, round)
        pump.onProbeExecuted(seq)
        pump.onPollServed(10_500) // real delivery (the waiting pong)
        assertFalse(pump.isRoundOpen())
        // The settle timer still fires later: it must not clear a gate that
        // ordinary traffic has legitimately re-armed in the meantime.
        val ordinarySeq = nextSeq()
        pump.onInjectionIssued(ordinarySeq, 0L)
        pump.onProbeSettled(seq, 12_000)
        assertTrue(pump.pollOutstanding())
        // Interval is measured from the ARRIVAL completion.
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(20_000))
        // A stale settle can never complete a NEWER round either.
        pump.onPollServed(20_400)
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(20_500))
        pump.onProbeSettled(seq, 21_000)
        assertTrue(pump.isRoundOpen())
    }

    @Test
    fun ordinaryTrafficArrivalAlsoCompletesAnOpenRound() {
        // Any served poll is delivery evidence: when heavy ordinary traffic
        // serves the queued pong before the round's own probe does, the
        // round still completes (its purpose — real data to the page — was
        // fulfilled), so pings stay bounded to one per interval.
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val ordinarySeq = nextSeq()
        pump.onInjectionIssued(ordinarySeq, 0L)
        assertTrue(pump.onProbeExecuted(ordinarySeq))
        pump.onPollServed(10_100) // ordinary-traffic poll served the batch
        assertFalse(pump.isRoundOpen())
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(15_000))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(20_100))
    }

    @Test
    fun issueFailureIsIdentityMatchedAndLeavesNoPhantomPendingPoll() {
        val pump = pump()
        val seq = nextSeq()
        pump.onInjectionIssued(seq, 0L)
        // A failure report for a DIFFERENT identity clears nothing.
        pump.onInjectionIssueFailed(nextSeq(), 1_000)
        assertTrue(pump.pollOutstanding())
        pump.onInjectionIssueFailed(seq, 1_000)
        assertFalse(pump.pollOutstanding())
        // Redundant reports can never drive the bookkeeping negative.
        pump.onInjectionIssueFailed(seq, 1_000)
        pump.onPollServed(1_000)
        assertFalse(pump.pollOutstanding())
    }

    @Test
    fun heartbeatIssueFailureRetriesOnALaterIntervalWithoutWedgingRound() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val round = pump.currentRoundId()
        val seq = nextSeq()
        pump.onInjectionIssued(seq, round)
        pump.onInjectionIssueFailed(seq, 10_100)
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(20_099))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(20_100))
        assertNotEquals(round, pump.currentRoundId())
    }

    @Test
    fun resetDropsViewOwnedBookkeepingAndAllowsImmediateRound() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        pump.onInjectionIssued(nextSeq(), pump.currentRoundId())
        // View/socket change: injections queued toward the OLD view can
        // never arrive; the fresh MobileSocket has a fresh serial space.
        pump.reset()
        assertFalse(pump.pollOutstanding())
        assertFalse(pump.isRoundOpen())
        assertEquals(0L, pump.currentRoundId())
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_500))
    }

    @Test
    fun stopIsTerminalAndResetDoesNotUnstop() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        pump.stop()
        assertTrue(pump.isStopped())
        assertFalse(pump.isRoundOpen())
        assertFalse(pump.pollOutstanding())
        repeat(10) { tick ->
            assertEquals(
                OfficeTransportPump.TickDecision.IDLE,
                pump.onTick(20_000 + tick * interval),
            )
        }
        pump.reset()
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(500_000))
    }

    @Test
    fun intervalBoundaryIsStrict() {
        val pump = pump()
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(10_000))
        val seq = nextSeq()
        pump.onInjectionIssued(seq, pump.currentRoundId())
        assertTrue(pump.onProbeExecuted(seq))
        pump.onPollServed(10_001) // completes at 10_001
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(20_000))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(20_001))
    }

    @Test
    fun onDemandRoundRespectsTheSingleRoundBound() {
        // The drain's retry path may request an immediate heartbeat (stale
        // real data on an open transport): at most ONE round can be open,
        // so a drain can never stack pings or probes either.
        val pump = pump()
        assertTrue(pump.requestRound())
        val round = pump.currentRoundId()
        assertFalse(pump.requestRound())
        assertEquals(round, pump.currentRoundId())
        // Before the first probe is registered, the pump offers its bounded
        // missing-probe recovery (Service/drain issues it without a new ping).
        assertEquals(OfficeTransportPump.TickDecision.PROBE, pump.onTick(100_000))
        val seq = nextSeq()
        pump.onInjectionIssued(seq, round)
        assertTrue(pump.onProbeExecuted(seq))
        pump.onPollServed(100_100) // delivery completes the on-demand round
        assertFalse(pump.isRoundOpen())
        // requestRound ignores the interval gate by design (drain retry path).
        assertTrue(pump.requestRound())
        // A settle with no probe ever executed never completes the round
        // (identity + execution guards).
        pump.onProbeSettled(seq, 100_200)
        assertTrue(pump.isRoundOpen())
        // Interval timing resumes from the eventual completion.
        val secondSeq = nextSeq()
        pump.onInjectionIssued(secondSeq, pump.currentRoundId())
        assertTrue(pump.onProbeExecuted(secondSeq))
        pump.onPollServed(100_300)
        assertFalse(pump.isRoundOpen())
        assertEquals(OfficeTransportPump.TickDecision.IDLE, pump.onTick(105_000))
        assertEquals(OfficeTransportPump.TickDecision.HEARTBEAT, pump.onTick(110_300))
    }

    @Test
    fun stoppedPumpRefusesOnDemandRounds() {
        val pump = pump()
        pump.stop()
        assertFalse(pump.requestRound())
        assertFalse(pump.isRoundOpen())
        assertEquals(0L, pump.currentRoundId())
    }

    @Test
    fun constantsStayInsideThePinnedWatchdogBudget() {
        // The whole safety argument rests on these bounds: two worst-case
        // heartbeat rounds (one served empty just before the pong is
        // queued) must still deliver real data strictly inside the pinned
        // 30 s no-response window, and the heartbeat must be more frequent
        // than the 15 s admission freshness window so an ordinary wait
        // re-witnesses through real handshake instead of a stale fact.
        assertEquals(10_000L, OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS)
        assertTrue(OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS * 2 < 30_000L)
        assertTrue(
            OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS <
                OfficePageEditModeWitness.DEFAULT_FRESH_WINDOW_MS,
        )
        assertEquals(500L, OfficeTransportPump.PROBE_SETTLE_MS)
        assertTrue(
            OfficeTransportPump.PROBE_SETTLE_MS <
                OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS,
        )
    }
}
