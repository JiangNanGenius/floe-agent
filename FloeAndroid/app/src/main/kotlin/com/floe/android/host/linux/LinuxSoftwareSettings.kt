// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.text.format.Formatter
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.*

@Composable
internal fun LinuxSoftwareSettings() {
    val context = LocalContext.current
    val app = context.applicationContext as? FloeApplication ?: return
    val service = app.runtimeHost?.linuxDesktop ?: return
    val state by service.state.collectAsState()
    var stop by remember { mutableStateOf(false) }
    var remove by remember { mutableStateOf<String?>(null) }
    FloeSettingsSectionCard(title = stringResource(R.string.linux_software_title)) {
        if (state.phase == "running") {
            FloeSectionRow(title = { FloeText(stringResource(R.string.linux_software_size_hint),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) })
            FloeActionRow(stringResource(R.string.storage_refresh), service::refreshSoftware)
            if (state.softwareOperation != null) FloeSectionRow(title = {
                FloeText(stringResource(R.string.linux_software_busy), color = Floe.colors.secondaryLabel)
            })
            for (row in state.software) {
                FloeValueRow(row.application, if (row.installed && row.packageBytes != null)
                    Formatter.formatFileSize(context, row.packageBytes) else stringResource(R.string.linux_software_not_installed))
                if (row.installed) FloeActionRow(stringResource(R.string.linux_software_remove, row.application),
                    onClick = { remove = row.application }, enabled = state.softwareOperation == null)
                else FloeActionRow(stringResource(R.string.linux_software_install, row.application),
                    onClick = { service.application(row.application, true) }, enabled = state.softwareOperation == null)
            }
            if (state.failure != null) FloeSectionRow(title = {
                FloeText(stringResource(R.string.linux_desktop_operation_failed), color = Floe.colors.secondaryLabel)
            })
            FloeActionRow(stringResource(R.string.linux_software_clean_cache), service::cleanSoftwareCache,
                enabled = state.softwareOperation == null)
            FloeActionRow(stringResource(R.string.linux_desktop_stop), onClick = { stop = true })
        } else if (state.phase in setOf("save_pending", "close_pending")) {
            FloeSectionRow(title = { FloeText(stringResource(R.string.linux_desktop_save_pending)) })
            FloeActionRow(stringResource(R.string.linux_desktop_retry_return), service::stop)
        } else FloeSectionRow(title = { FloeText(stringResource(R.string.linux_software_start_first),
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) })
    }
    if (stop) FloeConfirmDialog(title = stringResource(R.string.linux_desktop_stop),
        message = stringResource(R.string.linux_desktop_stop_notice),
        confirmLabel = stringResource(R.string.linux_desktop_stop), dismissLabel = stringResource(R.string.cancel),
        onConfirm = { stop = false; service.stop() }, onDismiss = { stop = false })
    remove?.let { appName -> FloeConfirmDialog(title = stringResource(R.string.linux_software_remove, appName),
        message = stringResource(R.string.linux_software_remove_notice),
        confirmLabel = stringResource(R.string.preview_components_uninstall), dismissLabel = stringResource(R.string.cancel),
        onConfirm = { remove = null; service.uninstallSoftware(appName) }, onDismiss = { remove = null }) }
}
