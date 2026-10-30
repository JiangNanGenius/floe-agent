// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)
package com.floe.android.host.update

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionItem

/**
 * Settings → Diagnostics & About → "App update" (full channel only).
 * The manual check stays available here; automatic checks are controlled by
 * the persisted enabled switch above it.
 */
@Composable
internal fun AppUpdateSettingsEntry() {
    val controller = AppUpdateFeature.controller() ?: return
    val ui by controller.ui.collectAsState()
    val context = LocalContext.current
    // The hosting settings page owns horizontal padding; this entry adds only
    // the vertical rhythm of a settings card group.
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.app_update_title)) {
            SectionItem(title = {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        FloeText(
                            stringResource(R.string.app_update_auto_check),
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                        )
                        FloeText(
                            stringResource(R.string.app_update_current_version, ui.currentVersion),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    FloeInlineSwitch(
                        checked = ui.autoCheckEnabled,
                        onCheckedChange = { enabled -> controller.setAutoCheckEnabled(enabled) },
                        description = stringResource(R.string.app_update_auto_check),
                    )
                }
            })
            SectionItem(title = {
                FloeText(
                    AppUpdateCopy.status(ui),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            })
            SectionItem(title = {
                FloeCapsuleAction(
                    label = AppUpdateCopy.primaryLabel(ui),
                    onClick = { primaryAction(controller, ui, context) },
                    enabled = AppUpdateCopy.primaryEnabled(ui),
                    modifier = Modifier.padding(vertical = 2.dp),
                )
            })
            SectionItem(title = {
                FloeCapsuleAction(
                    label = stringResource(R.string.app_update_check_now),
                    onClick = {
                        controller.showDialog()
                        controller.checkNow()
                    },
                    enabled = AppUpdateCopy.manualCheckEnabled(ui),
                    modifier = Modifier.padding(vertical = 2.dp),
                )
            })
        }
    }
}

private fun primaryAction(
    controller: AppUpdateController,
    ui: AppUpdateUiState,
    context: Context,
) {
    when {
        ui.install is AppInstallState.NeedsPermission -> {
            val permission = ui.install as AppInstallState.NeedsPermission
            // Once the unknown-sources page proved unavailable, the primary
            // action must move to the App-info surface (restricted settings).
            val target = if (permission.settingsUnavailable) {
                permission.appInfoIntent
            } else {
                permission.intent
            }
            if (!launchSystemIntent(context, target)) {
                controller.onPermissionIntentUnavailable()
            }
        }
        ui.install is AppInstallState.Confirming -> {
            controller.consumeSystemIntent()?.let { intent ->
                if (!launchSystemIntent(context, intent)) controller.onConfirmationUnavailable()
            }
        }
        ui.install is AppInstallState.Preparing ||
            ui.install is AppInstallState.AwaitingSystem ||
            ui.install is AppInstallState.WaitingForJobs ||
            ui.install is AppInstallState.Succeeded ||
            ui.install is AppInstallState.Failed -> controller.showDialog()
        ui.download is AppDownloadState.Ready -> controller.installNow(force = false)
        ui.download is AppDownloadState.InProgress -> controller.cancelDownload()
        ui.download is AppDownloadState.Applying -> Unit
        ui.download is AppDownloadState.Paused -> controller.resumeDownload()
        ui.download is AppDownloadState.Verifying -> Unit
        ui.download is AppDownloadState.DeltaFallback -> {
            controller.showDialog()
        }
        ui.download is AppDownloadState.Failed -> {
            if (ui.download.resumable) controller.resumeDownload() else controller.startDownload()
        }
        ui.check is AppCheckState.UpdateAvailable -> controller.startDownload()
        else -> {
            controller.showDialog()
            controller.checkNow()
        }
    }
}

/**
 * Only a visible user click reaches this path; never a background launch.
 * Returns false when the system surface is unavailable so the caller can move
 * to the other real route (App info) or publish a typed failure — a silently
 * swallowed exception used to leave the user on a dead button.
 */
