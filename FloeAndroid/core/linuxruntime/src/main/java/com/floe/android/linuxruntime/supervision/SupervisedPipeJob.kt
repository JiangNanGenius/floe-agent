// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.LaunchSpec
import com.floe.android.linuxruntime.PipeProcessSession
import com.floe.android.linuxruntime.RunOwnership
import com.floe.android.linuxruntime.StdinDelivery
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Bounds for ONE C01 managed-service stdio workload. Nothing here is resolved:
 * every bound is explicit, enforced locally and reported honestly.
 *
 * The stdout ring is sized to hold one MAXIMUM protocol line
 * (`C02MCPSetupLimits.maximumStdioLineBytes` == 2 MiB) plus headroom so a
 * conforming line-framed consumer never loses a byte. If a consumer stalls
 * long enough for the ring to wrap, [OutputPage.gapBytes] reports the loss and
 * the Swift channel treats it as a hard desynchronization (never a silent
 * resync). stderr is deliberately smaller: it is diagnostics, not protocol.
 */
data class PipeJobPolicy(
    val maxRetainedStdoutBytes: Int = 2 * 1024 * 1024 + 64 * 1024,
    val maxRetainedStderrBytes: Int = 64 * 1024,
    val maxReadChunkBytes: Int = 8 * 1024,
    val maxReadWaitMs: Long = 100,
    val maxWriteChunkBytes: Int = 8 * 1024,
    val maxStdinWriteRetries: Int = 64,
    val stdinRetryDelayMs: Long = 5,
    val terminalDrainRounds: Int = 8,
    val terminalDrainWaitMs: Long = 50,
    val spawnTimeoutMs: Long = 10_000,
) {
    init {
        require(maxRetainedStdoutBytes in BoundedOutputRing.MIN_CAPACITY..BoundedOutputRing.MAX_CAPACITY)
        require(maxRetainedStderrBytes in BoundedOutputRing.MIN_CAPACITY..BoundedOutputRing.MAX_CAPACITY)
        require(maxReadChunkBytes in 1..BoundedOutputRing.MAX_PAGE_BYTES)
        require(maxReadWaitMs in 0..1_000)
        require(maxWriteChunkBytes in 1..BoundedOutputRing.MAX_PAGE_BYTES)
        require(maxStdinWriteRetries in 0..1_024)
        require(terminalDrainRounds in 0..64)
        require(spawnTimeoutMs in 1..60_000)
    }
}

/** One independent page from each of the two output streams. */
data class StdioOutputPages(
    val stdout: OutputPage,
    val stderr: OutputPage,
    val stdoutEof: Boolean,
    val stderrEof: Boolean,
)

/**
 * One owned no-PTY stdio workload over the C01 pipe transport.
 *
 * Lifecycle invariants are IDENTICAL to [SupervisedPtyJob]: one drain owner,
 * a terminal only after a waitpid-backed root exit plus (scoped) whole-UID
 * quiescence, cancellation is a request, and no callback/output is ever
 * persisted or logged. Stream semantics are different by design:
 *
 * * stdout and stderr have separate bounded rings, separate absolute cursors
 *   and separate real EOF flags; nothing is merged;
 * * stdin is a dedicated pipe whose close is the only descriptor EOF source;
 * * there is no resize, no Ctrl-C byte and no line discipline (there is no
 *   PTY to own); a stop is the exact owned process-tree stop.
 */
