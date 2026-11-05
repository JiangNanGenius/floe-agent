// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.storage.StorageSettingsHost
import io.github.robinpcrd.cupertino.section.SectionItem

@Composable
internal fun StorageSettingsEntry() {
    var open by rememberSaveable { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(stringResource(R.string.storage_title)) {
            FloeValueRow(stringResource(R.string.storage_usage_and_cleanup), "") { open = true }
        }
    }
    if (open) {
        val app = LocalContext.current.applicationContext as FloeApplication
        val compact = LocalConfiguration.current.screenWidthDp < 600
        FloePageSheet(visible = true, onDismiss = { open = false },
            widthFraction = if (compact) 1f else .8f, heightFraction = .94f) {
            StorageSettingsDestination(app.storageSettings) { open = false }
        }
    }
}

@Composable
private fun StorageSettingsDestination(host: StorageSettingsHost, onDismiss: () -> Unit) {
    val state by host.state.collectAsState()
    val context = LocalContext.current
    LaunchedEffect(host) { host.refresh() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            FloeText(stringResource(R.string.storage_title), style = Floe.typography.title,
                modifier = Modifier.weight(1f))
            FloeToolbarIconButton(FloeIcons.ChevronDown, stringResource(R.string.done), onClick = onDismiss)
        }
        FloeDivider()
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(stringResource(R.string.storage_refresh), host::refresh, enabled = !state.busy)
                if (state.busy) FloeActivityIndicator()
            }
            com.floe.android.host.components.PreviewComponentSettings()
            com.floe.android.host.officecomponent.OfficeComponentSettings()
            com.floe.android.host.linux.LinuxSoftwareSettings()
            FloeSettingsSectionCard(stringResource(R.string.storage_usage)) {
                state.rows.forEach { row ->
                    val title = when (row.id) {
                        "appInstalled" -> R.string.storage_app_installed
                        "appData" -> R.string.storage_app_data
                        "appCache" -> R.string.storage_app_cache
                        "runtimeBase" -> R.string.storage_runtime_base
                        "runtimeEnvironments" -> R.string.storage_runtime_environments
                        "runtimeWorkspaces" -> R.string.storage_runtime_workspaces
                        "runtimeInstaller" -> R.string.storage_runtime_installer
                        "runtimeCache" -> R.string.storage_runtime_cache
                        else -> R.string.storage_runtime_other
                    }
                    val bytes = row.usage.allocatedBytes
                    val value = when {
                        bytes == null -> stringResource(R.string.storage_unknown)
                        !row.usage.complete -> stringResource(R.string.storage_partial_size, Formatter.formatFileSize(context, bytes))
                        else -> Formatter.formatFileSize(context, bytes)
                    }
                    FloeValueRow(stringResource(title), value)
                }
                if (state.runtimeState != "measured") {
                    SectionItem(title = {
                        FloeText(stringResource(if (state.runtimeState == "activeWork") R.string.storage_runtime_busy else R.string.storage_runtime_unknown),
                            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    })
                }
            }
            FloeText(stringResource(R.string.storage_measurement_note), style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel)
            FloeSettingsSectionCard(stringResource(R.string.storage_cleanup)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        FloeText(stringResource(R.string.storage_preserved), style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel)
                        FloeCapsuleAction(stringResource(R.string.storage_clean_unused), host::cleanUnusedTemporaries,
                            enabled = !state.busy)
                        state.cleanupState?.let { result ->
                            val message = when (result) {
                                "completed" -> if (state.reclaimedBytes == 0L) stringResource(R.string.storage_nothing_to_clean)
                                    else stringResource(R.string.storage_cleaned_size,
                                        state.reclaimedBytes?.let { Formatter.formatFileSize(context, it) } ?: stringResource(R.string.storage_unknown))
                                "activeWork", "quiescenceUnknown" -> stringResource(R.string.storage_cleanup_busy)
                                "inventoryIncomplete" -> stringResource(R.string.storage_cleanup_retained)
                                else -> stringResource(R.string.storage_cleanup_unknown)
                            }
                            FloeText(message, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                        }
                    }
                })
            }
        }
    }
}
