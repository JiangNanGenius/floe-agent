// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

/**
 * Terminal-state fence for one NSD service type.
 *
 * NsdManager may deliver a queued start/stop acknowledgement after discovery
 * has been stopped. Once a type reaches a terminal state (start failure, stop
 * failure or stopped), a late callback must not resurrect it or overwrite the
 * recorded failure. Shared network scope and the reported summary stay owned
 * by the discovery coroutine, not by these callbacks.
 */
internal class LanDiscoveryTypeState {
    internal data class Snapshot(
        val state: String,
        val errorCode: Int? = null,
        val errorText: String? = null,
    )

    private val lock = Any()
    private var state = "startPending"
    private var errorCode: Int? = null
    private var errorText: String? = null
    private var terminal = false

    internal fun snapshot(): Snapshot = synchronized(lock) {
        Snapshot(state, errorCode, errorText)
    }

    internal fun started() = transition("started", terminal = false)

    internal fun startedFailure(code: Int?, error: String?) =
        transition("startFailed", terminal = true, code = code, error = error)

    internal fun stopFailure(code: Int, error: String?) =
        transition("stopFailed", terminal = true, code = code, error = error)

    internal fun stopped() = transition("stopped", terminal = true)

    private fun transition(
        newState: String,
        terminal: Boolean,
        code: Int? = null,
        error: String? = null,
    ) {
        synchronized(lock) {
            if (this.terminal) return
            state = newState
            errorCode = code
            errorText = error
            if (terminal) this.terminal = true
        }
    }
}
