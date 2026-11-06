// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.components

import android.text.format.Formatter
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.floe.android.R
import com.floe.android.design.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun PreviewComponentSettings() {
    val context = LocalContext.current
    val store = remember(context) { PreviewComponentStore.get(context) }
    val state by store.state.collectAsState()
    LaunchedEffect(store) { withContext(Dispatchers.IO) { store.refresh() } }
    FloeSettingsSectionCard(title = stringResource(R.string.preview_components_title)) {
        FloeValueRow(stringResource(R.string.preview_components_cad),
            Formatter.formatFileSize(context, state.installedBytes))
        FloeSectionRow(title = { FloeText(stringResource(when {
            state.cancelling -> R.string.preview_components_cancelling
            state.installing -> R.string.preview_components_installing
            state.inUse -> R.string.preview_components_in_use
            state.installed -> R.string.preview_components_offline
            else -> R.string.preview_components_on_demand
        }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) })
        if (state.installing) FloeValueRow(stringResource(R.string.preview_components_progress),
            "${Formatter.formatFileSize(context, state.downloadedBytes)} / ${Formatter.formatFileSize(context, state.totalBytes)}")
        if (state.failure != null) FloeSectionRow(title = {
            FloeText(stringResource(when (state.failure) {
                "component_restore_pending" -> R.string.preview_components_restore_pending
                "component_cleanup_pending" -> R.string.preview_components_cleanup_pending
                "component_remove_failed" -> R.string.preview_components_remove_failed
                "component_in_use" -> R.string.preview_components_in_use
                else -> R.string.preview_components_failed
            }))
        })
        if (state.installing) FloeActionRow(label = stringResource(R.string.cancel),
            enabled = !state.cancelling, onClick = store::cancelInstall)
        if (state.installed || state.installedBytes > 0) FloeActionRow(label = stringResource(
            if (state.installed) R.string.preview_components_uninstall else R.string.preview_components_clear_cache),
            enabled = !state.installing && !state.inUse, onClick = store::requestUninstallCad)
        if (!state.installed) FloeActionRow(label = stringResource(R.string.preview_components_install), enabled = !state.installing,
            onClick = store::requestInstallCad)
    }
}
