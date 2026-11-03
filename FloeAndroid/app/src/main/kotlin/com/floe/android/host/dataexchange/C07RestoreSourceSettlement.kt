// SPDX-License-Identifier: MPL-2.0
//
// Exactly-once settlement of the C07 restore source reference.
//
// Entry (share/VIEW) retains its own read reference, then hands the URI to the
// EXISTING Data Exchange review owner. `beginRestore` may refuse
// synchronously (busy/reviewing/runtime unavailable), the coroutine body may
// never start because the scope is already cancelled, and stage cleanup in a
// `finally` may itself throw. In every case the source reference must be
// released exactly once after THIS consumer actually ends; a timer, a
// body-only `finally`, or a second callback would race the entry's lease
// transfer and can double-release the broker handle.
package com.floe.android.host.dataexchange

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Job

internal class C07RestoreSourceSettlement(
    private val onSettled: (() -> Unit)?,
) {
    private val settled = AtomicBoolean(false)

    /**
     * Settles immediately; used by every synchronous refusal/failure path.
     * Idempotent, so retries or a later job completion cannot release twice.
     */
    fun settle() {
        val callback = onSettled ?: return
        if (settled.compareAndSet(false, true)) {
            // The callback releases a URI grant/lease. Its own failure must
            // not change the restore result or make the settlement retryable.
            runCatching { callback() }
        }
    }

    /**
     * Settles exactly once when [job] completes. Jobs cancelled before their
     * body starts still complete, and a throwing `finally` still completes
     * the job, so this covers both cases without polling or a timer. If the
     * job is already complete, `invokeOnCompletion` invokes the handler
     * immediately.
     */
    fun attach(job: Job) {
        if (onSettled == null) return
        job.invokeOnCompletion { settle() }
    }
}
