// SPDX-License-Identifier: MPL-2.0
//
// VNC-only host creation and VNC endpoint editing. These sheets carry no
// transport or credential authority; the App controller writes the VNC
// password only through the approved credential gateway.

package com.floe.android.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

@Composable
internal fun RemoteVncHostSheet(
    draft: RemoteVncHostDraft,
    onDraftChange: (RemoteVncHostDraft) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    var revealed by remember { mutableStateOf(false) }
    val validation = validateRemoteVncHostDraft(draft)
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.66f,
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
                    stringResource(R.string.remote_vnc_hosts_add),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_save),
                    onClick = onSave,
                    enabled = validation == null,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FieldLabel(stringResource(R.string.remote_display_name))
                FloePlainFormField(
                    label = stringResource(R.string.remote_display_name),
                    value = draft.displayName,
                    onValueChange = { onDraftChange(draft.copy(displayName = it)) },
                )
                FieldLabel(stringResource(R.string.remote_vnc_host))
                FloePlainFormField(
                    label = stringResource(R.string.remote_vnc_host),
                    value = draft.host,
                    onValueChange = { onDraftChange(draft.copy(host = it)) },
                )
                FieldLabel(stringResource(R.string.remote_vnc_port))
                FloePlainFormField(
                    label = stringResource(R.string.remote_vnc_port),
                    value = draft.port,
                    onValueChange = { onDraftChange(draft.copy(port = it)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                FieldLabel(stringResource(R.string.remote_vnc_password))
                SecureSecretField(
                    label = stringResource(R.string.remote_vnc_password),
                    value = draft.password,
                    onValueChange = { onDraftChange(draft.copy(password = it)) },
                    revealed = revealed,
                    onRevealedChange = { revealed = it },
                    revealLabel = stringResource(R.string.remote_reveal_secret),
                    hideLabel = stringResource(R.string.remote_hide_secret),
                    singleLine = true,
                    minLines = 1,
                    maxLines = 1,
                    monospaced = false,
                )
                validation?.let {
                    FloeText(
                        remoteMessage(it),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                FloeText(
                    stringResource(R.string.remote_vnc_host_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
    }
}

@Composable
internal fun RemoteVncEndpointSheet(
    draft: RemoteVncEndpointDraft,
    allowTunnel: Boolean,
    onDraftChange: (RemoteVncEndpointDraft) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    var revealed by remember { mutableStateOf(false) }
    val validation = validateRemoteVncEndpointDraft(draft, allowTunnel)
    val transportIndex = if (draft.transport == RemoteVncEndpointDraft.TRANSPORT_SSH) 1 else 0
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.68f,
        heightFraction = 0.85f,
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
                    stringResource(R.string.remote_vnc_edit_endpoint),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_save),
                    onClick = onSave,
                    enabled = validation == null,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FieldLabel(stringResource(R.string.remote_vnc_display_name))
                FloePlainFormField(
                    label = stringResource(R.string.remote_vnc_display_name),
                    value = draft.displayName,
                    onValueChange = { onDraftChange(draft.copy(displayName = it)) },
                )
                FieldLabel(stringResource(R.string.remote_vnc_transport))
                FloeSegmented(
                    options = listOf(
                        stringResource(R.string.remote_vnc_direct),
                        stringResource(R.string.remote_vnc_ssh_tunnel),
                    ),
                    selectedIndex = transportIndex,
                    onSelect = { index ->
                        if (index == 0 || allowTunnel) {
                            onDraftChange(
                                draft.copy(
                                    transport = if (index == 1) {
                                        RemoteVncEndpointDraft.TRANSPORT_SSH
                                    } else {
                                        RemoteVncEndpointDraft.TRANSPORT_DIRECT
                                    },
                                    keepPassword = true,
                                ),
                            )
                        }
                    },
                )
                FieldLabel(stringResource(R.string.remote_vnc_host))
                FloePlainFormField(
                    label = stringResource(R.string.remote_vnc_host),
                    value = draft.host,
                    onValueChange = { onDraftChange(draft.copy(host = it)) },
                )
                FieldLabel(stringResource(R.string.remote_vnc_port))
                FloePlainFormField(
                    label = stringResource(R.string.remote_vnc_port),
                    value = draft.port,
                    onValueChange = { onDraftChange(draft.copy(port = it)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                FieldLabel(stringResource(R.string.remote_vnc_password))
                SecureSecretField(
                    label = stringResource(R.string.remote_secret_keep_hint),
                    value = draft.password,
                    onValueChange = {
                        onDraftChange(draft.copy(password = it, keepPassword = it.isBlank()))
                    },
                    revealed = revealed,
                    onRevealedChange = { revealed = it },
                    revealLabel = stringResource(R.string.remote_reveal_secret),
                    hideLabel = stringResource(R.string.remote_hide_secret),
                    singleLine = true,
                    minLines = 1,
                    maxLines = 1,
                    monospaced = false,
                )
                validation?.let {
                    FloeText(
                        remoteMessage(it),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                if (draft.transport == RemoteVncEndpointDraft.TRANSPORT_SSH) {
                    FloeText(
                        stringResource(R.string.remote_vnc_ssh_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
    }
}

@Composable
internal fun RemoteVncEndpointPickerSheet(
    hostName: String,
    endpoints: List<RemoteVncEndpointUi>,
    onConnect: (RemoteVncEndpointUi) -> Unit,
    onAdd: () -> Unit,
    onEdit: (RemoteVncEndpointUi) -> Unit,
    onDelete: (RemoteVncEndpointUi) -> Unit,
    onDismiss: () -> Unit,
) {
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.64f,
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
                    "$hostName · ${stringResource(R.string.remote_vnc_endpoints)}",
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_vnc_add_endpoint),
                    onClick = onAdd,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            if (endpoints.isEmpty()) {
                FloeText(
                    stringResource(R.string.remote_vnc_no_endpoints),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            } else {
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    endpoints.forEach { endpoint ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Floe.colors.chromeSurface)
                                .padding(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                FloeText(
                                    endpoint.displayName,
                                    style = Floe.typography.bodyEmphasized,
                                    color = Floe.colors.label,
                                )
                                FloeText(
                                    "${endpoint.target} · " + stringResource(
                                        if (endpoint.transport == "sshTunnel") {
                                            R.string.remote_vnc_ssh_tunnel
                                        } else {
                                            R.string.remote_vnc_direct
                                        },
                                    ),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                            FloeCapsuleAction(
                                label = stringResource(R.string.remote_connect),
                                onClick = { onConnect(endpoint) },
                                showHairline = false,
                            )
                            Spacer(Modifier.width(6.dp))
                            FloeCapsuleAction(
                                label = stringResource(R.string.remote_edit),
                                onClick = { onEdit(endpoint) },
                                showHairline = false,
                            )
                            Spacer(Modifier.width(6.dp))
                            FloeCapsuleAction(
                                label = stringResource(R.string.remote_delete),
                                onClick = { onDelete(endpoint) },
                                showHairline = false,
                                tint = Floe.colors.destructive,
                            )
                        }
                    }
                }
            }
        }
    }
}
