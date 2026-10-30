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
 * Bounded admission policy for the supervisor (G07.3A multi-workload).
 *
 * [single] is the historical whole-UID single-workload contract: one owned job,
 * every admission requires a fully clean UID proof, and a terminal proof sweeps
 * every non-owned stray. Existing callers keep this default byte-for-byte.
 *
 * [concurrent] admits up to [maxConcurrent] independently owned jobs (the App
 * composition uses 3: two interactive terminals plus ONE shared Agent/run
 * execution slot). Admission and terminal proofs are SCOPED: they exclude
 * only processes kernel-attributed to OTHER live owned jobs and never signal an
 * unattributable process while a sibling is live. That is what makes two real
 * PTY sessions plus an Agent command safe; it is not a tab-only simulation.
 */
data class WorkloadAdmission(
    val maxConcurrent: Int = 1,
    val enforceStraySweep: Boolean = true,
) {
    init { require(maxConcurrent in 1..4) { "maxConcurrent out of range" } }

    companion object {
        val single = WorkloadAdmission()
        val concurrent = WorkloadAdmission(maxConcurrent = 3, enforceStraySweep = false)
    }
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
    private val admissionLock = ReentrantLock()

    /** True only while a start/stop/settlement reservation is in progress. */
    private var reserved = false

    /**
     * Every owned workload this process instance has admitted and not yet
     * retired, in admission order. A TERMINATED job stays here until its lease
     * is really settled (`settleLease` -> [retire]) so a failed hand-back can
     * never be forgotten. Legacy single mode keeps at most one entry because
     * admission refuses a second start.
     */
    private val jobs = LinkedHashMap<String, SupervisedPtyJob>()

    @Volatile
    private var shuttingDown = false

    /** Most recently admitted live job (legacy diagnostic handle). */
    private val activeRef = AtomicReference<SupervisedPtyJob?>(null)

    /** Last terminal workload: its lease stays reconcilable even after a replacement. */
    @Volatile
    private var lastTerminal: SupervisedPtyJob? = null

    /** The first live workload of this UID, or null. Transient: nothing is stored elsewhere. */
    fun activeJob(): SupervisedPtyJob? =
        synchronized(admissionLock) { jobs.values.firstOrNull { it.stateNow != JobState.TERMINATED } }

    /** Live owned jobs (diagnostic/test observation; identifiers only). */
    fun ownedJobLeases(): List<LeaseToken> =
        synchronized(admissionLock) { jobs.values.filter { it.stateNow != JobState.TERMINATED }.map { it.lease } }

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
        val busy = reserve(WorkloadAdmission.single, "recovery")
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
     * [admission] defaults to the historical single-workload policy. In
     * [WorkloadAdmission.concurrent] mode the slot count is bounded, the
     * pre-admission proof excludes other owned jobs, and this job's terminal
     * proof excludes them too — so independent sessions never signal each
     * other. A start that cannot be admitted is refused without touching the
     * census or the transport.
     */
    fun start(
        spec: LaunchSpec,
        lease: LeaseToken,
        onTerminal: (WorkloadTerminal) -> Unit,
        admission: WorkloadAdmission = WorkloadAdmission.single,
    ): StartOutcome {
        boundaryGuard()?.let { return StartOutcome.Refused(it) }
        val busy = reserve(admission, "start")
        if (busy != null) return StartOutcome.Refused(busy)

        try {
            // Scope the pre-admission proof to OTHER owned jobs in concurrent
            // mode. With no sibling live this is the historical full-UID sweep.
            val siblingRoots = liveRootPids()
            val scoped = WorkloadAdmission(
                maxConcurrent = admission.maxConcurrent,
                enforceStraySweep = admission.enforceStraySweep && siblingRoots.isEmpty(),
            )
            val proof = quiescer.quiesce(
                "pre-admission",
                exclusion = QuiescenceExclusion.ownedRoots(siblingRoots),
                enforce = scoped.enforceStraySweep,
            )
            if (proof !is Quiescence.Proven) {
                return StartOutcome.Refused("admission-unproven:" + describe(proof))
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
            // A registered workload owns its slot; every other path returns the
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
            val siblings = liveRootPids()
            val proof = quiescer.quiesce(
                "spawn-identity-unproven",
                exclusion = QuiescenceExclusion.ownedRoots(siblings),
                enforce = siblings.isEmpty(),
            )
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
            // Evaluated at each proof: every OTHER live owned root, by kernel
            // parent chain only. This job's own descendants stay in scope.
            exclusionProvider = {
                QuiescenceExclusion.ownedRoots(liveRootPids(excludingLease = lease))
            },
            enforceProvider = {
                // Only the LAST live workload (or a legacy single one) may
                // sweep/kill unattributable own-UID processes.
                liveRootPids(excludingLease = lease).isEmpty()
            },
        )
        register(job)
        return StartOutcome.Accepted(job)
    }

    /**
     * G07.3A: the ORIGINAL whole-runtime-UID quiescence boundary for writable
     * workspace export. Only callable when no owned workload is live; if a
     * sibling is still live it answers Retained WITHOUT killing anything (the
     * caller must defer). With no live owned job this is the exact historical
     * full-UID sweep used before a workspace export/lease release.
     */
    fun globalQuiescence(reason: String): Quiescence {
        boundaryGuard()?.let {
            return Quiescence.Unknown(reason, 0, emptyList(), "boundary:$it", null)
        }
        val liveJobs = synchronized(admissionLock) {
            jobs.values.filter { it.stateNow != JobState.TERMINATED }
        }
        if (liveJobs.isNotEmpty()) {
            val snapshot = census.snapshot()
            return Quiescence.Retained(
                reason, 0, emptyList(), live = snapshot.ownLive,
                unreapedOwnChildren = snapshot.unreapedOwnChildren, audit = snapshot,
            )
        }
        return quiescer.quiesce(reason)
    }

    /**
     * Releases the supervisor's transient entry for a job whose lease was
     * really completed (authority hand-back succeeded). Keeps the map bounded;
     * a TERMINATED job is never used for a new proof. No-op for a still-live
     * or already-retired job.
     */
    fun retireSettled(lease: LeaseToken) {
        val job = synchronized(admissionLock) { jobs[lease.leaseId] } ?: return
        if (job.stateNow == JobState.TERMINATED) retire(job)
    }

    /** Stop the addressed owned workload (real transport stop, then scoped proof). */
    fun cancelActive(lease: LeaseToken, reason: String): CancelOutcome {
        boundaryGuard()?.let { return CancelOutcome.Rejected(it) }
        val job = reconcilableJob(lease) ?: return CancelOutcome.Rejected("no workload holds this lease")
        return job.requestCancel(reason)
    }

    /**
     * The ONLY question the credential-bearing lease authority may ask to decide a
     * release. `Released` carries the proof for THIS workload (whole UID in the
     * legacy single mode; sibling-excluded in concurrent mode). Anything else
     * means keep the lease. Unknown leases are denied, not forgotten, and a mere
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
     * state. Every live job is stopped (a root retirement must drain ALL owned
     * sessions). A non-[LeaseSettlement.Released] answer for any job is
     * [LeaseSettlement.Pending] and that job stays owned; the next instance
     * reconciles after recovery.
     */
    fun shutdown(reason: String): LeaseSettlement {
        shuttingDown = true
        val owned = synchronized(admissionLock) { jobs.values.toList() }
        if (owned.isEmpty()) {
            val terminal = lastTerminal
                ?: return LeaseSettlement.Denied("nothing active")
            val settlement = terminal.settleLease()
            if (settlement is LeaseSettlement.Released) retire(terminal)
            return settlement
        }
        var releasedTerminal: WorkloadTerminal? = null
        var releasedProof: Quiescence.Proven? = null
        var pending: LeaseSettlement.Pending? = null
        for (job in owned) {
            job.requestCancel(reason)
            when (val settlement = job.settleLease()) {
                is LeaseSettlement.Released -> {
                    releasedTerminal = settlement.terminal
                    releasedProof = settlement.quiescence
                    retire(job)
                }
                is LeaseSettlement.Pending -> pending = settlement
                is LeaseSettlement.Denied -> pending = LeaseSettlement.Pending(
                    settlement.reason, null, rootReapProven = false)
            }
        }
        if (pending != null) return pending
        val terminal = releasedTerminal ?: return LeaseSettlement.Denied("nothing active")
        return LeaseSettlement.Released(terminal, checkNotNull(releasedProof))
    }

    // ---- admission bookkeeping ------------------------------------------------

    /**
     * Non-null return value is the refusal reason; success reserves admission.
     * Capacity counts LIVE jobs only; a terminated-but-unreleased job still
     * occupies its lease but no process, so a new workload may be admitted only
     * in concurrent mode and only under [admission.maxConcurrent].
     */
    private fun reserve(admission: WorkloadAdmission, purpose: String): String? = admissionLock.withLock {
        if (shuttingDown) return@withLock "service is shutting down"
        if (reserved) return@withLock "admission already in progress ($purpose)"
        val live = jobs.values.filter { it.stateNow != JobState.TERMINATED }
        if (live.size >= admission.maxConcurrent) {
            val detail = live.joinToString { "${it.lease.leaseId}:${it.stateNow.name.lowercase()}" }
            return@withLock "workload capacity reached (${live.size}/${admission.maxConcurrent}): $detail"
        }
        reserved = true
        null
    }

    /** Returns a bare reservation to idle; a workload-owned slot is untouched. */
    private fun releaseReservation() = admissionLock.withLock {
        reserved = false
    }

    private fun register(job: SupervisedPtyJob) = admissionLock.withLock {
        check(reserved) { "a workload may only be registered on a reserved admission" }
        jobs[job.lease.leaseId] = job
        activeRef.set(job)
        reserved = false
    }

    /** Lock-free retirement; a later reserve() reconciles the slot itself. */
    private fun retire(job: SupervisedPtyJob) {
        admissionLock.withLock { jobs.remove(job.lease.leaseId) }
        activeRef.compareAndSet(job, null)
        lastTerminal = job
    }

    /** Kernel-attributed live roots of every OTHER owned job. */
    private fun liveRootPids(excludingLease: LeaseToken? = null): Set<Int> =
        admissionLock.withLock {
            jobs.values
                .filter { it.stateNow != JobState.TERMINATED }
                .filter { excludingLease == null || it.lease != excludingLease }
                .mapTo(LinkedHashSet()) { it.pid }
        }

    private fun reconcilableJob(lease: LeaseToken): SupervisedPtyJob? {
        admissionLock.withLock { jobs[lease.leaseId] }?.let { if (it.lease == lease) return it }
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
