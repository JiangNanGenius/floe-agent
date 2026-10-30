// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

/** One signal attempt the quiescer made, with its verification outcome. */
data class KillRecord(
    val birth: ProcessBirth,
    /** null when the target was not signalled (identity changed or unreadable). */
    val errno: Int?,
    val skipped: String?,
) {
    val delivered: Boolean get() = errno != null && errno == 0
}

/** Bounds for one whole-runtime-UID quiescence attempt. */
data class QuiescePolicy(
    /** Maximum census rounds; the attempt never runs unbounded. */
    val maxRounds: Int = 16,
    /** Quiet time between a census sample and the next. */
    val settleMs: Long = 120,
    /**
     * Consecutive clean samples required before quiescence is *proven*. One
     * sample is not enough: a detached `setsid` grandchild can appear slightly
     * after the root exits, so a second (and third) look is mandatory.
     */
    val stableSamplesRequired: Int = 2,
    /** Maximum kill attempts within one round (a hostile fan-out cannot spin us). */
    val maxKillsPerRound: Int = 256,
) {
    init {
        require(maxRounds in 1..64) { "maxRounds out of range" }
        require(settleMs in 0..5_000) { "settleMs out of range" }
        require(stableSamplesRequired in 1..8) { "stableSamplesRequired out of range" }
        require(maxKillsPerRound in 1..1024) { "maxKillsPerRound out of range" }
    }
}

/**
 * Scoped exclusion for a quiescence proof (G07.3A multi-workload admission and
 * per-session settlement).
 *
 * The runtime UID may own MORE than one supervised workload (two interactive
 * PTY sessions plus one Agent command). A proof that belongs to ONE workload
 * must not treat another owned workload's live process tree as its own
 * stragglers — and it must never kill it. The exclusion is a pure, live
 * observation over the SAME census snapshot: it never signals, never infers
 * from names and never trusts a caller-supplied pid without the snapshot.
 *
 * [QuiescenceExclusion.ownedRoots] attributes a process to an owned workload
 * only through the kernel-reported parent chain (pid -> ppid -> ...). A
 * process that detached (`setsid`, reparented to init) is deliberately NOT
 * attributed; it is treated as unattributable live work, so a concurrent
 * proof refuses rather than guessing and killing another session's guest.
 */
fun interface QuiescenceExclusion {
    fun excludes(process: OwnProcess, snapshot: List<OwnProcess>): Boolean

    companion object {
        /** Legacy single-workload proof: nothing is excluded. */
        val none: QuiescenceExclusion = QuiescenceExclusion { _, _ -> false }

        /** Excludes the supplied root pids and every snapshot descendant of them. */
        fun ownedRoots(roots: Set<Int>): QuiescenceExclusion {
            if (roots.isEmpty()) return none
            return QuiescenceExclusion { process, snapshot ->
                if (process.pid in roots) return@QuiescenceExclusion true
                val byPid = snapshot.associateBy { it.pid }
                var cursor = process
                var hops = 0
                while (hops++ < 256) {
                    val parent = byPid[cursor.ppid] ?: return@QuiescenceExclusion false
                    if (parent.pid in roots) return@QuiescenceExclusion true
                    if (parent.ppid == parent.pid) return@QuiescenceExclusion false
                    cursor = parent
                }
                false
            }
        }
    }
}

/**
 * Result of a whole-runtime-UID quiescence attempt. Only [Proven] may release a
 * lease or fire a terminal callback; [Retained] and [Unknown] keep the lease.
 */
sealed class Quiescence {
    abstract val reason: String
    abstract val rounds: Int
    abstract val kills: List<KillRecord>

    /**
     * Every live process of the runtime UID (other than the supervisor itself)
     * is gone, proven by [stableSamples] consecutive complete inventories. The
     * caller may now treat the UID as stopped; this is *evidence*, not a claim
     * about any per-task isolation.
     */
    data class Proven(
        override val reason: String,
        override val rounds: Int,
        override val kills: List<KillRecord>,
        val stableSamples: Int,
        val audit: CensusSnapshot,
        val observedZombies: List<OwnProcess>,
        /**
         * Live processes deliberately attributed to OTHER owned workloads and
         * therefore excluded from THIS proof (additive, default empty for the
         * legacy single-workload proofs). They were neither killed nor counted
         * as this workload's quiescence gap.
         */
        val excludedLive: List<OwnProcess> = emptyList(),
    ) : Quiescence()

    /** The budget ran out while own-UID work is still live, or our own child is unreaped. */
    data class Retained(
        override val reason: String,
        override val rounds: Int,
        override val kills: List<KillRecord>,
        val live: List<OwnProcess>,
        val unreapedOwnChildren: List<OwnProcess>,
        val audit: CensusSnapshot,
    ) : Quiescence()

    /** The census could not be trusted (failed/unreadable/ambiguous). Never success. */
    data class Unknown(
        override val reason: String,
        override val rounds: Int,
        override val kills: List<KillRecord>,
        val failure: String,
        val audit: CensusSnapshot?,
    ) : Quiescence()

    val proven: Boolean get() = this is Proven
}

/**
 * Proves and, when needed, enforces whole-runtime-UID quiescence.
 *
 * Why this exists: the R1 transport reaps the *root* child only. PRoot's
 * `--kill-on-exit` and the pinned `PTRACE_O_EXITKILL` patch terminate *traced*
 * descendants, but a guest that detaches (`setsid`, `fork` after detach) still
 * leaves processes that outlive the root, and the credential-bearing lease must
 * not be released while any of them can still read or write the workload's
 * files. This class closes exactly that gap by UID, not by name or process group.
 */
