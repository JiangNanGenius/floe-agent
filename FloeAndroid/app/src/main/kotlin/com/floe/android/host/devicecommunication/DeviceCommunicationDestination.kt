// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C05 device controller and the presentation
// module. The real engine, permissions, USB PendingIntent and terminal pumps
// stay in the App-owned controller; this file only wires screen callbacks and
// the two explicit platform permission intents.

package com.floe.android.host.devicecommunication

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.devicecommunication.DeviceCallbacks
import com.floe.android.feature.devicecommunication.DeviceCommunicationDestinationUi
import com.floe.android.feature.devicecommunication.R
import com.floe.android.host.RuntimeHost

@Composable
internal fun C05DeviceCommunicationDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.DeviceLocal,
            title = stringResource(R.string.devices_title),
            description = stringResource(R.string.devices_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val controller = host.c05Devices
    val state by controller.state.collectAsState()
    val terminal by controller.terminal.collectAsState()

    val blePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { result ->
        controller.onBlePermissionResult(result.values.all { it })
    }
    val enableBluetoothLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        controller.onBluetoothEnableResult(result.resultCode == Activity.RESULT_OK)
    }
    LaunchedEffect(controller) { controller.enter() }
    LaunchedEffect(state.permissionRequest) {
        val request = state.permissionRequest ?: return@LaunchedEffect
        if (request.permissions.isNotEmpty()) {
            blePermissionLauncher.launch(request.permissions.toTypedArray())
        }
    }

    DeviceCommunicationDestinationUi(
        state = state,
        terminalEngine = terminal,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        callbacks = DeviceCallbacks(
            onSelectTab = controller::selectTab,
            onDraftChange = controller::updateDraft,
            onRefresh = controller::refresh,
            onSaveConnection = controller::saveConnection,
            onDeleteProfile = controller::deleteProfile,
            onOpenProfile = controller::openProfile,
            onOpenConnection = controller::openConnection,
            onOpenSession = controller::openSession,
            onConnect = controller::connect,
            onCloseSession = controller::closeSession,
            onSend = controller::send,
            onConsoleInput = controller::consoleInput,
            onConsoleResize = controller::consoleResize,
            onScan = controller::scan,
            onRefreshUsb = controller::refreshUsb,
            onRequestUsbPermission = controller::requestUsbPermission,
            onRequestBlePermissions = { _ -> controller.requestBlePermissions() },
            onEnableBluetooth = {
                enableBluetoothLauncher.launch(
                    Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                )
            },
            onDismissError = controller::dismissError,
        ),
    )
}
