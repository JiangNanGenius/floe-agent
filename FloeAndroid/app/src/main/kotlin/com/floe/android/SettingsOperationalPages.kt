// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.RuntimeHost
import com.floe.android.feature.desktopassist.DesktopAssistSettingsPage

/** Configuration is reached from Settings. The existing operational service
 * surfaces open as secondary sheets without replacing the task/Notes route. */
@Composable
internal fun RemoteOperationalSettingsPage(host: RuntimeHost?) {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Box(Modifier.padding(horizontal = 16.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.settings_connections)) {
            FloeValueRow(stringResource(com.floe.android.feature.remote.R.string.remote_hosts_title), "") { open = "remote" }
            FloeValueRow(stringResource(com.floe.android.feature.rdp.R.string.rdp_title), "") { open = "rdp" }
        }
        }
        if (host != null) {
            LaunchedEffect(host.desktopAssist) { host.desktopAssist.ensureLoaded() }
            val state by host.desktopAssist.state.collectAsState()
            DesktopAssistSettingsPage(state = state, actions = host.desktopAssist)
        }
    }
    open?.let { SettingsOperationalSheet(it, host) { open = null } }
}

@Composable
internal fun SystemOperationalSettingsPage(host: RuntimeHost?) {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.settings_services_devices)) {
            FloeValueRow(stringResource(com.floe.android.feature.mail.R.string.mail_title), "") { open = "mail" }
            FloeValueRow(stringResource(com.floe.android.feature.calendar.R.string.calendar_title), "") { open = "calendar" }
            FloeValueRow(stringResource(com.floe.android.feature.devicecommunication.R.string.devices_title), "") { open = "devices" }
            FloeValueRow(stringResource(com.floe.android.feature.systemservices.R.string.system_services_title), "") { open = "system" }
        }
        Spacer(Modifier.height(16.dp))
        FloeSettingsSectionCard(title = stringResource(R.string.network_workbench)) {
            FloeValueRow(stringResource(R.string.settings_network_diagnostics), "") { open = "network" }
        }
    }
    open?.let { SettingsOperationalSheet(it, host) { open = null } }
}

@Composable
private fun SettingsOperationalSheet(kind: String, host: RuntimeHost?, onDismiss: () -> Unit) {
    val compact = LocalConfiguration.current.screenWidthDp < 600
    val navigation: @Composable () -> Unit = {
        FloeToolbarIconButton(
            icon = FloeIcons.ChevronDown,
            contentDescription = stringResource(R.string.done),
            onClick = onDismiss,
        )
    }
    FloePageSheet(
        visible = true, onDismiss = onDismiss,
        widthFraction = if (compact) 1f else .88f,
        heightFraction = .94f,
    ) {
        // Finite window; each original feature retains its own scroll owner,
        // permission launchers, cancellation and real native/storage backend.
        when (kind) {
            "remote" -> com.floe.android.host.remote.C05RemoteDestination(host, compact, false, {}, {}, navigation)
            "rdp" -> com.floe.android.host.rdp.C05RDPDestination(host, compact, false, {}, {}, navigation)
            "mail" -> com.floe.android.host.mail.C06MailDestination(host, compact, false, {}, {}, navigation)
            "calendar" -> com.floe.android.host.calendar.C06CalendarDestination(host, compact, false, {}, {}, navigation)
            "devices" -> com.floe.android.host.devicecommunication.C05DeviceCommunicationDestination(host, compact, false, {}, {}, navigation)
            "system" -> com.floe.android.host.systemservices.C06SystemServicesDestination(host, compact, false, {}, {}, navigation)
            "network" -> NetworkWorkbenchDestination(host, compact, false, {}, navigation)
        }
    }
}
