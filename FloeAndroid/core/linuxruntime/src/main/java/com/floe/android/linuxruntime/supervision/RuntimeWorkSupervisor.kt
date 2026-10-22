// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.LaunchSpec
import com.floe.android.linuxruntime.LinuxRuntimeBackend
import com.floe.android.linuxruntime.PtySession
import com.floe.android.linuxruntime.SpawnOutcome
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Result of a [RuntimeWorkSupervisor.start] attempt. */
sealed class StartOutcome {
    /** Accepted, running under the single-workload reservation; drain it with [SupervisedPtyJob.pump]. */
    data class Accepted(val job: SupervisedPtyJob) : StartOutcome()

    /**
     * Not started: boundary refused, admission reservation busy, the
     * pre-admission proof missing, or the transport reported a real failure.
     * Nothing was spawned in this case.
     */
    data class Refused(val reason: String) : StartOutcome()

    /**
     * Spawn really failed (no child exists) or the child's birth identity could
     * not be proven. The trusted owner was notified with
     * [WorkloadTerminal.SpawnAbandoned]. No quiescence is claimed for work that
     * never existed; a real child that had to be stopped carries its own proof,
     * and an unprovable stop keeps the lease held instead of pretending.
     */
    data class Abandoned(val terminal: WorkloadTerminal.SpawnAbandoned) : StartOutcome()
}

/**
 * Result of [RuntimeWorkSupervisor.recoverBeforeAdmission].
 *
 * [Refused] is not a failure of the sweep: it means the sweep was NOT performed,
 * so nobody accidentally stopped the workload that this service already admitted.
 */
sealed class RecoveryOutcome {
    data class Swept(val quiescence: Quiescence) : RecoveryOutcome()
    data class Refused(val reason: String) : RecoveryOutcome()
}

/**
 * Single entry point for the runtime service's Linux workloads.
 *
 * Responsibilities (and only these):
 * - Refuse to operate unless this process really is the allowlisted runtime UID,
 *   distinct from the credential-bearing core App UID ([RuntimeUidBoundary]).
 * - Enforce its OWN documented invariant, not just Main's serialized executor: at
 *   most ONE workload may exist in that UID. Admission is *reserved* before any
 *   census sweep or spawn, so two simultaneous starts can never both pass an
 *   empty check and one loser can never sweep away the winner's processes.
 * - Require whole-runtime-UID quiescence before admitting any new process
 *   (recovery), and after the root stops before proving a lease releasable.
 * - Wrap the R1 launch transport in a bounded PTY job with transient ownership.
 *
 * Reservation never blocks the stop path: [cancelActive], [settleLease] and
 * [shutdown] only take the job's own short locks, so a long bounded sweep cannot
 * hold up a cancellation, and a blocked drain read cannot hold up a stop.
 *
 * It is NOT a job registry, NOT an environment DB and it persists nothing: if the
 * service process dies, its state dies with it. The next instance must call
 * [recoverBeforeAdmission], which stops stale same-UID descendants instead of
 * replaying anything.
 */
