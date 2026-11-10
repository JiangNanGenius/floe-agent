// SPDX-License-Identifier: MPL-2.0
// The N08 compact launcher uses the same pinned foundation FlowRow the app
// already ships (ExternalEditorSheet / AppUpdateDialogHost); wrapping chip
// targets is a presentation concern only — selection, install, start/stop
// and service callbacks below are unchanged.
@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
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
import com.floe.android.feature.remote.R as RemoteR
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
    // decorFitsSystemWindows=false keeps the dialog fullscreen and lets the
    // Compose safe-drawing insets (system bars + IME) pad the content: the
    // keyboard then shrinks the desktop area instead of panning the top of
    // the page offscreen.
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(
        usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        FloeDialogSystemBarAppearance()
        FloeSettingsContentDensity(compact = compact) {
            Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface).safeDrawingPadding()) {
                val owned = state.workspaceID.equals(workspaceID, true)
                val viewer = state.vnc?.takeIf { owned }
                if (viewer != null && !softwareVisible) {
                    // The shared viewer bar is the only chrome: it closes
                    // (hides) the viewer, never stops the session; Stop stays
                    // an explicit, confirmed action in the options overlay.
                    Box(Modifier.weight(1f)) {
                        RemoteVncViewerPage(viewer, null, compact, onDismiss, service::setVisible,
                            { x, y -> service.input(C05VncInput.PointerMove(x, y)) },
                            { button, down, x, y -> service.input(C05VncInput.PointerButton(button, down, x, y)) },
                            { axis, steps, x, y -> service.input(C05VncInput.Wheel(axis, steps, x, y)) },
                            { key, down -> service.input(C05VncInput.Key(key, down)) },
                            { service.input(C05VncInput.Text(it)) }, service::releaseInput, {},
                            title = selectedApp,
                            closeLabel = stringResource(RemoteR.string.remote_vnc_close_viewer),
                            notice = {
                                if (state.phase in setOf("save_pending", "close_pending")) {
                                    Row(Modifier.fillMaxWidth()
                                        .background(Floe.colors.pending.copy(alpha = 0.08f))
                                        .padding(horizontal = 12.dp, vertical = 4.dp),
                                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                                        FloeText(stringResource(R.string.linux_desktop_save_pending),
                                            style = Floe.typography.metadata, color = Floe.colors.label,
                                            modifier = Modifier.weight(1f))
                                        FloeCapsuleAction(stringResource(R.string.linux_desktop_retry_return),
                                            onClick = service::stop, showHairline = false)
                                    }
                                } else if (filesFailed || state.failure != null) {
                                    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
                                        FloeText(stringResource(R.string.linux_desktop_operation_failed),
                                            style = Floe.typography.metadata, color = Floe.colors.destructive)
                                    }
                                }
                            },
                            infoActions = {
                                if (selectedPath.isNotBlank()) {
                                    FloeCapsuleAction(stringResource(R.string.linux_desktop_open_file),
                                        onClick = {
                                            filesFailed = runCatching {
                                                service.openFile(selectedApp, selectedPath, taskID, workspaceID)
                                            }.isFailure
                                        })
                                }
                                FloeCapsuleAction(stringResource(R.string.linux_desktop_software),
                                    onClick = { softwareVisible = true })
                                FloeCapsuleAction(stringResource(R.string.linux_desktop_stop),
                                    onClick = { stopRequested = true }, tint = Floe.colors.destructive)
                            })
                    }
                } else {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween) {
                        FloeText(stringResource(R.string.linux_desktop_title), style = Floe.typography.title)
                        FloeCapsuleAction(stringResource(R.string.external_edit_done), onClick = onDismiss,
                            modifier = Modifier.widthIn(min = 64.dp, max = 96.dp))
                    }
                    // N08 compact refinement: related content is grouped tightly
                    // and distinct groups separated generously; every string,
                    // state gate and service callback below matches the
                    // previous row-per-control layout exactly.
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp).padding(top = 6.dp, bottom = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeText(stringResource(R.string.linux_desktop_description), style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel)
                            LinuxDesktopDiagnosticsAction(state)
                            FloeText(stringResource(when (state.phase.takeIf { owned } ?: "idle") {
                                "running" -> R.string.linux_desktop_running
                                "installing" -> R.string.linux_desktop_installing
                                "starting" -> R.string.linux_desktop_starting
                                "failed" -> R.string.linux_desktop_failed
                                else -> R.string.linux_desktop_stopped
                            }))
                            if (state.phase in setOf("save_pending", "close_pending")) {
                                FloeText(stringResource(R.string.linux_desktop_save_pending),
                                    color = Floe.colors.secondaryLabel)
                                FloeCapsuleAction(stringResource(R.string.linux_desktop_retry_return),
                                    onClick = service::stop)
                            }
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeSegmented(options = listOf(stringResource(R.string.linux_desktop_single),
                                stringResource(R.string.linux_desktop_windows)), selectedIndex = if (desktop) 1 else 0,
                                onSelect = { desktop = it == 1 })
                            // iOS row language: the label leads and the switch
                            // trails to the row edge; the 48dp target and the
                            // callback are the shared FloeInlineSwitch ones.
                            Row(Modifier.fillMaxWidth(),
                                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                FloeText(stringResource(R.string.linux_desktop_install_base),
                                    style = Floe.typography.body, modifier = Modifier.weight(1f))
                                FloeInlineSwitch(install, { install = it }, stringResource(R.string.linux_desktop_install_base))
                            }
                        }
                        val busy = owned && state.phase in setOf("starting", "installing", "running")
                        val environmentReady = environment.phase == LocalRuntimeSetupHost.Phase.INSTALLED
                        if (!environmentReady && viewer == null) {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                FloeText(stringResource(R.string.linux_desktop_setup_required), color = Floe.colors.secondaryLabel)
                                LocalRuntimeSettingsCard()
                            }
                        }
                        Row(Modifier.fillMaxWidth(),
                            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (viewer != null) FloeCapsuleAction(stringResource(R.string.linux_desktop_return),
                                onClick = { softwareVisible = false })
                            // The start action is the screen's one primary
                            // action (shared filled-accent FloePrimaryAction);
                            // Stop keeps the destructive capsule language the
                            // viewer bar already uses.
                            if (!busy) FloePrimaryAction(stringResource(R.string.linux_desktop_start),
                                onClick = { service.start(taskID, workspaceID, desktop, install, selectedApp) },
                                modifier = Modifier.weight(1f),
                                enabled = environmentReady)
                            if (busy) FloeCapsuleAction(stringResource(R.string.linux_desktop_stop),
                                onClick = { stopRequested = true }, tint = Floe.colors.destructive,
                                modifier = Modifier.weight(1f))
                        }
                        if (!owned && state.workspaceID != null) FloeText(stringResource(R.string.linux_desktop_switch_notice))
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeText(stringResource(R.string.linux_desktop_software),
                                style = Floe.typography.groupHeader, color = Floe.colors.secondaryLabel)
                            if (owned && state.softwareOperation != null) {
                                FloeText(stringResource(R.string.linux_software_busy), color = Floe.colors.secondaryLabel)
                            }
                            if (owned && state.failure != null) {
                                FloeText(stringResource(R.string.linux_desktop_operation_failed), color = Floe.colors.secondaryLabel)
                            }
                            // Compact choice presentation: one wrapping chip
                            // flow replaces the five full-width pill rows. All
                            // featured apps stay findable and selected apps
                            // launch from the viewer exactly as before; a
                            // definite installed entry shows the neutral
                            // checkmark role (never green success).
                            FlowRow(modifier = Modifier.selectableGroup(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                for (app in LinuxDesktopCommands.featuredApplications) {
                                    val entry = state.software.firstOrNull { it.application == app }
                                    FloeChoiceChip(
                                        label = app,
                                        selected = selectedApp == app,
                                        enabled = state.softwareOperation == null,
                                        installed = owned && entry?.installed == true,
                                        onClick = {
                                            selectedApp = app
                                            if (viewer != null && entry?.installed != false) {
                                                service.application(app, false); softwareVisible = false
                                            }
                                        },
                                    )
                                }
                            }
                            // Install targets the chip the user selected (all
                            // five apps remain installable; same gate and
                            // service.application(app, true) callback).
                            if (owned && state.phase == "running") {
                                FloeCapsuleAction(stringResource(R.string.linux_desktop_install_software),
                                    onClick = { service.application(selectedApp, true) },
                                    enabled = state.softwareOperation == null)
                            }
                        }
                    }
                }
            }
        }
    }
}
