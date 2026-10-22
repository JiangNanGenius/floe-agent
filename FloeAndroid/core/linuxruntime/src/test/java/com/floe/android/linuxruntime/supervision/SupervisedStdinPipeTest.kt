// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.StdinDelivery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One-shot stdin descriptor-EOF regressions: nil/empty/nonempty stdin reach a
 * REAL EOF exactly after the supplied bytes (closing the owned write end),
 * EOF is distinct from process exit and from output drain, short/EAGAIN/EPIPE
 * writes stay bounded and honestly accounted, a cancelled or exited session
 * releases the writer descriptor so no background write can survive a falsely
 * released session, and PTY-delivery input semantics are unchanged.
 *
 * Honesty limit: these JVM fixtures drive scripted DESCRIPTOR ACCOUNTING over
 * the session seam. They prove no kernel-pipe timing, no PRoot fd inheritance
 * and no device EOF; the real native/device checks (read-to-EOF programs on
 * nil/empty/nonempty stdin through the actual pipe + PTY output path) are
 * Main's integrated batch verification.
 */
class SupervisedStdinPipeTest {

    /** One-shot pipe job wired the way RuntimeWorkSupervisor would. */
    private class Pipe(policy: PtyJobPolicy = PtyJobPolicy()) {
        val reader = FakeProcReader()
        val signals = FakeSignals(reader)
        val clock = FakeClock()
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals, clock)
        val terminals = mutableListOf<WorkloadTerminal>()
        val pty = fakePty(stdinDelivery = StdinDelivery.OneShotPipe)
        val job = jobFor(
            pty = pty,
            boundary = boundary,
            census = census,
            quiescer = quiescer,
            spec = launchSpec(stdinDelivery = StdinDelivery.OneShotPipe),
            policy = policy,
            clock = clock,
            onTerminal = { terminals += it },
        )
    }

    /** PTY-delivery job for the unchanged-input contrast cases. */
    private class PtyJob(policy: PtyJobPolicy = PtyJobPolicy()) {
        val reader = FakeProcReader()
        val signals = FakeSignals(reader)
        val clock = FakeClock()
        val boundary = acceptedBoundary()
        val census = ProcCensus(boundary, reader, signals)
        val quiescer = RuntimeUidQuiescer(boundary, census, signals, clock)
        val pty = fakePty()
        val job = jobFor(
            pty = pty,
            boundary = boundary,
            census = census,
            quiescer = quiescer,
            policy = policy,
            clock = clock,
            onTerminal = {},
        )
    }

    @Test
    fun nilStdinEmptyCloseDeliversEofAndIsNotAnExit() {
        val h = Pipe()
        // A zero-byte writeStdin is NOT an EOF: only the explicit EOF command
        // closes the descriptor (EOT-byte emulation stays impossible).
        val emptyWrite = h.job.writeStdin(byteArrayOf())
        assertTrue("$emptyWrite", emptyWrite is StdinWrite.Complete)
        assertEquals(0, h.pty.stdinPipeCloseCalls)
        assertFalse(h.job.stdinStatus().eofDelivered)

        val eof = h.job.requestStdinEof()
        assertTrue("$eof", eof is StdinEof.Closed)
        eof as StdinEof.Closed
        assertEquals(0, eof.acceptedBytesBeforeClose)
        assertFalse(eof.idempotent)
        assertTrue(h.pty.stdinPipeCloseCalls == 1 && !h.pty.stdinPipeOpen)
        // No PTY traffic at all: no EOT byte, no master write, and the shared
        // master is never closed to fake an EOF.
        assertTrue(h.pty.writeCalls.isEmpty())
        assertEquals(0, h.pty.closeMasterCalls)

        // EOF != exit: the child may keep running and streaming output.
        h.pty.reads.add(FakePty.ReadStep.Data("still-running".toByteArray()))
        h.pty.polls.add(null)
        val pumped = h.job.pump()
        assertTrue("$pumped", pumped is PumpOutcome.Received)
        assertEquals(JobState.RUNNING, h.job.stateNow)
        assertTrue(h.job.settleLease() is LeaseSettlement.Pending)
        assertTrue(h.terminals.isEmpty())
    }

    @Test
    fun nonemptyStdinKeepsDataFidelityIncludingEotBytes() {
        val h = Pipe()
        // EOT (0x04) is ordinary DATA on a pipe: exactly the bytes the caller
        // supplied must arrive, in order, with no special meaning.
        val payload = "hello\n".toByteArray() + byteArrayOf(4, 4)
        val write = h.job.writeStdin(payload)
        assertTrue("$write", write is StdinWrite.Complete)
        assertEquals(payload.size, (write as StdinWrite.Complete).bytes)
        assertEquals(1, h.pty.stdinPipeWrites.size)
        assertTrue(payload.contentEquals(h.pty.stdinPipeWrites.single()))
        assertTrue(h.pty.writeCalls.isEmpty()) // the PTY master is not the stdin path

        val eof = h.job.requestStdinEof()
        assertTrue("$eof", eof is StdinEof.Closed)
        assertEquals(payload.size, (eof as StdinEof.Closed).acceptedBytesBeforeClose)
        // The second EOF command is idempotent and never re-closes the fd.
        val again = h.job.requestStdinEof()
        assertTrue("$again", again is StdinEof.Closed && (again as StdinEof.Closed).idempotent)
        assertEquals(1, h.pty.stdinPipeCloseCalls)

        // A write after EOF is honestly refused, never silently swallowed.
        val late = h.job.writeStdin(byteArrayOf(1))
        assertEquals(StdinWrite.Failed(9, 0), late)
    }

    @Test
    fun shortWritesAndEagainBackpressureStayBoundedAndKeepAcceptedBytes() {
        val h = Pipe(PtyJobPolicy(maxStdinWriteRetries = 3, stdinRetryDelayMs = 0))
        // Short write, one full-pipe tick, then resumed acceptance: every byte
        // is written exactly once, from the correct offset.
        h.pty.stdinPipeResults += listOf(2, -11, 1, 3)
        val write = h.job.writeStdin("abcdef".toByteArray())
        assertTrue("$write", write is StdinWrite.Complete)
        assertEquals(6, (write as StdinWrite.Complete).bytes)
        val fed = h.pty.stdinPipeWrites.fold(byteArrayOf()) { acc, part -> acc + part }
        assertTrue("abcdef".toByteArray().contentEquals(fed))
        assertEquals(1, h.clock.sleeps.size) // exactly one bounded retry tick

        // A reader-less full pipe fails with Partial after the retry budget,
        // stating the backpressure errno instead of a fake success.
        h.pty.stdinPipeResults += List(10) { -11 }
        val stalled = h.job.writeStdin(byteArrayOf(7, 8))
        assertTrue("$stalled", stalled is StdinWrite.Partial)
        stalled as StdinWrite.Partial
        assertEquals(0, stalled.bytes)
        assertEquals(2, stalled.requested)
        assertEquals(3, stalled.retries)
        assertEquals(11, stalled.errno)
        // Admission is never blocked forever: retries were bounded and slept
        // on the injected clock only.
        assertEquals(4, h.clock.sleeps.size) // 1 earlier + 3 bounded this page
        assertEquals(6, h.job.stdinStatus().acceptedBytes)
    }

    @Test
    fun epipeAfterPartialIsHonestFailureAndEofCommandStillCloses() {
        val h = Pipe()
        // Child closed its stdin (e.g. `head -1`): the accepted prefix stays,
        // EPIPE is reported, and no remainder is pretended away.
        h.pty.stdinPipeResults += listOf(1, -32)
        val write = h.job.writeStdin(byteArrayOf(10, 11, 12))
        assertTrue("$write", write is StdinWrite.Partial)
        write as StdinWrite.Partial
        assertEquals(1, write.bytes)
        assertEquals(3, write.requested)
        assertEquals(32, write.errno)
        assertEquals(1, h.job.stdinStatus().acceptedBytes)
        assertEquals(32, h.job.stdinStatus().lastErrno)
        // EOF still needs delivering for the lifecycle owner; close succeeds.
        val eof = h.job.requestStdinEof()
        assertTrue("$eof", eof is StdinEof.Closed)
        assertEquals(1, (eof as StdinEof.Closed).acceptedBytesBeforeClose)
        assertTrue(!h.pty.stdinPipeOpen)
    }

    @Test
    fun cancelOfBlockedWriterClosesDescriptorAndNoWriteSurvives() {
        val h = Pipe(PtyJobPolicy(maxStdinWriteRetries = 2, stdinRetryDelayMs = 0))
        h.pty.stdinPipeResults += listOf(-11, -11, -11)
        val stalled = h.job.writeStdin(byteArrayOf(1, 2))
        assertTrue("$stalled", stalled is StdinWrite.Partial)
        val outcome = h.job.requestCancel("user-stop")
        assertTrue("$outcome", outcome is CancelOutcome.Terminated)
        // Transport stop owns the descriptor: a blocked writer cannot keep a
        // write end open behind a cancelled session.
        assertFalse(h.pty.stdinPipeOpen)
        assertTrue(h.pty.stdinPipeCloseCalls >= 1)
        // After termination nothing further can be written or claimed.
        assertEquals(StdinWrite.Failed(9, 0), h.job.writeStdin(byteArrayOf(3)))
        val late = h.job.requestStdinEof()
        assertTrue("$late", late is StdinEof.Rejected)
        assertEquals(JobState.TERMINATED, h.job.stateNow)
    }

    @Test
    fun naturalExitLifecycleClosesPipeWithoutClaimingEofCommand() {
        val h = Pipe()
        h.job.writeStdin("input".toByteArray())
        h.pty.reads.add(FakePty.ReadStep.Data(ByteArray(0)))
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))
        val outcome = h.job.pump()
        assertTrue("$outcome", outcome is PumpOutcome.Terminated)
        // The lifecycle close released the descriptor, but the owner never
        // delivered an EOF command: that truth stays visible.
        assertFalse("an exit alone never fabricates an EOF command", h.job.stdinStatus().eofDelivered)
        assertFalse(h.pty.stdinPipeOpen)
        assertTrue(h.pty.stdinPipeCloseCalls >= 1)
        // The shared PTY master was NOT closed to fake anything: output drain
        // and census proof still own their real paths.
        assertEquals(0, h.pty.closeMasterCalls)
    }

    @Test
    fun ptyDeliveryKeepsMasterInputAndRefusesPipeCommands() {
        val h = PtyJob()
        // Existing interactive/PTY semantics: writes ride the master with the
        // unchanged partial accounting.
        h.pty.writes.add(2)
        val write = h.job.writeStdin(byteArrayOf(1, 2, 3))
        assertTrue("$write", write is StdinWrite.Complete)
        assertEquals(listOf(3, 1), h.pty.writeCalls)
        assertTrue(h.pty.stdinPipeWrites.isEmpty())

        // An empty page stays the unchanged no-op for PTY sessions.
        val empty = h.job.writeStdin(byteArrayOf())
        assertTrue("$empty", empty is StdinWrite.Complete)

        // Pipe commands honestly refuse on a PTY-delivery session.
        val eof = h.job.requestStdinEof()
        assertTrue("$eof", eof is StdinEof.Rejected)
        assertEquals(0, h.pty.stdinPipeCloseCalls)
        val routed = h.job.stdinStatus()
        assertEquals(StdinDelivery.PtyInput, routed.delivery)

        // And a natural exit does not touch any (nonexistent) pipe.
        h.pty.polls.add(ExitResult(0, signaled = false, termSig = 0))
        h.job.pump()
        assertEquals(0, h.pty.stdinPipeCloseCalls)
    }

    @Test
    fun stdinDeliveryChoiceIsCarriedFromTheExplicitLaunchSpec() {
        val h = Pipe()
        assertEquals(StdinDelivery.OneShotPipe, h.job.stdinDelivery)
        val pty = PtyJob()
        assertEquals(StdinDelivery.PtyInput, pty.job.stdinDelivery)
        // Chunk paging bound surfaces to the caller instead of a wholesale
        // refusal of a valid 16 KiB wire page.
        assertTrue(h.job.maxStdinChunkBytes in 1..16_384)
    }
}
