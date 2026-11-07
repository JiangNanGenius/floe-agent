// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.floe.android.design.*
import com.floe.android.feature.remote.RemoteVncViewerPage
import com.floe.android.host.RuntimeHost
import com.floe.android.host.linux.LinuxDesktopCommands
import com.floe.android.host.linux.LinuxDesktopDiagnosticsAction
import com.floe.android.host.linux.LocalRuntimeSettingsCard
import com.floe.android.host.linux.LocalRuntimeSetupHost
import com.floe.android.host.remote.C05VncInput

@Composable
internal fun LinuxDesktopSheet(host: RuntimeHost, taskID: String, workspaceID: String,
    selectedPath: String, onDismiss: () -> Unit) {
    val service = host.linuxDesktop
    val state by service.state.collectAsState()
    val setup = (LocalContext.current.applicationContext as FloeApplication).linuxSetup
    val environment by setup.state.collectAsState()
    LaunchedEffect(setup) { setup.engage() }
    val compact = LocalConfiguration.current.screenWidthDp < 840
    var desktop by remember(workspaceID) { mutableStateOf(!compact) }
    var install by remember(workspaceID) { mutableStateOf(true) }
    var selectedApp by remember(workspaceID, selectedPath) { mutableStateOf(
        if (selectedPath.isBlank() && state.workspaceID.equals(workspaceID, true) &&
            state.phase == "running" && state.lastStartedApplication != null) {
            state.lastStartedApplication!!
        } else when (selectedPath.substringAfterLast('.', "").lowercase()) {
            "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "pdf" -> "libreoffice"
            "svg" -> "inkscape"
            "png", "jpg", "jpeg", "webp", "tif", "tiff", "xcf" -> "gimp"
            "blend", "glb", "gltf", "obj", "stl" -> "blender"
            else -> "pcmanfm"
        }) }
    var filesFailed by remember { mutableStateOf(false) }
    var softwareVisible by remember { mutableStateOf(false) }
    var stopRequested by remember { mutableStateOf(false) }
    DisposableEffect(service) {
        service.setVisible(true)
        onDispose { service.setVisible(false) }
    }
    if (stopRequested) FloeConfirmDialog(title = stringResource(R.string.linux_desktop_stop),
        message = stringResource(R.string.linux_desktop_stop_notice),
        confirmLabel = stringResource(R.string.linux_desktop_stop), dismissLabel = stringResource(R.string.cancel),
        onConfirm = { stopRequested = false; service.stop() }, onDismiss = { stopRequested = false })
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(
        usePlatformDefaultWidth = false, decorFitsSystemWindows = true)) {
        Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(10.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                FloeText(stringResource(R.string.linux_desktop_title))
                FloeCapsuleButton(stringResource(R.string.external_edit_done), onClick = onDismiss,
                    modifier = Modifier.widthIn(min = 64.dp, max = 96.dp))
            }
            val owned = state.workspaceID.equals(workspaceID, true)
            val viewer = state.vnc?.takeIf { owned }
            if (viewer != null && !softwareVisible) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(selectedApp, onClick = { softwareVisible = true }, modifier = Modifier.weight(1f))
                    if (selectedPath.isNotBlank()) FloeCapsuleButton(stringResource(R.string.linux_desktop_open_file),
                        onClick = { filesFailed = runCatching { service.openFile(selectedApp, selectedPath, taskID, workspaceID) }.isFailure },
                        modifier = Modifier.weight(1f))
                    FloeCapsuleButton(stringResource(R.string.linux_desktop_stop), onClick = { stopRequested = true },
                        modifier = Modifier.weight(1f))
                }
                if (state.phase in setOf("save_pending", "close_pending")) {
                    FloeText(stringResource(R.string.linux_desktop_save_pending))
                    FloeCapsuleButton(stringResource(R.string.linux_desktop_retry_return), onClick = service::stop)
                } else if (filesFailed || state.failure != null) FloeText(stringResource(R.string.linux_desktop_operation_failed))
                Box(Modifier.weight(1f)) {
                    RemoteVncViewerPage(viewer, null, compact, onDismiss, service::setVisible,
                        { x, y -> service.input(C05VncInput.PointerMove(x, y)) },
                        { button, down, x, y -> service.input(C05VncInput.PointerButton(button, down, x, y)) },
                        { axis, steps, x, y -> service.input(C05VncInput.Wheel(axis, steps, x, y)) },
                        { key, down -> service.input(C05VncInput.Key(key, down)) },
                        { service.input(C05VncInput.Text(it)) }, service::releaseInput, {})
                }
            } else {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    FloeText(stringResource(R.string.linux_desktop_description), color = Floe.colors.secondaryLabel)
                    LinuxDesktopDiagnosticsAction(state)
                    FloeText(stringResource(when (state.phase.takeIf { owned } ?: "idle") {
                        "running" -> R.string.linux_desktop_running
                        "installing" -> R.string.linux_desktop_installing
                        "starting" -> R.string.linux_desktop_starting
                        "failed" -> R.string.linux_desktop_failed
                        else -> R.string.linux_desktop_stopped
                    }))
                    FloeSegmented(options = listOf(stringResource(R.string.linux_desktop_single),
                        stringResource(R.string.linux_desktop_windows)), selectedIndex = if (desktop) 1 else 0,
                        onSelect = { desktop = it == 1 })
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        FloeText(stringResource(R.string.linux_desktop_install_base))
                        FloeInlineSwitch(install, { install = it }, stringResource(R.string.linux_desktop_install_base))
                    }
                    if (viewer != null) FloeCapsuleButton(stringResource(R.string.linux_desktop_return),
                        onClick = { softwareVisible = false })
                    val busy = owned && state.phase in setOf("starting", "installing", "running")
                    val environmentReady = environment.phase == LocalRuntimeSetupHost.Phase.INSTALLED
                    if (!environmentReady && viewer == null) {
                        FloeText(stringResource(R.string.linux_desktop_setup_required), color = Floe.colors.secondaryLabel)
                        LocalRuntimeSettingsCard()
                    }
                    FloeCapsuleButton(stringResource(R.string.linux_desktop_start),
                        onClick = { service.start(taskID, workspaceID, desktop, install, selectedApp) },
                        enabled = !busy && environmentReady, prominent = true)
                    if (busy) FloeCapsuleButton(stringResource(R.string.linux_desktop_stop), onClick = { stopRequested = true })
                    if (!owned && state.workspaceID != null) FloeText(stringResource(R.string.linux_desktop_switch_notice))
                    FloeText(stringResource(R.string.linux_desktop_software))
                    if (owned && state.softwareOperation != null) {
                        FloeText(stringResource(R.string.linux_software_busy), color = Floe.colors.secondaryLabel)
                    }
                    if (owned && state.failure != null) {
                        FloeText(stringResource(R.string.linux_desktop_operation_failed), color = Floe.colors.secondaryLabel)
                    }
                    for (app in LinuxDesktopCommands.featuredApplications) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            FloeCapsuleButton(app, onClick = {
                                selectedApp = app
                                if (viewer != null) { service.application(app, false); softwareVisible = false }
                            }, enabled = state.softwareOperation == null, modifier = Modifier.weight(1f))
                            if (owned && state.phase == "running") FloeCapsuleButton(
                                stringResource(R.string.linux_desktop_install_software),
                                onClick = { service.application(app, true) }, enabled = state.softwareOperation == null,
                                modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}
