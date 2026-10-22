// SPDX-License-Identifier: MPL-2.0
//
// Floe Android Linux runtime — distinct-UID process supervision (G03-R2).
//
// Scope of this package: *transient, service-owned* process supervision for the
// independent runtime UID plus a bounded PTY job wrapper over the R1 launch
// transport. It is NOT a job database, NOT an environment registry and NOT a
// security sandbox. FloeEnvironments (Swift, main App) stays the sole
// environment/lease authority; BackgroundJobService in the main App stays the
// sole persistent job authority. Everything here lives only as long as the
// runtime service process lives: on process death nothing is replayed, the next
// service instance must run [RuntimeWorkSupervisor.recoverBeforeAdmission] to
// stop stale same-UID descendants before admitting any new workload.

package com.floe.android.linuxruntime.supervision

/**
 * Opaque ownership proof handed over by the lease authority (owned by Main /
 * `FloeAndroidLinuxAuthority`). This package only *carries* it: it never mints,
 * stores, persists or validates leases beyond equality, and it keeps no registry.
 *
 * @param leaseId authority-side lease identifier, supplied by the caller.
 * @param holderId identity of the holder this service may hand terminal proofs to.
 */
data class LeaseToken(val leaseId: String, val holderId: String) {
    init {
        require(leaseId.isNotBlank() && holderId.isNotBlank()) { "lease fields must be explicit" }
        require(leaseId.length <= 256 && holderId.length <= 256) { "lease fields oversized" }
    }
}

/**
 * Process birth identity. A PID alone is never authority (PID reuse), so every
 * signal decision re-verifies PID + kernel start-time tick (and, for foreign
 * census candidates, the real UID) immediately before [SignalBoundary.kill].
 */
data class ProcessBirth(val pid: Int, val startTimeTicks: Long) {
    init {
        require(pid > 0) { "pid must be a positive process id; group signalling is not used here" }
        // A zero/negative tick means the observation failed; it must never become
        // a "valid" identity that a later kill would trust.
        require(startTimeTicks > 0L) { "startTimeTicks must come from a real /proc observation" }
    }

    /** Stable textual identity, matching the R1 transport's `creationIdentity` format. */
    val identity: String get() = "$pid:$startTimeTicks"

    companion object {
        /** Parses the R1 `PtySession.creationIdentity` string ("$pid:$startTicks"). */
        fun fromCreationIdentity(value: String): ProcessBirth? {
            val parts = value.split(':')
            if (parts.size != 2) return null
            val pid = parts[0].toIntOrNull() ?: return null
            val ticks = parts[1].toLongOrNull() ?: return null
            return if (pid > 0 && ticks > 0) ProcessBirth(pid, ticks) else null
        }
    }
}

/** Time source, injectable so JVM fixtures can drive the bounded rounds without real waits. */
interface SupervisorClock {
    fun nowMs(): Long
    fun sleep(ms: Long)
}

/** Production clock: monotonic millis and a real (bounded, interruptible) sleep. */
object WallClock : SupervisorClock {
    override fun nowMs(): Long = System.nanoTime() / 1_000_000

    override fun sleep(ms: Long) {
        if (ms <= 0) return
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}

/** Kernel signal numbers used by this package (kept local to avoid new dependencies). */
internal object PosixSignals {
    const val SIGKILL = 9
    const val EPERM = 1
    const val ESRCH = 3
    const val EINTR = 4
    const val EAGAIN = 11
    const val EBADF = 9
    const val EINVAL = 22
    const val EIO = 5

    fun name(errno: Int): String = when (errno) {
        EPERM -> "EPERM"; ESRCH -> "ESRCH"; EINTR -> "EINTR"; EBADF -> "EBADF"
        EAGAIN -> "EAGAIN"; EINVAL -> "EINVAL"; EIO -> "EIO"
        else -> "errno=$errno"
    }
}

/**
 * Log-safe identity summary. Command output, argv and environment values never
 * enter logs from this package; only supplied identifiers and process births do.
 */
internal fun identitySummary(
    lease: LeaseToken,
    environmentId: String,
    taskId: String,
    pid: Int?,
    state: String,
): String = "lease=${lease.leaseId} holder=${lease.holderId} env=$environmentId task=$taskId" +
    (pid?.let { " pid=$it" } ?: "") + " state=$state"
