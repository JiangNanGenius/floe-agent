// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.floe.android.design.*
import com.floe.android.feature.remote.RemoteVncViewerPage
import com.floe.android.host.RuntimeHost
import com.floe.android.host.linux.LinuxDesktopCommands
import com.floe.android.host.remote.C05VncInput

@Composable
internal fun LinuxDesktopSheet(host: RuntimeHost, taskID: String, workspaceID: String,
    selectedPath: String, onDismiss: () -> Unit) {
    val service = host.linuxDesktop
    val state by service.state.collectAsState()
    val compact = LocalConfiguration.current.screenWidthDp < 840
    var desktop by remember(workspaceID) { mutableStateOf(!compact) }
    var install by remember(workspaceID) { mutableStateOf(true) }
    var selectedApp by remember(workspaceID) { mutableStateOf("mousepad") }
    var filesFailed by remember { mutableStateOf(false) }
    var softwareVisible by remember { mutableStateOf(false) }
    DisposableEffect(service) {
        service.setVisible(true)
        onDispose { service.setVisible(false) }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(
        usePlatformDefaultWidth = false, decorFitsSystemWindows = true)) {
        Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(10.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                FloeText(stringResource(R.string.linux_desktop_title))
                FloeCapsuleButton(stringResource(R.string.external_edit_done), onClick = onDismiss)
            }
            val owned = state.workspaceID.equals(workspaceID, true)
            val viewer = state.vnc?.takeIf { owned }
            if (viewer != null && !softwareVisible) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(selectedApp, onClick = { softwareVisible = true })
                    if (selectedPath.isNotBlank()) FloeCapsuleButton(stringResource(R.string.linux_desktop_open_file),
                        onClick = { filesFailed = runCatching { service.openFile(selectedApp, selectedPath) }.isFailure })
                    FloeCapsuleButton(stringResource(R.string.linux_desktop_stop), onClick = service::stop)
                }
                if (filesFailed || state.failure != null) FloeText(stringResource(R.string.linux_desktop_operation_failed))
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
                    FloeText(stringResource(when (state.phase.takeIf { owned } ?: "idle") {
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
                    FloeCapsuleButton(stringResource(R.string.linux_desktop_start),
                        onClick = { service.start(taskID, workspaceID, desktop, install) }, enabled = !busy, prominent = true)
                    if (busy) FloeCapsuleButton(stringResource(R.string.linux_desktop_stop), onClick = service::stop)
                    if (!owned && state.workspaceID != null) FloeText(stringResource(R.string.linux_desktop_switch_notice))
                    FloeText(stringResource(R.string.linux_desktop_software))
                    for (app in LinuxDesktopCommands.applications) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            FloeCapsuleButton(app, onClick = {
                                selectedApp = app
                                if (viewer != null) { service.application(app, false); softwareVisible = false }
                            })
                            if (owned && state.phase == "running") FloeCapsuleButton(
                                stringResource(R.string.linux_desktop_install_software),
                                onClick = { service.application(app, true) })
                        }
                    }
                }
            }
        }
    }
}
