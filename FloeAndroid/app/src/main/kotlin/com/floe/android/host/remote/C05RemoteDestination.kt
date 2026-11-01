// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C05 controller and the presentation module.
// The actual SSH transport, credential gateway and profile persistence live
// in FloeSSH/FloeAndroidCore and the App-owned controller; this file only
// wires the screen callbacks.

package com.floe.android.host.remote

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.remote.RemoteDestinationUi
import com.floe.android.feature.remote.RemoteVncActions
import com.floe.android.feature.remote.R
import com.floe.android.host.RuntimeHost

@Composable
internal fun C05RemoteDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.Terminal,
            title = stringResource(R.string.remote_hosts_title),
            description = stringResource(R.string.remote_hosts_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val controller = host.c05Remote
    val state by controller.state.collectAsState()
    LaunchedEffect(controller) { controller.enter() }
    RemoteDestinationUi(
        state = state,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        onRefresh = controller::refresh,
        onSave = controller::saveProfile,
        onDelete = controller::deleteProfile,
        onConnect = controller::connect,
        onApproveChallenge = controller::approveChallenge,
        onDismissError = controller::dismissError,
        onCloseSession = controller::closeSession,
        onOpenTunnel = controller::openTunnel,
        onCloseTunnel = controller::closeTunnel,
        onStartExec = controller::startExec,
        onCancelExec = controller::cancelExec,
        onReleaseExec = controller::releaseExec,
        onTerminalVisible = controller::setTerminalVisible,
        vncActions = RemoteVncActions(
            onConnect = { profileID, endpointID -> controller.connectVNC(profileID, endpointID) },
            onClose = controller::disconnectVNC,
            onVisible = controller::setVncVisible,
            onPointerMove = controller::vncPointerMove,
            onPointerButton = controller::vncPointerButton,
            onWheel = controller::vncWheel,
            onKey = controller::vncKey,
            onText = controller::vncText,
            onReleaseAll = controller::vncReleaseAll,
            onSaveHost = controller::saveVNCOnlyHost,
            onSaveEndpoint = controller::saveVncEndpoint,
            onDeleteEndpoint = controller::deleteVncEndpoint,
        ),
    )
}
