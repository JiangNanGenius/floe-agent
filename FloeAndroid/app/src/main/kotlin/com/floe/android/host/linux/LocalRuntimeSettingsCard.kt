@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)
package com.floe.android.host.linux

import androidx.compose.foundation.clickable
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.*
import com.floe.android.terminalWorkspaceMappingPending
import io.github.robinpcrd.cupertino.section.SectionItem

/** Uses the same second-level modal and Floe components as other settings. */
@Composable
fun LocalRuntimeSettingsCard() {
    val context = LocalContext.current
    val app = context.applicationContext as FloeApplication
    val host = app.linuxSetup
    var visible by rememberSaveable { mutableStateOf(false) }
    val state by host.state.collectAsState()
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) host.prepare() else host.openNotificationSettings()
    }
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.linux_environment_title)) {
            SectionItem(title = {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable {
                    visible = true; host.engage()
                }, verticalAlignment = Alignment.CenterVertically) {
                    FloeText(stringResource(R.string.linux_environment_title), style = Floe.typography.body,
                        color = Floe.colors.label, modifier = Modifier.weight(1f))
                    FloeText(stringResource(R.string.linux_environment_open), style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel)
                }
            })
        }
    }
    if (visible) {
        val wide = LocalConfiguration.current.screenWidthDp >= 700
        FloePageSheet(visible = true, onDismiss = { visible = false },
            widthFraction = if (wide) 0.56f else 1f,
            heightFraction = if (wide) 0.66f else 0.74f,
            placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
            topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset) {
            Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    FloeText(stringResource(R.string.linux_environment_title), style = Floe.typography.title,
                        color = Floe.colors.label, modifier = Modifier.weight(1f))
                    FloeCapsuleAction(label = stringResource(R.string.done), onClick = { visible = false })
                }
                FloeText(stringResource(R.string.linux_environment_description), style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel)
                FloeText(stringResource(when (state.phase) {
                    LocalRuntimeSetupHost.Phase.UNKNOWN -> R.string.linux_environment_loading
                    LocalRuntimeSetupHost.Phase.COMPONENT_REQUIRED -> R.string.linux_environment_component
                    LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING -> R.string.linux_environment_component_installing
                    LocalRuntimeSetupHost.Phase.SETUP_REQUIRED -> R.string.linux_environment_setup
                    LocalRuntimeSetupHost.Phase.INSTALL_REQUIRED -> R.string.linux_environment_install_needed
                    LocalRuntimeSetupHost.Phase.INSTALLING -> R.string.linux_environment_installing
                    LocalRuntimeSetupHost.Phase.INSTALLED -> R.string.linux_environment_installed
                    LocalRuntimeSetupHost.Phase.STOPPING -> R.string.linux_environment_stopping
                    LocalRuntimeSetupHost.Phase.FAILED -> R.string.linux_environment_failed
                }), style = Floe.typography.body, color = Floe.colors.label)
                if (state.total > 0 && state.phase == LocalRuntimeSetupHost.Phase.INSTALLING) {
                    FloeText("${state.bytes / 1_048_576} / ${state.total / 1_048_576} MB",
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
                val busy = state.phase == LocalRuntimeSetupHost.Phase.INSTALLING || state.phase == LocalRuntimeSetupHost.Phase.STOPPING ||
                    state.phase == LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING
                if (state.pendingIntent != null) {
                    FloeCapsuleAction(label = stringResource(R.string.linux_environment_continue), onClick = {
                        host.consumeIntent()?.let { intent ->
                            try { context.startActivity(intent) }
                            catch (_: android.content.ActivityNotFoundException) { host.refresh() }
                            catch (_: SecurityException) { host.refresh() }
                        }
                    })
                } else if (!busy && state.phase != LocalRuntimeSetupHost.Phase.INSTALLED) {
                    FloeCapsuleAction(label = stringResource(R.string.linux_environment_prepare), onClick = {
                        if (android.os.Build.VERSION.SDK_INT >= 33 &&
                            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                        } else host.prepare()
                    })
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLING) {
                    FloeCapsuleAction(label = stringResource(R.string.cancel), onClick = { host.cancelInstall() })
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLED) {
                    if (state.localNetworkPermissionNeeded && state.pendingIntent == null) {
                        FloeCapsuleAction(label = stringResource(R.string.linux_environment_local_network),
                            onClick = { host.requestLocalNetworkAccess() })
                    }
                    // Truthful task-execution state: ONE bounded observation
                    // of the ORIGINAL readiness authority per open (no idle
                    // polling), plus one more after the system permission
                    // activity returns. A not-ready answer also reads the SAME
                    // closed stage authority Diagnostics opens, so the copy
                    // names the ONE real next step instead of a dead end: when
                    // every prerequisite is live and only this task's receipt-
                    // backed workspace facts are still missing, the terminal's
                    // own run-less first-use preparation produces them.
                    var taskState by remember { mutableStateOf(LocalRuntimeTaskState.UNVERIFIED) }
                    LaunchedEffect(state.phase, state.localNetworkPermissionNeeded, state.pendingIntent != null) {
                        val ready = app.linuxTaskExecutionReady()
                        taskState = localRuntimeTaskState(ready,
                            if (ready) null else app.linuxTaskExecutionDiagnostic())
                    }
                    FloeText(stringResource(when (taskState) {
                        LocalRuntimeTaskState.READY -> R.string.linux_environment_tools_ready
                        LocalRuntimeTaskState.PREPARING_WORKSPACE ->
                            R.string.linux_environment_tools_prepare_terminal
                        LocalRuntimeTaskState.UNVERIFIED -> R.string.linux_environment_tools_pending
                    }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
    }
}

/**
 * COPY-ONLY projection of the ORIGINAL local-task readiness authority for the
 * Settings card. It qualifies nothing, gates nothing and writes nothing: the
 * boolean still comes from `linuxTaskExecutionReady()` (the seven-fact live
 * ingress), and [diagnostic] is the SAME closed stage token the Diagnostics
 * surface reads (`ready` | `lane:unbound` | `status:unreadable` |
 * `<cause>|refusal:<closed>|stage:<closed>`).
 *
 * [PREPARING_WORKSPACE] is returned ONLY for the exact stage shape the
 * terminal's own first-use classifier already accepts: every prerequisite is
 * live, only this task's receipt-backed `workspaceMappingSynced` /
 * `leaseAuthorityQualified` facts are missing, and no attempt failed for this
 * generation (both attempt tokens empty). Everything else — a missing
 * prerequisite, an unbound lane, an unreadable status, a failed attempt,
 * unknown text — stays [UNVERIFIED] and keeps the existing setup-neutral copy,
 * so this function can never turn an unproven lane into an actionable promise.
 */
internal enum class LocalRuntimeTaskState { READY, PREPARING_WORKSPACE, UNVERIFIED }

internal fun localRuntimeTaskState(ready: Boolean, diagnostic: String?): LocalRuntimeTaskState =
    when {
        ready -> LocalRuntimeTaskState.READY
        terminalWorkspaceMappingPending(diagnostic) -> LocalRuntimeTaskState.PREPARING_WORKSPACE
        else -> LocalRuntimeTaskState.UNVERIFIED
    }
