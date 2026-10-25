// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.G04WorkspaceEditorController
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Explicit recovery of unconfirmed text retained by the Application.
 * Copying to this selected workspace is a user choice; old generations are
 * never replayed into a newer document. Only verified disk proof releases it. */
@Composable
internal fun WorkspaceRecoveryPanel(
    host: RuntimeHost,
    target: G04WorkspaceBridgeClient,
    visible: Boolean,
    onDismiss: () -> Unit,
    onOpenFile: (String) -> Unit,
    onTreeChanged: () -> Unit,
) {
    val context = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    var rows by remember(host, target) { mutableStateOf(emptyList<G04WorkspaceEditorController.RecoveryRow>()) }
    var preview by remember(host, target) { mutableStateOf<G04WorkspaceEditorController.RecoveryRow?>(null) }
    var discard by remember(host, target) { mutableStateOf<G04WorkspaceEditorController.RecoveryRow?>(null) }
    var saved by remember(host, target) { mutableStateOf<String?>(null) }
    var failure by remember(host, target) { mutableStateOf<String?>(null) }
    var busy by remember(host, target) { mutableStateOf(false) }
    suspend fun refresh() { rows = withContext(host.ioDispatcher) { host.workspaceEditors.recoveryRows() } }
    LaunchedEffect(visible, target) {
        preview = null; discard = null; saved = null; failure = null
        if (visible) refresh() else rows = emptyList()
    }
    FloeActionSheet(visible = visible, onDismiss = onDismiss, maxCardWidth = 640.dp) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(R.string.workspace_recovery_title), style = Floe.typography.toolbarTitle)
            FloeText(stringResource(R.string.workspace_recovery_caption), color = Floe.colors.secondaryLabel)
            if (busy) FloeActivityIndicator()
            failure?.let { FloeText(it, color = Floe.colors.secondaryLabel) }
            saved?.let { path ->
                FloeText(stringResource(R.string.workspace_recovery_saved))
                FloeText(path, style = Floe.typography.metadata)
                FloeCapsuleButton(stringResource(R.string.workspace_recovery_open), onClick = { onOpenFile(path); onDismiss() })
            }
            if (rows.isEmpty()) FloeText(stringResource(R.string.workspace_recovery_empty), color = Floe.colors.secondaryLabel)
            rows.forEach { row ->
                FloeDivider()
                FloeText(row.projection.relativePath)
                if (row.projection.composing) FloeText(stringResource(R.string.workspace_recovery_composing), color = Floe.colors.secondaryLabel)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    // Weighted siblings: an unweighted FloeCapsuleButton fills
                    // the whole row and collapses its neighbors off-screen.
                    FloeCapsuleButton(stringResource(R.string.workspace_recovery_preview), onClick = { preview = row }, enabled = !busy, modifier = Modifier.weight(1f))
                    FloeCapsuleButton(stringResource(R.string.workspace_recovery_copy), enabled = !busy && !row.projection.composing, modifier = Modifier.weight(1f), onClick = {
                        busy = true; failure = null
                        scope.launch {
                            try {
                                saved = host.workspaceEditors.copyRecovery(row, target)
                                refresh(); onTreeChanged()
                            } catch (error: Exception) {
                                if (error is CancellationException) throw error
                                val code = (error as? G04WorkspaceBridgeClient.Failure)?.code
                                failure = context.getString(if (code == "contentTooLarge") R.string.workspace_size_error else R.string.workspace_recovery_failed)
                            } finally { busy = false }
                        }
                    })
                    FloeCapsuleButton(stringResource(R.string.workspace_recovery_discard), onClick = { discard = row }, enabled = !busy, modifier = Modifier.weight(1f))
                }
            }
        }
    }
    FloeActionSheet(visible = visible && preview != null, onDismiss = { preview = null }, maxCardWidth = 640.dp) {
        val row = preview ?: return@FloeActionSheet
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(row.projection.relativePath, style = Floe.typography.toolbarTitle)
            // Display is bounded independently of the FULL recovery upload.
            if (row.projection.text.length > 4096) FloeText(stringResource(R.string.workspace_recovery_preview_partial), color = Floe.colors.secondaryLabel)
            SelectionContainer { FloeText(row.projection.text.take(4096)) }
        }
    }
    FloeActionSheet(visible = visible && discard != null, onDismiss = { discard = null }) {
        val row = discard ?: return@FloeActionSheet
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(R.string.workspace_recovery_discard_confirmation))
            FloeText(row.projection.relativePath, color = Floe.colors.secondaryLabel)
            FloeCapsuleButton(stringResource(R.string.workspace_recovery_discard), prominent = true, enabled = !busy, onClick = {
                busy = true; failure = null
                scope.launch {
                    try {
                        val released = withContext(host.ioDispatcher) { host.workspaceEditors.discardRecovery(row) }
                        if (!released) failure = context.getString(R.string.workspace_recovery_changed)
                        discard = null; refresh()
                    } finally { busy = false }
                }
            })
            FloeCapsuleButton(stringResource(R.string.cancel), onClick = { discard = null }, enabled = !busy)
        }
    }
}
