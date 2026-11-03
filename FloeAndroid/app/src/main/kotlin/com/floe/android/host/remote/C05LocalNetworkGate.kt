// SPDX-License-Identifier: MPL-2.0
//
// Narrow adapter over the EXISTING IntegrationsHostController
// LocalNetworkAccessBroker. C05 does not create a second permission broker:
// the real Android 17 ACCESS_LOCAL_NETWORK platform read, dialog ownership
// and typed denial remain in the broker. Tests inject a fake gate.

package com.floe.android.host.remote

import com.floe.android.host.LocalNetworkAccessBroker

internal interface C05LocalNetworkGate {
    fun isLocalLikely(endpoint: String): Boolean

    fun runExplicitAction(
        ownerID: String,
        endpoint: String,
        isCurrent: () -> Boolean,
        onDenied: (String) -> Unit,
        dispatch: () -> Unit,
    ): Boolean
}

internal class C05BrokerLocalNetworkGate(
    private val broker: LocalNetworkAccessBroker,
) : C05LocalNetworkGate {
    override fun isLocalLikely(endpoint: String): Boolean = broker.isLocalLikely(endpoint)

    override fun runExplicitAction(
        ownerID: String,
        endpoint: String,
        isCurrent: () -> Boolean,
        onDenied: (String) -> Unit,
        dispatch: () -> Unit,
    ): Boolean = broker.runExplicitAction(
        ownerID = ownerID,
        endpoint = endpoint,
        isCurrent = isCurrent,
        onDenied = onDenied,
        dispatch = dispatch,
    )
}
