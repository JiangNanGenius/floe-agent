// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.floe.android.DeviceAccessPairingCode
import com.floe.android.DeviceAccessSettingsPage

/**
 * The attached FULL settings presentation. The page itself stays stateless; the
 * only local state is the RAM-only pairing code field (never saveable).
 */
@Composable
internal fun DeviceAccessSettingsRoute(host: DeviceAccessHost) {
    val state by host.presentation.collectAsState()
    var pairingCode by remember { mutableStateOf("") }
    // The host projection is a StateFlow that only changes on real events.
    // Entering this page is itself the event that must expose the CURRENT
    // live run (a run may have started while Settings was closed). This is
    // read-only: it never arms, resumes or changes any grant.
    LaunchedEffect(host) { host.onPresentationVisible() }
    DeviceAccessSettingsPage(
        state = state,
        callbacks = host.callbacks,
        pairingCode = pairingCode,
        onPairingCodeChange = { pairingCode = DeviceAccessPairingCode.sanitize(it) },
    )
}
