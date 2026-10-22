// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import android.system.Os

/** `kill(pid, 0)` answers, reduced to the three distinctions the census needs. */
sealed class ProbeOutcome {
    /** The kernel let us signal it: same UID (or otherwise permitted) and alive. */
    object Alive : ProbeOutcome()

    /** EPERM: another UID, or a policy denial we cannot distinguish from one. */
    object MayNotSignal : ProbeOutcome()

    /** ESRCH: no such process. */
    object Gone : ProbeOutcome()

    /** Any other errno; treated as unresolved, never as "absent". */
    data class Error(val errno: Int) : ProbeOutcome()
}

/**
 * Signal/identity seam used for every destructive decision. Production is
 * [PosixSignalBoundary] (over the existing qualified [com.floe.android.linuxruntime.PosixBridge]);
 * JVM fixtures inject their own so the kill/drain logic is testable without a device.
 *
 * Contract: implementations must never signal a process group or a name. Only a
 * positive pid that the caller has just verified (UID + birth time) may be killed.
 */
interface SignalBoundary {
    fun selfPid(): Int
    fun selfUid(): Int
    fun probe(pid: Int): ProbeOutcome
    fun uidOf(pid: Int): Int?
    fun startTimeOf(pid: Int): Long?

    /** 0 on success, otherwise negative errno (mirrors the bridge's convention). */
    fun kill(pid: Int, sig: Int): Int
}

/** Device-side boundary. Requires the R1 native library; never loaded in JVM tests. */
class PosixSignalBoundary(
    private val reader: ProcReader = LinuxProcReader,
) : SignalBoundary {

    override fun selfPid(): Int = Os.getpid()

    override fun selfUid(): Int = Os.getuid()

    override fun probe(pid: Int): ProbeOutcome {
        if (pid <= 0) return ProbeOutcome.Error(PosixSignals.EINVAL)
        return when (val rc = com.floe.android.linuxruntime.PosixBridge.exists(pid)) {
            0 -> ProbeOutcome.Alive
            -PosixSignals.ESRCH -> ProbeOutcome.Gone
            -PosixSignals.EPERM -> ProbeOutcome.MayNotSignal
            else -> ProbeOutcome.Error(if (rc < 0) -rc else rc)
        }
    }

    override fun uidOf(pid: Int): Int? =
        reader.statusLines(pid)?.let { ProcParsing.parseStatus(it) }?.uidReal

    override fun startTimeOf(pid: Int): Long? =
        reader.statFields(pid)?.let { ProcParsing.parseStat(it) }?.startTimeTicks

    /**
     * Positive pid only: a negative pid would signal a whole group, which this
     * package forbids (group membership is not a birth/UID proof).
     */
    override fun kill(pid: Int, sig: Int): Int {
        if (pid <= 0) return -PosixSignals.EINVAL
        return com.floe.android.linuxruntime.PosixBridge.kill(pid, sig)
    }
}
