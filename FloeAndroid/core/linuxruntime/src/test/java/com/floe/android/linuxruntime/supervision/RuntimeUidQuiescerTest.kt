// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whole-runtime-UID quiescence. The core claim under test: root exit alone is
 * never enough, and anything the census cannot resolve becomes an explicit
 * Retained/Unknown failure instead of a success.
 */
class RuntimeUidQuiescerTest {

    private class Harness(policy: QuiescePolicy = QuiescePolicy()) {
        val reader = FakeProcReader()
        val signals = FakeSignals(reader)
        val clock = FakeClock()
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals, clock, policy)
    }

    @Test
    fun cleanCensusStillRequiresConsecutiveStableSamples() {
        val h = Harness()
        val proof = h.quiescer.quiesce("pre-admission")

        assertTrue(proof is Quiescence.Proven)
        val proven = proof as Quiescence.Proven
        assertEquals(2, proven.stableSamples)
        assertEquals(2, proven.rounds)
        assertEquals(1, h.clock.sleeps.size) // one settle between the two samples
    }

    @Test
    fun oneCleanSampleIsNotEnoughWhenADetachedDescendantAppearsLate() {
        val h = Harness()
        h.reader.put(FakeProcEntry(5100, uid = RUNTIME_UID, ppid = 5099))
        // A detached setsid grandchild surfaces one sweep after the root looked clean.
        h.reader.onList = { count ->
            when (count) {
                // Round 2 looks clean; the detached grandchild only shows up in round 3.
                3 -> h.reader.put(
                    FakeProcEntry(5101, uid = RUNTIME_UID, ppid = 1, pgid = 5101, sid = 5101),
                )
            }
        }
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }

        val proof = h.quiescer.quiesce("workload-exit")
        assertTrue("late descendant must be caught, not declared idle", proof is Quiescence.Proven)
        val proven = proof as Quiescence.Proven
        assertEquals(5, proven.rounds)
        assertEquals(listOf(5100, 5101), proven.kills.map { it.birth.pid })
        assertEquals(2, proven.stableSamples)
    }

    @Test
    fun everySignalIsVerifiedByUidAndBirthAndUsesOnlyPositivePids() {
        val h = Harness()
        h.reader.put(FakeProcEntry(5200, uid = RUNTIME_UID, startTicks = 4242))
        h.reader.put(FakeProcEntry(5201, uid = CORE_UID))
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }

        val proof = h.quiescer.quiesce("cancel:test")
        assertTrue(proof is Quiescence.Proven)
        val proven = proof as Quiescence.Proven
        assertEquals(listOf(5200), proven.kills.map { it.birth.pid })
        assertEquals(listOf(4242L), proven.kills.map { it.birth.startTimeTicks })
        // Only SIGKILL to individual positive pids: no group, no name-based kill.
        assertTrue(h.signals.kills.all { (pid, sig) -> pid > 0 && sig == PosixSignals.SIGKILL })
    }

    @Test
    fun pidReusedByAnotherUidIsNeverSignalled() {
        val h = Harness()
        val reused = h.reader.put(FakeProcEntry(5300, uid = RUNTIME_UID, startTicks = 1234))
        h.signals.beforeUidOf = { pid ->
            if (pid == 5300) {
                // Between the sweep and the signal the process died and its pid was
                // recycled to a different UID's process.
                reused.uid = CORE_UID
                reused.startTicks = 999_999
            }
        }

        val proof = h.quiescer.quiesce("cancel:test")
        assertTrue("the recycled pid belongs to someone else; next sweep sees it as foreign",
            proof is Quiescence.Proven)
        assertTrue("no signal may be delivered to a reused pid", h.signals.kills.isEmpty())
        assertEquals("uid-changed:$CORE_UID", proof.kills.single().skipped)
    }

    @Test
    fun changedBirthIsReverifiedInsteadOfTrustingTheStaleRecord() {
        val h = Harness()
        val recycled = h.reader.put(FakeProcEntry(5400, uid = RUNTIME_UID, startTicks = 2222))
        var once = false
        // Right before the first signal the pid is recycled to a *new* own-UID
        // process: the stale record must not be used, and only a freshly
        // verified birth may ever be signalled.
        h.signals.beforeUidOf = { pid ->
            if (pid == 5400 && !once) {
                once = true
                recycled.startTicks = 777
            }
        }
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }

        val proof = h.quiescer.quiesce("cancel:test")
        assertTrue(proof is Quiescence.Proven)
        val records = proof.kills
        assertEquals(listOf("birth-changed"), records.mapNotNull { it.skipped })
        val delivered = records.filter { it.delivered }
        assertEquals(1, delivered.size)
        assertEquals(777L, delivered.single().birth.startTimeTicks)
        assertEquals(5400, h.signals.kills.single().first)
    }

    @Test
    fun unkillableOwnWorkIsRetainedNotSuccess() {
        val h = Harness(QuiescePolicy(maxRounds = 3, stableSamplesRequired = 2, settleMs = 10))
        h.reader.put(FakeProcEntry(5500, uid = RUNTIME_UID))
        h.signals.killResult = { 0 } // reports success but the process stays (hostile/unkillable)

        val proof = h.quiescer.quiesce("pre-admission")
        assertTrue(proof is Quiescence.Retained)
        val retained = proof as Quiescence.Retained
        assertEquals(3, retained.rounds)
        assertEquals(listOf(5500), retained.live.map { it.pid })
        assertEquals(3, retained.kills.size)
        assertFalse(retained.proven)
    }

    @Test
    fun failedInventoryIsUnknownAndNotClean() {
        val h = Harness()
        h.reader.listFailure = "proc-listing-EACCES"
        val proof = h.quiescer.quiesce("pre-admission")
        assertTrue(proof is Quiescence.Unknown)
        val unknown = proof as Quiescence.Unknown
        assertTrue(unknown.failure.startsWith("inventory-failed:proc-listing-EACCES"))
        assertTrue(h.signals.kills.isEmpty())
    }

    @Test
    fun ambiguousOwnCandidateIsUnknownAndNeverKilledBlindly() {
        val h = Harness()
        h.reader.put(FakeProcEntry(5600, uid = RUNTIME_UID, statusUnreadable = true))
        h.signals.probeOverrides = mapOf(5600 to ProbeOutcome.Alive)

        val proof = h.quiescer.quiesce("workload-exit")
        assertTrue(proof is Quiescence.Unknown)
        assertTrue((proof as Quiescence.Unknown).failure.contains("ambiguous-candidates:5600"))
        assertTrue("an unidentifiable candidate must not be signalled", h.signals.kills.isEmpty())
    }

    @Test
    fun unreapedOwnChildZombieIsRetained() {
        val h = Harness()
        h.reader.put(FakeProcEntry(5700, uid = RUNTIME_UID, state = 'Z', ppid = SERVICE_PID))

        val proof = h.quiescer.quiesce("workload-exit")
        assertTrue("this service must reap its own child before claiming quiescence",
            proof is Quiescence.Retained)
        assertEquals(listOf(5700), (proof as Quiescence.Retained).unreapedOwnChildren.map { it.pid })
    }

    @Test
    fun zombieReapedByAnotherParentIsRecordedAndDoesNotBlock() {
        val h = Harness()
        // A zombie has no writable execution; its parent (here init) reaps it.
        h.reader.put(FakeProcEntry(5800, uid = RUNTIME_UID, state = 'Z', ppid = 1))

        val proof = h.quiescer.quiesce("workload-exit")
        assertTrue(proof is Quiescence.Proven)
        assertEquals(listOf(5800), (proof as Quiescence.Proven).observedZombies.map { it.pid })
    }

    @Test
    fun killFanOutPerRoundIsBounded() {
        val h = Harness(QuiescePolicy(maxRounds = 2, maxKillsPerRound = 4, settleMs = 5))
        for (pid in 6000..6299) h.reader.put(FakeProcEntry(pid, uid = RUNTIME_UID))
        h.signals.killResult = { 0 } // nothing actually dies

        val proof = h.quiescer.quiesce("pre-admission")
        assertTrue(proof is Quiescence.Retained)
        assertTrue("a hostile fan-out cannot spin the supervisor", proof.kills.size <= 8)
    }
}
