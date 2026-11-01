// SPDX-License-Identifier: MPL-2.0
//
// C05 SFTP remote-file browser. Presentation only; every lane, byte and
// commit belongs to the App-owned controller and the native SFTP domain.

package com.floe.android.feature.sftp

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph

@Composable
fun SftpBrowserPage(
    state: SftpBrowserUiState,
    compact: Boolean,
    onClose: () -> Unit,
    onSelectHost: (String) -> Unit,
    onLoadPath: (String) -> Unit,
    onOpenEntry: (SftpEntryUi) -> Unit,
    onGoUp: () -> Unit,
    onRefresh: () -> Unit,
    onDownload: (SftpEntryUi) -> Unit,
    onConfirmDownload: () -> Unit,
    onCancelPending: () -> Unit,
    onUpload: (Uri) -> Unit,
    onCancelTransfer: () -> Unit,
    onApproveChallenge: (accept: Boolean, replaceChanged: Boolean) -> Unit,
    onDismissError: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri != null) onUpload(uri)
    }
    var pathDraft by remember(state.path) { mutableStateOf(state.path) }
    var showOverwrite by rememberSaveable(state.pendingDownload?.localPath) {
        mutableStateOf(state.pendingDownload != null)
    }
    LaunchedEffect(state.pendingDownload) {
        if (state.pendingDownload != null) showOverwrite = true
    }
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = state.lane?.displayName
                ?: stringResource(R.string.sftp_title),
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.sftp_close),
                    onClick = onClose,
                )
            },
            actions = {
                FloeCapsuleAction(
                    label = stringResource(R.string.sftp_refresh),
                    onClick = onRefresh,
                )
                Spacer(Modifier.width(6.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.sftp_upload),
                    onClick = { picker.launch(arrayOf("*/*")) },
                )
            },
            showHairline = true,
        )
        state.error?.let { error ->
            Row(
                Modifier.fillMaxWidth()
                    .background(Floe.colors.destructive.copy(alpha = 0.08f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
                Spacer(Modifier.width(8.dp))
                FloeText(
                    sftpErrorText(error),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.sftp_dismiss),
                    onClick = onDismissError,
                    showHairline = false,
                    tint = Floe.colors.destructive,
                )
            }
        }
        if (!state.coreReady && !state.loading) {
            FloeUnavailableView(
                icon = FloeIcons.Folder,
                title = stringResource(R.string.sftp_unavailable_title),
                description = stringResource(R.string.sftp_unavailable_body),
                modifier = Modifier.fillMaxSize(),
            )
            return@Column
        }
        val lane = state.lane
        if (lane == null) {
            HostPicker(state, onSelectHost)
            return@Column
        }
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeCapsuleAction(label = stringResource(R.string.sftp_up), onClick = onGoUp)
                FloeText(
                    "${lane.user}@${lane.address}:${lane.port}",
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
            }
            FloePlainFormField(
                label = stringResource(R.string.sftp_path),
                value = pathDraft,
                onValueChange = { pathDraft = it },
                enabled = state.busy == null,
                monospaced = true,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeCapsuleButton(
                    label = stringResource(R.string.sftp_open),
                    onClick = { onLoadPath(pathDraft) },
                    enabled = state.busy == null && pathDraft.isNotBlank(),
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleButton(
                    label = stringResource(R.string.sftp_go_home),
                    onClick = { pathDraft = lane.homePath; onLoadPath(lane.homePath) },
                    enabled = state.busy == null,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        FloeDivider()
        if (state.loading || state.busy != null) {
            Row(
                Modifier.fillMaxWidth().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeActivityIndicator()
                FloeText(
                    sftpBusyText(state.busy ?: "loading"),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (state.truncated) {
            FloeText(
                stringResource(R.string.sftp_truncated),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        if (state.entries.isEmpty() && !state.loading) {
            FloeText(
                stringResource(R.string.sftp_empty),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(16.dp),
            )
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            items(state.entries, key = { it.path }) { entry ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp)
                        .clickable(enabled = entry.isDirectory && state.busy == null) {
                            if (entry.isDirectory) onOpenEntry(entry)
                        }
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(
                        if (entry.isDirectory) FloeIcons.Folder else FloeIcons.Document,
                        Floe.colors.secondaryLabel,
                        20.dp,
                    )
                    Column(Modifier.weight(1f)) {
                        FloeText(
                            entry.name,
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                        )
                        if (!entry.isDirectory) {
                            FloeText(
                                sftpBytesText(entry.bytes),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                    if (!entry.isDirectory) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.sftp_download),
                            onClick = { onDownload(entry) },
                            showHairline = true,
                        )
                    }
                }
                FloeDivider()
            }
        }
        state.transfer?.let { transfer ->
            TransferBar(transfer, onCancelTransfer)
        }
        state.notice?.let { notice ->
            FloeText(
                sftpNoticeText(notice),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(12.dp),
            )
        }
    }

    val pending = state.pendingDownload
    if (pending != null && showOverwrite) {
        FloeActionSheet(
            visible = true,
            onDismiss = { showOverwrite = false; onCancelPending() },
            maxCardWidth = 560.dp,
        ) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    stringResource(R.string.sftp_overwrite_title),
                    style = Floe.typography.toolbarTitle,
                    color = Floe.colors.label,
                )
                FloeText(
                    stringResource(
                        R.string.sftp_overwrite_body,
                        pending.localPath,
                        sftpBytesText(pending.bytes),
                    ),
                    style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(
                        label = stringResource(R.string.sftp_cancel),
                        onClick = { showOverwrite = false; onCancelPending() },
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleButton(
                        label = stringResource(R.string.sftp_overwrite_confirm),
                        onClick = { showOverwrite = false; onConfirmDownload() },
                        prominent = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }

    val challenge = state.challenge
    if (challenge != null) {
        FloeActionSheet(
            visible = true,
            onDismiss = { onApproveChallenge(false, false) },
            maxCardWidth = 560.dp,
        ) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(
                    stringResource(
                        if (challenge.changed) R.string.sftp_host_changed_title
                        else R.string.sftp_trust_title
                    ),
                    style = Floe.typography.toolbarTitle,
                    color = Floe.colors.label,
                )
                FloeText(
                    stringResource(
                        if (challenge.changed) R.string.sftp_host_changed_body
                        else R.string.sftp_trust_body,
                        challenge.address,
                        challenge.port,
                        challenge.keyType,
                        challenge.fingerprint,
                    ),
                    style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(
                        label = stringResource(R.string.sftp_cancel),
                        onClick = { onApproveChallenge(false, false) },
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleButton(
                        label = stringResource(
                            if (challenge.changed) R.string.sftp_host_replace
                            else R.string.sftp_trust_confirm
                        ),
                        onClick = { onApproveChallenge(true, challenge.changed) },
                        prominent = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun HostPicker(state: SftpBrowserUiState, onSelectHost: (String) -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeText(
            stringResource(R.string.sftp_choose_host),
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
        )
        if (state.hosts.isEmpty() && !state.loading) {
            FloeText(
                stringResource(R.string.sftp_no_hosts),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
        } else {
            state.hosts.forEach { host ->
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Floe.colors.chromeSurface)
                        .clickable(enabled = state.busy == null) { onSelectHost(host.id) }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    IconGlyph(FloeIcons.Terminal, Floe.colors.accent, 20.dp)
                    Column(Modifier.weight(1f)) {
                        FloeText(host.displayName, style = Floe.typography.body, color = Floe.colors.label)
                        FloeText(
                            "${host.user}@${host.address}:${host.port}",
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
            }
        }
        if (state.loading) FloeActivityIndicator()
    }
}

@Composable
private fun TransferBar(transfer: SftpTransferUi, onCancel: () -> Unit) {
    val stateText = sftpTransferStateText(transfer)
    Column(
        Modifier.fillMaxWidth().background(Floe.colors.chromeSurface).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeText(
                "${transfer.displayName} · $stateText",
                style = Floe.typography.metadata,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            if (transfer.state == "running" || transfer.state == "completing") {
                FloeCapsuleAction(
                    label = stringResource(R.string.sftp_cancel),
                    onClick = onCancel,
                    showHairline = false,
                    tint = Floe.colors.destructive,
                )
            }
        }
        FloeText(
            if (transfer.totalBytes > 0)
                "${sftpBytesText(transfer.bytesDone)} / ${sftpBytesText(transfer.totalBytes)}"
            else sftpBytesText(transfer.bytesDone),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (transfer.errorCode != null) {
            FloeText(
                sftpTransferErrorText(transfer.errorCode),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
        }
    }
}
