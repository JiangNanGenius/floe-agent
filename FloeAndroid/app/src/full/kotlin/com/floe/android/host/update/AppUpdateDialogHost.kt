// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)
package com.floe.android.host.update

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

/**
 * The single window for every self-update state: new version, download
 * progress, verification, delta reconstruction/fallback, install readiness,
 * quiescence wait, permission handoff, system confirmation and the terminal
 * result. Nothing here starts a check, download or install on recomposition;
 * every action is a user click routed to the Application-owned controller.
 */
@Composable
internal fun AppUpdateDialogHost() {
    val controller = AppUpdateFeature.controller() ?: return
    val ui by controller.ui.collectAsState()
    if (!ui.dialogVisible) return
    val context = LocalContext.current
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(
        visible = true,
        onDismiss = { controller.dismissDialog() },
        widthFraction = if (wide) 0.52f else 1f,
        heightFraction = if (wide) 0.62f else 0.78f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
        topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset,
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.app_update_title),
                    style = Floe.typography.title,
                    color = Floe.colors.label,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.done),
                    onClick = { controller.dismissDialog() },
                )
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when {
                    ui.install !is AppInstallState.Idle -> InstallContent(controller, ui, context)
                    ui.download is AppDownloadState.InProgress -> ProgressContent(controller, ui)
                    ui.download is AppDownloadState.Applying -> BusyContent(
                        text = stringResource(R.string.app_update_applying_delta),
                    )
                    ui.download is AppDownloadState.Verifying -> BusyContent(
                        text = stringResource(R.string.app_update_verifying),
                    )
                    ui.download is AppDownloadState.Ready -> ReadyContent(controller, ui)
                    ui.download is AppDownloadState.DeltaFallback -> DeltaFallbackContent(controller, ui)
                    ui.download is AppDownloadState.Paused ||
                        ui.download is AppDownloadState.Failed -> DownloadFailedContent(controller, ui)
                    ui.check is AppCheckState.UpdateAvailable -> NewVersionContent(controller, ui)
                    ui.check is AppCheckState.Checking -> BusyContent(
                        text = stringResource(R.string.app_update_checking),
                    )
                    else -> ResultContent(controller, ui)
                }
            }
        }
    }
}

@Composable
private fun NewVersionContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    val release = (ui.check as AppCheckState.UpdateAvailable).release
    FloeText(
        stringResource(R.string.app_update_new_version, release.version.toString()),
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label,
    )
    val summary = release.summary
    if (summary.isNotEmpty()) {
        FloeText(
            stringResource(R.string.app_update_release_notes),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeText(summary, style = Floe.typography.metadata, color = Floe.colors.label)
    }
    if (release.delta != null) {
        FloeText(
            stringResource(R.string.app_update_delta_offer),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
    FloeText(
        stringResource(R.string.app_update_system_note),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_update_now),
            onClick = { controller.startDownload() },
            tint = Floe.colors.accent,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_later),
            onClick = { controller.dismissDialog() },
        )
    }
}

@Composable
private fun ProgressContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    val state = ui.download as AppDownloadState.InProgress
    FloeText(
        if (state.mode == DownloadMode.DELTA) {
            stringResource(R.string.app_update_delta_downloading, state.versionName)
        } else {
            stringResource(R.string.app_update_downloading, state.versionName)
        },
        style = Floe.typography.body,
        color = Floe.colors.label,
    )
    val total = state.total
    val fraction = if (total > 0L) {
        (state.received.toFloat() / total.toFloat()).coerceIn(0f, 1f)
    } else {
        0f
    }
    Box(
        Modifier
            .fillMaxWidth()
            .height(6.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(Floe.colors.chromeSurface),
    ) {
        Box(
            Modifier
                .fillMaxWidth(fraction)
                .height(6.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(Floe.colors.accent),
        )
    }
    if (total > 0L) {
        FloeText(
            stringResource(
                R.string.app_update_progress,
                state.received / 1_048_576L,
                total / 1_048_576L,
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    } else {
        FloeText(
            stringResource(R.string.app_update_progress_unknown, state.received / 1_048_576L),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
    FloeCapsuleAction(
        label = stringResource(R.string.cancel),
        onClick = { controller.cancelDownload() },
    )
}

@Composable
private fun ReadyContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    val state = ui.download as AppDownloadState.Ready
    FloeText(
        stringResource(R.string.app_update_ready),
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label,
    )
    FloeText(
        stringResource(R.string.app_update_ready_version, state.versionName),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    if (state.mode == DownloadMode.DELTA) {
        FloeText(
            stringResource(R.string.app_update_delta_ready),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
    FloeText(
        stringResource(R.string.app_update_system_note),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_install),
            onClick = { controller.installNow(force = false) },
            tint = Floe.colors.accent,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_discard),
            onClick = { controller.discardDownload() },
        )
    }
}

@Composable
private fun DeltaFallbackContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    val fallback = ui.download as AppDownloadState.DeltaFallback
    FloeText(
        stringResource(R.string.app_update_delta_fallback_title),
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label,
    )
    FloeText(
        AppUpdateCopy.deltaFallback(fallback.reason),
        style = Floe.typography.body,
        color = Floe.colors.label,
    )
    if (fallback.fullBytes > 0L) {
        FloeText(
            stringResource(R.string.app_update_full_size, fallback.fullBytes / 1_048_576L),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_download_full),
            onClick = { controller.startFullDownload() },
            tint = Floe.colors.accent,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_discard),
            onClick = { controller.discardDownload() },
        )
    }
}

@Composable
private fun DownloadFailedContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    val download = ui.download
    val (message, resumable) = when (download) {
        is AppDownloadState.Paused -> stringResource(R.string.app_update_download_paused) to true
        is AppDownloadState.Failed -> AppUpdateCopy.downloadFailure(download.kind) to download.resumable
        else -> stringResource(R.string.app_update_download_failed) to true
    }
    FloeText(message, style = Floe.typography.body, color = Floe.colors.label)
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeCapsuleAction(
            label = stringResource(if (resumable) R.string.app_update_resume else R.string.retry),
            onClick = {
                if (resumable) controller.resumeDownload() else controller.startDownload()
            },
            tint = Floe.colors.accent,
        )
        FloeCapsuleAction(
            label = stringResource(R.string.app_update_discard),
            onClick = { controller.discardDownload() },
        )
    }
}

