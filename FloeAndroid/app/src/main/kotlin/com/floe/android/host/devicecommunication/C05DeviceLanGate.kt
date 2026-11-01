// SPDX-License-Identifier: MPL-2.0
//
// Narrow adapter over the EXISTING IntegrationsHostController
// LocalNetworkAccessBroker. Device TCP/Telnet does not create a second
// permission broker: the real Android 17 ACCESS_LOCAL_NETWORK read, dialog
// ownership and typed denial stay in the broker. Tests inject a fake gate.

package com.floe.android.host.devicecommunication

import com.floe.android.host.LocalNetworkAccessBroker

internal interface C05DeviceLanGate {
    fun isLocalLikely(endpoint: String): Boolean

    fun blocksConnectHop(endpoint: String): Boolean

    fun runExplicitAction(
        ownerID: String,
        endpoint: String,
        isCurrent: () -> Boolean,
        onDenied: (String) -> Unit,
        dispatch: () -> Unit,
    ): Boolean
}

internal class C05BrokerDeviceLanGate(
    private val broker: LocalNetworkAccessBroker,
) : C05DeviceLanGate {
    override fun isLocalLikely(endpoint: String): Boolean = broker.isLocalLikely(endpoint)

    override fun blocksConnectHop(endpoint: String): Boolean = broker.blocksConnectHop(endpoint)

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