class RuntimeUidQuiescer(
    private val boundary: RuntimeUidBoundary,
    private val census: ProcCensus,
    private val signals: SignalBoundary,
    private val clock: SupervisorClock = WallClock,
    private val policy: QuiescePolicy = QuiescePolicy(),
) {

    /**
     * @param reason audit label ("pre-admission", "workload-exit", "cancel", …).
     * @param exclusion live processes that belong to OTHER owned workloads and
     *   must be neither killed nor counted for THIS proof. Defaults to the
     *   legacy whole-UID scope.
     * @param enforce when false, live non-excluded processes are never
     *   signalled: the attempt answers [Quiescence.Retained] immediately. This
     *   is the only safe shape for a CONCURRENT admission check, because an
     *   unattributable process might belong to another live session whose
     *   descendant detached.
     *
     * The caller must have already tried to reap its own root child through the
     * transport. If that root is somehow still observable here, it is treated
     * like any other owned live process: verified (UID + birth) and killed
     * (enforcing scopes only). A caller's belief is never a kernel fact.
     */
    fun quiesce(
        reason: String,
        exclusion: QuiescenceExclusion = QuiescenceExclusion.none,
        enforce: Boolean = true,
    ): Quiescence {
        val kills = mutableListOf<KillRecord>()
        var rounds = 0
        var stable = 0
        var last: CensusSnapshot? = null

        while (rounds < policy.maxRounds) {
            rounds++
            val snapshot = census.snapshot()
            last = snapshot

            if (snapshot.inventoryFailure != null) {
                return Quiescence.Unknown(
                    reason, rounds, kills,
                    "inventory-failed:${snapshot.inventoryFailure}", snapshot,
                )
            }
            if (snapshot.ambiguous.isNotEmpty()) {
                // An own-UID candidate we cannot identify is NOT an empty result.
                return Quiescence.Unknown(
                    reason, rounds, kills,
                    "ambiguous-candidates:" + snapshot.ambiguous.joinToString(",") {
                        "${it.pid}(${it.reason})"
                    },
                    snapshot,
                )
            }

            val allLive = snapshot.ownLive
            val excluded = allLive.filter { exclusion.excludes(it, allLive) }
            val live = allLive.filterNot { exclusion.excludes(it, allLive) }
            val unreaped = snapshot.unreapedOwnChildren
                .filterNot { exclusion.excludes(it, allLive) }
            if (live.isEmpty()) {
                if (unreaped.isNotEmpty()) {
                    return Quiescence.Retained(
                        reason, rounds, kills, live = emptyList(),
                        unreapedOwnChildren = unreaped, audit = snapshot,
                    )
                }
                stable++
                if (stable >= policy.stableSamplesRequired) {
                    return Quiescence.Proven(
                        reason, rounds, kills, stableSamples = stable,
                        audit = snapshot, observedZombies = snapshot.ownZombies,
                        excludedLive = excluded,
                    )
                }
                clock.sleep(policy.settleMs)
                continue
            }
            if (!enforce) {
                // Concurrent admission: NEVER signal a process that may belong
                // to another live session whose guest detached from its root.
                // The owner sees the real live list and can act explicitly.
                return Quiescence.Retained(
                    reason, rounds, kills, live = live,
                    unreapedOwnChildren = unreaped, audit = snapshot,
                )
            }

            stable = 0
            var budget = policy.maxKillsPerRound
            for (target in live) {
                if (budget-- <= 0) break
                if (target.tgid == boundary.selfPid) continue // paranoia: never kill our own thread
                val birth = target.birth
                if (birth.pid == boundary.selfPid) continue // never signal this process

                // Verify actual UID + birth immediately before signalling.
                val uidNow = try { signals.uidOf(birth.pid) } catch (_: Exception) { null }
                val startNow = try { signals.startTimeOf(birth.pid) } catch (_: Exception) { null }
                if (uidNow == null || startNow == null) {
                    kills += KillRecord(birth, errno = null, skipped = "identity-unreadable")
                    continue
                }
                if (uidNow != boundary.runtimeUid) {
                    kills += KillRecord(birth, errno = null, skipped = "uid-changed:$uidNow")
                    continue
                }
                if (startNow != birth.startTimeTicks) {
                    // PID reuse: the current occupant is a different process and
                    // is not ours to kill. It will be re-evaluated next round.
                    kills += KillRecord(birth, errno = null, skipped = "birth-changed")
                    continue
                }
                val rc = signals.kill(birth.pid, PosixSignals.SIGKILL)
                kills += KillRecord(birth, errno = if (rc == 0) 0 else -rc, skipped = null)
            }
            clock.sleep(policy.settleMs)
        }

        val audit = last ?: census.snapshot()
        if (audit.inventoryFailure != null || audit.ambiguous.isNotEmpty()) {
            return Quiescence.Unknown(reason, rounds, kills, "budget-exhausted-unresolved", audit)
        }
        val remaining = audit.ownLive.filterNot { exclusion.excludes(it, audit.ownLive) }
        val remainingZombies = audit.unreapedOwnChildren
            .filterNot { exclusion.excludes(it, audit.ownLive) }
        if (remaining.isEmpty() && remainingZombies.isEmpty()) {
            // Nothing live is observable, but stability was not observed long
            // enough to *prove* it. That is an unproven result, never a success
            // and never "retained work" either.
            return Quiescence.Unknown(
                reason, rounds, kills,
                "budget-exhausted-before-stable-samples(stable=$stable/${policy.stableSamplesRequired})",
                audit,
            )
        }
        return Quiescence.Retained(
            reason, rounds, kills, live = remaining,
            unreapedOwnChildren = remainingZombies, audit = audit,
        )
    }
}