class RuntimeWorkSupervisor(
    private val boundary: RuntimeUidBoundary,
    private val backend: LinuxRuntimeBackend,
    private val census: ProcCensus,
    private val signals: SignalBoundary,
    private val quiescer: RuntimeUidQuiescer,
    private val jobPolicy: PtyJobPolicy = PtyJobPolicy(),
    private val clock: SupervisorClock = WallClock,
) {
    init {
        require(census.runtimeUid == boundary.runtimeUid) { "census UID does not match the boundary" }
        // Trusted-boundary contract, re-checked against live kernel facts: a
        // transplanted or stale proof cannot unlock any operation here.
        require(signals.selfUid() == boundary.runtimeUid) {
            if (signals.selfUid() == boundary.coreUid) {
                "supervisor must run as the allowlisted runtime UID ${boundary.runtimeUid}; " +
                    "this process is the credential-bearing core App UID ${boundary.coreUid}"
            } else {
                "supervisor must run as runtime UID ${boundary.runtimeUid}, not ${signals.selfUid()}"
            }
        }
        require(signals.selfPid() == boundary.selfPid) {
            "boundary was validated for pid ${boundary.selfPid}, this process is ${signals.selfPid()}"
        }
    }

    /** Admission bookkeeping, guarded by [admissionLock]; never consulted by a stop path. */
    private sealed interface Slot {
        object Idle : Slot
        object Reserved : Slot
        data class Running(val job: SupervisedPtyJob) : Slot
    }

    private val admissionLock = ReentrantLock()

    private var slot: Slot = Slot.Idle

    @Volatile
    private var shuttingDown = false

    /** Lock-free reader handle for the stop/reconcile paths. */
    private val activeRef = AtomicReference<SupervisedPtyJob?>(null)

    /** Last terminal workload: its lease stays reconcilable even after a replacement. */
    @Volatile
    private var lastTerminal: SupervisedPtyJob? = null

    /** The one active workload of this UID, or null. Transient: nothing is stored elsewhere. */
    fun activeJob(): SupervisedPtyJob? = activeRef.get()?.takeIf { it.stateNow != JobState.TERMINATED }

    /** Live census UID for the service's own reporting. */
    fun runtimeUid(): Int = boundary.runtimeUid

    /**
     * Recovery sweep. Call at service start (including after an abnormal process
     * death) to stop stale same-UID descendants. It refuses to sweep while a
     * workload is admitted or admission is reserved, because that would kill the
     * service's own live workload. It never replays a command and writes nothing.
     */
    fun recoverBeforeAdmission(reason: String): RecoveryOutcome {
        boundaryGuard()?.let { return RecoveryOutcome.Refused(it) }
        val busy = reserve("recovery")
        if (busy != null) return RecoveryOutcome.Refused(busy)
        try {
            return RecoveryOutcome.Swept(quiescer.quiesce("recovery:$reason"))
        } finally {
            releaseReservation()
        }
    }

    /**
     * Starts one workload from fully explicit inputs: a caller-resolved
     * [LaunchSpec] (no defaults, no host aliases resolved here) and the
     * [LeaseToken] the lease authority handed this service.
     *
     * Admission reserves the single slot first, then requires a fresh
     * whole-runtime-UID proof, then spawns. A second concurrent call is refused
     * without touching the census or the transport.
     */
    fun start(
        spec: LaunchSpec,
        lease: LeaseToken,
        onTerminal: (WorkloadTerminal) -> Unit,
    ): StartOutcome {
        boundaryGuard()?.let { return StartOutcome.Refused(it) }
        val busy = reserve("start")
        if (busy != null) return StartOutcome.Refused(busy)

        try {
            // Recovery BEFORE admitting any new process: never spawn over a busy UID.
            val admission = quiescer.quiesce("pre-admission")
            if (admission !is Quiescence.Proven) {
                return StartOutcome.Refused("admission-unproven:" + describe(admission))
            }

            val spawn = try {
                backend.spawn(spec, timeoutMs = jobPolicy.spawnTimeoutMs)
            } catch (e: Exception) {
                return StartOutcome.Refused("spawn-threw-${e.javaClass.simpleName}")
            }

            return when (spawn) {
                is SpawnOutcome.Failed -> {
                    // No child ever existed: safe abandon, no quiescence claim; the
                    // lease authority is told immediately so it can return the lease.
                    val terminal = WorkloadTerminal.SpawnAbandoned(
                        lease, spec.ownership,
                        "spawn-failed:errno=${spawn.error.errno}(${spawn.error.message})", null,
                    )
                    deliverTo(onTerminal, terminal)
                    StartOutcome.Abandoned(terminal)
                }

                is SpawnOutcome.Spawned -> startSpawned(spawn.session, spec, lease, onTerminal)
            }
        } finally {
            // A registered workload owns the slot; every other path returns the
            // reservation, so a refusal can never wedge admission.
            releaseReservation()
        }
    }

    private fun startSpawned(
        session: PtySession,
        spec: LaunchSpec,
        lease: LeaseToken,
        onTerminal: (WorkloadTerminal) -> Unit,
    ): StartOutcome {
        val birth = ProcessBirth.fromCreationIdentity(session.creationIdentity)
        if (birth == null) {
            // A real child exists but its birth cannot be proven. Stop it through
            // the transport, then prove the UID actually stopped. Without that
            // proof the lease is held, not released.
            val stopped = runCatching { session.cancel() }.getOrNull()
            val proof = quiescer.quiesce("spawn-identity-unproven")
            val detail = if (stopped == null || stopped.waitErrno != 0) {
                " root-reap-unproven(waitErrno=${stopped?.waitErrno ?: session.lastWaitErrno()})"
            } else {
                ""
            }
            val terminal = WorkloadTerminal.SpawnAbandoned(
                lease, spec.ownership, "creationIdentity-unparsable:${session.creationIdentity}$detail", proof,
            )
            return if (proof is Quiescence.Proven && stopped != null && stopped.waitErrno == 0) {
                deliverTo(onTerminal, terminal)
                StartOutcome.Abandoned(terminal)
            } else {
                StartOutcome.Refused("spawn-identity-unproven-and-retained:" + describe(proof))
            }
        }

        val job = SupervisedPtyJob(
            session = session,
            boundary = boundary,
            quiescer = quiescer,
            census = census,
            lease = lease,
            ownership = spec.ownership,
            spec = spec,
            policy = jobPolicy,
            clock = clock,
            onTerminal = onTerminal,
            rootBirthOverride = birth,
        )
        register(job)
        return StartOutcome.Accepted(job)
    }

    /** Stop the active workload (real transport stop, then whole-UID proof). */
    fun cancelActive(lease: LeaseToken, reason: String): CancelOutcome {
        boundaryGuard()?.let { return CancelOutcome.Rejected(it) }
        val job = reconcilableJob(lease) ?: return CancelOutcome.Rejected("no workload holds this lease")
        return job.requestCancel(reason)
    }

    /**
     * The ONLY question the credential-bearing lease authority may ask to decide a
     * release. `Released` carries the whole-runtime-UID proof; anything else means
     * keep the lease. Unknown leases are denied, not forgotten, and a mere
     * cancellation or disconnect never produces a release.
     */
    fun settleLease(lease: LeaseToken): LeaseSettlement {
        boundaryGuard()?.let { return LeaseSettlement.Denied(it) }
        val job = reconcilableJob(lease)
            ?: return LeaseSettlement.Denied("no workload held by this service instance")
        val settlement = job.settleLease()
        if (settlement is LeaseSettlement.Released) retire(job)
        return settlement
    }

    /**
     * Service teardown: stop whatever this instance owns and report the proof
     * state. A non-[LeaseSettlement.Released] answer must NOT be treated as
     * "stopped": the lease stays and the next instance reconciles after recovery.
     */
    fun shutdown(reason: String): LeaseSettlement {
        shuttingDown = true
        val job = activeRef.get() ?: run {
            val terminal = lastTerminal
            if (terminal != null) {
                val settlement = terminal.settleLease()
                if (settlement is LeaseSettlement.Released) retire(terminal)
                return settlement
            }
            return LeaseSettlement.Denied("nothing active")
        }
        job.requestCancel(reason)
        val settlement = job.settleLease()
        if (settlement is LeaseSettlement.Released) retire(job)
        return settlement
    }

    // ---- admission bookkeeping ------------------------------------------------

    /** Non-null return value is the refusal reason; success means the slot is ours. */
    private fun reserve(purpose: String): String? = admissionLock.withLock {
        if (shuttingDown) return@withLock "service is shutting down"
        when (val current = slot) {
            Slot.Reserved -> "admission already in progress ($purpose)"
            Slot.Idle -> {
                slot = Slot.Reserved
                null
            }

            is Slot.Running -> {
                val job = current.job
                if (job.stateNow == JobState.TERMINATED) {
                    lastTerminal = job
                    slot = Slot.Reserved
                    null
                } else {
                    "one workload at a time in this UID: lease ${job.lease.leaseId} is ${job.stateNow.name.lowercase()}"
                }
            }
        }
    }

    /** Returns a bare reservation to Idle; a workload-owned slot is untouched. */
    private fun releaseReservation() = admissionLock.withLock {
        if (slot === Slot.Reserved) slot = Slot.Idle
    }

    private fun register(job: SupervisedPtyJob) = admissionLock.withLock {
        check(slot === Slot.Reserved) { "a workload may only be registered on a reserved slot" }
        slot = Slot.Running(job)
        activeRef.set(job)
    }

    /** Lock-free retirement; a later reserve() reconciles the slot itself. */
    private fun retire(job: SupervisedPtyJob) {
        activeRef.compareAndSet(job, null)
        lastTerminal = job
    }

    private fun reconcilableJob(lease: LeaseToken): SupervisedPtyJob? {
        val active = activeRef.get()
        if (active != null && active.lease == lease) return active
        val terminal = lastTerminal
        return terminal.takeIf { it?.lease == lease }
    }

    // ---- boundary -------------------------------------------------------------

    /** Live re-verification of the boundary; non-null means "refuse everything". */
    private fun boundaryGuard(): String? {
        val uid = runCatching { signals.selfUid() }.getOrDefault(-1)
        if (uid != boundary.runtimeUid) {
            return "boundary-denied:process-uid=$uid runtime-uid=${boundary.runtimeUid}"
        }
        if (uid == boundary.coreUid) return "boundary-denied:credential-bearing-uid"
        val pid = runCatching { signals.selfPid() }.getOrDefault(-1)
        if (pid != boundary.selfPid) return "boundary-denied:pid-mismatch-$pid"
        return null
    }

    private fun describe(quiescence: Quiescence): String = when (quiescence) {
        is Quiescence.Proven -> "proven(rounds=${quiescence.rounds})"
        is Quiescence.Retained -> "retained(live=" +
            quiescence.live.joinToString { it.birth.identity } +
            ", unreapedChildren=${quiescence.unreapedOwnChildren.size}, rounds=${quiescence.rounds})"

        is Quiescence.Unknown -> "unknown(${quiescence.failure}, rounds=${quiescence.rounds})"
    }

    private fun deliverTo(onTerminal: (WorkloadTerminal) -> Unit, terminal: WorkloadTerminal) {
        runCatching { onTerminal(terminal) }
    }
}
