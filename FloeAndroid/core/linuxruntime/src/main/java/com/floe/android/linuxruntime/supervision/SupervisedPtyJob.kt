// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.LaunchSpec
import com.floe.android.linuxruntime.PtySession
import com.floe.android.linuxruntime.RunOwnership
import com.floe.android.linuxruntime.StdinDelivery
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Lifecycle states of one transient, service-owned workload. */
enum class JobState {
    /** Root child alive; output is being drained by the registered owner. */
    RUNNING,

    /** A stop was requested: transport stop and/or whole-UID proof in progress. */
    CANCELLING,

    /**
     * Not quiescent: the root reap could not be proven, or the whole-runtime-UID
     * census did not reach proof. The lease is NOT releasable and the terminal
     * callback has not fired. [SupervisedPtyJob.settleLease] retries the proof.
     */
    LEASE_RETAINED,

    /** Whole-UID quiescence proven; terminal callback delivered exactly once. */
    TERMINATED,
}

/** Bounds for one bounded PTY job. Everything here is explicit; nothing is resolved. */
data class PtyJobPolicy(
    val maxRetainedOutputBytes: Int = 64 * 1024,
    val maxReadChunkBytes: Int = 8 * 1024,
    /** Transport read wait; the R1 session caps this at 1000 ms by design. */
    val maxReadWaitMs: Long = 250,
    val maxWriteChunkBytes: Int = 8 * 1024,
    val maxStdinWriteRetries: Int = 32,
    val stdinRetryDelayMs: Long = 5,
    /** Bounded extra reads after the root exited, so late output is still retained. */
    val terminalDrainRounds: Int = 4,
    val terminalDrainWaitMs: Long = 50,
    /** Spawn handshake bound, forwarded to the transport (its own cap is 60 000). */
    val spawnTimeoutMs: Long = 10_000,
) {
    init {
        require(maxRetainedOutputBytes in BoundedOutputRing.MIN_CAPACITY..BoundedOutputRing.MAX_CAPACITY)
        require(maxReadChunkBytes in 1..BoundedOutputRing.MAX_PAGE_BYTES)
        require(maxReadWaitMs in 0..1_000) { "transport read wait is capped at 1000ms" }
        require(maxWriteChunkBytes in 1..BoundedOutputRing.MAX_PAGE_BYTES)
        require(maxStdinWriteRetries in 0..1024)
        require(terminalDrainRounds in 0..64)
        require(spawnTimeoutMs in 1..60_000) { "transport spawn timeout out of range" }
    }
}

/**
 * The only proof shape the trusted owner may act on. [Completed] and [Cancelled]
 * always carry a [Quiescence.Proven]: the whole runtime UID was observed stopped,
 * not merely the root child. [SpawnAbandoned] never claims that proof for work
 * that did exist; it only carries one when a real child had to be stopped.
 */
sealed class WorkloadTerminal {
    abstract val lease: LeaseToken
    abstract val ownership: RunOwnership

    data class Completed(
        override val lease: LeaseToken,
        override val ownership: RunOwnership,
        val exit: ExitResult,
        val quiescence: Quiescence.Proven,
        val droppedOutputBytes: Long,
    ) : WorkloadTerminal()

    data class Cancelled(
        override val lease: LeaseToken,
        override val ownership: RunOwnership,
        val exit: ExitResult,
        val quiescence: Quiescence.Proven,
        val reason: String,
        val droppedOutputBytes: Long,
    ) : WorkloadTerminal()

    /** No workload to supervise: spawn failed (no child) or identity could not be proven. */
    data class SpawnAbandoned(
        override val lease: LeaseToken,
        override val ownership: RunOwnership,
        val failure: String,
        val quiescence: Quiescence?,
    ) : WorkloadTerminal()
}

/** Result of one [SupervisedPtyJob.pump] step. */
sealed class PumpOutcome {
    data class Received(
        val bytes: Int,
        val eof: Boolean,
        val totalProducedBytes: Long,
        val droppedBytes: Long,
    ) : PumpOutcome()

    data class Terminated(val terminal: WorkloadTerminal) : PumpOutcome()

