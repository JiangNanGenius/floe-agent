// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

/**
 * G03-R3 first-start admission repair — the runtime kernel's stopping-fence
 * state machine under ONE serialization monitor.
 *
 * WHY THIS CLASS EXISTS (actual device failure, candidate08,
 * NEW_TASK_WORKSPACE_FAILURE_08.json): the kernel's `stopping` flag could
 * previously fall at only two moments — requestStop's own entry/finally and
 * the queued executor's finally — and BOTH evaluate the live predicate
 * `!hasOwnedWork()`. When a stop arrives while a shell session is still
 * draining on the OPERATIONS pump thread (observed closed-stage order:
 * PUMP_STOP_SESSION -> OPS_PUMP_ENDED -> OPS_FINISH_RETURNED ->
 * PUMP_FINISHED), every one of those moments still saw the lease held, and
 * the REAL release landed later on the pump thread, where nothing revisited
 * the flag. The bound runtime process survives sessions, so the next
 * admission — the FIRST tool run of a brand-new ordinary New task — was
 * deterministically refused at `check(!stopping)` between
 * KERNEL_START_ENTER and KERNEL_ADMISSION_CHECK: host grant READY
 * (PUMP_GRANT_READY), permit freshly proven in the same binder call, no
 * child process, zero wake locks, exit 125 runtime_not_started. The same
 * stale fence also refused that run's first-use preflight (the pump's
 * bounded busy-retry then answered runtime_busy without invalidating, which
 * is why the older generation's facts stayed live and exec.shell stayed
 * advertised while every dispatch was refused).
 *
 * CONTRACT — every ORIGINAL refusal is preserved byte-for-byte; this adds
 * NO bypass, NO timer and NO fabricated release:
 *  * every fence read/write runs inside one monitor that serializes raises
 *    against settles, so no externally-sampled boolean can ever drive a
 *    clear (Main review r3-stop-fence-atomicity-20261023: an unlocked
 *    snapshot->set(false) is a TOCTOU, not a generation fence);
 *  * raise/queue-claim semantics are the ORIGINAL GLOBAL requestStop rule:
 *    the fence rises on every genuine global stop (null request), ONE queued
 *    global stopOwnedWork task drains at a time, and the requestStop tail
 *    clears the fence only while the engine provably owns nothing. A
 *    TARGET-scoped cancellation (closure A of a live B) must NOT call
 *    [beginStop]: the kernel routes it to its exact work only, so a sibling
 *    keeps its input/resize/admission rights while that target settles;
 *  * a FRESH stop (queued, or converging on live ownership) keeps refusing:
 *    [settleAfterOwnedWorkReleased] drops the fence ONLY when no stop is
 *    queued AND the engine's own live ownership reads empty — the same
 *    predicate the ORIGINAL finally applied, now also evaluated at the
 *    REAL completion event it previously missed;
 *  * the read-only `status` metadata path merely READS [isStopping]:
 *    metadata observation never drives lifecycle tidying here;
 *  * only real lifecycle events settle the fence (a drained stop, a drained
 *    queued request, a released owned work) — never an elapsed budget.
 *
 * JVM-testable by construction: no Android, no org.json — the same
 * authored-not-run discipline as the other runtimeapp pure decision cores.
 * [ownedWork] must itself be a lock-free live read (kernel request count +
 * operations' atomic lease/install state); it is only ever called inside
 * this monitor.
 */
internal class RuntimeStoppingFence(private val ownedWork: () -> Boolean) {
    private val monitor = Any()
    private var stopping = false
    private var stopQueued = false

    /** Pure read: the kernel `status` snapshot and every admission check. */
    val isStopping: Boolean get() = synchronized(monitor) { stopping }

    /** GLOBAL requestStop entry (ORIGINAL rule, monitor-atomic): raise the
     *  fence. TRUE is returned only to the raiser that claimed the single
     *  queued global stop slot and must therefore run the real stopOwnedWork
     *  drain. Target-scoped stops never call this. */
    fun beginStop(): Boolean = synchronized(monitor) {
        stopping = true
        if (stopQueued) false else { stopQueued = true; true }
    }

    /** requestStop tail (ORIGINAL rule, monitor-atomic): the fence may only
     *  stand while the engine actually owns work — a stop with nothing to
     *  stop never fences future admission. */
    fun settleAfterRaise() = synchronized(monitor) {
        if (!ownedWork()) stopping = false
    }

    /** Stop-executor finally (ORIGINAL rule, monitor-atomic): this drain's
     *  own completion; release the queue slot and settle on the live
     *  predicate. */
    fun stopDrained() = synchronized(monitor) {
        stopQueued = false
        if (!ownedWork()) stopping = false
    }

    /** Queued-request executor finally (ORIGINAL rule, monitor-atomic):
     *  this request's own admission count has already dropped; settle on
     *  the live predicate. */
    fun settleAfterRequestDrained() = synchronized(monitor) {
        if (!ownedWork()) stopping = false
    }

    /**
     * NEW convergence site — the REAL owned-work release note from the
     * operations lane ([LinuxRuntimeOperations.finish] after the actual
     * native hand-back succeeded and the held lease/running slot were
     * cleared), which is exactly where a stop that arrived during the drain
     * used to leave the fence raised forever (the candidate08 leak). The
     * fence falls ONLY when no stop is queued/converging AND the engine
     * provably owns nothing; because raise and settle share this monitor, a
     * NEWER stop can never be unwound by an older release — it is either
     * already visible here (queue slot held -> refuse) or raises after this
     * settle and stands on its own drain.
     */
    fun settleAfterOwnedWorkReleased() = synchronized(monitor) {
        if (!stopQueued && !ownedWork()) stopping = false
    }
}
