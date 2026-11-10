// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
package com.floe.android.host.update

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.host.linux.LocalRuntimeSettingsCard

/**
 * The single window for every self-update state: new version, download
 * progress, verification, delta reconstruction/fallback, install readiness,
 * quiescence wait, permission handoff, system confirmation and the terminal
 * result. Nothing here starts a check, download or install on recomposition;
 * every action is a user click routed to the Application-owned controller.
 *
 * Actions are pinned beneath the scrolling body: long known-issue lists and
 * release notes scroll inside the body while Update / Download full /
 * Install / Cancel stay reachable without swiping past them. Short receipt
 * and busy states size the sheet to their content instead of stretching a
 * mostly blank surface to the long-form height.
 */
@Composable
internal fun AppUpdateDialogHost() {
    val controller = AppUpdateFeature.controller() ?: return
    val ui by controller.ui.collectAsState()
    if (!ui.dialogVisible) return
    val context = LocalContext.current
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    val compact = compactSheet(ui)
    FloePageSheet(
        visible = true,
        onDismiss = { controller.dismissDialog() },
        widthFraction = if (wide) 0.52f else 1f,
        heightFraction = if (compact) {
            if (wide) 0.34f else 0.30f
        } else {
            if (wide) 0.62f else 0.78f
        },
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
                    ui.install !is AppInstallState.Idle -> InstallContent(ui)
                    ui.download is AppDownloadState.InProgress -> ProgressContent(ui)
                    ui.download is AppDownloadState.Applying -> BusyContent(
                        text = stringResource(R.string.app_update_applying_delta),
                    )
                    ui.download is AppDownloadState.Verifying -> BusyContent(
                        text = stringResource(R.string.app_update_verifying),
                    )
                    ui.download is AppDownloadState.Ready -> ReadyContent(ui)
                    ui.download is AppDownloadState.DeltaFallback -> DeltaFallbackContent(ui)
                    ui.download is AppDownloadState.Paused ||
                        ui.download is AppDownloadState.Failed -> DownloadFailedContent(ui)
                    ui.check is AppCheckState.UpdateAvailable -> NewVersionContent(ui)
                    ui.check is AppCheckState.Checking -> BusyContent(
                        text = stringResource(R.string.app_update_checking),
                    )
                    else -> ResultContent(ui)
                }
            }
            // Actions stay pinned under the scrolling notes so the primary
            // control remains visible however long the known-issue or
            // release-note text runs; nothing here starts work on recompose.
            if (ui.install is AppInstallState.Idle && (
                    ui.download is AppDownloadState.InProgress || ui.download is AppDownloadState.Paused ||
                    ui.download is AppDownloadState.Failed || ui.download is AppDownloadState.DeltaFallback ||
                    (ui.download is AppDownloadState.Idle && ui.check is AppCheckState.UpdateAvailable)
                )) UpdateSourceSelector(controller, ui)
            SheetActions(controller, ui, context)
        }
    }
}

/**
 * Short status-only states (a one-line receipt or a busy spinner) hug their
 * content; note-bearing states keep the long-form budget so nothing
 * collapses mid-read. The install handoff states always keep the taller
 * surface: they carry explanation copy plus their pinned actions.
 */
private fun compactSheet(ui: AppUpdateUiState): Boolean {
    val install = ui.install
    return when {
        install !is AppInstallState.Idle &&
            install !is AppInstallState.Succeeded &&
            install !is AppInstallState.Preparing &&
            install !is AppInstallState.Committing -> false
        install is AppInstallState.Succeeded ->
            !(install as AppInstallState.Succeeded).runtimeUpdateRequired
        install is AppInstallState.Preparing || install is AppInstallState.Committing -> true
        ui.download is AppDownloadState.Applying ||
            ui.download is AppDownloadState.Verifying -> true
        ui.download !is AppDownloadState.Idle -> false
        ui.check is AppCheckState.Checking -> true
        ui.check is AppCheckState.UpdateAvailable -> false
        else -> true
    }
}

