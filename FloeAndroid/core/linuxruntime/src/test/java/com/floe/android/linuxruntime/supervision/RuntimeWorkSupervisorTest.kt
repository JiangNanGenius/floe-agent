// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.SpawnOutcome
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Admission invariants of the single-workload supervisor: the slot is reserved
 * before any sweep or spawn, recovery can never sweep a live admitted workload,
 * and the lease authority's only release path is a real whole-UID proof.
 */
class RuntimeWorkSupervisorTest {

    private class Harness(quiescePolicy: QuiescePolicy = QuiescePolicy()) {
        val reader = FakeProcReader()
        val signals = FakeSignals(reader)
        val clock = FakeClock()
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals, clock, quiescePolicy)
        val backend = FakeBackend()
        val supervisor = RuntimeWorkSupervisor(boundary, backend, census, signals, quiescer, clock = clock)
    }

    private val leaseA = LeaseToken("lease-a", "holder-main")

    @Test
    fun simultaneousStartReservesBeforeSweepAndNeverDisturbsTheWinner() {
        val h = Harness()
        val insideSpawn = CountDownLatch(1)
        val releaseSpawn = CountDownLatch(1)
        h.backend.spawnBehaviour = {
            insideSpawn.countDown()
            assertTrue("test must release the spawn", releaseSpawn.await(5, TimeUnit.SECONDS))
            // The winner's child is now live own-UID work.
            h.reader.put(FakeProcEntry(8001, uid = RUNTIME_UID, startTicks = 8181))
            SpawnOutcome.Spawned(fakePty(pid = 8001, ticks = 8181))
        }

        var accepted: StartOutcome? = null
        val worker = Thread { accepted = h.supervisor.start(launchSpec(), leaseA) {} }
        worker.name = "floe-admission-a"
        worker.start()
        assertTrue(insideSpawn.await(5, TimeUnit.SECONDS))

        // A competing admission while the winner holds the reservation.
        val sweepsBefore = h.reader.listCount
        val spawnedBefore = h.backend.spawnCalls
        val raced = h.supervisor.start(launchSpec("task-2"), LeaseToken("lease-b", "holder-main")) {}
        assertTrue("concurrent admission is refused: $raced", raced is StartOutcome.Refused)
        assertTrue(
            (raced as StartOutcome.Refused).reason.contains("admission already in progress"),
        )
        assertEquals("a losing start must not sweep the census", sweepsBefore, h.reader.listCount)
        assertEquals("a losing start must not touch the transport", spawnedBefore, h.backend.spawnCalls)

        releaseSpawn.countDown()
        worker.join(5_000)
        assertTrue("winner accepted: $accepted", accepted is StartOutcome.Accepted)
        assertEquals(1, h.backend.spawnCalls)

        // And while the winner is RUNNING, a later start is refused without a sweep,
        // proving the loser can never kill the winner's processes.
        val sweepsWhileRunning = h.reader.listCount
        val second = h.supervisor.start(launchSpec("task-3"), LeaseToken("lease-c", "holder-main")) {}
        assertTrue(second is StartOutcome.Refused)
        assertTrue((second as StartOutcome.Refused).reason.contains("one workload at a time"))
        assertEquals(h.reader.listCount, sweepsWhileRunning)
        assertTrue("the winner's child was never signalled", h.signals.kills.isEmpty())
        assertTrue(h.reader.entries.containsKey(8001))
        assertTrue("the winner is still the active workload", h.supervisor.activeJob() != null)
    }

    @Test
    fun recoveryRefusesToSweepALiveAdmittedWorkload() {
        val h = Harness()
        h.backend.spawnBehaviour = {
            h.reader.put(FakeProcEntry(8100, uid = RUNTIME_UID, startTicks = 1212))
            SpawnOutcome.Spawned(fakePty(pid = 8100, ticks = 1212))
        }
        val start = h.supervisor.start(launchSpec(), leaseA) {}
        assertTrue(start is StartOutcome.Accepted)
        val sweeps = h.reader.listCount

        val recovery = h.supervisor.recoverBeforeAdmission("operator-mistake")
        assertTrue("recovery must not sweep an admitted workload: $recovery",
            recovery is RecoveryOutcome.Refused)
        assertTrue((recovery as RecoveryOutcome.Refused).reason.contains("one workload at a time"))
        assertEquals("no sweep happened", sweeps, h.reader.listCount)
        assertTrue("the live workload was not signalled", h.signals.kills.isEmpty())
        assertTrue(h.reader.entries.containsKey(8100))
    }

    @Test
    fun recoverySweepsStaleDescendantsBeforeTheFirstAdmission() {
        val h = Harness()
        // Leftovers from a previous service instance that died.
        h.reader.put(FakeProcEntry(8200, uid = RUNTIME_UID, ppid = 1))
        h.reader.put(FakeProcEntry(8201, uid = RUNTIME_UID, ppid = 1))
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8250, ticks = 4242)) }

        val recovery = h.supervisor.recoverBeforeAdmission("service-start")
        assertTrue("$recovery", recovery is RecoveryOutcome.Swept)
        assertTrue((recovery as RecoveryOutcome.Swept).quiescence is Quiescence.Proven)
        assertEquals(listOf(8200, 8201), h.signals.kills.map { it.first }.sorted())
        assertTrue(h.reader.entries.isEmpty())
        // Recovery released its reservation, so admission can proceed afterwards.
        assertTrue(h.supervisor.start(launchSpec(), leaseA) {} is StartOutcome.Accepted)
    }

    @Test
    fun admissionIsNotGrantedOverABusyUid() {
        val h = Harness(QuiescePolicy(maxRounds = 3, settleMs = 1))
        h.reader.put(FakeProcEntry(8300, uid = RUNTIME_UID)) // refuses to die
        h.signals.killResult = { 0 }

        val start = h.supervisor.start(launchSpec(), leaseA) {}
        assertTrue("$start", start is StartOutcome.Refused)
        assertTrue((start as StartOutcome.Refused).reason.startsWith("admission-unproven"))
        assertEquals("never spawn over a busy UID", 0, h.backend.spawnCalls)
    }

    @Test
    fun spawnFailureAbandonsWithoutAQuiescenceClaimAndFreesTheSlot() {
        val h = Harness()
        h.backend.spawnBehaviour = { spawnFailure(13) }
        val terminals = mutableListOf<WorkloadTerminal>()

        val start = h.supervisor.start(launchSpec(), leaseA) { terminals += it }
        assertTrue("$start", start is StartOutcome.Abandoned)
        val terminal = (start as StartOutcome.Abandoned).terminal
        assertTrue(terminal.failure.contains("errno=13"))
        assertNull("no child existed, so no whole-UID proof is claimed", terminal.quiescence)
        assertEquals(1, terminals.size)
        assertTrue(h.signals.kills.isEmpty())
        // The slot was released: a later start can still be admitted.
        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8400, ticks = 999)) }
        assertTrue(h.supervisor.start(launchSpec(), LeaseToken("lease-b", "holder-main")) {}
            is StartOutcome.Accepted)
    }

    @Test
    fun unparsableChildIdentityIsStoppedAndProvenBeforeAbandoning() {
        val h = Harness()
        var broken: FakePty? = null
        h.backend.spawnBehaviour = {
            h.reader.put(FakeProcEntry(8500, uid = RUNTIME_UID, startTicks = 1234))
            FakePty(8500, "8500:0", "/system/bin/sh", listOf("/system/bin/sh"), ownership())
                .also { broken = it }
                .let { SpawnOutcome.Spawned(it) }
        }
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        val terminals = mutableListOf<WorkloadTerminal>()

        val start = h.supervisor.start(launchSpec(), leaseA) { terminals += it }
        assertTrue("an unverifiable child must be stopped and proven, not trusted: $start",
            start is StartOutcome.Abandoned)
        val terminal = (start as StartOutcome.Abandoned).terminal
        assertTrue(terminal.failure.contains("creationIdentity-unparsable"))
        assertTrue(terminal.quiescence is Quiescence.Proven)
        assertEquals(listOf(8500), h.signals.kills.map { it.first })
        assertEquals("the real child was stopped through the transport", 1, broken?.cancelCalls)
        assertEquals(1, terminals.size)
    }

    @Test
    fun boundaryDeniesEverythingWithoutTouchingTheTransport() {
        val h = Harness()
        h.signals.selfPid = 999_999 // proof was made for another process instance

        val start = h.supervisor.start(launchSpec(), leaseA) {}
        assertTrue(start is StartOutcome.Refused)
        assertTrue((start as StartOutcome.Refused).reason.contains("boundary-denied:pid-mismatch"))
        assertEquals(0, h.backend.spawnCalls)
        assertEquals(0, h.reader.listCount)
        assertTrue(h.supervisor.cancelActive(leaseA, "x") is CancelOutcome.Rejected)
        assertTrue(h.supervisor.settleLease(leaseA) is LeaseSettlement.Denied)
    }

    @Test
    fun constructionRefusesTheCredentialUidAndAMismatchedCensus() {
        val reader = FakeProcReader()
        val coreUidSignals = FakeSignals(reader, selfUid = CORE_UID)
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, coreUidSignals)
        val quiescer = RuntimeUidQuiescer(boundary, census, coreUidSignals, FakeClock())
        val failure = assertThrows(IllegalArgumentException::class.java) {
            RuntimeWorkSupervisor(boundary, FakeBackend(), census, coreUidSignals, quiescer)
        }
        assertTrue(failure.message!!.contains("credential"))

        val otherBoundary = acceptedBoundary(runtimeUid = 10777)
        val okSignals = FakeSignals(reader, selfUid = 10777)
        val mismatchedCensus = ProcCensus(boundary, reader, okSignals) // census says RUNTIME_UID
        assertThrows(IllegalArgumentException::class.java) {
            RuntimeWorkSupervisor(otherBoundary, FakeBackend(), mismatchedCensus, okSignals,
                RuntimeUidQuiescer(otherBoundary, mismatchedCensus, okSignals, FakeClock()))
        }
    }

    @Test
    fun releasedLeaseStaysReconcilableAfterTheNextWorkloadStarts() {
        val h = Harness()
        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8600, ticks = 5151)) }
        val first = h.supervisor.start(launchSpec("task-1"), leaseA) {} as StartOutcome.Accepted
        // The root exited, but the guest detached a daemon that outlived it.
        h.reader.put(FakeProcEntry(8611, uid = RUNTIME_UID, ppid = 1, pgid = 8611, sid = 8611))
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        h.backend.spawnSucceededSession().polls.add(ExitResult(0, signaled = false, termSig = 0))

        val pumped = first.job.pump()
        assertTrue("$pumped", pumped is PumpOutcome.Terminated)
        assertEquals(listOf(8611), h.signals.kills.map { it.first })
        assertTrue(h.supervisor.settleLease(leaseA) is LeaseSettlement.Released)

        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8601, ticks = 6161)) }
        val second = h.supervisor.start(launchSpec("task-2"), LeaseToken("lease-b", "holder-main")) {}
        assertTrue("$second", second is StartOutcome.Accepted)

        // The original lease can still be re-read by the authority after replacement.
        val again = h.supervisor.settleLease(leaseA)
        assertTrue("$again", again is LeaseSettlement.Released)
        // An unknown lease is denied, never guessed.
        assertTrue(h.supervisor.settleLease(LeaseToken("lease-zzz", "holder")) is LeaseSettlement.Denied)
        assertTrue(h.supervisor.cancelActive(LeaseToken("lease-zzz", "holder"), "x") is CancelOutcome.Rejected)
    }

    @Test
    fun shutdownStopsTheActiveWorkloadAndRefusesFurtherAdmission() {
        val h = Harness()
        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8700, ticks = 7171)) }
        assertTrue(h.supervisor.start(launchSpec(), leaseA) {} is StartOutcome.Accepted)

        val settlement = h.supervisor.shutdown("service-destroy")
        assertTrue("$settlement", settlement is LeaseSettlement.Released)
        val released = settlement as LeaseSettlement.Released
        assertTrue(released.terminal is WorkloadTerminal.Cancelled)
        assertEquals(1, h.backend.spawnSucceededSession().cancelCalls)

        val after = h.supervisor.start(launchSpec(), LeaseToken("lease-b", "holder-main")) {}
        assertTrue(after is StartOutcome.Refused)
        assertTrue((after as StartOutcome.Refused).reason.contains("shutting down"))
        assertEquals(1, h.backend.spawnCalls)
    }

    @Test
    fun leaseReleaseRequiresTheProofNotMereCancellation() {
        // A short budget proves the point: kill round plus two stable samples is
        // the minimum, and fewer rounds must fail closed instead of guessing.
        val h = Harness(QuiescePolicy(maxRounds = 4, settleMs = 1))
        h.backend.spawnBehaviour = { SpawnOutcome.Spawned(fakePty(pid = 8800, ticks = 8181)) }
        val job = (h.supervisor.start(launchSpec(), leaseA) {} as StartOutcome.Accepted).job
        h.reader.put(FakeProcEntry(8800, uid = RUNTIME_UID, startTicks = 8181)) // unkillable here
        h.signals.killResult = { 0 }

        val cancel = h.supervisor.cancelActive(leaseA, "user-cancel")
        assertTrue("$cancel", cancel is CancelOutcome.Retained)
        val pending = h.supervisor.settleLease(leaseA)
        assertTrue("a cancelled-but-not-quiesced workload keeps the lease",
            pending is LeaseSettlement.Pending)
        pending as LeaseSettlement.Pending
        assertTrue("the root itself was reaped...", pending.rootReapProven)
        assertFalse("...yet the UID is not quiescent, so the lease is still held",
            (pending.quiescence as? Quiescence.Proven) != null)
        assertTrue(h.signals.kills.isNotEmpty())

        // When the leftover finally dies, the same lease reconciles to Released.
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        assertTrue(h.supervisor.settleLease(leaseA) is LeaseSettlement.Released)
        assertEquals(1, job.stateNow.let { if (it == JobState.TERMINATED) 1 else 0 })
    }
}
