// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

/**
 * Real file-transaction IO gate for a workspace grant (Main lifetime review
 * 2026-10-22): every authenticated binder transaction that may touch Core
 * files or native session state ENTERS here before dispatch and EXITS after
 * the actual operation returns. `close()` fences new entries atomically,
 * requests native cancellation, and then WAITS for already-entered file/
 * native operations to return before closing the session table — so the
 * pump releasing its owned lease can never overlap a still-running export.
 *
 * Deliberate properties:
 *  * no fake zero counter, no timeout release: `awaitDrained()` waits for
 *    the ACTUAL entered-and-unreturned transaction count to reach zero;
 *    liveness comes from the native cancellation path (abort sets the
 *    engine's frame-boundary abort flag; every bounded bridge wait inside
 *    the engine has its own fail-closed timeout), not from abandoning the
 *    drain here;
 *  * the fence flip and the inflight gauge share one monitor, so
 *    `begin() after fence` is refused deterministically (never counted);
 *  * callers may NOT hold the monitor across real work: begin/end wrap
 *    dispatch; waiting uses Object.wait which releases the monitor.
 */
class WorkspaceIOLatch {

    private val lock = java.util.concurrent.locks.ReentrantLock()
    private val drained = lock.newCondition()
    private var inflight = 0
    private var fenced = false

    /** True when the transaction may proceed (entered). False after the
     *  fence: the caller must answer `grantClosed` without dispatching. */
    fun begin(): Boolean {
        lock.lock()
        try {
            if (fenced) return false
            inflight += 1
            return true
        } finally {
            lock.unlock()
        }
    }

    /** Marks one entered transaction as actually returned. */
    fun end() {
        lock.lock()
        try {
            check(inflight > 0) { "unbalanced IO gate exit" }
            inflight -= 1
            if (inflight == 0) drained.signalAll()
        } finally {
            lock.unlock()
        }
    }

    /** Atomic fence: after this returns true, no NEW transaction can enter
     *  and any already-entered transaction is still draining. Returns false
     *  when another closer already fenced (that caller owns the drain). */
    fun fence(): Boolean {
        lock.lock()
        try {
            if (fenced) return false
            fenced = true
            return true
        } finally {
            lock.unlock()
        }
    }

    val isFenced: Boolean
        get() {
            lock.lock()
            try {
                return fenced
            } finally {
                lock.unlock()
            }
        }

    /** Number of entered-and-unreturned transactions (audit only; the drain
     *  itself uses the condition, never this as a readiness guess). */
    val inflightCount: Int
        get() {
            lock.lock()
            try {
                return inflight
            } finally {
                lock.unlock()
            }
        }

    /** Wait until every already-entered transaction has returned. No
     *  timeout: returning early would release the grant while real file IO
     *  continues. Interruption restores the flag and still waits (the
     *  caller's cancellation semantics belong to the native abort path). */
    fun awaitDrained() {
        var reassert = false
        lock.lock()
        try {
            while (inflight > 0) {
                try {
                    drained.await()
                } catch (_: InterruptedException) {
                    reassert = true
                }
            }
        } finally {
            lock.unlock()
        }
        if (reassert) Thread.currentThread().interrupt()
    }
}
