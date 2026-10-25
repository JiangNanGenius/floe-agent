// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.LocalNetworkAccessBroker
import com.floe.android.host.NetworkWorkspaceHostController
import com.floe.android.host.RuntimeHost

/**
 * G04-R1 reusable Network storage panel (WebDAV + SMB) for one ordinary
 * task workspace. Presentation-only: every mount, progress, conflict and
 * credential fact comes from the trusted host lane / native authority
 * (`floe_g04_net_*`). The password field is write-only and cleared at
 * submit; endpoints render in the native REDACTED form; denied/unavailable
 * states are shown honestly; cancel is a visible request until native
 * proves settlement; journaled recovery stays reachable.
 */
@Composable
internal fun WorkspaceNetworkPanel(
    host: RuntimeHost,
    taskID: String,
    workspaceID: String,
    isOwnerCurrent: () -> Boolean,
    onOpenWorkspaceFile: (String) -> Unit,
    onWorkspaceTreeChanged: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val controller = host.networkWorkspaceHost
    val lane = remember(controller, taskID, workspaceID) {
        val epoch = host.nativeRootEpoch()
        if (epoch == null) null else controller?.laneFor(
            taskID = taskID, workspaceID = workspaceID, nativeEpoch = epoch,
            hostGeneration = host.commandClient.generation(), isCurrentOwner = isOwnerCurrent)
    }
    if (lane == null) {
        FloeUnavailableView(icon = FloeIcons.Folder,
            title = stringResource(R.string.network_workspace_title),
            description = stringResource(R.string.network_workspace_runtime_pending))
        return
    }
    val state by lane.state.collectAsState()
    LaunchedEffect(lane) { lane.refresh() }
    LaunchedEffect(state.operations.map { it.state }) {
        // One tree refresh after an import lands (the workspace body exists).
        if (state.operations.any { it.state == "completed" && it.result["logicalPath"] != null }) {
            onWorkspaceTreeChanged()
        }
    }

    var editing by remember(lane) { mutableStateOf<NetworkMountDraftModel?>(null) }
    var browseMount by remember(lane) { mutableStateOf<NetworkMountRow?>(null) }
    var confirming by remember(lane) { mutableStateOf<NetworkMountRow?>(null) }
    var forgetCredential by remember(lane) { mutableStateOf(true) }

    Column(modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // header
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            FloeText(stringResource(R.string.network_workspace_title),
                style = Floe.typography.toolbarTitle, color = Floe.colors.label,
                modifier = Modifier.weight(1f))
            // Weighted siblings: unweighted capsule buttons fill and collapse
            // their row partners (420dp inspector evidence, 2026-10-25).
            FloeCapsuleButton(stringResource(R.string.network_workspace_refresh),
                onClick = { lane.refresh() }, enabled = !state.busy, modifier = Modifier.weight(1f))
            FloeCapsuleButton(stringResource(R.string.network_workspace_add), prominent = true,
                onClick = { editing = NetworkMountDraftModel() }, enabled = !state.busy,
                modifier = Modifier.weight(1f))
        }
        if (!state.runtimeAvailable) {
            FloeText(stringResource(R.string.network_workspace_runtime_unavailable),
                style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }

        // mounts
        FloeDivider()
        if (state.mounts.isEmpty()) {
            FloeText(stringResource(R.string.network_workspace_none),
                style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }
        state.mounts.forEach { mount ->
            NetworkMountRowView(mount = mount, busy = state.busy,
                onBrowse = { browseMount = mount; lane.browse(mount.id, "", mount.endpoint) },
                onConnect = { lane.probeMount(mount.id, mount.endpoint) },
                onDisconnect = { lane.disconnectMount(mount.id, mount.endpoint) },
                onEdit = { editing = NetworkMountDraftModel(mount) },
                onRemove = { confirming = mount; forgetCredential = true })
        }

        // bound network sources (save back over the journal ladder)
        if (state.sources.isNotEmpty()) {
            FloeDivider()
            FloeSectionHeader(stringResource(R.string.network_workspace_sources_title))
            state.sources.forEach { source ->
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        FloeText(source.path, style = Floe.typography.body, color = Floe.colors.label)
                        FloeText(networkSourceSubtitle(context, source),
                            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    FloeCapsuleButton(stringResource(R.string.network_workspace_save),
                        enabled = !state.busy, modifier = Modifier.weight(1f),
                        onClick = { lane.startSave(source.id, endpointForSource(state, source.id)) })
                }
            }
        }

        // operations
        if (state.operations.isNotEmpty()) {
            FloeDivider()
            FloeSectionHeader(stringResource(R.string.network_workspace_operations_title))
            state.operations.forEach { operation ->
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    FloeText("${networkOperationLabel(context, operation.kind)} · ${operation.displayName}",
                        style = Floe.typography.body, color = Floe.colors.label)
                    FloeText(networkOperationStateText(context, operation),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    if (operation.entriesFailed > 0) {
                        FloeText(stringResource(R.string.network_workspace_partial_hint),
                            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (operation.isLive) {
                            FloeCapsuleButton(stringResource(R.string.network_workspace_cancel_request),
                                modifier = Modifier.weight(1f),
                                onClick = { lane.cancelOperation(operation.id) })
                        }
                        operation.recoverableRecoveryID?.let { recoveryID ->
                            FloeCapsuleButton(stringResource(R.string.network_workspace_reconcile),
                                enabled = !state.busy, modifier = Modifier.weight(1f),
                                onClick = { lane.startReconcile(recoveryID, endpointForMount(state, operation.mountID)) })
                        }
                        if (operation.state == "completed" && operation.result["logicalPath"] != null) {
                            FloeCapsuleButton(stringResource(R.string.network_workspace_open),
                                modifier = Modifier.weight(1f),
                                onClick = { onOpenWorkspaceFile(operation.result.getValue("logicalPath")) })
                        }
                        if (!operation.isLive) {
                            FloeCapsuleButton(stringResource(R.string.network_workspace_dismiss),
                                modifier = Modifier.weight(1f),
                                onClick = { lane.dismissOperation(operation.id) })
                        }
                    }
                }
            }
        }

        // export (never overwrites)
        FloeDivider()
        FloeSectionHeader(stringResource(R.string.network_workspace_export_title))
        NetworkExportSection(state = state, busy = state.busy,
            onExport = { mountID, logicalPath, remotePath, conflictCopy ->
                lane.startExport(mountID, logicalPath, remotePath, conflictCopy,
                    endpointForMount(state, mountID))
            })

        // honest message row
        state.messageToken?.let { token ->
            FloeDivider()
            FloeText(networkMessageText(context, token),
                style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            if (token == LocalNetworkAccessBroker.CODE_DENIED ||
                token == LocalNetworkAccessBroker.CODE_RECOVERY) {
                FloeCapsuleButton(stringResource(R.string.network_workspace_retry),
                    onClick = { lane.refresh() })
            }
        }
        if (state.busy) FloeActivityIndicator()
    }

    // ---- add / edit sheet ----
    val draft = editing
    if (draft != null) {
        FloeActionSheet(visible = true, onDismiss = { if (!state.busy) editing = null }, maxCardWidth = 640.dp) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeText(stringResource(if (draft.mountID == null) R.string.network_workspace_add
                                        else R.string.network_workspace_edit),
                    style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                FloeSegmented(options = listOf("WebDAV", "SMB"),
                    selectedIndex = if (draft.transport == "smb") 1 else 0,
                    onSelect = { index -> editing = draft.copy(transport = if (index == 1) "smb" else "webdav") })
                FloePlainFormField(stringResource(R.string.network_workspace_name), draft.name,
                    { editing = draft.copy(name = it) }, enabled = !state.busy)
                FloePlainFormField(stringResource(R.string.network_workspace_endpoint), draft.endpoint,
                    { editing = draft.copy(endpoint = it) }, enabled = !state.busy, monospaced = true)
                FloePlainFormField(stringResource(R.string.network_workspace_root_path), draft.rootPath,
                    { editing = draft.copy(rootPath = it) }, enabled = !state.busy, monospaced = true)
                FloePlainFormField(stringResource(R.string.network_workspace_username), draft.username,
                    { editing = draft.copy(username = it) }, enabled = !state.busy)
                if (draft.password != null || draft.mountID != null) {
                    FloePlainFormField(stringResource(R.string.network_workspace_password),
                        draft.password ?: "", { editing = draft.copy(password = it) },
                        enabled = !state.busy,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                    if (draft.mountID != null) {
                        FloeCheckboxRow(label = stringResource(R.string.network_workspace_clear_credential),
                            checked = draft.clearCredential,
                            onCheckedChange = { editing = draft.copy(clearCredential = it, password = null) },
                            modifier = Modifier)
                    }
                }
                FloeCheckboxRow(label = stringResource(R.string.network_workspace_read_only),
                    checked = draft.readOnly,
                    onCheckedChange = { editing = draft.copy(readOnly = it) },
                    modifier = Modifier)
                FloeText(stringResource(R.string.network_workspace_credential_hint),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloeCapsuleButton(stringResource(R.string.cancel),
                        onClick = { editing = null }, enabled = !state.busy,
                        modifier = Modifier.weight(1f))
                    FloeCapsuleButton(stringResource(R.string.network_workspace_connect), prominent = true,
                        enabled = !state.busy && draft.endpoint.isNotBlank(),
                        modifier = Modifier.weight(1f),
                        onClick = {
                            val passwordChars =
                                if (draft.clearCredential || draft.password.isNullOrEmpty()) null
                                else draft.password!!.toCharArray()
                            lane.addMount(draft.toLaneModel(passwordChars))
                            editing = null
                        })
                }
            }
        }
    }

    // ---- browse sheet ----
    val mounted = browseMount
    if (mounted != null) {
        FloeActionSheet(visible = true, onDismiss = { if (!state.busy) browseMount = null }, maxCardWidth = 640.dp) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText("${mounted.name} · ${if (state.browse?.path.isNullOrEmpty()) "/" else state.browse?.path}",
                    style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                val browse = state.browse
                if (browse?.mountID != mounted.id) {
                    LaunchedEffect(mounted.id) { lane.browse(mounted.id, "", mounted.endpoint) }
                }
                if (browse != null && browse.mountID == mounted.id) {
                    if (browse.truncated) {
                        FloeText(stringResource(R.string.network_workspace_truncated),
                            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    if (browse.entries.isEmpty()) {
                        FloeText(stringResource(R.string.network_workspace_empty_folder),
                            style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    }
                    browse.entries.forEach { entry ->
                        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Column(Modifier.weight(1f)) {
                                FloeText(entry.name, style = Floe.typography.body, color = Floe.colors.label)
                                if (!entry.isDirectory) {
                                    FloeText(networkBytesText(entry.bytes),
                                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                                }
                            }
                            if (entry.isDirectory) {
                                FloeCapsuleButton(stringResource(R.string.network_workspace_open),
                                    enabled = !state.busy, modifier = Modifier.weight(1f),
                                    onClick = { lane.browse(mounted.id, entry.path, mounted.endpoint) })
                            } else {
                                FloeCapsuleButton(stringResource(R.string.network_workspace_import),
                                    enabled = !state.busy, modifier = Modifier.weight(1f),
                                    onClick = {
                                        val target = defaultImportPath(mounted.name, entry.path)
                                        lane.startImport(mounted.id, entry.path, target, false,
                                            false, mounted.endpoint)
                                    })
                            }
                        }
                    }
                    // Folder import of the current listing level.
                    if (browse.path.isNotEmpty()) {
                        FloeCapsuleButton(
                            stringResource(R.string.network_workspace_import_folder),
                            enabled = !state.busy,
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                lane.startImport(mounted.id, browse.path,
                                    defaultImportPath(mounted.name, browse.path), true, false,
                                    mounted.endpoint)
                            })
                    }
                }
            }
        }
    }

    // ---- remove confirmation ----
    val target = confirming
    if (target != null) {
        FloeConfirmDialog(title = stringResource(R.string.network_workspace_remove),
            message = stringResource(R.string.network_workspace_remove_message),
            confirmLabel = stringResource(R.string.network_workspace_remove),
            dismissLabel = stringResource(R.string.cancel),
            onConfirm = {
                lane.removeMount(target.id, target.endpoint, forgetCredential)
                confirming = null
            },
            onDismiss = { confirming = null })
    }
}

// MARK: - small views

private typealias NetworkMountRow = NetworkWorkspaceHostController.NetworkMountUi

@Composable
private fun NetworkMountRowView(mount: NetworkMountRow, busy: Boolean,
                                onBrowse: () -> Unit, onConnect: () -> Unit,
                                onDisconnect: () -> Unit, onEdit: () -> Unit,
                                onRemove: () -> Unit) {
    val context = LocalContext.current.applicationContext
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                FloeText(mount.name, style = Floe.typography.body, color = Floe.colors.label)
                FloeText("${networkTransportLabel(context, mount.transport)} · ${mount.endpoint}",
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            FloeText(networkStatusLabel(context, mount.status),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            // Weighted siblings so all five mount actions stay reachable.
            FloeCapsuleButton(stringResource(R.string.network_workspace_browse),
                onClick = onBrowse, enabled = !busy, modifier = Modifier.weight(1f))
            FloeCapsuleButton(stringResource(R.string.network_workspace_connect),
                onClick = onConnect, enabled = !busy, modifier = Modifier.weight(1f))
            FloeCapsuleButton(stringResource(R.string.network_workspace_disconnect),
                onClick = onDisconnect, enabled = !busy, modifier = Modifier.weight(1f))
            FloeCapsuleButton(stringResource(R.string.network_workspace_edit),
                onClick = onEdit, enabled = !busy, modifier = Modifier.weight(1f))
            FloeCapsuleButton(stringResource(R.string.network_workspace_remove),
                onClick = onRemove, enabled = !busy, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun NetworkExportSection(state: NetworkWorkspaceHostController.NetworkLaneState,
                                 busy: Boolean,
                                 onExport: (String, String, String, Boolean) -> Unit) {
    val context = LocalContext.current.applicationContext
    // Data-class equality keeps this draft stable across content-unchanged
    // refreshes; only a genuinely changed mount set resets the form.
    var mountID by remember(state.mounts) { mutableStateOf(state.mounts.firstOrNull()?.id ?: "") }
    var workspacePath by remember(state.mounts) { mutableStateOf("") }
    var remotePath by remember(state.mounts) { mutableStateOf("") }
    var conflictCopy by remember(state.mounts) { mutableStateOf(false) }
    if (state.mounts.isNotEmpty()) {
        FloeText(stringResource(R.string.network_workspace_mount),
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            state.mounts.forEach { mount ->
                // Weighted chips keep EVERY mount selectable; an unweighted
                // fillMaxWidth button collapsed all later mounts to zero
                // width in the 420dp inspector (evidence 2026-10-25).
                FloeCapsuleButton(mount.name, enabled = !busy,
                    prominent = mount.id == mountID,
                    modifier = Modifier.weight(1f),
                    onClick = { mountID = mount.id })
            }
        }
    }
    FloePlainFormField(stringResource(R.string.network_workspace_workspace_path), workspacePath,
        { workspacePath = it }, enabled = !busy, monospaced = true)
    FloePlainFormField(stringResource(R.string.network_workspace_remote_path), remotePath,
        { remotePath = it }, enabled = !busy, monospaced = true)
    FloeCheckboxRow(label = stringResource(R.string.network_workspace_conflict_copy),
        checked = conflictCopy, onCheckedChange = { conflictCopy = it }, modifier = Modifier)
    FloeCapsuleButton(stringResource(R.string.network_workspace_export),
        enabled = !busy && mountID.isNotEmpty() && workspacePath.isNotBlank() && remotePath.isNotBlank(),
        onClick = { onExport(mountID, workspacePath.trim(), remotePath.trim(), conflictCopy) })
    FloeText(stringResource(R.string.network_workspace_export_hint),
        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
}

// MARK: - draft model + helpers

private data class NetworkMountDraftModel(
    val mountID: String? = null,
    val name: String = "",
    val transport: String = "webdav",
    val endpoint: String = "",
    val rootPath: String = "",
    val username: String = "",
    val readOnly: Boolean = false,
    /** Transient field content; never kept after submit (the lane stages it
     * into a native RAM ticket and zeroes the array). */
    val password: String? = null,
    val clearCredential: Boolean = false,
) {
    constructor(existing: NetworkMountRow) : this(
        mountID = existing.id, name = existing.name, transport = existing.transport,
        endpoint = existing.endpoint, rootPath = existing.rootPath, username = existing.username,
        readOnly = existing.readOnly)

    fun toLaneModel(passwordChars: CharArray?): NetworkWorkspaceHostController.NetworkMountDraft =
        NetworkWorkspaceHostController.NetworkMountDraft(
            mountID = mountID, name = name.trim(), transport = transport,
            endpoint = endpoint.trim(), rootPath = rootPath.trim(), username = username.trim(),
            readOnly = readOnly, password = passwordChars,
            credentialAction = if (clearCredential) -1L else 0L)
}

private fun defaultImportPath(mountName: String, remotePath: String): String {
    val segments = remotePath.split("/").filter { it.isNotEmpty() && it != "." && it != ".." }
    val tail = segments.joinToString("/")
    val base = mountName.replace("/", "-").take(40).ifBlank { "Network" }
    return "Imported/$base/$tail"
}

/// Readable metadata-only subtitle for a bound network source: transport +
/// the remote file NAME (last path segment). The mount UUID reference and
/// any full internal protocol identifier stay OUT of ordinary copy (they
/// belong to explicit details views only).
private fun networkSourceSubtitle(
    context: android.content.Context,
    source: NetworkWorkspaceHostController.NetworkSourceUi,
): String {
    val transport = networkTransportLabel(context, source.kind)
    val remoteName = source.documentID.substringAfterLast('/', "")
    val readable = remoteName.isNotBlank() && remoteName.length <= 80 &&
        !remoteName.equals(source.reference, ignoreCase = true)
    return if (readable) "$transport · $remoteName" else transport
}

private fun endpointForMount(
    state: NetworkWorkspaceHostController.NetworkLaneState, mountID: String?,
): String = state.mounts.firstOrNull { it.id == mountID }?.endpoint ?: "https://invalid.invalid"

private fun endpointForSource(
    state: NetworkWorkspaceHostController.NetworkLaneState, sourceID: String,
): String {
    val source = state.sources.firstOrNull { it.id == sourceID } ?: return "https://invalid.invalid"
    return state.mounts.firstOrNull { it.id.equals(source.reference, ignoreCase = true) }?.endpoint
        ?: "https://invalid.invalid"
}

private fun networkBytesText(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / 1073741824.0)
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / 1048576.0)
    bytes >= 1L shl 10 -> "%.0f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}

private fun networkTransportLabel(context: android.content.Context, transport: String): String =
    context.getString(if (transport == "smb") R.string.network_workspace_transport_smb
                      else R.string.network_workspace_transport_webdav)

private fun networkStatusLabel(context: android.content.Context, status: String): String =
    context.getString(when (status) {
        "connected" -> R.string.network_workspace_status_connected
        "readOnly" -> R.string.network_workspace_status_readonly
        "connecting" -> R.string.network_workspace_status_connecting
        "authenticationFailed" -> R.string.network_workspace_status_auth_failed
        "unreachable" -> R.string.network_workspace_status_unreachable
        "failed" -> R.string.network_workspace_status_failed
        else -> R.string.network_workspace_status_disconnected
    })

private fun networkOperationLabel(context: android.content.Context, kind: String): String =
    context.getString(when (kind) {
        "import" -> R.string.network_workspace_op_import
        "export" -> R.string.network_workspace_op_export
        "save" -> R.string.network_workspace_op_save
        "reconcile" -> R.string.network_workspace_op_reconcile
        else -> R.string.network_workspace_op_import
    })

private fun networkOperationStateText(
    context: android.content.Context,
    operation: NetworkWorkspaceHostController.NetworkOperationUi,
): String {
    val progress = if (operation.totalBytes > 0)
        " ${networkBytesText(operation.bytesDone)} / ${networkBytesText(operation.totalBytes)}" else ""
    val entries = if (operation.entriesDone + operation.entriesFailed > 0)
        " · ${operation.entriesDone}+${operation.entriesFailed}" else ""
    return when (operation.state) {
        "running" -> context.getString(R.string.network_workspace_state_running) + progress + entries
        "cancelRequested" -> context.getString(R.string.network_workspace_state_cancelling)
        "completed" -> context.getString(R.string.network_workspace_state_done) + entries
        "failed", "cancelled" -> (if (operation.state == "cancelled")
            context.getString(R.string.network_workspace_state_cancelled)
            else context.getString(R.string.network_workspace_state_failed)) +
            " · " + networkMessageText(context, operation.errorCode)
        else -> operation.state
    }
}

private fun networkMessageText(context: android.content.Context, token: String): String =
    context.getString(when (token) {
        "authenticationFailed", "credentialRejected", "credentialNotFound",
        "credentialTicketRefused", "credentialLabelRefused" -> R.string.network_workspace_error_auth
        "credentialMissing", "credentialCleanupPending", "credentialGatewayUnavailable",
        "credentialEffectUnknown" -> R.string.network_workspace_error_credential
        "networkUnreachable", "timedOut", "hopTimeout", "remoteRejected" -> R.string.network_workspace_error_unreachable
        "conflict", "workingCopyExists", "conflictCopyTaken", "driftAtClaim" -> R.string.network_workspace_error_conflict
        "sourceChangedSinceImport", "providerReadbackMismatch", "digestMismatch",
        "readbackUnproven" -> R.string.network_workspace_error_drift
        "readOnly" -> R.string.network_workspace_error_readonly
        "sizeExceeded", "aggregateExceeded" -> R.string.network_workspace_error_size
        "diskFull", "storageFull" -> R.string.network_workspace_error_storage
        "emptyFile" -> R.string.network_workspace_error_empty
        "partialFailures" -> R.string.network_workspace_error_partial
        "cancelled" -> R.string.network_workspace_state_cancelled
        "notFound" -> R.string.network_workspace_error_notfound
        "unsupported", "protocolFailure" -> R.string.network_workspace_error_protocol
        LocalNetworkAccessBroker.CODE_DENIED -> R.string.network_workspace_error_lan_denied
        LocalNetworkAccessBroker.CODE_RECOVERY -> R.string.network_workspace_error_lan_recovery
        "mountUnknown" -> R.string.network_workspace_error_mount
        "pathInvalid", "invalidArguments" -> R.string.network_workspace_error_path
        "journalRefused", "transitionRefused", "transition.*", "staleRevision",
        "receiptMismatch", "sourceMissing" -> R.string.network_workspace_error_journal
        "runtimeUnavailable", "epochMismatch", "ownerChanged", "retired",
        "identityRefused" -> R.string.network_workspace_runtime_unavailable
        "busy" -> R.string.network_workspace_error_busy
        "emptyCredential" -> R.string.network_workspace_error_credential
        else -> R.string.network_workspace_error_generic
    })
