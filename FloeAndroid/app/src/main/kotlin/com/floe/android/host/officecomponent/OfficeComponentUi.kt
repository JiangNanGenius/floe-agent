// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.app.Activity
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.*

@Composable
internal fun OfficeComponentSettings() {
    val context = LocalContext.current
    val app = context.applicationContext as? FloeApplication ?: return
    val service = app.officeComponent
    val state by service.state.collectAsState()
    OfficeComponentSystemConfirmation(service)
    LaunchedEffect(service) { service.refresh() }
    FloeSettingsSectionCard(title = stringResource(R.string.office_module_title)) {
        if (state.phase == "installed") {
            if (state.installedBytes > 0) FloeValueRow(stringResource(R.string.preview_components_cad_size),
                Formatter.formatFileSize(context, state.installedBytes))
            FloeSectionRow(title = { FloeText(stringResource(R.string.preview_components_offline)) })
            FloeActionRow(stringResource(R.string.preview_components_uninstall), service::requestUninstall,
                enabled = state.removable)
        } else if (state.phase in setOf("downloading", "cancelling", "clearing", "installing", "removing", "remove_pending")) {
            FloeSectionRow(title = { ComponentProgress(state) })
            if (state.phase !in setOf("remove_pending", "cancelling", "clearing")) FloeActionRow(stringResource(R.string.cancel), service::cancel)
        } else {
            FloeSectionRow(title = { FloeText(stringResource(R.string.preview_components_on_demand)) })
            if (state.failure != null) FloeSectionRow(title = { FloeText(stringResource(R.string.preview_components_failed)) })
            FloeActionRow(stringResource(R.string.preview_components_install), service::requestInstall)
        }
        if (state.cachedBytes > 0) {
            FloeValueRow(stringResource(R.string.preview_components_download_cache),
                Formatter.formatFileSize(context, state.cachedBytes))
            FloeActionRow(stringResource(R.string.preview_components_clear_cache),
                service::requestClearCache, enabled = !state.working)
        }
    }
}

@Composable
internal fun OfficeComponentDialog(visible: Boolean, onCancel: () -> Unit) {
    val context = LocalContext.current
    val service = (context.applicationContext as? FloeApplication)?.officeComponent ?: return
    val state by service.state.collectAsState()
    FloeActionSheet(visible = visible, onDismiss = onCancel, maxCardWidth = 460.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(R.string.office_module_title), style = Floe.typography.toolbarTitle)
            ComponentProgress(state)
            if (state.phase in setOf("failed", "missing")) FloeCapsuleButton(stringResource(R.string.retry),
                onClick = service::requestInstall)
            if (state.phase in setOf("permission", "confirm", "play_confirm")) {
                val activity = context as? Activity
                FloeCapsuleButton(stringResource(R.string.office_component_continue), onClick = {
                    if (activity != null) service.confirm(activity)
                })
            }
            FloeCapsuleButton(stringResource(R.string.cancel), onClick = { service.cancel(); onCancel() })
        }
    }
}

@Composable
private fun ComponentProgress(state: OfficeComponentState) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeText(stringResource(when (state.phase) {
            "downloading" -> R.string.office_component_downloading
            "cancelling" -> R.string.preview_components_cancelling
            "clearing" -> R.string.preview_components_clearing
            "installing" -> R.string.office_component_installing
            "permission", "confirm", "play_confirm" -> R.string.office_component_confirmation
            "removing", "remove_pending" -> R.string.office_component_removing
            "failed" -> R.string.preview_components_failed
            else -> R.string.preview_components_on_demand
        }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        if (state.totalBytes > 0) {
            val context = LocalContext.current
            FloeText("${Formatter.formatFileSize(context, state.bytes)} / ${Formatter.formatFileSize(context, state.totalBytes)}",
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

@Composable
internal fun OfficeComponentSystemConfirmation(service: OfficeComponentController) {
    val state by service.state.collectAsState()
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        (context as? Activity)?.let(service::onForeground)
    }
    LaunchedEffect(state.pendingIntent) {
        state.pendingIntent?.let { runCatching { launcher.launch(it) } }
    }
    LaunchedEffect(state.phase) {
        if (state.phase == "play_confirm") (context as? Activity)?.let(service::confirm)
    }
}
