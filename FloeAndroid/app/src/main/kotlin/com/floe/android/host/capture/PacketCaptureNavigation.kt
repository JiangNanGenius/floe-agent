// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.content.Intent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One-shot, same-app notification route. The Intent carries no path, session
 * id or capture content; it only asks the existing shell to reveal the network
 * workbench, which then reads the live service-owned capture state.
 */
object PacketCaptureNavigation {
    private val mutableRequests = MutableStateFlow<Long?>(null)
    val requests: StateFlow<Long?> = mutableRequests.asStateFlow()
    private var lastNonce = 0L

    fun submitFromIntent(intent: Intent?, ownPackage: String): Boolean {
        val incoming = intent ?: return false
        if (incoming.action != Intent.ACTION_MAIN) return false
        if (incoming.component?.packageName != ownPackage) return false
        if (incoming.getStringExtra(PacketCaptureIntents.EXTRA_DESTINATION) !=
            PacketCaptureIntents.DESTINATION_NETWORK_CAPTURE
        ) return false
        mutableRequests.value = ++lastNonce
        return true
    }

    fun consume(request: Long?) {
        if (request != null && mutableRequests.value == request) mutableRequests.value = null
    }
}
