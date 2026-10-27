// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Exactly-one-terminal-callback gate for the print adapter lifecycle.
 *
 * Why it exists (Main review 2026-10-27): the AOSP
 * `PrintFileDocumentAdapter` reference can deliver TWO terminal callbacks
 * for one request — its `doInBackground` reports `onWriteFailed` on an
 * IOException and `onPostExecute` then still reports `onWriteFinished`;
 * a cancellation racing the copy can report failure twice. The framework
 * tolerates it poorly and the semantics are wrong. Every onLayout/onWrite
 * invocation here owns ONE gate; the first terminal wins and every later
 * attempt is ignored (and observable in diagnostics, never silent-then-
 * contradictory).
 *
 * Pure JVM: callbacks are plain functions, injected by the caller (which
 * hops to the main thread itself), so the rule is unit-testable without
 * any Android types.
 */
class OfficePdfOnceCallback(kind: String) {

    enum class Terminal { FINISHED, FAILED, CANCELLED }

    private val gate = AtomicBoolean(false)
    private val winner = AtomicReference<Terminal?>(null)

    /** Non-null once a terminal callback fired; later calls return false. */
    fun fired(): Terminal? = winner.get()

    /**
     * Fire [action] exactly once when no terminal has fired yet. Returns
     * true only for the winning call. [terminal] names which terminal this
     * is (finished/failed/cancelled) for diagnostics.
     */
    fun fire(terminal: Terminal, action: () -> Unit): Boolean {
        if (!gate.compareAndSet(false, true)) return false
        winner.set(terminal)
        runCatching(action)
        return true
    }

    /** True while no terminal fired (used by cancellation listeners). */
    fun pending(): Boolean = !gate.get()
}
