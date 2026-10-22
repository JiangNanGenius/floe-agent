// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bounded PTY job lifecycle: EOF is not exit, a wait error is not benign, output
 * is bounded and truthfully paged, and the terminal callback only fires on a
 * whole-runtime-UID proof.
 */
class SupervisedPtyJobTest {

    private class Harness(
        val policy: PtyJobPolicy = PtyJobPolicy(),
        val quiescePolicy: QuiescePolicy = QuiescePolicy(),
    ) {
        val reader = FakeProcReader()
        val signals = FakeSignals(reader)
        val clock = FakeClock()
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals, clock, quiescePolicy)
        val terminals = mutableListOf<WorkloadTerminal>()
        val pty = fakePty()

        fun job(lease: LeaseToken = LeaseToken("lease-1", "holder-1")) = jobFor(
            pty = pty,
            boundary = boundary,
            census = census,
            quiescer = quiescer,
            lease = lease,
            policy = policy,
            clock = clock,
            onTerminal = { terminals += it },
        )
    }

    @Test
    fun pumpUntilIsBoundedByStepsByDeadlineAndByTerminalState() {
        // (a) It returns as soon as the workload is terminal.
        val a = Harness()
        val jobA = a.job()
        a.pty.reads.add(FakePty.ReadStep.Data("x".toByteArray()))
        a.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))
        val terminated = jobA.pumpUntil(deadlineMs = 10_000, maxSteps = 8)
        assertTrue("$terminated", terminated is PumpOutcome.Terminated)
        assertEquals(1, a.terminals.size)

        // (b) A still-running workload stops at the caller's deadline: no invented
        // exit, no callback, lease intact.
        val b = Harness()
        val jobB = b.job()
        b.clock.now = 5_000
        b.pty.reads.add(FakePty.ReadStep.Data("y".toByteArray()))
        b.pty.polls.add(null)
        val blocked = jobB.pumpUntil(deadlineMs = 1_000, maxSteps = 8)
        assertTrue("$blocked", blocked is PumpOutcome.Blocked)
        assertTrue((blocked as PumpOutcome.Blocked).reason.contains("drain deadline"))
        assertEquals(JobState.RUNNING, jobB.stateNow)
        assertTrue(b.terminals.isEmpty())
        assertTrue(jobB.settleLease() is LeaseSettlement.Pending)

        // (c) The step bound is real, and it is refused when out of range.
        val c = Harness()
        val jobC = c.job()
        repeat(100) { c.pty.reads.add(FakePty.ReadStep.Data("z".toByteArray())) }
        repeat(100) { c.pty.polls.add(null) }
        val capped = jobC.pumpUntil(deadlineMs = Long.MAX_VALUE / 2, maxSteps = 3)
        assertTrue("$capped", capped is PumpOutcome.Received)
        assertEquals(3, c.pty.readCapacities.size)
        assertThrows(IllegalArgumentException::class.java) { jobC.pumpUntil(1_000, 0) }
    }

    @Test
    fun eofAloneIsNotAnExitAndFiresNoCallback() {
        val h = Harness()
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.Eof)
        // poll scripted as "still running" (null) deliberately.
        h.pty.polls.add(null)

        val outcome = job.pump()
        assertTrue(outcome is PumpOutcome.Received)
        val received = outcome as PumpOutcome.Received
        assertTrue(received.eof)
        assertEquals(0, received.bytes)
        assertEquals(JobState.RUNNING, job.stateNow)
        assertTrue(h.terminals.isEmpty())
        assertEquals(
            LeaseSettlement.Pending("root workload still running", null, rootReapProven = false),
            job.settleLease(),
        )
    }

    @Test
    fun rootExitIsProvenOverTheWholeUidBeforeAnyCallback() {
        val h = Harness()
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.Data("hello".toByteArray()))
        h.pty.polls.add(ExitResult(23, signaled = false, termSig = 0))

        val outcome = job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.Terminated)
        val terminal = (outcome as PumpOutcome.Terminated).terminal as WorkloadTerminal.Completed
        assertEquals(23, terminal.exit.exitCode)
        assertEquals(2, terminal.quiescence.stableSamples)
        assertEquals(1, h.terminals.size)
        assertEquals(JobState.TERMINATED, job.stateNow)
        assertTrue(job.settleLease() is LeaseSettlement.Released)
        // A second settle is idempotent and still reports the same proof.
        assertTrue(job.settleLease() is LeaseSettlement.Released)
        assertEquals(1, h.terminals.size)
    }

    @Test
    fun leftoverDaemonIsStoppedBeforeTheTerminalCallback() {
        val h = Harness()
        val job = h.job()
        // The guest detached a daemon that outlives the root command.
        h.reader.put(FakeProcEntry(7001, uid = RUNTIME_UID, ppid = 1, pgid = 7001, sid = 7001))
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))

        val outcome = job.pump()
        assertTrue(outcome is PumpOutcome.Terminated)
        assertEquals(listOf(7001), h.signals.kills.map { it.first })
        assertTrue("the daemon must be stopped, not merely reported", h.reader.entries.isEmpty())
        assertEquals(1, h.terminals.size)
    }

    @Test
    fun unprovenQuiescenceHoldsTheLeaseAndSuppressesTheCallbackUntilProof() {
        val h = Harness(quiescePolicy = QuiescePolicy(maxRounds = 4, settleMs = 5))
        val job = h.job()
        h.reader.put(FakeProcEntry(7100, uid = RUNTIME_UID)) // unkillable in the first pass
        h.signals.killResult = { 0 }
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))

        val outcome = job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.QuiescePending)
        assertEquals(JobState.LEASE_RETAINED, job.stateNow)
        assertTrue("no terminal notice without a whole-UID proof", h.terminals.isEmpty())
        val pending = job.settleLease() as LeaseSettlement.Pending
        assertTrue("the root exit was clean; only the UID proof is missing", pending.rootReapProven)
        assertFalse(pending.quiescence is Quiescence.Proven)

        // The owner's service loop retries; the process finally dies.
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }
        val released = job.settleLease()
        assertTrue("$released", released is LeaseSettlement.Released)
        assertEquals(1, h.terminals.size)
        assertTrue(h.terminals.single() is WorkloadTerminal.Completed)
    }

    @Test
    fun rootWaitErrorIsNeverBenignAndNeverReleasesTheLease() {
        val h = Harness()
        val job = h.job()
        h.pty.polls.add(ExitResult(-1, signaled = false, termSig = 0, waitErrno = 10 /* ECHILD */))

        val outcome = job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.Blocked)
        assertEquals(JobState.LEASE_RETAINED, job.stateNow)
        assertTrue(h.terminals.isEmpty())
        val settlement = job.settleLease()
        assertTrue("$settlement", settlement is LeaseSettlement.Pending)
        val pending = settlement as LeaseSettlement.Pending
        assertFalse("ECHILD must not be read as a benign reap", pending.rootReapProven)
        assertTrue(pending.reason.contains("waitErrno=10"))
    }

    @Test
    fun cancelStopsTransportThenProvesTheWholeUid() {
        val h = Harness()
        val job = h.job()
        h.reader.put(FakeProcEntry(7200, uid = RUNTIME_UID))
        h.signals.killResult = { pid -> h.reader.remove(pid); 0 }

        val outcome = job.requestCancel("user-stop")
        assertTrue("$outcome", outcome is CancelOutcome.Terminated)
        val terminal = (outcome as CancelOutcome.Terminated).terminal as WorkloadTerminal.Cancelled
        assertEquals("user-stop", terminal.reason)
        assertEquals(1, h.pty.cancelCalls)
        assertEquals(listOf(7200), h.signals.kills.map { it.first })
        assertEquals(1, h.terminals.size)
        assertTrue(job.settleLease() is LeaseSettlement.Released)
    }

    @Test
    fun cancelIsNotBlockedByTheDrainOwnerRead() {
        val h = Harness()
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.BlockUntilCancelled)

        val pumpStarted = CountDownLatch(1)
        val pumpDone = CountDownLatch(1)
        val pumpThread = Thread {
            pumpStarted.countDown()
            job.pump()
            pumpDone.countDown()
        }
        pumpThread.name = "floe-drain-owner"
        pumpThread.start()
        assertTrue(pumpStarted.await(2, TimeUnit.SECONDS))

        // A different thread stops the workload while the drain read is parked.
        val stopper = CountDownLatch(1)
        var stopResult: CancelOutcome? = null
        val stopThread = Thread {
            stopResult = job.requestCancel("stop-while-reading")
            stopper.countDown()
        }
        stopThread.name = "floe-stop-path"
        stopThread.start()
        assertTrue("stop must not wait on the drain read", stopper.await(2, TimeUnit.SECONDS))
        assertTrue(stopResult is CancelOutcome.Terminated)
        assertTrue(pumpDone.await(3, TimeUnit.SECONDS))
        assertEquals(JobState.TERMINATED, job.stateNow)
        assertEquals(1, h.terminals.size)
    }

    @Test
    fun outputIsBoundedAndPagingReportsTheDroppedGap() {
        val h = Harness(policy = PtyJobPolicy(maxRetainedOutputBytes = 1024, maxReadChunkBytes = 700))
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.Data(ByteArray(700) { (it % 251).toByte() }))
        h.pty.reads.add(FakePty.ReadStep.Data(ByteArray(700) { (it % 251).toByte() }))
        h.pty.polls.add(null)
        h.pty.polls.add(null)

        job.pump()
        job.pump()
        assertEquals(1400L, job.totalProducedBytes)
        assertEquals(1024, job.retainedBytes)
        assertEquals(376L, job.droppedOutputBytes)

        val page = job.output(0, 4096)
        assertEquals(376L, page.gapBytes)
        assertEquals(1024, page.bytes.size)
        assertEquals(1400L, page.nextCursor)
        assertTrue(page.totalDroppedBytes >= 376L)

        // The transport is never asked for more than the read chunk bound.
        assertTrue(h.pty.readCapacities.all { it <= 700 })
    }

    @Test
    fun stdinPartialWritesAreAccountedAndBounded() {
        val h = Harness(policy = PtyJobPolicy(maxStdinWriteRetries = 2, stdinRetryDelayMs = 0))
        val job = h.job()

        h.pty.writes.add(2) // first syscall accepts only 2 of 3 bytes
        val partialThenDone = job.writeStdin(byteArrayOf(1, 2, 3))
        assertTrue("$partialThenDone", partialThenDone is StdinWrite.Complete)
        assertEquals(3, (partialThenDone as StdinWrite.Complete).bytes)
        assertEquals(listOf(3, 1), h.pty.writeCalls)

        h.pty.writes.clear()
        h.pty.writes.add(-9) // EBADF
        val failed = job.writeStdin(byteArrayOf(4, 5))
        assertEquals(StdinWrite.Failed(9, 0), failed)

        h.pty.writes.clear()
        repeat(6) { h.pty.writes.add(0) } // accepts nothing
        val stalled = job.writeStdin(byteArrayOf(6, 7, 8))
        assertTrue("$stalled", stalled is StdinWrite.Partial)
        stalled as StdinWrite.Partial
        assertEquals(0, stalled.bytes)
        assertEquals(3, stalled.requested)
        assertEquals(2, stalled.retries)
    }

    @Test
    fun oversizedStdinChunkIsRefusedRatherThanSplitSilently() {
        val h = Harness(policy = PtyJobPolicy(maxWriteChunkBytes = 16))
        val job = h.job()
        assertThrows(IllegalArgumentException::class.java) {
            job.writeStdin(ByteArray(32))
        }
    }

    @Test
    fun readFailureIsNeitherEofNorExit() {
        val h = Harness()
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.Throw("EIO"))

        val outcome = job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.ReadFailed)
        assertEquals(JobState.RUNNING, job.stateNow)
        assertTrue(h.terminals.isEmpty())
    }

    @Test
    fun drainHasOneOwnerAndHandoffIsExplicit() {
        val h = Harness()
        val job = h.job()
        job.pump() // binds this thread

        var error: Throwable? = null
        val other = Thread { error = runCatching { job.pump() }.exceptionOrNull() }
        other.name = "floe-other"
        other.start()
        other.join(2_000)
        assertTrue("a second drain owner is refused", error is IllegalStateException)

        // Explicit rebinding lets a new service thread take over.
        val taken = CountDownLatch(1)
        val newOwner = Thread {
            job.rebindDrainOwner()
            runCatching { job.pump() }
            taken.countDown()
        }
        newOwner.start()
        assertTrue(taken.await(2, TimeUnit.SECONDS))
        assertNull(job.lastCallbackError())
    }

    @Test
    fun resizeIsRefusedOnceTerminatedAndSummaryCarriesNoOutput() {
        val h = Harness()
        val job = h.job()
        h.pty.reads.add(FakePty.ReadStep.Data("secret-output".toByteArray()))
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))
        job.pump()

        assertTrue(h.pty.resizeCalls >= 0)
        assertFalse(job.resize(40, 120))
        val summary = job.identitySummary()
        assertTrue(summary.contains("lease=lease-1"))
        assertTrue(summary.contains("task=task-1"))
        assertFalse(summary.contains("secret-output"))
    }

    @Test
    fun censusAmbiguityDuringTerminalPhaseHoldsTheLease() {
        val h = Harness(quiescePolicy = QuiescePolicy(maxRounds = 4, settleMs = 1))
        val job = h.job()
        h.reader.put(FakeProcEntry(7300, uid = RUNTIME_UID, statusUnreadable = true))
        h.signals.probeOverrides = mapOf(7300 to ProbeOutcome.Alive)
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))

        val outcome = job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.QuiescePending)
        assertTrue((outcome as PumpOutcome.QuiescePending).failure is Quiescence.Unknown)
        assertTrue(h.signals.kills.isEmpty())
        assertEquals(JobState.LEASE_RETAINED, job.stateNow)
    }

    @Test
    fun unparsableSpawnIdentityIsNotPromotedToAValidBirth() {
        // A failed /proc observation (0 or -1 ticks) must never become a usable identity.
        assertNull(ProcessBirth.fromCreationIdentity("7400:0"))
        assertNull(ProcessBirth.fromCreationIdentity("7400:-1"))
        assertNull(ProcessBirth.fromCreationIdentity("garbage"))
        assertNull(ProcessBirth.fromCreationIdentity("7400"))
        assertEquals(ProcessBirth(7400, 5), ProcessBirth.fromCreationIdentity("7400:5"))
        assertThrows(IllegalArgumentException::class.java) { ProcessBirth(7400, 0) }
        assertThrows(IllegalArgumentException::class.java) { ProcessBirth(0, 5) }
    }
}