@Composable
private fun InstallContent(controller: AppUpdateController, ui: AppUpdateUiState, context: android.content.Context) {
    when (val install = ui.install) {
        is AppInstallState.Preparing -> {
            BusyContent(text = stringResource(R.string.app_update_preparing))
        }
        is AppInstallState.WaitingForJobs -> {
            FloeText(
                stringResource(R.string.app_update_waiting_jobs),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            if (ui.blockingKinds.isNotEmpty()) {
                FloeText(
                    stringResource(
                        R.string.app_update_waiting_jobs_kinds,
                        AppUpdateCopy.blockingKindLabels(ui.blockingKinds),
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            FloeText(
                stringResource(R.string.app_update_install_kills_app),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_install_now),
                    onClick = { controller.installNow(force = true) },
                    tint = Floe.colors.accent,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_later),
                    onClick = { controller.cancelInstallWait() },
                )
            }
        }
        is AppInstallState.NeedsPermission -> {
            FloeText(
                if (install.deniedOnce) {
                    stringResource(R.string.app_update_permission_denied)
                } else {
                    stringResource(R.string.app_update_permission)
                },
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            FloeText(
                if (install.settingsUnavailable) {
                    stringResource(R.string.app_update_permission_settings_unavailable)
                } else {
                    stringResource(R.string.app_update_permission_detail)
                },
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            // Android 13+ may hide "Allow from this source" behind restricted
            // settings for a sideloaded install; the App-info route is the
            // documented way to unlock it, so it is always offered here.
            FloeText(
                stringResource(R.string.app_update_permission_restricted),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_open_permission),
                    onClick = {
                        if (!launchSystemIntent(context, install.intent)) {
                            controller.onPermissionIntentUnavailable()
                        }
                    },
                    tint = Floe.colors.accent,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_open_app_info),
                    onClick = {
                        if (!launchSystemIntent(context, install.appInfoIntent)) {
                            controller.onPermissionIntentUnavailable()
                        }
                    },
                )
            }
        }
        is AppInstallState.Confirming -> {
            FloeText(
                stringResource(R.string.app_update_confirm_system),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_confirm_now),
                    onClick = {
                        controller.consumeSystemIntent()?.let { intent ->
                            if (!launchSystemIntent(context, intent)) {
                                controller.onConfirmationUnavailable()
                            }
                        }
                    },
                    tint = Floe.colors.accent,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_cancel_pending),
                    onClick = { controller.cancelPendingInstall() },
                )
            }
        }
        is AppInstallState.AwaitingSystem -> {
            BusyContent(text = stringResource(R.string.app_update_waiting_system))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_check_status),
                    onClick = { controller.onApplicationForeground() },
                )
                // Explicit recovery for a session whose system confirmation
                // was lost across process death: abandon THIS owned session;
                // never start a duplicate install.
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_cancel_pending),
                    onClick = { controller.cancelPendingInstall() },
                )
            }
        }
        is AppInstallState.Committing -> BusyContent(text = stringResource(R.string.app_update_committing))
        is AppInstallState.Succeeded -> {
            FloeText(
                stringResource(R.string.app_update_installed),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.done),
                onClick = { controller.clearInstallSucceeded() },
            )
        }
        is AppInstallState.Failed -> {
            FloeText(
                AppUpdateCopy.installFailure(install.kind),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (ui.pendingInstall) {
                    // The owned session may have crossed Binder; a retry must
                    // not submit a second install. Offer explicit abandonment.
                    FloeCapsuleAction(
                        label = stringResource(R.string.app_update_cancel_pending),
                        onClick = { controller.cancelPendingInstall() },
                        tint = Floe.colors.accent,
                    )
                } else if (ui.download is AppDownloadState.Ready) {
                    // The verified APK was deliberately kept: retry from the
                    // same bytes instead of downloading hundreds of MB again.
                    FloeCapsuleAction(
                        label = stringResource(R.string.app_update_retry_install),
                        onClick = { controller.retryInstall() },
                        tint = Floe.colors.accent,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.app_update_download_full),
                        onClick = { controller.startFullDownload() },
                        tint = Floe.colors.accent,
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.done),
                    onClick = { controller.dismissInstallFailure() },
                )
            }
        }
        is AppInstallState.Idle -> Unit
    }
}

@Composable
private fun ResultContent(controller: AppUpdateController, ui: AppUpdateUiState) {
    FloeText(
        AppUpdateCopy.status(ui),
        style = Floe.typography.body,
        color = Floe.colors.label,
    )
    FloeCapsuleAction(
        label = stringResource(R.string.app_update_check_now),
        onClick = { controller.checkNow() },
    )
}

@Composable
private fun BusyContent(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeActivityIndicator()
        FloeText(text, style = Floe.typography.body, color = Floe.colors.label)
    }
}