class SupervisedPipeJob internal constructor(
    private val session: PipeProcessSession,
    private val boundary: RuntimeUidBoundary,
    private val quiescer: RuntimeUidQuiescer,
    private val census: ProcCensus,
    override val lease: LeaseToken,
    val ownership: RunOwnership,
    val spec: LaunchSpec,
    private val policy: PipeJobPolicy,
    private val clock: SupervisorClock,
    private val onTerminal: (WorkloadTerminal) -> Unit,
    rootBirthOverride: ProcessBirth? = null,
    private val exclusionProvider: () -> QuiescenceExclusion = { QuiescenceExclusion.none },
    private val enforceProvider: () -> Boolean = { true },
) : SupervisedWorkload {
    private val stateLock = ReentrantLock()
    private val stdoutRing = BoundedOutputRing(policy.maxRetainedStdoutBytes)
    private val stderrRing = BoundedOutputRing(policy.maxRetainedStderrBytes)
    private val terminating = AtomicBoolean(false)
    private val delivered = AtomicBoolean(false)

    init {
        require(census.runtimeUid == boundary.runtimeUid) {
            "census UID ${census.runtimeUid} does not match boundary UID ${boundary.runtimeUid}"
        }
        require(spec.ownership == ownership) { "session ownership must equal the launch spec ownership" }
    }

    @Volatile private var state: JobState = JobState.RUNNING
    @Volatile private var stdoutEof: Boolean = false
    @Volatile private var stderrEof: Boolean = false
    @Volatile private var rootExit: ExitResult? = null
    @Volatile private var terminalResult: WorkloadTerminal? = null
    @Volatile private var lastFailure: Quiescence? = null
    @Volatile private var drainOwner: Thread? = null
    @Volatile private var lastCallbackFailure: Throwable? = null
    private var lastCancelReason: String? = null

    private val stdinLock = ReentrantLock()
    @Volatile private var stdinAcceptedBytes: Int = 0
    @Volatile private var stdinEofDelivered: Boolean = false
    @Volatile private var stdinLastErrno: Int? = null

    override val rootBirth: ProcessBirth = rootBirthOverride
        ?: ProcessBirth.fromCreationIdentity(session.creationIdentity)
        ?: throw IllegalArgumentException(
            "pipe transport must report a parsable creationIdentity, got '${session.creationIdentity}'",
        )

    val rootReapProven: Boolean get() = rootExit?.let { it.waitErrno == 0 } ?: false
    override val pid: Int get() = session.pid
    override val stateNow: JobState get() = state
    override val exitResult: ExitResult? get() = rootExit
    val retainedStdoutBytes: Int get() = stdoutRing.retainedBytes
    val retainedStderrBytes: Int get() = stderrRing.retainedBytes
    val droppedStdoutBytes: Long get() = stdoutRing.totalDroppedBytes
    val droppedStderrBytes: Long get() = stderrRing.totalDroppedBytes

    private fun requireDrainOwner() {
        val owner = drainOwner
        if (owner == null) {
            drainOwner = Thread.currentThread()
            return
        }
        check(owner === Thread.currentThread()) {
            "output has one drain owner; bound to ${owner.name}, called from ${Thread.currentThread().name}"
        }
    }

    /** Explicit handoff of the drain owner (a new service instance may take over). */
    fun rebindDrainOwner(thread: Thread = Thread.currentThread()) {
        drainOwner = thread
    }

    /**
     * One bounded step: read at most one chunk from EACH output stream into its
     * own ring, then poll the root. On a proven root exit the bounded terminal
     * phase runs (leftover drain -> whole-UID proof -> callback).
     */
    override fun pump(): PumpOutcome {
        requireDrainOwner()
        val before = state
        if (before == JobState.TERMINATED) {
            terminalResult?.let { return PumpOutcome.Terminated(it) }
        }
        if (before != JobState.RUNNING) {
            return PumpOutcome.Blocked(before, "job is ${before.name.lowercase()}")
        }

        val stdoutChunk = try {
            session.readStdout(policy.maxReadChunkBytes, policy.maxReadWaitMs)
        } catch (e: Exception) {
            return PumpOutcome.ReadFailed("stdout-${e.javaClass.simpleName}:${e.message}")
        }
        if (stdoutChunk == null) stdoutEof = true
        if (stdoutChunk != null && stdoutChunk.isNotEmpty()) {
            stateLock.withLock { stdoutRing.append(stdoutChunk) }
        }
        val stderrChunk = try {
            session.readStderr(policy.maxReadChunkBytes, 0)
        } catch (e: Exception) {
            return PumpOutcome.ReadFailed("stderr-${e.javaClass.simpleName}:${e.message}")
        }
        if (stderrChunk == null) stderrEof = true
        if (stderrChunk != null && stderrChunk.isNotEmpty()) {
            stateLock.withLock { stderrRing.append(stderrChunk) }
        }

        val accepted = (stdoutChunk?.size ?: 0) + (stderrChunk?.size ?: 0)
        val exit = try {
            session.pollExit()
        } catch (e: Exception) {
            return PumpOutcome.ReadFailed("poll-${e.javaClass.simpleName}:${e.message}")
        }
        if (exit == null) {
            val waitErrno = runCatching { session.lastWaitErrno() }.getOrDefault(0)
            if (waitErrno != 0) {
                markRetained("root-wait-error:errno=$waitErrno")
                return PumpOutcome.Blocked(state, "root wait error $waitErrno")
            }
            if (stdoutEof && stderrEof && accepted == 0) {
                // Both pipes are closed but the root is still alive (for
                // example a server that daemonized its own work). Keep the
                // lease responsive without a busy spin; the deadline/stop
                // checks in the owner loop still run every 20 ms.
                clock.sleep(20)
            }
            return PumpOutcome.Received(accepted, stdoutEof && stderrEof,
                stdoutRing.totalProducedBytes + stderrRing.totalProducedBytes,
                stdoutRing.totalDroppedBytes + stderrRing.totalDroppedBytes)
        }
        if (exit.waitErrno != 0) {
            markRetained("root-wait-error:errno=${exit.waitErrno}")
            return PumpOutcome.Blocked(state, "root exit came from a waitpid error (${exit.waitErrno})")
        }
        rootExit = exit
        return withTerminalPhase("workload-exit", cancelled = false, exit = exit)
    }

    /**
     * Bounded paging of the two independent streams. A gap in EITHER stream is
     * reported truthfully; the client must treat it as a protocol failure
     * rather than resynchronizing.
     */
    fun pages(stdoutCursor: Long, stderrCursor: Long, maxBytes: Int): StdioOutputPages =
        stateLock.withLock {
            StdioOutputPages(
                stdout = stdoutRing.read(stdoutCursor, maxBytes),
                stderr = stderrRing.read(stderrCursor, maxBytes),
                stdoutEof = stdoutEof,
                stderrEof = stderrEof,
            )
        }

    override fun output(cursor: Long, maxBytes: Int): OutputPage =
        stateLock.withLock { stdoutRing.read(cursor, maxBytes) }

    override val stdinDelivery: StdinDelivery get() = StdinDelivery.OneShotPipe
    override val maxStdinChunkBytes: Int get() = policy.maxWriteChunkBytes

    override fun stdinStatus(): StdinStatus =
        StdinStatus(StdinDelivery.OneShotPipe, stdinAcceptedBytes, stdinEofDelivered, stdinLastErrno)

    override fun writeStdin(data: ByteArray, offset: Int, length: Int): StdinWrite {
        require(length in 0..policy.maxWriteChunkBytes) {
            "chunk exceeds maxWriteChunkBytes=${policy.maxWriteChunkBytes}"
        }
        if (length == 0) return StdinWrite.Complete(0)
        val result = accountStdin(writePipeBounded(data, offset, length))
        return result
    }

    private fun writePipeBounded(data: ByteArray, offset: Int, length: Int): StdinWrite {
        var sent = 0
        var retries = 0
        var lastErrno: Int? = null
        while (sent < length) {
            val rc = session.writeStdin(data, offset + sent, length - sent)
            if (rc > 0) {
                sent += rc
                continue
            }
            if (rc == 0 || rc == -11 /* EAGAIN */) {
                if (retries >= policy.maxStdinWriteRetries) {
                    return StdinWrite.Partial(sent, length, retries, lastErrno ?: 11)
                }
                retries++
                clock.sleep(policy.stdinRetryDelayMs)
                continue
            }
            val errno = if (rc < 0) -rc else 5
            lastErrno = errno
            return if (sent == 0) StdinWrite.Failed(errno, 0)
            else StdinWrite.Partial(sent, length, retries, errno)
        }
        return StdinWrite.Complete(sent)
    }

    private fun accountStdin(result: StdinWrite): StdinWrite {
        when (result) {
            is StdinWrite.Complete -> stdinAcceptedBytes += result.bytes
            is StdinWrite.Partial -> {
                stdinAcceptedBytes += result.bytes
                result.errno?.let { stdinLastErrno = it }
            }
            is StdinWrite.Failed -> {
                stdinAcceptedBytes += result.bytesAlreadyWritten
                stdinLastErrno = result.errno
            }
        }
        return result
    }

    override fun requestStdinEof(): StdinEof {
        val observed = state
        if (observed != JobState.RUNNING) {
            return StdinEof.Rejected("job is ${observed.name.lowercase()}; lifecycle owns the stdin descriptor")
        }
        stdinLock.withLock {
            if (stdinEofDelivered) return StdinEof.Closed(stdinAcceptedBytes, idempotent = true)
            val rc = session.closeStdin()
            if (rc < 0) {
                stdinLastErrno = -rc
                return StdinEof.Failed(-rc)
            }
            stdinEofDelivered = true
            return StdinEof.Closed(stdinAcceptedBytes, idempotent = false)
        }
    }

    override fun resize(rows: Int, cols: Int): Boolean = false

    override fun requestCancel(reason: String): CancelOutcome {
        val current = stateLock.withLock {
            val observed = state
            if (observed == JobState.TERMINATED) return CancelOutcome.Rejected("already terminated")
            if (observed == JobState.CANCELLING) return CancelOutcome.InProgress(observed)
            state = JobState.CANCELLING
            observed
        }
        if (!terminating.compareAndSet(false, true)) return CancelOutcome.InProgress(JobState.CANCELLING)
        try {
            val exit = try {
                session.cancel()
            } catch (e: Exception) {
                markRetained("transport-stop-${e.javaClass.simpleName}")
                return CancelOutcome.Retained(
                    lastFailure ?: Quiescence.Unknown("cancel", 0, emptyList(), "transport-stop-throw", null),
                    "transport stop threw ${e.javaClass.simpleName}",
                )
            }
            if (exit == null) {
                markRetained("root-reap-unproven:cancel-returned-null")
                return CancelOutcome.Retained(
                    lastFailure ?: Quiescence.Unknown("cancel", 0, emptyList(), "root-reap-unproven", null),
                    "root reap unproven (transport cancel returned no exit)",
                )
            }
            if (exit.waitErrno != 0) {
                markRetained("root-reap-unproven:waitErrno=${exit.waitErrno}")
                return CancelOutcome.Retained(
                    lastFailure ?: Quiescence.Unknown("cancel", 0, emptyList(), "root-wait-error", null),
                    "root wait error ${exit.waitErrno} (ECHILD/wait errors are not benign)",
                )
            }
            rootExit = exit
            val outcome = enterTerminalPhase("cancel:$reason", cancelled = true, exit = exit)
            return when (outcome) {
                is PumpOutcome.Terminated -> CancelOutcome.Terminated(outcome.terminal)
                is PumpOutcome.QuiescePending -> CancelOutcome.Retained(outcome.failure, outcome.reason)
                else -> CancelOutcome.InProgress(state)
            }
        } finally {
            terminating.set(false)
        }
    }

    override fun settleLease(): LeaseSettlement {
        val observed = state
        if (observed == JobState.TERMINATED) {
            val terminal = terminalResult
                ?: return LeaseSettlement.Pending("terminated without terminal record", null, rootReapProven = true)
            val proof = (terminal as? WorkloadTerminal.Completed)?.quiescence
                ?: (terminal as? WorkloadTerminal.Cancelled)?.quiescence
                ?: return LeaseSettlement.Pending("terminal carries no whole-UID proof", null, rootReapProven = true)
            return LeaseSettlement.Released(terminal, proof)
        }
        if (observed == JobState.CANCELLING) {
            return LeaseSettlement.Pending("cancel in progress", lastFailure, rootReapProven)
        }
        if (observed == JobState.RUNNING) {
            return LeaseSettlement.Pending("root workload still running", null, rootReapProven)
        }
        if (!terminating.compareAndSet(false, true)) {
            return LeaseSettlement.Pending("terminal phase already running", lastFailure, rootReapProven)
        }
        try {
            if (rootExit == null) {
                val exit = try {
                    session.pollExit()
                } catch (e: Exception) {
                    return LeaseSettlement.Pending("root re-poll failed ${e.javaClass.simpleName}", lastFailure, false)
                }
                if (exit == null || exit.waitErrno != 0) {
                    val errno = exit?.waitErrno ?: session.lastWaitErrno()
                    return LeaseSettlement.Pending(
                        "root reap still unproven (waitErrno=$errno)", lastFailure, false,
                    )
                }
                rootExit = exit
            }
            val outcome = enterTerminalPhase(
                lastCancelReason ?: "workload-exit",
                cancelled = lastCancelReason != null,
                exit = requireNotNull(rootExit),
            )
            return when (outcome) {
                is PumpOutcome.Terminated -> {
                    val proof = (outcome.terminal as? WorkloadTerminal.Completed)?.quiescence
                        ?: (outcome.terminal as? WorkloadTerminal.Cancelled)?.quiescence
                    if (proof == null) {
                        LeaseSettlement.Pending("terminal without proof", null, true)
                    } else {
                        LeaseSettlement.Released(outcome.terminal, proof)
                    }
                }
                is PumpOutcome.QuiescePending -> LeaseSettlement.Pending(outcome.reason, outcome.failure, true)
                else -> LeaseSettlement.Pending("retry blocked in state ${state.name}", lastFailure, true)
            }
        } finally {
            terminating.set(false)
        }
    }

    fun inspectCensus(): CensusSnapshot = census.snapshot()

    private fun markRetained(detail: String) {
        stateLock.withLock {
            if (state != JobState.TERMINATED) state = JobState.LEASE_RETAINED
        }
        if (lastFailure == null) {
            lastFailure = Quiescence.Unknown(detail, 0, emptyList(), detail, null)
        }
    }

    private fun withTerminalPhase(reason: String, cancelled: Boolean, exit: ExitResult): PumpOutcome {
        if (!terminating.compareAndSet(false, true)) {
            return PumpOutcome.Blocked(state, "terminal phase already in progress")
        }
        try {
            return enterTerminalPhase(reason, cancelled, exit)
        } finally {
            terminating.set(false)
        }
    }

    private fun enterTerminalPhase(reason: String, cancelled: Boolean, exit: ExitResult): PumpOutcome {
        if (cancelled) lastCancelReason = reason
        // Lifecycle ownership: close the stdin write end once the workload is
        // terminal. This releases the descriptor (never an EOF "command").
        runCatching { session.closeStdin() }
        run {
            if (!cancelled) drainLeftoverOutput()
            // The output descriptors belong to this terminal. Closing them
            // after the bounded drain releases kernel resources even if a
            // detached guest descendant still holds a write end (the
            // whole-UID proof below then decides whether the lease is
            // releasable; an EOF that never arrived is never invented).
            runCatching { session.closeStreams() }
            val proof = quiescer.quiesce(reason, exclusion = exclusionProvider(), enforce = enforceProvider())
            lastFailure = if (proof is Quiescence.Proven) null else proof
            return when (proof) {
                is Quiescence.Proven -> {
                    val terminal = if (cancelled) {
                        WorkloadTerminal.Cancelled(
                            lease, ownership, exit, proof,
                            reason = reason.removePrefix("cancel:"),
                            droppedOutputBytes = stdoutRing.totalDroppedBytes + stderrRing.totalDroppedBytes,
                        )
                    } else {
                        WorkloadTerminal.Completed(
                            lease, ownership, exit, proof,
                            droppedOutputBytes = stdoutRing.totalDroppedBytes + stderrRing.totalDroppedBytes,
                        )
                    }
                    stateLock.withLock {
                        state = JobState.TERMINATED
                        terminalResult = terminal
                    }
                    deliver(terminal)
                    PumpOutcome.Terminated(terminal)
                }

                is Quiescence.Retained -> {
                    stateLock.withLock { if (state != JobState.TERMINATED) state = JobState.LEASE_RETAINED }
                    PumpOutcome.QuiescePending(
                        proof,
                        "retained own-UID work: " + proof.live.joinToString { it.birth.identity } +
                            ", unreapedChildren=${proof.unreapedOwnChildren.size}",
                    )
                }

                is Quiescence.Unknown -> {
                    stateLock.withLock { if (state != JobState.TERMINATED) state = JobState.LEASE_RETAINED }
                    PumpOutcome.QuiescePending(proof, "unresolved census: ${proof.failure}")
                }
            }
        }
    }

    /** Bounded final drain of BOTH streams so late output is retained. */
    private fun drainLeftoverOutput() {
        var rounds = 0
        while (rounds++ < policy.terminalDrainRounds) {
            var progressed = false
            if (!stdoutEof) {
                val chunk = try {
                    session.readStdout(policy.maxReadChunkBytes, policy.terminalDrainWaitMs)
                } catch (_: Exception) {
                    null
                }
                if (chunk == null) stdoutEof = true
                else if (chunk.isNotEmpty()) {
                    stateLock.withLock { stdoutRing.append(chunk) }
                    progressed = true
                }
            }
            if (!stderrEof) {
                val chunk = try {
                    session.readStderr(policy.maxReadChunkBytes, 0)
                } catch (_: Exception) {
                    null
                }
                if (chunk == null) stderrEof = true
                else if (chunk.isNotEmpty()) {
                    stateLock.withLock { stderrRing.append(chunk) }
                    progressed = true
                }
            }
            if (stdoutEof && stderrEof) return
            if (!progressed) return
        }
    }

    private fun deliver(terminal: WorkloadTerminal) {
        if (!delivered.compareAndSet(false, true)) return
        runCatching { onTerminal(terminal) }
            .onFailure { lastCallbackFailure = it }
    }

    fun lastCallbackError(): Throwable? = lastCallbackFailure
}
