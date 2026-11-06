// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.RuntimeHost
import com.floe.android.host.externaledit.ExternalEditOwner
import com.floe.android.host.externaledit.ExternalEditPhase

@Composable
internal fun ExternalEditorSheet(host: RuntimeHost, taskID: String, workspaceID: String,
    suggestedPath: String, visible: Boolean, onOpenLinux: (String) -> Unit, onDismiss: () -> Unit) {
    if (!visible) return
    val service = host.externalEdits
    val state by service.state.collectAsState()
    val activity = LocalContext.current as? Activity
    var path by remember(taskID, workspaceID, suggestedPath) { mutableStateOf(suggestedPath) }
    val owner = remember(taskID, workspaceID) { ExternalEditOwner(taskID, workspaceID) }
    val rows = state.records.filter { it.owner.taskID.equals(taskID, true) &&
        it.owner.workspaceID.equals(workspaceID, true) }
    var opened by rememberSaveable(taskID, workspaceID, suggestedPath) { mutableStateOf(false) }
    LaunchedEffect(activity, taskID, workspaceID, suggestedPath) {
        if (!opened && activity != null && suggestedPath.isNotBlank()) {
            opened = true
            val existing = rows.firstOrNull { it.logicalPath == suggestedPath && it.linuxWorkingPath == null &&
                it.phase in setOf(ExternalEditPhase.EDITING, ExternalEditPhase.SAVED, ExternalEditPhase.PAUSED) }
            // This sheet was explicitly opened for external editing. Use the
            // Android default app directly; retain this surface for return,
            // conflicts and choosing a different editor. Do not relaunch on resume.
            service.openAndroid(activity, owner, suggestedPath.trim(), existing?.id, forceChooser = false)
        }
    }
    FloeActionSheet(visible = visible, onDismiss = onDismiss, maxCardWidth = 640.dp) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                FloeText(stringResource(R.string.external_edit_title))
                FloeCapsuleButton(stringResource(R.string.external_edit_done), onClick = onDismiss)
            }
            FloeText(stringResource(R.string.external_edit_description), color = Floe.colors.secondaryLabel)
            FloePlainFormField(stringResource(R.string.external_edit_path), path, { path = it }, monospaced = true)
            FloeCapsuleButton(stringResource(if (state.preparing) R.string.external_edit_preparing else R.string.external_edit_open),
                enabled = activity != null && path.isNotBlank() && !state.preparing,
                onClick = { activity?.let { service.openAndroid(it, owner, path.trim()) } })
            FloeCapsuleButton(stringResource(R.string.external_edit_linux),
                enabled = path.isNotBlank() && !state.preparing,
                onClick = { onOpenLinux(path.trim()) })
            state.failure?.let { code ->
                FloeText(stringResource(when (code) {
                    "noEditor" -> R.string.external_edit_no_handler
                    "editorAlreadyOpen" -> R.string.external_edit_already_open
                    else -> R.string.external_edit_retry_error
                }), color = Floe.colors.secondaryLabel)
            }
            rows.forEach { row ->
                FloeSectionHeader(row.displayName)
                val label = when (row.phase) {
                    ExternalEditPhase.EDITING -> R.string.external_edit_waiting
                    ExternalEditPhase.COMMITTING -> R.string.external_edit_saving
                    ExternalEditPhase.SAVED -> R.string.external_edit_saved
                    ExternalEditPhase.CONFLICT -> R.string.external_edit_conflict
                    ExternalEditPhase.SOURCE_PENDING -> R.string.external_edit_source_pending
                    ExternalEditPhase.PAUSED -> R.string.external_edit_retry_error
                    ExternalEditPhase.FINISHED -> if (row.pendingSHA256 != null)
                        R.string.external_edit_unconfirmed else R.string.external_edit_finished
                }
                FloeText(stringResource(label), color = Floe.colors.secondaryLabel)
                if (row.errorCode == "noEditor") FloeText(stringResource(R.string.external_edit_no_handler))
                val busy = row.id in state.busy
                if (row.linuxWorkingPath == null && row.phase in setOf(
                        ExternalEditPhase.EDITING, ExternalEditPhase.SAVED, ExternalEditPhase.PAUSED)) {
                    FloeCapsuleButton(stringResource(R.string.external_edit_open),
                        enabled = activity != null && !busy && !state.preparing,
                        onClick = { activity?.let { service.openAndroid(it, owner, row.logicalPath, row.id) } })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(stringResource(R.string.external_edit_view_copy), enabled = activity != null,
                        onClick = { activity?.let { service.viewCopy(it, row.id) } })
                    FloeCapsuleButton(stringResource(R.string.external_edit_view_original), enabled = activity != null,
                        onClick = { activity?.let { service.viewOriginal(it, row.id) } })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (row.phase != ExternalEditPhase.FINISHED && row.phase != ExternalEditPhase.CONFLICT) {
                        FloeCapsuleButton(stringResource(R.string.external_edit_check), enabled = !busy,
                            onClick = { service.retry(row.id) })
                    }
                }
                if (row.phase == ExternalEditPhase.CONFLICT) {
                    FloeText(stringResource(R.string.external_edit_conflict_description))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(stringResource(R.string.external_edit_use_copy), enabled = !busy,
                            onClick = { service.resolve(row.id, true, row.editedSHA256, row.conflictSHA256) })
                        FloeCapsuleButton(stringResource(R.string.external_edit_keep_current), enabled = !busy,
                            onClick = { service.resolve(row.id, false, row.editedSHA256, row.conflictSHA256) })
                    }
                } else if (row.phase != ExternalEditPhase.FINISHED) {
                    FloeCapsuleButton(stringResource(R.string.external_edit_finish), enabled = !busy,
                        onClick = { service.finish(row.id) })
                }
            }
        }
    }
}
