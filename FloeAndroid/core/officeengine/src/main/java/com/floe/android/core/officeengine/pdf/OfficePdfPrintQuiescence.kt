// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The REAL print-session lifetime coordinator (Main lane 14 repair):
 * the delivered [OfficePdfPrintAdapter.onFinish] closed the BASE-owned
 * descriptor and fired the caller's lease release BEFORE shutting/draining
 * the worker that owns every copy pass. A pass already running holds its own
 * dup and can still read and write AFTER that release, and a queued pass can
 * later emit a false finish — so the source owner's lease could be dropped
 * while I/O was still active.
 *
 * The corrected order this class enforces (and the adapter uses for real):
 *  1. [finish] first RETIRES the session: [retired] fences all future work,
 *     and passes entering the worker after that point settle through
 *     [runOrSettleCancel] with the CANCELLED terminal — never a false
 *     finish, never a double terminal;
 *  2. the owner release [release] runs as a finalizer SUBMITTED TO THE SAME
 *     single-worker executor that owned every pass, so it executes only
 *     after every already-queued pass has returned from its own `finally`
 *     (each pass closes its dup and destination stream there);
 *  3. the caller thread (framework main) NEVER blocks joining I/O — the
 *     release is serialized, not awaited;
 *  4. the release runs EXACTLY ONCE per session even if the framework (or a
 *     non-admitted flow fallback) calls finish more than once;
 *  5. if the owned executor is already shut down and cannot accept the
 *     finalizer, the release runs inline at the finish call — the only
 *     honest way to never strand the caller's lease;
 *  6. if a pass can never settle (stuck I/O), the owner is RETAINED —
 *     never a fake close, never an auto-undo of an admitted framework job.
 *
 * Pure JVM (no Android types), so the production object itself is directly
 * unit-testable with a real executor, real [java.util.concurrent.CountDownLatch]
 * and the real [OfficePdfOnceCallback] gates.
 */
class OfficePdfPrintQuiescence(
    /**
     * Submits the finalizer to the executor that ALREADY owns every I/O
     * pass (the adapter's single worker). Throws [RejectedExecutionException]
     * once that executor is shut down.
     */
    private val submitFinalizer: (Runnable) -> Unit,
) {

    private val retiredFlag = AtomicBoolean(false)
    private val finishStarted = AtomicBoolean(false)
    private val releasedOnce = AtomicBoolean(false)

    /** True once [finish] has retired the session: no new pass may run or terminal-finish. */
    fun retired(): Boolean = retiredFlag.get()

    /**
     * One retirement + quiescent release per session. The first call fences
     * future work and serializes [release] on the owned I/O worker after
     * every already-queued pass; later calls (framework finish plus a flow
     * fallback on the same adapter) are ignored.
     */
    fun finish(release: () -> Unit) {
        if (!finishStarted.compareAndSet(false, true)) return
        retiredFlag.set(true)
        val finalizer = Runnable {
            if (releasedOnce.compareAndSet(false, true)) runCatching { release() }
        }
        try {
            submitFinalizer(finalizer)
        } catch (_: RejectedExecutionException) {
            // Worker already shut (nothing can still be queued for THIS
            // session): settle the owner inline rather than stranding it.
            finalizer.run()
        }
    }

    /**
     * Every real adapter pass (layout or write) enters the worker through
     * this exact helper. Rules:
     *  - if the request's [gate] has already fired (cancellation listener
     *    won), the pass touches nothing — exactly-one-terminal holds;
     *  - if the session is [retired], the pass settles [gate] with the
     *    CANCELLED terminal via [settleCancelled] and runs NO work: a late
     *    or queued pass can never emit a false finish after retirement;
     *  - otherwise [work] runs exactly as submitted.
     * Returns true only when [work] actually ran.
     */
    fun runOrSettleCancel(
        gate: OfficePdfOnceCallback,
        work: () -> Unit,
        settleCancelled: () -> Unit,
    ): Boolean {
        if (!gate.pending()) return false
        if (retired()) {
            gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { settleCancelled() }
            return false
        }
        work()
        return true
    }
}
