// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.cadcomponent

import android.app.Activity
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeValueRow
import com.floe.android.design.Floe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Storage-management row: occupancy, honest phase label and the same real
 * actions as the Office component (install/cancel/uninstall). */
@Composable
internal fun CadComponentSettings() {
    val context = LocalContext.current
    val app = context.applicationContext as? FloeApplication ?: return
    val service = app.cadComponent
    val state by service.state.collectAsState()
    CadComponentSystemConfirmation(service)
    val scope = rememberCoroutineScope()
    // Upgraded devices can carry the legacy app-managed viewer cache from
    // releases up to Alpha45. It is preserved on disk, never counts as this
    // component (the split is the only installed truth) and shows here as a
    // separate reclaimable row until the user clears it explicitly.
    var legacyBytes by remember { mutableLongStateOf(-1L) }
    LaunchedEffect(service) {
        legacyBytes = withContext(Dispatchers.IO) { LegacyCadCache.cacheBytes(context) }
    }
    LaunchedEffect(service) { withContext(Dispatchers.IO) { service.refresh() } }
    FloeSettingsSectionCard(title = stringResource(R.string.cad_module_title)) {
        if (state.phase == "installed") {
            if (state.installedBytes > 0) {
                FloeValueRow(
                    stringResource(R.string.preview_components_cad_size),
                    Formatter.formatFileSize(context, state.installedBytes))
            }
            FloeSectionRow(title = {
                FloeText(stringResource(R.string.preview_components_offline))
            })
            FloeActionRow(
                stringResource(R.string.preview_components_uninstall),
                service::requestUninstall,
                enabled = state.removable)
        } else if (state.phase in setOf(
                "downloading", "cancelling", "clearing", "installing", "removing", "remove_pending")) {
            FloeSectionRow(title = { CadComponentProgress(state) })
            if (state.phase !in setOf("remove_pending", "cancelling", "clearing")) {
                FloeActionRow(stringResource(R.string.cancel), service::cancel)
            }
        } else {
            FloeSectionRow(title = {
                FloeText(stringResource(R.string.preview_components_on_demand))
            })
            if (state.failure != null) {
                FloeSectionRow(title = {
                    FloeText(stringResource(R.string.preview_components_failed))
                })
            }
            FloeActionRow(
                stringResource(R.string.preview_components_install),
                service::requestInstall)
        }
        if (state.cachedBytes > 0) {
            FloeValueRow(stringResource(R.string.preview_components_download_cache),
                Formatter.formatFileSize(context, state.cachedBytes))
            FloeActionRow(stringResource(R.string.preview_components_clear_cache),
                service::requestClearCache, enabled = !state.working)
        }
        if (legacyBytes > 0) {
            FloeValueRow(
                stringResource(R.string.cad_legacy_cache),
                Formatter.formatFileSize(context, legacyBytes))
            FloeActionRow(
                stringResource(R.string.preview_components_clear_cache),
                enabled = state.removable && !state.working,
                onClick = {
                    scope.launch {
                        val remaining = withContext(Dispatchers.IO) {
                            val cleared = LegacyCadCache.clear(context)
                            if (cleared) 0L else LegacyCadCache.cacheBytes(context)
                        }
                        legacyBytes = remaining
                    }
                })
        }
    }
}

/** First-use sheet shown by the CAD destination while the signed component
 * installs. Honest phases only: progress from the delivery backend, a failed
 * phase is never announced installed, and cancel leaves the file untouched. */
@Composable
internal fun CadComponentInstallSheet(
    visible: Boolean,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
) {
    val context = LocalContext.current
    val app = context.applicationContext as? FloeApplication ?: return
    val service = app.cadComponent
    val state by service.state.collectAsState()
    CadComponentSystemConfirmation(service)
    FloeActionSheet(visible = visible, onDismiss = {
        service.cancel()
        onCancel()
    }, maxCardWidth = 460.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(R.string.cad_module_title),
                style = Floe.typography.toolbarTitle)
            CadComponentProgress(state)
            if (state.phase in setOf("failed", "missing", "cancelled")) {
                FloeCapsuleButton(stringResource(R.string.retry), onClick = onRetry)
            }
            if (state.phase in setOf("permission", "confirm", "play_confirm")) {
                val activity = context as? Activity
                FloeCapsuleButton(stringResource(R.string.office_component_continue),
                    onClick = {
                        if (activity != null) service.confirm(activity)
                    })
            }
            FloeCapsuleButton(stringResource(R.string.cancel),
                enabled = state.phase != "cancelling",
                onClick = {
                    service.cancel()
                    onCancel()
                })
        }
    }
}

@Composable
internal fun CadComponentProgress(state: CadComponentState) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeText(stringResource(when (state.phase) {
            "downloading" -> R.string.cad_component_downloading
            "cancelling" -> R.string.preview_components_cancelling
            "cancelled" -> R.string.preview_components_cancelled
            "clearing" -> R.string.preview_components_clearing
            "installing" -> R.string.cad_component_installing
            "permission", "confirm", "play_confirm" -> R.string.cad_component_confirmation
            "removing", "remove_pending" -> R.string.cad_component_removing
            "failed" -> R.string.preview_components_failed
            else -> R.string.preview_components_on_demand
        }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        if (state.totalBytes > 0) {
            val context = LocalContext.current
            FloeText(
                "${Formatter.formatFileSize(context, state.bytes)} / " +
                    Formatter.formatFileSize(context, state.totalBytes),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel)
        }
    }
}

/** Mirrors the Office confirmation wiring: the Full-channel system install
 * PendingIntent launches through a remembered result contract, and the Play
 * confirmation dialog is requested from a resumed activity. */
@Composable
internal fun CadComponentSystemConfirmation(service: CadComponentController) {
    val state by service.state.collectAsState()
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()) {
        (context as? Activity)?.let(service::onForeground)
    }
    LaunchedEffect(state.pendingIntent) {
        state.pendingIntent?.let { runCatching { launcher.launch(it) } }
    }
    LaunchedEffect(state.phase) {
        if (state.phase == "play_confirm") {
            (context as? Activity)?.let(service::confirm)
        }
    }
}
