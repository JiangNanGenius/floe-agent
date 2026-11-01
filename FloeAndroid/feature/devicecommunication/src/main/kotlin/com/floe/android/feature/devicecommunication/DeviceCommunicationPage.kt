// SPDX-License-Identifier: MPL-2.0
//
// C05 Devices screen. Presentation only: the App-owned controller performs
// every socket/GATT/USB/permission effect. Text consoles reuse the EXISTING
// :feature:terminal renderer; the screen never decodes a transport itself.

package com.floe.android.feature.devicecommunication

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.core.devicecommunication.BleScanResult
import com.floe.android.core.devicecommunication.DeviceParity
import com.floe.android.core.devicecommunication.DeviceSessionSnapshot
import com.floe.android.core.devicecommunication.UsbDeviceInfo
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.G04TerminalView
import com.floe.android.feature.terminal.TerminalTransport
import com.floe.android.feature.terminal.TerminalViewSettings

@Composable
fun DeviceCommunicationDestinationUi(
    state: DeviceScreenState,
    terminalEngine: G04TerminalEngine?,
    callbacks: DeviceCallbacks,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    var pendingDelete by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.devices_title),
            navigation = {
                if (compact || showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.devices_open_sidebar),
                        onClick = if (compact) onOpenDrawer else onExpandSidebar,
                    )
                }
            },
            actions = {
                if (state.busy != null) {
                    FloeActivityIndicator()
                    Spacer(Modifier.width(6.dp))
                }
                FloeCircleButton(
                    icon = FloeIcons.Plus,
                    contentDescription = stringResource(R.string.devices_add),
                    onClick = {
                        callbacks.onDraftChange(
                            DeviceDraft(tab = state.tab),
                        )
                    },
                )
                FloeCircleButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.devices_refresh),
                    onClick = callbacks.onRefresh,
                )
            },
            showHairline = true,
        )
        state.error?.let { problem ->
            DeviceErrorBanner(problem = problem, onDismiss = callbacks.onDismissError)
        }
        state.notice?.let { notice ->
            DeviceNoticeBanner(notice)
        }

        val active = state.activeSession
        when {
            state.loading && !state.coreReady -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) { FloeActivityIndicator() }

            !state.coreReady -> FloeUnavailableView(
                icon = FloeIcons.DeviceLocal,
                title = stringResource(R.string.devices_title),
                description = stringResource(
                    if (state.coreUpdateRequired) R.string.devices_error_runtime
                    else R.string.devices_unavailable,
                ),
            )

            active != null && terminalEngine != null -> DeviceConsolePage(
                state = state,
                session = active,
                engine = terminalEngine,
                callbacks = callbacks,
            )

            active != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator()
            }

            else -> DeviceBrowsePage(
                state = state,
                callbacks = callbacks,
                onDeleteProfile = { pendingDelete = it },
            )
        }
    }
    val deleting = pendingDelete
    if (deleting != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.devices_delete_title),
            message = stringResource(R.string.devices_delete_message),
            confirmLabel = stringResource(R.string.devices_delete),
            dismissLabel = stringResource(R.string.devices_cancel),
            onConfirm = {
                callbacks.onDeleteProfile(deleting)
                pendingDelete = null
            },
            onDismiss = { pendingDelete = null },
        )
    }
}