    /** Stop/proof work is owned by another path (cancel in flight, retained, terminated). */
    data class Blocked(val state: JobState, val reason: String) : PumpOutcome()

    /** Transport read failed. This is NOT an exit and NOT EOF: the lease stays. */
    data class ReadFailed(val detail: String) : PumpOutcome()

    /** Root exited but whole-runtime-UID quiescence is not proven yet. Lease held. */
    data class QuiescePending(val failure: Quiescence, val reason: String) : PumpOutcome()
}

/** Result of [SupervisedPtyJob.requestCancel]. */
sealed class CancelOutcome {
    data class Terminated(val terminal: WorkloadTerminal) : CancelOutcome()
    data class Retained(val failure: Quiescence, val reason: String) : CancelOutcome()
    data class InProgress(val state: JobState) : CancelOutcome()
    data class Rejected(val reason: String) : CancelOutcome()
}

/** stdin write accounting (partial writes are normal; errno is never hidden). */
sealed class StdinWrite {
    data class Complete(val bytes: Int) : StdinWrite()
    data class Partial(val bytes: Int, val requested: Int, val retries: Int, val errno: Int?) : StdinWrite()
    data class Failed(val errno: Int, val bytesAlreadyWritten: Int) : StdinWrite()
}

/**
 * Result of the one-shot EOF command
 * ([SupervisedPtyJob.requestStdinEof]). Real descriptor EOF is an event of
 * the STDIN PIPE, distinct from the process exiting and from output drain:
 * closing the write end must never close the shared PTY master.
 */
sealed class StdinEof {
    /** Write end closed by THIS or a previous EOF command (idempotent). */
    data class Closed(val acceptedBytesBeforeClose: Int, val idempotent: Boolean) : StdinEof()

    /** close() itself failed; the fd stays owned and the command is retryable. */
    data class Failed(val errno: Int) : StdinEof()

    /** This session's delivery is not a one-shot pipe, or lifecycle owns it. */
    data class Rejected(val reason: String) : StdinEof()
}

/** Bounded one-shot stdin accounting surfaced honestly in engine polls. */
data class StdinStatus(
    val delivery: StdinDelivery,
    val acceptedBytes: Int,
    val eofDelivered: Boolean,
    val lastErrno: Int?,
)

/**
 * What the credential-bearing lease authority may conclude about one lease.
 * Main's private native lifecycle path releases the original lease ONLY on
 * [Released]; every other answer keeps it.
 */
sealed class LeaseSettlement {
    data class Released(val terminal: WorkloadTerminal, val quiescence: Quiescence.Proven) : LeaseSettlement()
    data class Pending(val reason: String, val quiescence: Quiescence?, val rootReapProven: Boolean) : LeaseSettlement()
    data class Denied(val reason: String) : LeaseSettlement()
}

/**
 * Bounded PTY job over the R1 launch transport: one owned [PtySession], one
 * explicit [LaunchSpec], one carried [LeaseToken], one in-memory output ring.
 *
 * Ownership and lifecycle rules this class enforces:
 * - Explicit inputs only. No rootfs/path/project defaults, no raw host alias, no
 *   environment resolution: [com.floe.android.linuxruntime.PRootLaunchSpec] and
 *   `FloeEnvironments` remain the caller's responsibility.
 * - A single drain owner calls [pump]; [settleLease]/[requestCancel] may be
 *   called from any thread (they are the stop and reconciliation paths).
 * - No lock is ever held across a transport read, a transport stop or a
 *   whole-UID quiescence, so a stop cannot be blocked by the drain loop.
 * - EOF is not an exit; only a waitpid-backed [ExitResult] with `waitErrno == 0`
 *   proves the root stopped. A wait error (including ECHILD) is never benign.
 * - The terminal callback fires exactly once, only with a proven result.
 * - Output is never persisted or logged; only IDs and process births are.
 */