internal fun launchSystemIntent(context: Context, intent: Intent): Boolean {
    // The updater dialog is hosted inside a Compose Dialog; its LocalContext is
    // an activity-backed wrapper but not an Activity instance. A system
    // confirmation intent must then carry NEW_TASK or startActivity throws.
    val launch = if (context is android.app.Activity) {
        intent
    } else {
        Intent(intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    return try {
        context.startActivity(launch)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    } catch (_: android.util.AndroidRuntimeException) {
        false
    }
}

/** Bilingual, state-exact copy for the settings card and dialog. */
internal object AppUpdateCopy {

    /**
     * Human labels for the owned-work kinds that gate an install. Raw enum
     * tokens stay out of ordinary UI copy.
     */
    @Composable
    fun blockingKindLabels(kinds: Set<com.floe.android.runlifecycle.OperationKind>): String =
        kinds.map { kind ->
            stringResource(
                when (kind) {
                    com.floe.android.runlifecycle.OperationKind.AGENT_RUN -> R.string.app_update_job_agent
                    com.floe.android.runlifecycle.OperationKind.LOCAL_EXECUTION -> R.string.app_update_job_terminal
                    com.floe.android.runlifecycle.OperationKind.DURABLE_JOB -> R.string.app_update_job_durable
                    com.floe.android.runlifecycle.OperationKind.ENVIRONMENT_INSTALL -> R.string.app_update_job_environment
                },
            )
        }.joinToString(stringResource(R.string.app_update_list_separator))

    @Composable
    fun status(ui: AppUpdateUiState): String {
        val install = ui.install
        if (install !is AppInstallState.Idle) {
            return when (install) {
                is AppInstallState.Preparing -> stringResource(R.string.app_update_preparing)
                is AppInstallState.WaitingForJobs -> stringResource(R.string.app_update_waiting_jobs)
                is AppInstallState.NeedsPermission ->
                    if (install.deniedOnce) stringResource(R.string.app_update_permission_denied)
                    else stringResource(R.string.app_update_permission)
                is AppInstallState.Committing -> stringResource(R.string.app_update_committing)
                is AppInstallState.AwaitingSystem -> stringResource(R.string.app_update_waiting_system)
                is AppInstallState.Confirming -> stringResource(R.string.app_update_confirm_system)
                is AppInstallState.Succeeded -> stringResource(R.string.app_update_installed)
                is AppInstallState.Failed -> installFailure(install.kind)
                is AppInstallState.Idle -> ""
            }
        }
        return when (val download = ui.download) {
            is AppDownloadState.InProgress ->
                if (download.mode == DownloadMode.DELTA) {
                    stringResource(R.string.app_update_delta_downloading, download.versionName)
                } else {
                    stringResource(R.string.app_update_downloading, download.versionName)
                }
            is AppDownloadState.Verifying -> stringResource(R.string.app_update_verifying)
            is AppDownloadState.Applying -> stringResource(R.string.app_update_applying_delta)
            is AppDownloadState.Ready ->
                if (download.mode == DownloadMode.DELTA) stringResource(R.string.app_update_delta_ready)
                else stringResource(R.string.app_update_ready)
            is AppDownloadState.Paused -> stringResource(R.string.app_update_download_paused)
            is AppDownloadState.Failed -> downloadFailure(download.kind)
            is AppDownloadState.DeltaFallback -> deltaFallback(download.reason)
            is AppDownloadState.Idle -> when (val check = ui.check) {
                is AppCheckState.Checking -> stringResource(R.string.app_update_checking)
                is AppCheckState.UpToDate -> stringResource(R.string.app_update_up_to_date)
                is AppCheckState.UpdateAvailable ->
                    stringResource(R.string.app_update_available, check.release.version.toString())
                is AppCheckState.Unavailable -> when (check.kind) {
                    UnavailableKind.RATE_LIMITED -> stringResource(R.string.app_update_rate_limited)
                    UnavailableKind.NO_ANDROID_RELEASE -> stringResource(R.string.app_update_no_release)
                    else -> stringResource(R.string.app_update_check_failed)
                }
                is AppCheckState.Idle -> stringResource(R.string.app_update_idle)
            }
        }
    }

    @Composable
    fun primaryLabel(ui: AppUpdateUiState): String = when {
        ui.install is AppInstallState.NeedsPermission -> {
            val permission = ui.install as AppInstallState.NeedsPermission
            stringResource(
                if (permission.settingsUnavailable) R.string.app_update_open_app_info
                else R.string.app_update_open_permission,
            )
        }
        ui.install is AppInstallState.Confirming -> stringResource(R.string.app_update_confirm_now)
        ui.install is AppInstallState.Preparing -> stringResource(R.string.app_update_preparing)
        ui.install is AppInstallState.AwaitingSystem -> stringResource(R.string.app_update_check_status)
        ui.install is AppInstallState.WaitingForJobs -> stringResource(R.string.app_update_install_now)
        ui.install is AppInstallState.Committing -> stringResource(R.string.app_update_committing)
        ui.install is AppInstallState.Succeeded -> stringResource(R.string.done)
        ui.install is AppInstallState.Failed -> stringResource(R.string.retry)
        ui.download is AppDownloadState.Ready -> stringResource(R.string.app_update_install)
        ui.download is AppDownloadState.InProgress -> stringResource(R.string.cancel)
        ui.download is AppDownloadState.Applying -> stringResource(R.string.app_update_applying_delta)
        ui.download is AppDownloadState.Paused -> stringResource(R.string.app_update_resume)
        ui.download is AppDownloadState.Verifying -> stringResource(R.string.app_update_verifying)
        ui.download is AppDownloadState.DeltaFallback -> stringResource(R.string.app_update_download_full)
        ui.download is AppDownloadState.Failed ->
            stringResource(if (ui.download.resumable) R.string.app_update_resume else R.string.retry)
        ui.check is AppCheckState.UpdateAvailable -> stringResource(R.string.app_update_update_now)
        ui.check is AppCheckState.Checking -> stringResource(R.string.app_update_checking)
        ui.check is AppCheckState.Unavailable -> stringResource(R.string.retry)
        else -> stringResource(R.string.app_update_check_now)
    }

    fun primaryEnabled(ui: AppUpdateUiState): Boolean =
        ui.install !is AppInstallState.Preparing &&
            ui.install !is AppInstallState.Committing &&
            ui.download !is AppDownloadState.Verifying &&
            ui.download !is AppDownloadState.Applying &&
            ui.check !is AppCheckState.Checking

    fun manualCheckEnabled(ui: AppUpdateUiState): Boolean =
        ui.check !is AppCheckState.Checking &&
            ui.download is AppDownloadState.Idle &&
            ui.install is AppInstallState.Idle

    @Composable
    fun installFailure(kind: InstallFailure): String = when (kind) {
        InstallFailure.CANCELLED -> stringResource(R.string.app_update_install_cancelled)
        InstallFailure.ABORTED -> stringResource(R.string.app_update_install_aborted)
        InstallFailure.BLOCKED -> stringResource(R.string.app_update_install_blocked)
        InstallFailure.INCOMPATIBLE -> stringResource(R.string.app_update_install_incompatible)
        InstallFailure.INVALID_PACKAGE -> stringResource(R.string.app_update_install_invalid)
        InstallFailure.STORAGE -> stringResource(R.string.app_update_install_storage)
        InstallFailure.VERIFICATION -> stringResource(R.string.app_update_install_verification)
        InstallFailure.CONFLICT -> stringResource(R.string.app_update_install_conflict)
        InstallFailure.IDENTITY -> stringResource(R.string.app_update_install_identity_failed)
        InstallFailure.SYSTEM -> stringResource(R.string.app_update_install_failed)
    }

    @Composable
    fun deltaFallback(reason: DeltaFallbackReason): String = when (reason) {
        DeltaFallbackReason.BASE_MISMATCH -> stringResource(R.string.app_update_delta_base_changed)
        DeltaFallbackReason.PATCH_UNAVAILABLE -> stringResource(R.string.app_update_delta_patch_unavailable)
        DeltaFallbackReason.PATCH_CORRUPT -> stringResource(R.string.app_update_delta_patch_corrupt)
        DeltaFallbackReason.APPLY_FAILED -> stringResource(R.string.app_update_delta_apply_failed)
        DeltaFallbackReason.OUTPUT_INVALID -> stringResource(R.string.app_update_delta_output_invalid)
        DeltaFallbackReason.DISK -> stringResource(R.string.app_update_delta_disk)
        DeltaFallbackReason.NOT_OFFERED -> stringResource(R.string.app_update_download_failed)
    }

    @Composable
    fun downloadFailure(kind: DownloadFailure): String = when (kind) {
        DownloadFailure.CHECKSUM_MISMATCH,
        DownloadFailure.NO_CHECKSUM -> stringResource(R.string.app_update_checksum_failed)
        DownloadFailure.APK_IDENTITY -> stringResource(R.string.app_update_apk_invalid)
        DownloadFailure.DISK,
        DownloadFailure.SIZE_BUDGET -> stringResource(R.string.app_update_disk_full)
        DownloadFailure.INVALID_ASSET -> stringResource(R.string.app_update_apk_invalid)
        DownloadFailure.NETWORK -> stringResource(R.string.app_update_download_failed)
    }
}