@Composable
private fun NewVersionContent(ui: AppUpdateUiState) {
    val release = (ui.check as AppCheckState.UpdateAvailable).release
    FloeText(
        stringResource(R.string.app_update_new_version, release.version.toString()),
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label,
    )
    KnownIssuesContent(release.knownIssues, release.intermediate)
    val summary = release.summary
    if (summary.isNotEmpty()) {
        var expanded by remember { mutableStateOf(false) }
        FloeText(
            stringResource(R.string.app_update_release_notes),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        // The full notes stay one tap away; collapsed they cannot push the
        // pinned actions off the first screen.
        FloeText(
            summary,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            maxLines = if (expanded) Int.MAX_VALUE else 4,
            overflow = TextOverflow.Ellipsis,
        )
        FloeCapsuleAction(
            label = stringResource(if (expanded) R.string.app_update_show_less else R.string.app_update_show_more),
            onClick = { expanded = !expanded },
        )
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
}

@Composable
private fun ProgressContent(ui: AppUpdateUiState) {
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
}

@Composable
private fun ReadyContent(ui: AppUpdateUiState) {
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
    // Keep the verified completion and transfer mode above long release notes.
    // A full base install replaces optional preview splits; they reinstall on demand.
    if (ui.reinstallsOffice) FloeText(stringResource(R.string.app_update_office_reinstall),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    if (ui.reinstallsCad) FloeText(stringResource(R.string.app_update_cad_reinstall),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    if (ui.officeInstallBusy || ui.cadInstallBusy) FloeText(stringResource(R.string.app_update_component_busy),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    ReadyKnownIssues(ui.knownIssues, ui.intermediate)
    FloeText(
        stringResource(R.string.app_update_system_note),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    SequentialConfirmNote()
}

/**
 * Known issues remain expanded before installation, including after process
 * recovery. The pinned action strip keeps Install reachable while this body
 * scrolls. Users may collapse the list explicitly; warnings are not hidden
 * merely because download completed.
 */
@Composable
private fun ReadyKnownIssues(issues: String, intermediate: Boolean) {
    if (!intermediate && issues.isBlank()) return
    var expanded by remember(issues, intermediate) { mutableStateOf(true) }
    FloeText(stringResource(R.string.app_update_known_issues), style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label)
    if (intermediate) FloeText(stringResource(R.string.app_update_intermediate_notice),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    if (expanded) {
        FloeText(issues.ifBlank { stringResource(R.string.app_update_issues_not_listed) },
            style = Floe.typography.metadata, color = Floe.colors.label)
    }
    FloeCapsuleAction(
        label = stringResource(if (expanded) R.string.app_update_known_issues_hide else R.string.app_update_known_issues_show),
        onClick = { expanded = !expanded },
    )
}

/**
 * One verified update can legitimately need several system prompts: a
 * confirmation for the app itself and a separate one for the Linux runtime
 * when the release updates both, plus a possible package scan before the
 * system continues. The wording states the possibility without inventing
 * progress and without weakening the install policy.
 */
@Composable
private fun SequentialConfirmNote() {
    FloeText(
        stringResource(R.string.app_update_sequential_confirm_note),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
}

@Composable
private fun DeltaFallbackContent(ui: AppUpdateUiState) {
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
}

@Composable
private fun DownloadFailedContent(ui: AppUpdateUiState) {
    val download = ui.download
    val message = when (download) {
        is AppDownloadState.Paused -> stringResource(R.string.app_update_download_paused)
        is AppDownloadState.Failed -> AppUpdateCopy.downloadFailure(download.kind)
        else -> stringResource(R.string.app_update_download_failed)
    }
    FloeText(message, style = Floe.typography.body, color = Floe.colors.label)
}

@Composable
private fun InstallContent(ui: AppUpdateUiState) {
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
        }
        is AppInstallState.Confirming -> {
            FloeText(
                stringResource(R.string.app_update_confirm_system),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            SequentialConfirmNote()
        }
        is AppInstallState.AwaitingSystem -> {
            BusyContent(text = stringResource(R.string.app_update_waiting_system))
            SequentialConfirmNote()
        }
        is AppInstallState.Committing -> BusyContent(text = stringResource(R.string.app_update_committing))
        is AppInstallState.Succeeded -> {
            FloeText(
                stringResource(R.string.app_update_installed),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
            )
            if (install.runtimeUpdateRequired) {
                FloeText(stringResource(R.string.app_update_runtime_required), color = Floe.colors.secondaryLabel)
                LocalRuntimeSettingsCard()
            }
            // No body Done: the header Done already closes the receipt via
            // dismissDialog(), which clears the succeeded state — a second
            // identical button used to duplicate it.
        }
        is AppInstallState.Failed -> {
            if (install.detail == "runtime-installed-mismatch") {
                FloeText(stringResource(R.string.app_update_runtime_required), color = Floe.colors.secondaryLabel)
                LocalRuntimeSettingsCard()
            }
            FloeText(
                AppUpdateCopy.installFailure(install.kind),
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
        }
        is AppInstallState.Idle -> Unit
    }
}

/**
 * The pinned action strip for the active state. Every click routes to the
 * same Application-owned controller calls the in-body buttons used to make;
 * cancel / retry / close meanings are unchanged and all service-owned work
 * stays owned by the updater service.
 */
@Composable
private fun SheetActions(controller: AppUpdateController, ui: AppUpdateUiState, context: android.content.Context) {
    when {
        ui.install !is AppInstallState.Idle -> InstallActions(controller, ui, context)
        ui.download is AppDownloadState.Applying || ui.download is AppDownloadState.Verifying -> Unit
        ui.download is AppDownloadState.Idle && ui.check is AppCheckState.Checking -> Unit
        ui.download is AppDownloadState.InProgress -> FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.cancel),
                enabled = !ui.sourceState.switching,
                onClick = { controller.cancelDownload() },
            )
        }
        ui.download is AppDownloadState.Ready -> FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.app_update_install),
                enabled = !(ui.officeInstallBusy || ui.cadInstallBusy),
                onClick = { controller.installNow(force = false) },
                tint = Floe.colors.accent,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.app_update_discard),
                onClick = { controller.discardDownload() },
            )
        }
        ui.download is AppDownloadState.DeltaFallback -> FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        ui.download is AppDownloadState.Paused || ui.download is AppDownloadState.Failed -> {
            val download = ui.download
            val resumable = when (download) {
                is AppDownloadState.Paused -> true
                is AppDownloadState.Failed -> download.resumable
                else -> true
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        ui.check is AppCheckState.UpdateAvailable -> {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_download_full),
                    onClick = { controller.startFullDownload() },
                )
            }
        }
        else -> FloeCapsuleAction(
            label = stringResource(R.string.app_update_check_now),
            onClick = { controller.checkNow() },
        )
    }
}

