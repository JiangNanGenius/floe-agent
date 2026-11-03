// SPDX-License-Identifier: MPL-2.0
//
// Narrow adapter over the EXISTING IntegrationsHostController
// LocalNetworkAccessBroker. This does not create a second permission broker:
// the real Android 37 ACCESS_LOCAL_NETWORK platform read, dialog ownership
// and typed denial remain in the broker. Public endpoints are never gated.

package com.floe.android.host.mail

import com.floe.android.host.LocalNetworkAccessBroker
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal fun interface C06MailLanGate {
    /** true = proceed; false = not granted / not available. */
    suspend fun authorize(host: String, port: Int): Boolean
}

internal class C06BrokerMailLanGate(
    private val brokerProvider: () -> LocalNetworkAccessBroker?,
) : C06MailLanGate {
    override suspend fun authorize(host: String, port: Int): Boolean {
        val broker = brokerProvider() ?: return true
        val literal = if (host.contains(':')) "[$host]" else host
        val endpoint = "mail://$literal:$port"
        if (!broker.isLocalLikely(endpoint)) return true
        return withContext(Dispatchers.Main.immediate) {
            withTimeoutOrNull(40_000) {
                suspendCancellableCoroutine { continuation ->
                    val started = broker.runExplicitAction(
                        ownerID = "mail:$literal:$port",
                        endpoint = endpoint,
                        isCurrent = { continuation.isActive },
                        onDenied = {
                            if (continuation.isActive) continuation.resume(false)
                        },
                        dispatch = {
                            if (continuation.isActive) continuation.resume(true)
                        },
                    )
                    if (!started && continuation.isActive) continuation.resume(false)
                }
            } ?: false
        }
    }
}
