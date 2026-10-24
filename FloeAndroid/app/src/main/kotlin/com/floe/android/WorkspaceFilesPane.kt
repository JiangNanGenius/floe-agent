// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.feature.ide.FloeIdeWorkspace
import com.floe.android.host.G04WorkspaceEditorController
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostReadiness
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private class WorkspacePaneOwner {
    val live = AtomicBoolean(true)
}
private typealias WorkspacePaneBinding = G04WorkspaceEditorController.Binding
private enum class WorkspaceAction(val label: Int) {
    FILE(R.string.workspace_new_file), DIRECTORY(R.string.workspace_new_folder),
    MOVE(R.string.workspace_move), COPY(R.string.workspace_copy), DELETE(R.string.workspace_delete),
}

/** Visible ordinary-task entry only. Opening the pane may bind that task's
 * real workspace; composition elsewhere never creates one or starts a Run.
 * The service owns drafts after this presentation is dismissed.
 */
@Composable
internal fun WorkspaceFilesPane(host: RuntimeHost?, taskID: String?, onDismiss: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val entry = taskID?.let { host?.conversations?.entryFor(it) }
    if (host == null || taskID == null || entry == null || entry.isTemporary) {
        FloeUnavailableView(icon = FloeIcons.Folder, title = stringResource(R.string.inspector_files),
            description = stringResource(if (entry?.isTemporary == true) R.string.workspace_temporary_unavailable else R.string.root_detail_absent))
        return
    }
    val readiness by host.readiness.collectAsState()
    val domain = readiness.domains["workspaceDomain"] as? RuntimeHostReadiness.DomainReadiness.Available
    val owner = remember(host, taskID, entry, domain?.generation) { WorkspacePaneOwner() }
    var binding by remember(owner) { mutableStateOf<WorkspacePaneBinding?>(null) }
    var failure by remember(owner) { mutableStateOf<String?>(null) }
    var retry by remember(owner) { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val errorText: (String) -> String = { code ->
        context.getString(when (code) {
            "staleRevision", "conflict", "dirtyDocument" -> R.string.workspace_conflict_error
            "secretFile", "escapesRoot", "notAdmitted" -> R.string.workspace_access_error
            "contentTooLarge", "bufferLimit" -> R.string.workspace_size_error
            "languageServerUnavailable" -> R.string.workspace_language_unavailable
            "operationPending" -> R.string.workspace_run_pending
            "ownerChanged", "ownerUnavailable", "retired", "epochMismatch" -> R.string.workspace_owner_error
            else -> R.string.workspace_operation_error
        })
    }
    DisposableEffect(owner) {
        onDispose { owner.live.set(false) }
    }
    LaunchedEffect(owner, retry, readiness.storeReady) {
        binding = null; failure = null
        if (domain == null || !readiness.storeReady) {
            failure = context.getString(R.string.inspector_runtime_pending)
            return@LaunchedEffect
        }
        try {
            val retained = withContext(host.ioDispatcher) { host.workspaceEditors.acquire(taskID, errorText, owner.live) }
            if (owner.live.get() && retained.isCurrent()) binding = retained
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (owner.live.get()) failure = errorText((error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError")
        }
    }
    val bound = binding
    if (bound == null) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (failure == null) FloeActivityIndicator() else {
                FloeText(failure!!, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                FloeCapsuleButton(stringResource(R.string.workspace_retry), onClick = { retry++ })
            }
        }
        return
    }
    val presenter = bound.presenter
    val sourceLane = remember(bound, host) {
        host.nativeRootEpoch()?.let { epoch ->
            host.workspaceSourceHost?.laneFor(
                taskID = bound.client.taskID, workspaceID = bound.client.workspaceID,
                nativeEpoch = epoch, hostGeneration = host.commandClient.generation(),
                isCurrentOwner = bound.isCurrent,
            )
        }
    }
    var sourcesVisible by remember(owner) { mutableStateOf(false) }
    var recoveryVisible by remember(owner) { mutableStateOf(false) }
    var networkVisible by remember(owner) { mutableStateOf(false) }
    var action by remember(owner) { mutableStateOf<WorkspaceAction?>(null) }
    var source by remember(owner) { mutableStateOf("") }
    var destination by remember(owner) { mutableStateOf("") }
    var operationError by remember(owner) { mutableStateOf<String?>(null) }
    var busy by remember(owner) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            WorkspaceAction.entries.take(2).forEach { item ->
                FloeCapsuleButton(stringResource(item.label), onClick = { source = ""; destination = ""; operationError = null; action = item },
                    modifier = Modifier.weight(1f), enabled = !busy)
            }
            FloeCapsuleButton(stringResource(R.string.workspace_file_actions), onClick = {
                source = ""; destination = ""; operationError = null; action = WorkspaceAction.MOVE
            }, modifier = Modifier.weight(1f), enabled = !busy)
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
            FloeCapsuleButton(stringResource(R.string.workspace_source_title),
                onClick = { sourcesVisible = true }, enabled = !busy)
            FloeCapsuleButton(stringResource(R.string.network_workspace_title),
                onClick = { networkVisible = true }, enabled = !busy)
            FloeCapsuleButton(stringResource(R.string.workspace_recovery_title),
                onClick = { recoveryVisible = true }, enabled = !busy)
        }
        FloeDivider()
        FloeIdeWorkspace(presenter, onBack = onDismiss, modifier = Modifier.weight(1f))
    }
    WorkspaceRecoveryPanel(host, bound.client, recoveryVisible, onDismiss = { recoveryVisible = false },
        onOpenFile = { presenter.openFile(it) }, onTreeChanged = { bound.ide.refreshWorkspace(); presenter.loadTreeRoot() })
    FloePageSheet(visible = networkVisible, onDismiss = { networkVisible = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            WorkspaceNetworkPanel(
                host = host, taskID = bound.client.taskID, workspaceID = bound.client.workspaceID,
                isOwnerCurrent = bound.isCurrent,
                onOpenWorkspaceFile = { path -> presenter.openFile(path); networkVisible = false },
                onWorkspaceTreeChanged = { bound.ide.refreshWorkspace(); presenter.loadTreeRoot() },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    FloePageSheet(visible = sourcesVisible, onDismiss = { sourcesVisible = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            WorkspaceSourcePanel(sourceLane,
                onOpenWorkspaceFile = { path -> presenter.openFile(path); sourcesVisible = false },
                onWorkspaceTreeChanged = { bound.ide.refreshWorkspace(); presenter.loadTreeRoot() },
                modifier = Modifier.fillMaxWidth())
        }
    }
    FloePageSheet(visible = action != null, onDismiss = { if (!busy) action = null }) {
        val selected = action ?: return@FloePageSheet
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(selected.label), style = Floe.typography.toolbarTitle, color = Floe.colors.label)
            if (selected in setOf(WorkspaceAction.MOVE, WorkspaceAction.COPY, WorkspaceAction.DELETE)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(WorkspaceAction.MOVE, WorkspaceAction.COPY, WorkspaceAction.DELETE).forEach { item ->
                        FloeCapsuleButton(stringResource(item.label), onClick = { action = item; operationError = null },
                            modifier = Modifier.weight(1f), enabled = !busy, prominent = item == selected)
                    }
                }
            }
            FloePlainFormField(stringResource(R.string.workspace_relative_path), source, { source = it }, enabled = !busy, monospaced = true)
            if (selected == WorkspaceAction.MOVE || selected == WorkspaceAction.COPY) {
                FloePlainFormField(stringResource(R.string.workspace_destination_path), destination, { destination = it }, enabled = !busy, monospaced = true)
            }
            if (selected == WorkspaceAction.DELETE) FloeText(stringResource(R.string.workspace_delete_confirmation), style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            operationError?.let { FloeText(it, style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
            if (busy) FloeActivityIndicator()
            FloeCapsuleButton(stringResource(if (selected == WorkspaceAction.DELETE) R.string.workspace_delete else R.string.workspace_apply),
                enabled = !busy && source.isNotBlank() && (selected !in setOf(WorkspaceAction.MOVE, WorkspaceAction.COPY) || destination.isNotBlank()),
                prominent = true, onClick = {
                    val path = source.trim(); val target = destination.trim(); val requested = selected
                    busy = true; operationError = null
                    scope.launch {
                        try {
                            withContext(host.ioDispatcher) {
                                val operation = when (requested) {
                                    WorkspaceAction.FILE -> "createFile"; WorkspaceAction.DIRECTORY -> "createDirectory"
                                    WorkspaceAction.MOVE -> "move"; WorkspaceAction.COPY -> "copy"; WorkspaceAction.DELETE -> "delete"
                                }
                                bound.client.request(operation, buildJsonObject {
                                    if (requested == WorkspaceAction.MOVE || requested == WorkspaceAction.COPY) {
                                        put("from", path); put("to", target)
                                    } else put("path", path)
                                    if (requested == WorkspaceAction.FILE) put("content", "")
                                    if (requested == WorkspaceAction.DELETE) put("recursive", true)
                                })
                            }
                            if (owner.live.get()) { action = null; bound.ide.refreshWorkspace(); presenter.loadTreeRoot() }
                        } catch (error: Exception) {
                            if (error is CancellationException) throw error
                            if (owner.live.get()) operationError = errorText((error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError")
                        } finally { if (owner.live.get()) busy = false }
                    }
                })
            FloeCapsuleButton(stringResource(R.string.cancel), onClick = { action = null }, enabled = !busy)
        }
    }
}
