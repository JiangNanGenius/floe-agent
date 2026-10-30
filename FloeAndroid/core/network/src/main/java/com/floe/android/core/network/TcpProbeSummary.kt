// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

/**
 * Pure TCP-probe completion/limitation policy shared with AndroidTcpProbe.
 * The timeout sentence is emitted only when the budget really ended before
 * every resolved address was attempted; a successful first connect must never
 * carry a trailing timeout limitation just because later addresses were not
 * tried.
 */
internal object TcpProbeSummary {
    fun status(
        connected: Boolean,
        attempted: Int,
        sawTimeout: Boolean,
        sawRefused: Boolean,
        sawError: Boolean,
    ): ObservationStatus = when {
        connected -> ObservationStatus.OK
        attempted == 0 -> ObservationStatus.TIMEOUT
        sawTimeout -> ObservationStatus.TIMEOUT
        sawRefused && !sawError -> ObservationStatus.OK
        else -> ObservationStatus.ERROR
    }

    fun limitations(
        connected: Boolean,
        attempted: Int,
        resolvedCount: Int,
    ): List<String> {
        val limitations = ArrayList<String>()
        limitations += "A TCP connect result proves only that the handshake completed or failed; it is not an application-protocol or TLS health check."
        limitations += "No payload is sent and no response is read."
        if (!connected && attempted < resolvedCount) {
            limitations += "The timeout budget ended before every resolved address was attempted."
        }
        if (connected && attempted > 1) {
            limitations += "Earlier address attempts are retained; a later address succeeded."
        }
        return limitations
    }
}
