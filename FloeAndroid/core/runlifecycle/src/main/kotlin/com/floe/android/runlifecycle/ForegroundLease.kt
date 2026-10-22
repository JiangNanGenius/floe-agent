// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.os.IBinder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One live claim on the Core foreground service for one REAL operation.
 * The lease is held until the actual work ends: a remote shell
 * stop-request, an EOF, a run.cancel echo or a notification Stop press
 * does NOT close it — only the owner that awaited the real settlement
 * calls [close], and Main additionally holds per-remote-session leases
 * through actual release plus detached-cancellation reconciliation.
 *
 * Semantics (Main review hardened):
 *  * [runtimePermit] is the single opaque Binder token for the exact
 *    registration; leases attached to the SAME live operation share it —
 *    the runtime may validate through any holder and gets the same
 *    answer, because the answer is per-REGISTRATION (this exact owner
 *    generation) plus real confirmed foreground, never per-holder;
 *  * [close] is idempotent for THIS lease object. Every attached lease
 *    must close before the owned set changes (refcounted), so a second
 *    holder's early close can never silently revoke a still-owned first
 *    operation, and a stale object can never touch a newer
 *    same-id registration (generation check lives in the registry);
 *  * close() does not cancel work. It only releases SERVICE ownership.
 */
class ForegroundLease internal constructor(
    val operationID: String,
    val kind: OperationKind,
    val runtimePermit: IBinder,
    internal val ownerGeneration: Long,
) {
    private val closed = AtomicBoolean(false)

    /** True after THIS lease object released its claim (idempotent). */
    val isClosed: Boolean get() = closed.get()

    /** Releases this lease's claim on the registration. Idempotent: a
     *  second close on the same object is an honest no-op. Returns true
     *  only when this close removed the operation from the owned set
     *  (last lease closed), which callers never need to act on — the
     *  service stops itself when the set goes empty. */
    fun close(): Boolean {
        if (!closed.compareAndSet(false, true)) return false
        return RunForegroundState.release(operationID, ownerGeneration)
    }

    /** Honest permit-state read for Main's UI/diagnostics: true only for
     *  this exact still-owned registration AND confirmed real FGS. Never
     *  used by the Binder fast path itself (that reads the registry
     *  directly), only for reporting. */
    fun isActiveNow(): Boolean = RunForegroundState.permitActive(operationID, ownerGeneration)

    override fun toString(): String =
        "ForegroundLease(kind=$kind, operationID=$operationID, closed=${closed.get()})"
}
