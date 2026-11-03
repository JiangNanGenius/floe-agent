// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C05 RDP controller and the presentation
// module. The actual FreeRDP transport, certificate decision and credential
// gateway live in FloeAndroidCore/FloeRDP and the App-owned controller; this
// file only wires the screen callbacks.

package com.floe.android.host.rdp

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.rdp.R
import com.floe.android.feature.rdp.RdpActions
import com.floe.android.feature.rdp.RdpDestinationUi
import com.floe.android.host.RuntimeHost

@Composable
internal fun C05RDPDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    sheetNavigation: (@Composable () -> Unit)? = null,
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.DeviceLocal,
            title = stringResource(R.string.rdp_title),
            description = stringResource(R.string.rdp_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val controller = host.c05Rdp
    val state by controller.state.collectAsState()
    LaunchedEffect(controller) { controller.enter() }
    RdpDestinationUi(
        sheetNavigation = sheetNavigation,
        state = state,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        actions = RdpActions(
            onRefresh = controller::refresh,
            onConnect = controller::connect,
            onTrust = controller::trust,
            onRejectTrust = controller::rejectTrust,
            onDisconnect = controller::disconnect,
            onReconnect = controller::reconnect,
            onReset = controller::reset,
            onDismissError = controller::dismissError,
            onVisible = controller::setVisible,
            onPointerMove = controller::pointerMove,
            onPointerButton = controller::pointerButton,
            onWheel = controller::wheel,
            onKey = controller::key,
            onNamedKey = controller::namedKey,
            onModifier = controller::modifier,
            onText = controller::text,
            onSubmit = controller::submit,
            onReleaseAll = controller::releaseAll,
            onSave = controller::saveProfile,
            onDeleteEndpoint = controller::deleteEndpoint,
            onDeleteHost = { profileID -> controller.deleteProfile(profileID, deleteHost = true) },
        ),
    )
}
