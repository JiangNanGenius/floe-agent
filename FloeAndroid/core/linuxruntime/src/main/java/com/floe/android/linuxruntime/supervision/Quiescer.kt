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
     *
     * The caller must have already tried to reap its own root child through the
     * transport. If that root is somehow still observable here, it is treated
     * like any other own-UID live process: verified (UID + birth) and killed.
     * A caller's belief is never a kernel fact.
     */
    fun quiesce(reason: String): Quiescence {
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

            val live = snapshot.ownLive
            if (live.isEmpty()) {
                val unreaped = snapshot.unreapedOwnChildren
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
                    )
                }
                clock.sleep(policy.settleMs)
                continue
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
        if (audit.ownLive.isEmpty() && audit.unreapedOwnChildren.isEmpty()) {
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
            reason, rounds, kills, live = audit.ownLive,
            unreapedOwnChildren = audit.unreapedOwnChildren, audit = audit,
        )
    }
}
