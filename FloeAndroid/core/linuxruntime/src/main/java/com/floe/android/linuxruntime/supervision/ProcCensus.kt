// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

/** A process that positively belongs to the runtime UID (live or zombie). */
data class OwnProcess(
    val birth: ProcessBirth,
    val uid: Int,
    val state: Char,
    val ppid: Int,
    val tgid: Int,
    val name: String,
) {
    val pid: Int get() = birth.pid
    val isZombie: Boolean get() = state == 'Z'
}

/**
 * A candidate whose relationship to the runtime UID could not be resolved. It is
 * never silently dropped and never counted as "clean": an unreadable or
 * ambiguous own-UID candidate blocks any quiescence claim.
 */
data class AmbiguousCandidate(val pid: Int, val reason: String)

/** Outcome of one `/proc` sweep of the runtime UID. */
data class CensusSnapshot(
    val servicePid: Int,
    val ownLive: List<OwnProcess>,
    val ownZombies: List<OwnProcess>,
    val ambiguous: List<AmbiguousCandidate>,
    /** Entries that belong to the supervisor's own process (threads, not subprocesses). */
    val serviceThreads: List<Int>,
    val foreignCount: Int,
    /** Pids whose status was unreadable but which the kernel says we may not signal. */
    val unreadableForeignCount: Int,
    val scannedCount: Int,
    /** Non-null when the sweep itself failed; the result is then NOT usable. */
    val inventoryFailure: String?,
) {
    /** Strictly clean: fully readable inventory, no live own work, no ambiguity. */
    val isCleanlyQuiescent: Boolean
        get() = inventoryFailure == null && ambiguous.isEmpty() && ownLive.isEmpty()

    /** Own zombies whose parent is this supervisor: only this process can reap them. */
    val unreapedOwnChildren: List<OwnProcess>
        get() = ownZombies.filter { it.ppid == servicePid }
}

/**
 * Own-UID process census, built from kernel-derived facts only:
 * `/proc/<pid>/status` (Tgid, PPid, Uid, State) plus `/proc/<pid>/stat`
 * (starttime, for birth verification), with a `kill(pid, 0)` probe to classify
 * entries whose status cannot be read.
 *
 * Deliberate limits (Main owns the rest):
 * - Lifecycle accounting for ONE runtime UID; not per-task isolation and not a
 *   sandbox. Everything it sees shares the runtime UID's files and rights.
 * - It never enumerates a pid's task directory, so a thread is not mistaken for a
 *   subprocess; a leaked `Tgid == self` entry is still excluded and recorded.
 */
class ProcCensus(
    private val boundary: RuntimeUidBoundary,
    private val reader: ProcReader,
    private val signals: SignalBoundary,
) {
    val runtimeUid: Int get() = boundary.runtimeUid

    private fun failed(reason: String) = CensusSnapshot(
        servicePid = boundary.selfPid, ownLive = emptyList(), ownZombies = emptyList(),
        ambiguous = emptyList(), serviceThreads = emptyList(), foreignCount = 0,
        unreadableForeignCount = 0, scannedCount = 0, inventoryFailure = reason,
    )

    fun snapshot(): CensusSnapshot {
        val listing = try {
            reader.procPids()
        } catch (e: Exception) {
            return failed("proc-listing-${e.javaClass.simpleName}")
        }
        val pids = when (listing) {
            is ProcListOutcome.Failed -> return failed(listing.reason)
            is ProcListOutcome.Available -> listing.pids
        }

        val live = mutableListOf<OwnProcess>()
        val zombies = mutableListOf<OwnProcess>()
        val ambiguous = mutableListOf<AmbiguousCandidate>()
        val threads = mutableListOf<Int>()
        var foreign = 0
        var unreadableForeign = 0

        for (pid in pids) {
            if (pid <= 0) continue
            if (pid == boundary.selfPid) continue // the supervisor process itself

            val statusLines = try {
                reader.statusLines(pid)
            } catch (_: Exception) {
                null
            }
            if (statusLines == null) {
                // EPERM can be a same-UID policy denial; it is NOT proof of a
                // foreign process. Root-owned proc directories are also
                // inconclusive (non-dumpable processes can be owned by root).
                when (val probe = signals.probe(pid)) {
                    ProbeOutcome.Alive -> ambiguous += AmbiguousCandidate(
                        pid, "status-unreadable-but-signalable",
                    )

                    ProbeOutcome.MayNotSignal -> {
                        val owner = runCatching { reader.directoryOwnerUid(pid) }.getOrNull()
                        if (owner != null && owner > 0 && owner != boundary.runtimeUid) unreadableForeign++
                        else ambiguous += AmbiguousCandidate(pid, "status-unreadable-permission-denied-owner-unproven")
                    }
                    ProbeOutcome.Gone -> Unit
                    is ProbeOutcome.Error -> ambiguous += AmbiguousCandidate(
                        pid, "status-unreadable-probe-${PosixSignals.name(probe.errno)}",
                    )
                }
                continue
            }

            val status = ProcParsing.parseStatus(statusLines)
            if (status == null) {
                ambiguous += AmbiguousCandidate(pid, "status-unparsable")
                continue
            }
            if (status.tgid == boundary.selfPid) {
                threads += pid // a thread of this service, not an independent subprocess
                continue
            }
            if (status.uidReal != boundary.runtimeUid) {
                foreign++
                continue
            }

            val statLine = try {
                reader.statFields(pid)
            } catch (_: Exception) {
                null
            }
            val stat = statLine?.let { ProcParsing.parseStat(it) }
            if (stat == null || stat.startTimeTicks <= 0L) {
                // Birth time is required to signal safely (PID-reuse guard):
                // without it this own-UID candidate is unresolved, not absent.
                ambiguous += AmbiguousCandidate(pid, "birth-time-unreadable")
                continue
            }
            val record = OwnProcess(
                birth = ProcessBirth(pid, stat.startTimeTicks),
                uid = status.uidReal,
                // status is the authoritative state source; the stat copy can be
                // a race window apart and is not used here.
                state = status.state,
                ppid = status.ppid,
                tgid = status.tgid,
                name = status.name,
            )
            if (record.isZombie) zombies += record else live += record
        }

        return CensusSnapshot(
            servicePid = boundary.selfPid, ownLive = live, ownZombies = zombies,
            ambiguous = ambiguous, serviceThreads = threads, foreignCount = foreign,
            unreadableForeignCount = unreadableForeign, scannedCount = pids.size,
            inventoryFailure = null,
        )
    }
}
