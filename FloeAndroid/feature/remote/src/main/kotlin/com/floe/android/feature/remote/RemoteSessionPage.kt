// SPDX-License-Identifier: MPL-2.0
//
// C05 SSH terminal session surface. The terminal renderer/parser is the
// existing Termux-emulator feature (`G04TerminalView`), driven by the
// App-owned controller over the real SSH PTY bytes. This file holds no
// transport or session authority.

package com.floe.android.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.IconGlyph
import com.floe.android.feature.terminal.G04TerminalView

@Composable
internal fun RemoteSessionPage(
    state: RemoteHostUiState,
    session: RemoteSessionUi,
    compact: Boolean,
    onCloseSession: () -> Unit,
    onOpenTunnel: (String, Int) -> Unit,
    onCloseTunnel: (String) -> Unit,
    onStartExec: (String) -> Unit,
    onCancelExec: () -> Unit,
    onReleaseExec: () -> Unit,
    onTerminalVisible: (Boolean) -> Unit,
    onDismissError: () -> Unit,
) {
    var tunnelsVisible by rememberSaveable { mutableStateOf(false) }
    var commandVisible by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(session.id) { onTerminalVisible(true) }
    DisposableEffect(session.id) {
        onDispose { onTerminalVisible(false) }
    }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = session.displayName,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.remote_close_session),
                    onClick = onCloseSession,
                )
            },
            actions = {
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_tunnels),
                    onClick = { tunnelsVisible = true },
                )
                Spacer(Modifier.width(6.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_command),
                    onClick = { commandVisible = true },
                )
            },
            showHairline = true,
        )

        state.error?.let { error ->
            Row(
                Modifier.fillMaxWidth().background(Floe.colors.destructive.copy(alpha = 0.08f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
                Spacer(Modifier.width(8.dp))
                FloeText(
                    remoteMessage(error.code),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_cancel),
                    onClick = onDismissError,
                    showHairline = false,
                    tint = Floe.colors.destructive,
                )
            }
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeBadgePill(
                text = remoteSessionStateLabel(session.state, session.transportConnected),
                tone = when {
                    session.state == "connected" && session.transportConnected -> FloeBadgeTone.SUCCESS
                    session.state == "unknown" || !session.transportConnected -> FloeBadgeTone.PENDING
                    else -> FloeBadgeTone.SECONDARY
                },
            )
            Spacer(Modifier.width(8.dp))
            FloeText(
                "${session.user}@${session.address}:${session.port}",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                stringResource(R.string.remote_close_session),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(Floe.colors.destructive.copy(alpha = 0.08f))
                    .padding(horizontal = 10.dp, vertical = 6.dp)
                    .clickable { onCloseSession() },
            )
        }

        val terminal = state.terminal
        if (terminal != null) {
            G04TerminalView(
                engine = terminal.engine,
                transport = terminal.transport,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                statusLine = remoteTerminalStatusLabel(terminal.status),
            )
        } else {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    com.floe.android.design.FloeActivityIndicator(
                        description = stringResource(R.string.remote_connecting))
                    Spacer(Modifier.height(8.dp))
                    FloeText(
                        stringResource(R.string.remote_connecting),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }

        FloeDivider()
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                terminal?.status?.let { remoteTerminalStatusLabel(it) }
                    ?: remoteSessionStateLabel(session.state, session.transportConnected),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            terminal?.inputIssue?.let { issue ->
                FloeText(
                    stringResource(R.string.remote_input_issue, remoteIssueLabel(issue)),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
        }
    }

    if (tunnelsVisible) {
        RemoteTunnelSheet(
            state = state,
            onDismiss = { tunnelsVisible = false },
            onOpen = onOpenTunnel,
            onClose = onCloseTunnel,
        )
    }
    if (commandVisible) {
        RemoteCommandSheet(
            state = state,
            onDismiss = { commandVisible = false },
            onStart = onStartExec,
            onCancel = onCancelExec,
            onRelease = onReleaseExec,
        )
    }
}

@Composable
private fun RemoteTunnelSheet(
    state: RemoteHostUiState,
    onDismiss: () -> Unit,
    onOpen: (String, Int) -> Unit,
    onClose: (String) -> Unit,
) {
    var host by rememberSaveable { mutableStateOf("127.0.0.1") }
    var port by rememberSaveable { mutableStateOf("5900") }
    val error = validateTunnelTarget(host, port)
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.7f,
        heightFraction = 0.7f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_cancel),
                    onClick = onDismiss,
                    showHairline = false,
                )
                Spacer(Modifier.weight(1f))
                FloeText(
                    stringResource(R.string.remote_tunnels),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_tunnel_open),
                    onClick = {
                        val parsed = port.trim().toIntOrNull()
                        if (error == null && parsed != null) onOpen(host.trim(), parsed)
                    },
                    enabled = error == null,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(2f)) {
                    FloeText(
                        stringResource(R.string.remote_tunnel_host),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloePlainFormField(
                        label = stringResource(R.string.remote_tunnel_host),
                        value = host,
                        onValueChange = { host = it },
                    )
                }
                Column(Modifier.weight(1f)) {
                    FloeText(
                        stringResource(R.string.remote_tunnel_port),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloePlainFormField(
                        label = stringResource(R.string.remote_tunnel_port),
                        value = port,
                        onValueChange = { port = it },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    )
                }
            }
            error?.let {
                FloeText(
                    remoteMessage(it),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
            Spacer(Modifier.height(10.dp))
            if (state.tunnels.isEmpty()) {
                FloeText(
                    stringResource(R.string.remote_tunnel_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            } else {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    state.tunnels.forEach { tunnel ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Floe.colors.chromeSurface)
                                .padding(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                FloeText(
                                    "${tunnel.targetHost}:${tunnel.targetPort}",
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                )
                                FloeText(
                                    "${stringResource(R.string.remote_tunnel_local)} 127.0.0.1:${tunnel.localPort ?: "—"} · " +
                                        "${tunnel.bytesToRemote}B ↑ ${tunnel.bytesFromRemote}B ↓",
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                            FloeBadgePill(
                                text = remoteTunnelStateLabel(tunnel.state),
                                tone = if (tunnel.state == "open") {
                                    FloeBadgeTone.SUCCESS
                                } else {
                                    FloeBadgeTone.SECONDARY
                                },
                            )
                            Spacer(Modifier.width(8.dp))
                            FloeCapsuleAction(
                                label = stringResource(R.string.remote_tunnel_close),
                                onClick = { onClose(tunnel.id) },
                                showHairline = false,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RemoteCommandSheet(
    state: RemoteHostUiState,
    onDismiss: () -> Unit,
    onStart: (String) -> Unit,
    onCancel: () -> Unit,
    onRelease: () -> Unit,
) {
    var command by remember { mutableStateOf("") }
    val exec = state.exec
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.78f,
        heightFraction = 0.78f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_cancel),
                    onClick = onDismiss,
                    showHairline = false,
                )
                Spacer(Modifier.weight(1f))
                FloeText(
                    stringResource(R.string.remote_command),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                if (exec == null || exec.state == "exited" || exec.state == "cancelled" || exec.state == "unknown") {
                    FloeCapsuleAction(
                        label = stringResource(R.string.remote_release_command),
                        onClick = onRelease,
                        enabled = exec != null,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.remote_cancel_command),
                        onClick = onCancel,
                        tint = Floe.colors.destructive,
                    )
                }
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                FloePlainFormField(
                    label = stringResource(R.string.remote_command),
                    value = command,
                    onValueChange = { command = it },
                    modifier = Modifier.weight(1f),
                    singleLine = false,
                    minLines = 2,
                    maxLines = 4,
                    monospaced = true,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_run),
                    onClick = {
                        if (command.isNotBlank()) onStart(command)
                    },
                    enabled = command.isNotBlank() && exec == null,
                )
            }
            exec?.let {
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeBadgePill(
                        text = remoteExecStateLabel(it.state),
                        tone = when (it.state) {
                            "exited" -> FloeBadgeTone.SUCCESS
                            "cancelled", "unknown" -> FloeBadgeTone.PENDING
                            else -> FloeBadgeTone.ACCENT
                        },
                    )
                    Spacer(Modifier.width(8.dp))
                    FloeText(
                        "stdout ${it.stdoutBytes}B · stderr ${it.stderrBytes}B" +
                            (it.exitCode?.let { code -> " · exit $code" } ?: ""),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            val emptyOutput = stringResource(R.string.remote_output_empty)
            val outputText = exec?.output?.takeIf { it.isNotEmpty() } ?: emptyOutput
            Box(
                Modifier.fillMaxWidth().weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.chromeSurface)
                    .padding(10.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                FloeText(
                    text = outputText,
                    style = Floe.typography.evidence,
                    color = Floe.colors.label,
                )
            }
        }
    }
}