@Composable
private fun DeviceBrowsePage(
    state: DeviceScreenState,
    callbacks: DeviceCallbacks,
    onDeleteProfile: (String) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item { PermissionBanners(state, callbacks) }
        item {
            FloeSegmented(
                options = DeviceTab.entries.map { deviceTabLabel(it) },
                selectedIndex = DeviceTab.entries.indexOf(state.tab),
                onSelect = { index ->
                    val tab = DeviceTab.entries.getOrNull(index) ?: return@FloeSegmented
                    val draft = state.draft.copy(
                        tab = tab,
                        port = if (tab == DeviceTab.TCP || tab == DeviceTab.TELNET) {
                            state.draft.port.ifBlank { "23" }
                        } else {
                            state.draft.port
                        },
                    )
                    callbacks.onSelectTab(tab)
                    callbacks.onDraftChange(draft)
                },
            )
        }
        item { DeviceDraftForm(state, callbacks) }
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloePrimaryAction(
                    label = stringResource(R.string.devices_connect),
                    onClick = callbacks.onConnect,
                    enabled = state.busy == null,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.devices_save),
                    onClick = callbacks.onSaveConnection,
                    enabled = state.busy == null && state.tab != DeviceTab.USB,
                )
            }
        }
        item {
            FloeText(
                stringResource(R.string.devices_local_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        when (state.tab) {
            DeviceTab.BLE -> {
                item { BleSection(state, callbacks) }
            }
            DeviceTab.USB -> {
                item { UsbSection(state, callbacks) }
            }
            else -> Unit
        }
        item { FloeDivider() }
        item {
            FloeText(
                stringResource(R.string.devices_saved),
                style = Floe.typography.section,
                color = Floe.colors.label,
            )
        }
        if (state.profiles.isEmpty()) {
            item {
                FloeText(
                    stringResource(R.string.devices_saved_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        } else {
            items(state.profiles, key = { it.id }) { profile ->
                ProfileCard(
                    profile = profile,
                    callbacks = callbacks,
                    onDelete = { onDeleteProfile(profile.id) },
                )
            }
        }
        if (state.sessions.isNotEmpty()) {
            item { FloeDivider() }
            item {
                FloeText(
                    stringResource(R.string.devices_sessions),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
            }
            items(state.sessions, key = { it.id }) { session ->
                SessionRow(session, onOpen = { callbacks.onOpenSession(session.id) })
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun PermissionBanners(state: DeviceScreenState, callbacks: DeviceCallbacks) {
    val requirements = state.bleRequirements
    if (requirements != null && requirements.supported &&
        requirements.missingPermissions.isNotEmpty()
    ) {
        BannerCard(
            text = stringResource(R.string.devices_permission_ble),
            actionLabel = stringResource(R.string.devices_usb_allow),
            onAction = { callbacks.onRequestBlePermissions(requirements.missingPermissions) },
        )
    }
    if (requirements != null && requirements.supported && !requirements.enabled) {
        BannerCard(
            text = stringResource(R.string.devices_bluetooth_off),
            actionLabel = stringResource(R.string.devices_enable_bluetooth),
            onAction = callbacks.onEnableBluetooth,
        )
    }
    if (state.usbHostSupported == false) {
        FloeText(
            stringResource(R.string.devices_usb_unsupported),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun DeviceDraftForm(state: DeviceScreenState, callbacks: DeviceCallbacks) {
    val draft = state.draft
    fun update(transform: (DeviceDraft) -> DeviceDraft) =
        callbacks.onDraftChange(transform(draft))

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloePlainFormField(
            label = stringResource(R.string.devices_display_name),
            value = draft.displayName,
            onValueChange = { value -> update { it.copy(displayName = value) } },
        )
        when (state.tab) {
            DeviceTab.TCP, DeviceTab.TELNET -> {
                FloePlainFormField(
                    label = stringResource(R.string.devices_host),
                    value = draft.host,
                    onValueChange = { value -> update { it.copy(host = value) } },
                )
                FloePlainFormField(
                    label = stringResource(R.string.devices_port),
                    value = draft.port,
                    onValueChange = { value ->
                        update { it.copy(port = value.filter(Char::isDigit).take(5)) }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
            }
            DeviceTab.BLE -> {
                BleScanRow(state, callbacks)
                FloePlainFormField(
                    label = stringResource(R.string.devices_ble_address),
                    value = draft.peripheralAddress,
                    onValueChange = { value -> update { it.copy(peripheralAddress = value) } },
                    monospaced = true,
                )
                FloePlainFormField(
                    label = stringResource(R.string.devices_ble_service),
                    value = draft.serviceUuid,
                    onValueChange = { value -> update { it.copy(serviceUuid = value) } },
                    monospaced = true,
                )
                FloePlainFormField(
                    label = stringResource(R.string.devices_ble_write),
                    value = draft.writeUuid,
                    onValueChange = { value -> update { it.copy(writeUuid = value) } },
                    monospaced = true,
                )
                FloePlainFormField(
                    label = stringResource(R.string.devices_ble_notify),
                    value = draft.notifyUuid,
                    onValueChange = { value -> update { it.copy(notifyUuid = value) } },
                    monospaced = true,
                )
                FloePlainFormField(
                    label = stringResource(R.string.devices_ble_read),
                    value = draft.readUuid,
                    onValueChange = { value -> update { it.copy(readUuid = value) } },
                    monospaced = true,
                )
                FloeText(
                    stringResource(R.string.devices_ble_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            DeviceTab.USB -> {
                FloePlainFormField(
                    label = stringResource(R.string.devices_baud),
                    value = draft.baudRate,
                    onValueChange = { value ->
                        update { it.copy(baudRate = value.filter(Char::isDigit).take(7)) }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                FloeText(
                    stringResource(R.string.devices_data_bits),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeSegmented(
                    options = listOf("5", "6", "7", "8"),
                    selectedIndex = (draft.dataBits - 5).coerceIn(0, 3),
                    onSelect = { index -> update { it.copy(dataBits = 5 + index) } },
                )
                FloeText(
                    stringResource(R.string.devices_stop_bits),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeSegmented(
                    options = listOf("1", "2"),
                    selectedIndex = (draft.stopBits - 1).coerceIn(0, 1),
                    onSelect = { index -> update { it.copy(stopBits = 1 + index) } },
                )
                ParityRow(draft.parity) { parity -> update { it.copy(parity = parity) } }
            }
        }
    }
}

@Composable
private fun ParityRow(selected: DeviceParity, onSelect: (DeviceParity) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FloeText(
            stringResource(R.string.devices_parity),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            DeviceParity.entries.forEach { parity ->
                FloeCapsuleAction(
                    label = stringResource(
                        when (parity) {
                            DeviceParity.NONE -> R.string.devices_parity_none
                            DeviceParity.ODD -> R.string.devices_parity_odd
                            DeviceParity.EVEN -> R.string.devices_parity_even
                            DeviceParity.MARK -> R.string.devices_parity_mark
                            DeviceParity.SPACE -> R.string.devices_parity_space
                        },
                    ),
                    onClick = { onSelect(parity) },
                    showHairline = parity == selected,
                    tint = if (parity == selected) Floe.colors.accent else Floe.colors.secondaryLabel,
                )
            }
        }
    }
}

@Composable
private fun BleScanRow(state: DeviceScreenState, callbacks: DeviceCallbacks) {
    val requirements = state.bleRequirements
    val canScan = state.busy == null && requirements?.enabled == true &&
        requirements.missingPermissions.isEmpty()
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeCapsuleAction(
            label = stringResource(
                if (state.busy == "scan") R.string.devices_scanning else R.string.devices_scan,
            ),
            onClick = callbacks.onScan,
            enabled = canScan,
        )
        if (state.bleScan.isEmpty() && requirements?.supported == true) {
            FloeText(
                stringResource(R.string.devices_scan_empty),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun BleSection(state: DeviceScreenState, callbacks: DeviceCallbacks) {
    if (state.bleScan.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        state.bleScan.take(12).forEach { result ->
            BleResultRow(result) {
                callbacks.onDraftChange(
                    state.draft.copy(peripheralAddress = result.address),
                )
            }
        }
    }
}

@Composable
private fun BleResultRow(result: BleScanResult, onSelect: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onSelect)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            FloeText(
                result.name ?: result.address,
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            FloeText(
                "${result.address} · ${result.rssi} dBm",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        FloeBadgePill(stringResource(R.string.devices_open), FloeBadgeTone.ACCENT)
    }
}

@Composable
private fun UsbSection(state: DeviceScreenState, callbacks: DeviceCallbacks) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeCapsuleAction(
            label = stringResource(R.string.devices_usb_refresh),
            onClick = callbacks.onRefreshUsb,
            enabled = state.busy == null && state.usbHostSupported != false,
        )
    }
    if (state.usbDevices.isEmpty()) {
        FloeText(
            stringResource(R.string.devices_usb_empty),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        state.usbDevices.forEach { device ->
            UsbDeviceRow(
                device = device,
                selected = state.draft.usbDeviceKey == device.key,
                onSelect = { callbacks.onDraftChange(state.draft.copy(usbDeviceKey = device.key)) },
                onAllow = { callbacks.onRequestUsbPermission(device.key) },
            )
        }
    }
}

@Composable
private fun UsbDeviceRow(
    device: UsbDeviceInfo,
    selected: Boolean,
    onSelect: () -> Unit,
    onAllow: () -> Unit,
) {
    val label = device.productName
        ?: "${device.vendorId.toString(16)}:${device.productId.toString(16)}"
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onSelect)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    label,
                    style = Floe.typography.body,
                    color = if (selected) Floe.colors.accent else Floe.colors.label,
                )
                FloeText(
                    buildString {
                        append(device.driverName ?: "USB serial")
                        append(" · ")
                        append(device.vendorId.toString(16).padStart(4, '0'))
                        append(":")
                        append(device.productId.toString(16).padStart(4, '0'))
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (device.permissionGranted) {
                FloeBadgePill(stringResource(R.string.devices_usb_ready), FloeBadgeTone.SUCCESS)
            } else {
                FloeCapsuleAction(
                    label = stringResource(R.string.devices_usb_allow),
                    onClick = onAllow,
                )
            }
        }
        if (device.driverName == null) {
            FloeText(
                stringResource(R.string.devices_usb_unknown_driver),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun ProfileCard(
    profile: DeviceProfileUi,
    callbacks: DeviceCallbacks,
    onDelete: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.sectionCardSurface)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                profile.displayName,
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.devices_delete),
                onClick = onDelete,
                tint = Floe.colors.destructive,
            )
        }
        profile.connections.forEach { connection ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable { callbacks.onOpenConnection(connection) }
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    FloeText(
                        connection.displayName,
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                    )
                    FloeText(
                        connectionEndpoint(connection),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.devices_open),
                    onClick = { callbacks.onOpenConnection(connection) },
                )
            }
        }
    }
}

@Composable
private fun connectionEndpoint(connection: DeviceConnectionUi): String = when (connection.tab) {
    DeviceTab.TCP, DeviceTab.TELNET ->
        "${connection.host.orEmpty()}:${connection.port ?: ""}"
    DeviceTab.BLE -> connection.peripheralAddress.orEmpty()
    DeviceTab.USB -> stringResource(R.string.devices_tabs_usb)
}

@Composable
private fun SessionRow(session: DeviceSessionSnapshot, onOpen: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClick = onOpen)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            FloeText(
                session.endpoint,
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            FloeText(
                "${session.protocol.wireName.uppercase()} · ${
                    stringResource(R.string.devices_bytes, session.bytesIn, session.bytesOut)
                }",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        FloeBadgePill(
            deviceStateLabel(session.state.wireName),
            if (session.state.wireName == "connected") FloeBadgeTone.SUCCESS else FloeBadgeTone.SECONDARY,
        )
    }
}

@Composable
private fun DeviceConsolePage(
    state: DeviceScreenState,
    session: DeviceSessionSnapshot,
    engine: G04TerminalEngine,
    callbacks: DeviceCallbacks,
) {
    var sendText by rememberSaveable(session.id) { mutableStateOf("") }
    var appendNewline by rememberSaveable(session.id) { mutableStateOf(true) }
    val transport = remember(engine, callbacks) {
        object : TerminalTransport {
            override fun write(bytes: ByteArray) = callbacks.onConsoleInput(bytes)
            override fun resize(columns: Int, rows: Int) = callbacks.onConsoleResize(columns, rows)
        }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    session.endpoint,
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                )
                FloeText(
                    stringResource(R.string.devices_bytes, session.bytesIn, session.bytesOut),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            FloeBadgePill(
                deviceStateLabel(session.state.wireName),
                if (session.state.wireName == "connected") {
                    FloeBadgeTone.SUCCESS
                } else {
                    FloeBadgeTone.SECONDARY
                },
            )
            FloeCapsuleAction(
                label = stringResource(R.string.devices_close),
                onClick = callbacks.onCloseSession,
                tint = Floe.colors.destructive,
            )
        }
        if (state.sessions.size > 1) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                state.sessions.forEach { item ->
                    FloeCapsuleAction(
                        label = item.endpoint.take(28),
                        onClick = { callbacks.onOpenSession(item.id) },
                        showHairline = item.id == session.id,
                        tint = if (item.id == session.id) Floe.colors.accent else Floe.colors.secondaryLabel,
                    )
                }
            }
        }
        FloeDivider()
        G04TerminalView(
            engine = engine,
            transport = transport,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            settings = TerminalViewSettings(keyboardVisible = true),
            statusLine = "${session.endpoint} · ${deviceStateLabel(session.state.wireName)}",
        )
        FloeDivider()
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloePlainFormField(
                label = stringResource(R.string.devices_send_hint),
                value = sendText,
                onValueChange = { sendText = it },
                modifier = Modifier.weight(1f),
                monospaced = true,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.devices_send),
                onClick = {
                    if (sendText.isNotEmpty()) {
                        callbacks.onSend(sendText, appendNewline)
                        sendText = ""
                    }
                },
                enabled = session.state.wireName == "connected",
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeText(
                stringResource(R.string.devices_append_newline),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeCapsuleAction(
                label = if (appendNewline) "✓" else "—",
                onClick = { appendNewline = !appendNewline },
                showHairline = true,
            )
        }
    }
}

@Composable
private fun DeviceErrorBanner(problem: DeviceProblemUi, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.destructive.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            deviceErrorText(problem),
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
            modifier = Modifier.weight(1f),
        )
        FloeCircleButton(
            icon = FloeIcons.Xmark,
            contentDescription = stringResource(R.string.devices_cancel),
            onClick = onDismiss,
            hairline = false,
            background = Floe.colors.destructive.copy(alpha = 0.12f),
            tint = Floe.colors.destructive,
        )
    }
}

@Composable
private fun DeviceNoticeBanner(notice: String) {
    FloeText(
        notice,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun BannerCard(text: String, actionLabel: String, onAction: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(label = actionLabel, onClick = onAction)
    }
}