class SupervisedPtyJob internal constructor(
    private val session: PtySession,
    private val boundary: RuntimeUidBoundary,
    private val quiescer: RuntimeUidQuiescer,
    private val census: ProcCensus,
    val lease: LeaseToken,
    val ownership: RunOwnership,
    val spec: LaunchSpec,
    private val policy: PtyJobPolicy,
    private val clock: SupervisorClock,
    private val onTerminal: (WorkloadTerminal) -> Unit,
    rootBirthOverride: ProcessBirth? = null,
    /**
     * G07.3A: this job's terminal proof may run while OTHER owned workloads are
     * live in the same runtime UID (two interactive terminals + one Agent
     * command). The provider returns the live scoped exclusion for THIS proof.
     * It is evaluated at proof time, never cached, and returns only kernel-
     * attributed roots of other jobs — so this job's own descendants still must
     * be gone and another session is never signalled.
     */
    private val exclusionProvider: () -> QuiescenceExclusion = { QuiescenceExclusion.none },
    /**
     * Whether an unattributable non-excluded process may be signalled by THIS
     * proof. False while OTHER owned workloads are live: an unattributable
     * process might be another session's detached guest, so the proof must
     * refuse (retain the lease) instead of guessing and killing it.
     */
    private val enforceProvider: () -> Boolean = { true },
) {
    private val stateLock = ReentrantLock()
    private val ring = BoundedOutputRing(policy.maxRetainedOutputBytes)
    private val terminating = AtomicBoolean(false)
    private val delivered = AtomicBoolean(false)

    init {
        // A job may only supervise inside the UID its boundary was validated for.
        require(census.runtimeUid == boundary.runtimeUid) {
            "census UID ${census.runtimeUid} does not match boundary UID ${boundary.runtimeUid}"
        }
        require(spec.ownership == ownership) { "session ownership must equal the launch spec ownership" }
    }

    @Volatile
    private var state: JobState = JobState.RUNNING

    @Volatile
    private var eof: Boolean = false

    @Volatile
    private var rootExit: ExitResult? = null

    @Volatile
    private var terminalResult: WorkloadTerminal? = null

    @Volatile
    private var lastFailure: Quiescence? = null

    @Volatile
    private var drainOwner: Thread? = null

    // One-shot stdin pipe accounting (PTY-delivery sessions never touch these;
    // the descriptor itself is owned by the transport session).
    private val stdinLock = ReentrantLock()

    @Volatile
    private var stdinAcceptedBytes: Int = 0

    @Volatile
    private var stdinEofDelivered: Boolean = false

    @Volatile
    private var stdinLastErrno: Int? = null

    /**
     * Birth of the root child. The supervisor's verified identity wins; otherwise
     * the transport's own `creationIdentity` is parsed. A failed observation is
     * never promoted into a usable identity, so [rootReap] checks can only ever
     * compare against a real kernel fact.
     */
    val rootBirth: ProcessBirth = rootBirthOverride
        ?: ProcessBirth.fromCreationIdentity(session.creationIdentity)
        ?: throw IllegalArgumentException(
            "transport must report a parsable creationIdentity, got '${session.creationIdentity}'",
        )

    /** Whether the root's own exit was proven by a waitpid-backed result. */
    val rootReapProven: Boolean get() = rootExit?.let { it.waitErrno == 0 } ?: false

    val pid: Int get() = session.pid
    val stateNow: JobState get() = state
    val exitResult: ExitResult? get() = rootExit
    val retainedBytes: Int get() = ring.retainedBytes
    val totalProducedBytes: Long get() = ring.totalProducedBytes
    val droppedOutputBytes: Long get() = ring.totalDroppedBytes

    /** Log-safe identity line: identifiers and state only, never output or argv. */
    fun identitySummary(): String = identitySummary(
        lease = lease,
        environmentId = ownership.environmentId,
        taskId = ownership.taskId,
        pid = session.pid,
        state = state.name,
    )

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
     * One bounded step: read at most one chunk into the ring, then poll the root.
     * On a proven root exit the bounded terminal phase runs here: leftover output
     * is drained and the whole runtime UID is proven stopped *before* any
     * terminal callback. A background daemon therefore cannot leave the
     * environment silently idle.
     */
    fun pump(): PumpOutcome {
        requireDrainOwner()
        val before = state
        if (before == JobState.TERMINATED) {
            terminalResult?.let { return PumpOutcome.Terminated(it) }
        }
        if (before != JobState.RUNNING) {
            return PumpOutcome.Blocked(before, "job is ${before.name.lowercase()}")
        }

        val chunk = try {
            session.read(minOf(policy.maxReadChunkBytes, policy.maxRetainedOutputBytes), policy.maxReadWaitMs)
        } catch (e: Exception) {
            // A read failure is neither EOF nor exit: keep the lease, tell the owner.
            return PumpOutcome.ReadFailed("${e.javaClass.simpleName}:${e.message}")
        }
        if (chunk == null) {
            eof = true
        } else if (chunk.isNotEmpty()) {
            stateLock.withLock { ring.append(chunk) }
        }

        val accepted = chunk?.size ?: 0
        val exit = try {
            session.pollExit()
        } catch (e: Exception) {
            return PumpOutcome.ReadFailed("poll-${e.javaClass.simpleName}:${e.message}")
        }
        if (exit == null) {
            val waitErrno = runCatching { session.lastWaitErrno() }.getOrDefault(0)
            if (waitErrno != 0) {
                // The transport already saw a wait error; a running child cannot be assumed.
                markRetained("root-wait-error:errno=$waitErrno")
                return PumpOutcome.Blocked(state, "root wait error $waitErrno")
            }
            return PumpOutcome.Received(accepted, eof, ring.totalProducedBytes, ring.totalDroppedBytes)
        }
        if (exit.waitErrno != 0) {
            markRetained("root-wait-error:errno=${exit.waitErrno}")
            return PumpOutcome.Blocked(state, "root exit came from a waitpid error (${exit.waitErrno})")
        }
        rootExit = exit
        return withTerminalPhase("workload-exit", cancelled = false, exit = exit)
    }

    /**
     * Bounded drain loop for the owner's service thread: at most [maxSteps]
     * [pump] steps, stopping as soon as the workload is terminal or the caller's
     * [deadlineMs] (an absolute [SupervisorClock.nowMs] value) passes. Timeouts
     * belong to the job authority in the main App: this helper only bounds the
     * wait, it never decides on its own, and it holds no lock between steps, so a
     * concurrent stop is never blocked by it.
     */
    fun pumpUntil(deadlineMs: Long, maxSteps: Int = 64): PumpOutcome {
        require(maxSteps in 1..1_024) { "maxSteps out of range" }
        var last: PumpOutcome = PumpOutcome.Blocked(state, "no step performed")
        var steps = 0
        while (steps++ < maxSteps) {
            last = pump()
            when (last) {
                is PumpOutcome.Terminated, is PumpOutcome.QuiescePending, is PumpOutcome.ReadFailed -> return last
                is PumpOutcome.Blocked -> return last
                is PumpOutcome.Received ->
                    if (clock.nowMs() >= deadlineMs) return PumpOutcome.Blocked(state, "drain deadline reached")
            }
        }
        return last
    }

    /**
     * Request a stop: real transport stop first (kill verified root + reap + close
     * master), then whole-runtime-UID quiescence. The trusted owner's callback is
     * invoked only when that proof exists.
     */
    fun requestCancel(reason: String): CancelOutcome {
        val current = stateLock.withLock {
            val observed = state
            if (observed == JobState.TERMINATED) return CancelOutcome.Rejected("already terminated")
            if (observed == JobState.CANCELLING) return CancelOutcome.InProgress(observed)
            state = JobState.CANCELLING
            observed
        }
        if (!terminating.compareAndSet(false, true)) return CancelOutcome.InProgress(JobState.CANCELLING)
        try {
            // 1) Real transport stop of the owned root. Never a bare group/name kill.
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

    /**
     * Reconciliation entry for the lease authority (Main's private native
     * lifecycle). It either returns the existing proof, retries a pending proof,
     * or states precisely why the lease cannot be released. It never fabricates
     * success and never releases on a mere cancellation or disconnect.
     */
    fun settleLease(): LeaseSettlement {
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
        // LEASE_RETAINED: retry the missing proof, bounded by one pass.
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

    /**
     * Bounded, truthful paging of retained output. A [OutputPage.gapBytes] greater
     * than zero means the consumer missed bytes; it is never presented as
     * continuous output.
     */
    fun output(cursor: Long, maxBytes: Int = BoundedOutputRing.MAX_PAGE_BYTES): OutputPage =
        stateLock.withLock { ring.read(cursor, maxBytes) }

    /** Whole-UID census view for the owner's diagnostics (no signal side effects). */
    fun inspectCensus(): CensusSnapshot = census.snapshot()

    /** The stdin descriptor choice carried by this job's explicit [LaunchSpec]. */
    val stdinDelivery: StdinDelivery get() = spec.stdinDelivery

    /** Largest [writeStdin] chunk this job accepts; callers page larger payloads. */
    val maxStdinChunkBytes: Int get() = policy.maxWriteChunkBytes

    /** Honest bounded stdin accounting for engine polls (never output bytes). */
    fun stdinStatus(): StdinStatus =
        StdinStatus(spec.stdinDelivery, stdinAcceptedBytes, stdinEofDelivered, stdinLastErrno)

    /**
     * stdin write with bounded partial-write retries. A short write is reported,
     * never silently retried forever, and an errno is never turned into success.
     * Routing is descriptor-level: [StdinDelivery.PtyInput] writes the PTY
     * master exactly as before (terminal input keeps tty semantics);
     * [StdinDelivery.OneShotPipe] writes the owned nonblocking pipe write end,
     * where real EOF can only come from [requestStdinEof]/lifecycle close —
     * an EOT byte here is ordinary stdin DATA, never an EOF emulation.
     */
    fun writeStdin(data: ByteArray, offset: Int = 0, length: Int = data.size): StdinWrite {
        require(length in 0..policy.maxWriteChunkBytes) {
            "chunk exceeds maxWriteChunkBytes=${policy.maxWriteChunkBytes}"
        }
        if (length == 0) return StdinWrite.Complete(0)
        return accountStdin(
            if (spec.stdinDelivery == StdinDelivery.OneShotPipe)
                writeStdinPipeBounded(data, offset, length)
            else
                writePtyStdinBounded(data, offset, length)
        )
    }

    /**
     * Deliver REAL EOF for a one-shot pipe session by closing the owned write
     * end. Exactly-once at the descriptor level (idempotent at the command
     * level); this is NOT an exit and NOT an output drain: the shared PTY
     * master stays open, and a child that has not read yet simply sees EOF on
     * its next read. Refused for PTY delivery and in every non-RUNNING state
     * — a lifecycle close is reported, never re-labelled as a delivered
     * command.
     */
    fun requestStdinEof(): StdinEof {
        if (spec.stdinDelivery != StdinDelivery.OneShotPipe) {
            return StdinEof.Rejected(
                "stdin delivery is ${spec.stdinDelivery.name.lowercase()}, not one-shot pipe",
            )
        }
        val observed = state
        if (observed != JobState.RUNNING) {
            // Cancelling/retained/terminated sessions already (or about to)
            // own the descriptor through the stop/terminal lifecycle: an EOF
            // command there would mislabel a lifecycle close as delivered
            // stdin, so it refuses instead.
            return StdinEof.Rejected(
                "job is ${observed.name.lowercase()}; lifecycle owns the stdin descriptor",
            )
        }
        stdinLock.withLock {
            if (stdinEofDelivered) return StdinEof.Closed(stdinAcceptedBytes, idempotent = true)
            val rc = session.closeStdinPipe()
            if (rc < 0) {
                stdinLastErrno = -rc
                return StdinEof.Failed(-rc)
            }
            stdinEofDelivered = true
            return StdinEof.Closed(stdinAcceptedBytes, idempotent = false)
        }
    }

    private fun writePtyStdinBounded(data: ByteArray, offset: Int, length: Int): StdinWrite {
        var sent = 0
        var retries = 0
        var lastErrno: Int? = null
        while (sent < length) {
            val rc = session.write(data, offset + sent, length - sent)
            if (rc > 0) {
                sent += rc
                continue
            }
            if (rc == 0) {
                if (retries >= policy.maxStdinWriteRetries) {
                    return StdinWrite.Partial(sent, length, retries, lastErrno)
                }
                retries++
                clock.sleep(policy.stdinRetryDelayMs)
                continue
            }
            val errno = -rc
            lastErrno = errno
            return if (sent == 0) StdinWrite.Failed(errno, 0)
            else StdinWrite.Partial(sent, length, retries, errno)
        }
        return StdinWrite.Complete(sent)
    }

    // One-shot pipe write: the native call already retried EINTR and never
    // blocks on a reader, so EAGAIN/0 mean "no progress right now" and are
    // retried ONLY inside this bounded budget. EPIPE (child closed stdin) and
    // any other errno are honest failures; accepted bytes are kept.
    private fun writeStdinPipeBounded(data: ByteArray, offset: Int, length: Int): StdinWrite {
        var sent = 0
        var retries = 0
        var lastErrno: Int? = null
        while (sent < length) {
            val rc = session.writeStdinPipe(data, offset + sent, length - sent)
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
            val errno = if (rc < 0) -rc else 5 /* defensive EIO; never fake success */
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

    /** Terminal size change; refused once the master is closed (post-terminal). */
    fun resize(rows: Int, cols: Int): Boolean {
        if (state == JobState.TERMINATED) return false
        return runCatching { session.resize(rows, cols) }.getOrDefault(false)
    }

    private var lastCancelReason: String? = null

    private fun markRetained(detail: String) {
        stateLock.withLock {
            if (state != JobState.TERMINATED) state = JobState.LEASE_RETAINED
        }
        if (lastFailure == null) {
            lastFailure = Quiescence.Unknown(detail, 0, emptyList(), detail, null)
        }
    }

    /**
     * Acquires the single-phase guard, then runs the terminal phase.
     * Used by the drain owner's [pump] path only.
     */
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

    /**
     * The single terminal phase: bounded leftover drain, then the whole-runtime-UID
     * proof. The caller must already hold the [terminating] guard; no other lock
     * is taken here, so a stop path is never blocked by this work.
     */
    private fun enterTerminalPhase(reason: String, cancelled: Boolean, exit: ExitResult): PumpOutcome {
        if (cancelled) lastCancelReason = reason
        // Lifecycle ownership of the one-shot stdin write end: once a session
        // enters its terminal phase (natural exit or cancelled stop), the
        // descriptor must not outlive it. This close is an OWNERSHIP release,
        // not an EOF command: [stdinStatus] still reports eofDelivered=false
        // unless the owner actually asked for EOF beforehand, and it never
        // touches the shared PTY master needed for the leftover output drain.
        if (spec.stdinDelivery == StdinDelivery.OneShotPipe) session.closeStdinPipe()
        run {
            if (!cancelled) drainLeftoverOutput()
            val proof = quiescer.quiesce(reason, exclusion = exclusionProvider(), enforce = enforceProvider())
            lastFailure = if (proof is Quiescence.Proven) null else proof
            return when (proof) {
                is Quiescence.Proven -> {
                    val terminal = if (cancelled) {
                        WorkloadTerminal.Cancelled(
                            lease, ownership, exit, proof,
                            reason = reason.removePrefix("cancel:"),
                            droppedOutputBytes = ring.totalDroppedBytes,
                        )
                    } else {
                        WorkloadTerminal.Completed(
                            lease, ownership, exit, proof,
                            droppedOutputBytes = ring.totalDroppedBytes,
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
                    // No proof: keep the lease, hold the callback, stay retryable.
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

    /** Bounded final drain so late output is still retained and paging stays truthful. */
    private fun drainLeftoverOutput() {
        var rounds = 0
        while (rounds++ < policy.terminalDrainRounds && !eof) {
            val chunk = try {
                session.read(minOf(policy.maxReadChunkBytes, policy.maxRetainedOutputBytes), policy.terminalDrainWaitMs)
            } catch (_: Exception) {
                return
            }
            if (chunk == null) {
                eof = true
                return
            }
            if (chunk.isNotEmpty()) stateLock.withLock { ring.append(chunk) }
            if (chunk.isEmpty()) return
        }
    }

    private fun deliver(terminal: WorkloadTerminal) {
        if (!delivered.compareAndSet(false, true)) return
        runCatching { onTerminal(terminal) }
            .onFailure { lastCallbackFailure = it }
    }

    @Volatile
    private var lastCallbackFailure: Throwable? = null

    /** A throwing owner callback never corrupts the proof; the owner can read it back. */
    fun lastCallbackError(): Throwable? = lastCallbackFailure

}