/** Pinned actions for the install handoff states; the session/ receiver and
 *  download ownership live in the updater service, these only forward clicks. */
@Composable
private fun InstallActions(controller: AppUpdateController, ui: AppUpdateUiState, context: android.content.Context) {
    when (val install = ui.install) {
        is AppInstallState.WaitingForJobs -> {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_open_permission),
                    onClick = {
                        // Once the unknown-sources page proved unavailable, the
                        // primary action must move to the App-info surface
                        // (restricted settings).
                        val target = if (install.settingsUnavailable) {
                            install.appInfoIntent
                        } else {
                            install.intent
                        }
                        if (!launchSystemIntent(context, target)) {
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
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_confirm_now),
                    onClick = {
                        controller.consumeSystemIntent()?.let { intent ->
                            if (!launchSystemIntent(context, intent)) {
                                controller.onConfirmationUnavailable(install.sessionID)
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
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        is AppInstallState.Failed -> {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        else -> Unit
    }
}

@Composable
private fun ResultContent(ui: AppUpdateUiState) {
    FloeText(
        AppUpdateCopy.status(ui),
        style = Floe.typography.body,
        color = Floe.colors.label,
    )
}

@Composable
private fun BusyContent(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeActivityIndicator()
        FloeText(text, style = Floe.typography.body, color = Floe.colors.label)
    }
}

@Composable
private fun KnownIssuesContent(issues: String, intermediate: Boolean) {
    if (!intermediate && issues.isBlank()) return
    FloeText(stringResource(R.string.app_update_known_issues), style = Floe.typography.bodyEmphasized,
        color = Floe.colors.label)
    if (intermediate) FloeText(stringResource(R.string.app_update_intermediate_notice),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    FloeText(issues.ifBlank { stringResource(R.string.app_update_issues_not_listed) },
        style = Floe.typography.metadata, color = Floe.colors.label)
}
