// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.G04ActionsHostController
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/** The reachable GitHub Actions flow for the saved task: connect (through
 * the existing host credential seam — this UI never reads a key), choose a
 * repository and workflow (or review and install a Floe template), review the
 * exact snapshot and inputs, dispatch, then follow durable runs — status,
 * jobs, bounded logs, artifacts and verified downloads into the workspace —
 * with durable stop and explicit retry-as-new-intent.
 *
 * All truth is the native durable engine's; this pane only renders the
 * bounded projection owned by [G04ActionsHostController]. Internal protocol
 * names, tokens and raw remote payloads are never user-facing copy. */
@Composable
internal fun WorkspaceActionsPane(host: RuntimeHost?, taskID: String?) {
    val task = taskID?.let { host?.conversations?.entryFor(it) }
    if (host == null || taskID == null || task == null || task.isTemporary) {
        FloeUnavailableView(FloeIcons.Folder, stringResource(R.string.git_actions_title),
            stringResource(R.string.workspace_temporary_unavailable))
        return
    }
    val readiness by host.readiness.collectAsState()
    val rows by host.workspaceActions.state.collectAsState()
    val state = rows[taskID]?.takeIf {
        it.epoch == host.nativeRootEpoch() && it.generation == host.commandClient.generation()
    }
    var repo by remember(taskID) { mutableStateOf<JsonObject?>(null) }
    var workflowPath by remember(taskID) { mutableStateOf("") }
    var selectedTemplate by remember(taskID) { mutableStateOf<JsonObject?>(null) }
    var yamlOpen by remember(taskID) { mutableStateOf(false) }
    var language by remember(taskID) { mutableStateOf("rust") }
    var role by remember(taskID) { mutableStateOf("build") }
    var platform by remember(taskID) { mutableStateOf("linux") }
    var targetFile by remember(taskID) { mutableStateOf("") }
        var detailOpen by remember(taskID) { mutableStateOf(false) }
    var lastIntent by remember(taskID) { mutableStateOf<G04ActionsHostController.Plan?>(null) }
    var pendingRetry by remember(taskID) { mutableStateOf<G04ActionsHostController.Plan?>(null) }
    LaunchedEffect(taskID, readiness.storeReady, host.commandClient.generation()) {
        if (readiness.storeReady) host.workspaceActions.load(taskID, connection = true)
    }
    // Durable records are cheap local store reads; refresh them while the
    // pane is open. Remote status polling is the native engine's own bounded
    // scheduler (started by the trusted scene forward), never this loop.
    LaunchedEffect(taskID) {
        while (true) {
            delay(10_000)
            host.workspaceActions.load(taskID, connection = false)
        }
    }
    // An explicit retry re-reviews first (snapshot bytes may have changed),
    // then dispatches as a NEW intent — the old record is never re-fired.
    LaunchedEffect(state?.preview, pendingRetry) {
        val plan = pendingRetry ?: return@LaunchedEffect
        if (state?.preview != null) {
            pendingRetry = null
            host.workspaceActions.dispatch(taskID, plan.copy(requestID = host.workspaceActions.newRequestID()))
        }
    }
    val busy = state?.busy == true
    val account = state?.account
    val repositories = state?.repositories.orEmpty()
    val preview = state?.preview
    val included = ((preview?.get("manifest") as? JsonObject)?.get("entries") as? JsonArray)
    val excluded = ((preview?.get("manifest") as? JsonObject)?.get("excluded") as? JsonArray)
    val totalBytes = ((preview?.get("manifest") as? JsonObject)?.get("totalBytes") as? JsonPrimitive)?.longOrNull
    val records = state?.records.orEmpty()
    val repoParts = repo?.stringField("fullName")?.let { splitFullName(it) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        FloeText(stringResource(R.string.git_actions_caption),
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        if (busy) FloeActivityIndicator()
        state?.error?.let { code ->
            FloeText(actionsErrorText(code, state.engineError), color = Floe.colors.secondaryLabel)
        }
        // 1. Account + repository.
        FloeSectionHeader(stringResource(R.string.git_actions_connection))
        if (account == null) {
            FloeText(stringResource(R.string.git_actions_account_required), color = Floe.colors.secondaryLabel)
        } else {
            FloeText(stringResource(R.string.git_actions_connected_as,
                account.stringField("login") ?: ""), color = Floe.colors.secondaryLabel)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleButton(stringResource(R.string.git_actions_refresh), enabled = !busy,
                    onClick = { host.workspaceActions.load(taskID, connection = true) })
                if (repoParts != null) {
                    FloeCapsuleButton(stringResource(R.string.git_actions_registered_workflows), enabled = !busy,
                        onClick = { host.workspaceActions.loadWorkflows(taskID, repoParts.first, repoParts.second) })
                }
            }
            if (repositories.isNotEmpty()) {
                FloePageSheetList(title = stringResource(R.string.git_actions_repository),
                    rows = repositories.map { it.stringField("fullName") ?: "" },
                    selected = repo?.stringField("fullName"), enabled = !busy) { fullName ->
                    val match = repositories.firstOrNull { it.stringField("fullName") == fullName }
                    repo = match
                    workflowPath = ""
                    if (match != null) {
                        val parts = splitFullName(fullName)
                        host.workspaceActions.loadWorkflows(taskID, parts.first, parts.second)
                    }
                }
            }
        }
        // 2. Workflow: registered or Floe template.
        if (account != null) {
            FloeSectionHeader(stringResource(R.string.git_actions_workflow))
            (state?.workflows ?: emptyList()).forEach { workflow ->
                val path = workflow.stringField("path") ?: return@forEach
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(label = workflow.stringField("name")?.take(40) ?: path, enabled = !busy,
                        onClick = { workflowPath = path; selectedTemplate = null })
                    if (workflowPath == path) FloeBadgePill(stringResource(R.string.git_actions_workflow),
                        tone = FloeBadgeTone.ACCENT)
                }
            }
            FloeText(stringResource(R.string.git_actions_templates), color = Floe.colors.secondaryLabel)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloePlainFormField(stringResource(R.string.git_actions_language), language,
                    { language = it }, monospaced = true)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("build", "lintTest").forEach { value ->
                    FloeCapsuleButton(value, enabled = !busy, onClick = { role = value })
                }
                listOf("linux", "macOS").forEach { value ->
                    FloeCapsuleButton(value, enabled = !busy, onClick = { platform = value })
                }
            }
            FloeCapsuleButton(stringResource(R.string.git_actions_load_templates), enabled = !busy,
                onClick = { host.workspaceActions.loadTemplates(taskID, language.trim()) })
            (state?.templates ?: emptyList()).forEach { template ->
                val id = template.stringField("id") ?: return@forEach
                val path = template.stringField("workflowPath") ?: return@forEach
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloeCapsuleButton(id, enabled = !busy,
                        onClick = { workflowPath = path; selectedTemplate = template })
                    FloeCapsuleButton(stringResource(R.string.git_actions_review_template), enabled = !busy,
                        onClick = { selectedTemplate = template; yamlOpen = true })
                    if (repoParts != null) {
                        FloeCapsuleButton(stringResource(R.string.git_actions_install_template), enabled = !busy,
                            onClick = { host.workspaceActions.installTemplate(taskID,
                                repoParts.first, repoParts.second, id) })
                    }
                }
            }
            FloeText(stringResource(R.string.git_actions_install_hint),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        // 3. Snapshot review.
        if (account != null && repo != null && workflowPath.isNotBlank()) {
            FloeSectionHeader(stringResource(R.string.git_actions_snapshot))
            // The reviewed list is ALWAYS the full workspace-root walk: exactly
            // what the durable publish re-verifies file-by-file before GitHub
            // ever sees a byte.
            FloeCapsuleButton(stringResource(R.string.git_actions_preview), enabled = !busy,
                onClick = { host.workspaceActions.previewSnapshot(taskID, ".") })
            if (preview != null) {
                FloeText(stringResource(R.string.git_actions_snapshot_includes,
                    included?.size ?: 0, humanBytes(totalBytes ?: 0)), color = Floe.colors.secondaryLabel)
                if (!excluded.isNullOrEmpty())
                    FloeText(stringResource(R.string.git_actions_snapshot_excludes, excluded.size),
                        color = Floe.colors.secondaryLabel)
                included?.take(80)?.forEach { row ->
                    val entry = row as? JsonObject ?: return@forEach
                    FloeText(entry.stringField("path")?.take(120) ?: "",
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            } else {
                FloeText(stringResource(R.string.git_actions_snapshot_hint),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            FloePlainFormField(stringResource(R.string.git_actions_target_file), targetFile,
                { targetFile = it }, monospaced = true)
            // A Floe template REQUIRES the reviewed target file (its workflow
            // declares target_file); an existing user workflow dispatches with
            // the inputs you reviewed instead.
            val chosenTemplate = selectedTemplate
            val needsTarget = chosenTemplate != null &&
                chosenTemplate.stringField("workflowPath") == workflowPath
            val canDispatch = preview != null && busy.not() && repoParts != null &&
                workflowPath.isNotBlank() && (!needsTarget || targetFile.isNotBlank())
            FloeCapsuleButton(stringResource(R.string.git_actions_dispatch), prominent = true,
                enabled = canDispatch && repoParts != null,
                onClick = {
                    val plan = G04ActionsHostController.Plan(
                        owner = repoParts?.first ?: "", repository = repoParts?.second ?: "",
                        workflowPath = workflowPath,
                        requestID = host.workspaceActions.newRequestID(),
                        languageID = selectedTemplate?.stringField("languageID") ?: language.trim(),
                        role = role, platform = platform,
                        targetFile = targetFile.trim(),
                        inputs = mapOf(),
                    )
                    lastIntent = plan
                    host.workspaceActions.dispatch(taskID, plan)
                })
        }
        // 4. Durable run history.
        FloeSectionHeader(stringResource(R.string.git_actions_runs))
        if (records.isEmpty()) {
            FloeText(stringResource(R.string.git_actions_no_runs), color = Floe.colors.secondaryLabel)
        }
        records.forEach { record ->
            val id = record.stringField("id") ?: return@forEach
            FloeDivider()
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(record.stringField("repositoryFullName")?.take(40) ?: "", maxLines = 2)
                FloeBadgePill(stateLabel(record.stringField("state") ?: "error"),
                    tone = stateTone(record.stringField("state") ?: "error"))
            }
            (record.stringField("workflowPath"))?.let {
                FloeText(it.take(120), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            state?.engineError?.let {
                FloeText(stringResource(R.string.git_actions_engine_error, it.take(200)),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeCapsuleButton(stringResource(R.string.git_actions_refresh_run), enabled = !busy,
                    onClick = { host.workspaceActions.refreshRecord(taskID, id) })
                FloeCapsuleButton(stringResource(R.string.git_actions_run_details), enabled = !busy,
                    onClick = {
                        host.workspaceActions.openRecord(taskID, id)
                        host.workspaceActions.loadDetailJobs(taskID, record)
                        detailOpen = true
                    })
                val stopPending = record["cancelRequestedAt"]?.let { it.toString() != "null" } == true
                if (!stopPending && record.stringField("state") !in TERMINAL_STATES) {
                    FloeCapsuleButton(stringResource(R.string.git_actions_cancel_run), enabled = !busy,
                        onClick = { host.workspaceActions.cancelRecord(taskID, id) })
                }
                if (record.stringField("state") == "error" && lastIntent != null) {
                    FloeCapsuleButton(stringResource(R.string.git_actions_retry_run), enabled = !busy,
                        onClick = {
                            pendingRetry = lastIntent
                            host.workspaceActions.previewSnapshot(taskID, ".")
                        })
                }
            }
        }
        if (state?.corruptFiles.orEmpty().isNotEmpty()) {
            FloeText(stringResource(R.string.git_actions_corrupt_records, state?.corruptFiles?.size ?: 0),
                color = Floe.colors.secondaryLabel)
        }
        if (state?.editorRefreshUnavailable.orEmpty().isNotEmpty()) {
            FloeText(stringResource(R.string.git_workspace_removed_tabs), color = Floe.colors.secondaryLabel)
            state?.editorRefreshUnavailable.orEmpty().forEach { FloeText(it, style = Floe.typography.metadata) }
        }
        FloeText(stringResource(R.string.git_actions_paused_note),
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
    // Template YAML review (bounded, verbatim).
    FloePageSheet(visible = yamlOpen && selectedTemplate != null, onDismiss = { yamlOpen = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.git_actions_review_template), style = Floe.typography.toolbarTitle)
            SelectionContainer {
                FloeText(selectedTemplate?.stringField("yaml").orEmpty(),
                    Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                    style = Floe.typography.body.copy(fontFamily = FontFamily.Monospace))
            }
        }
    }
    // Record detail: jobs + bounded logs + artifacts + verified downloads.
    FloePageSheet(visible = detailOpen, onDismiss = { detailOpen = false; host.workspaceActions.closeDetail(taskID) }) {
        val detail = state?.detail
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.git_actions_run_details), style = Floe.typography.toolbarTitle)
            val record = detail?.get("record") as? JsonObject
            val recordID = record?.stringField("id")
            (state?.detailJobs ?: emptyList()).forEach { job ->
                val jobID = (job["id"] as? JsonPrimitive)?.longOrNull ?: return@forEach
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloeText(job.stringField("name")?.take(60) ?: "", maxLines = 2)
                    FloeBadgePill(stateLabel(normalizeState(job.stringField("status"),
                        job.stringField("conclusion"))), tone = stateTone(normalizeState(job.stringField("status"),
                        job.stringField("conclusion"))))
                    if (recordID != null) {
                        FloeCapsuleButton(stringResource(R.string.git_actions_logs), enabled = !busy,
                            onClick = { host.workspaceActions.loadDetailLog(taskID, recordID, jobID) })
                    }
                }
            }
            state?.detailLog?.let {
                SelectionContainer {
                    FloeText(it, Modifier.fillMaxWidth().height(240.dp).verticalScroll(rememberScrollState()),
                        style = Floe.typography.body.copy(fontFamily = FontFamily.Monospace))
                }
            }
            val artifacts = (record?.get("artifacts") as? JsonArray)?.mapNotNull { it as? JsonObject }
            if (!artifacts.isNullOrEmpty()) {
                FloeText(stringResource(R.string.git_actions_artifacts), style = Floe.typography.toolbarTitle)
                artifacts.forEach { artifact ->
                    val artifactID = (artifact["id"] as? JsonPrimitive)?.longOrNull ?: return@forEach
                    val name = artifact.stringField("name") ?: ""
                    FloeDivider()
                    FloeText(name.take(80), maxLines = 2)
                    val verified = artifact["downloadVerified"] as? JsonPrimitive
                    when {
                        hasPath(artifact, "downloadedRelativePath") && verified?.booleanOrNull == true ->
                            FloeText(stringResource(R.string.git_actions_download_verified),
                                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                        hasPath(artifact, "downloadedRelativePath") ->
                            FloeText(stringResource(R.string.git_actions_download_checksum),
                                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    artifact.stringField("downloadedRelativePath")?.let {
                        FloeText(stringResource(R.string.git_actions_downloaded, it.take(120)),
                            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    if (recordID != null && !hasPath(artifact, "downloadedRelativePath")) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeCapsuleButton(stringResource(R.string.git_actions_download), enabled = !busy,
                                onClick = { host.workspaceActions.downloadArtifact(taskID, recordID, artifactID, false) })
                        }
                    } else if (recordID != null && hasPath(artifact, "downloadedRelativePath") &&
                        verified?.booleanOrNull != true) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeCapsuleButton(stringResource(R.string.git_actions_overwrite), enabled = !busy,
                                onClick = { host.workspaceActions.downloadArtifact(taskID, recordID, artifactID, true) })
                        }
                    }
                }
            } else if (recordID != null) {
                FloeCapsuleButton(stringResource(R.string.git_actions_artifacts), enabled = !busy,
                    onClick = { host.workspaceActions.loadArtifacts(taskID, recordID) })
            }
            record?.stringField("remoteHTMLURL")?.let {
                FloeText(it.take(160), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            if (record?.stringField("state") == "cancelling") {
                FloeText(stringResource(R.string.git_actions_cancel_hint),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            if (recordID != null && (record?.stringField("state") == "associationPending" ||
                    record?.stringField("state") == "dispatching")) {
                // Uncertain dispatch is re-associated, never re-fired.
                FloeCapsuleButton(stringResource(R.string.git_actions_refresh_run), enabled = !busy,
                    onClick = { host.workspaceActions.refreshRecord(taskID, recordID) })
            }
        }
    }
}

private fun splitFullName(fullName: String): Pair<String, String> {
    val parts = fullName.split("/", limit = 2)
    return if (parts.size == 2) parts[0] to parts[1] else fullName to fullName
}

private fun JsonObject.stringField(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

private val TERMINAL_STATES = setOf("completed", "failed", "cancelled", "error")

private fun hasPath(artifact: JsonObject, name: String): Boolean =
    (artifact[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull != null

private fun JsonObject.longField(name: String): Long? =
    (this[name] as? JsonPrimitive)?.longOrNull

private fun normalizeState(status: String?, conclusion: String?): String = when {
    conclusion == "success" -> "completed"
    conclusion == "cancelled" -> "cancelled"
    status == "completed" || conclusion != null -> "failed"
    status == "in_progress" -> "running"
    status == "queued" -> "queued"
    else -> "error"
}

private fun humanBytes(bytes: Long): String = when {
    bytes >= 1_048_576 -> "%.1f MiB".format(bytes / 1_048_576.0)
    bytes >= 1_024 -> "%.1f KiB".format(bytes / 1_024.0)
    else -> "$bytes B"
}

@Composable
private fun stateLabel(state: String): String = stringResource(when (state) {
    "preparing" -> R.string.git_actions_state_preparing
    "snapshotPublished" -> R.string.git_actions_state_snapshotPublished
    "dispatching" -> R.string.git_actions_state_dispatching
    "associationPending" -> R.string.git_actions_state_associationPending
    "queued" -> R.string.git_actions_state_queued
    "running" -> R.string.git_actions_state_running
    "cancelling" -> R.string.git_actions_state_cancelling
    "completed" -> R.string.git_actions_state_completed
    "failed" -> R.string.git_actions_state_failed
    "cancelled" -> R.string.git_actions_state_cancelled
    else -> R.string.git_actions_state_error
})

private fun stateTone(state: String): FloeBadgeTone = when (state) {
    "completed" -> FloeBadgeTone.SUCCESS
    "failed", "error" -> FloeBadgeTone.DESTRUCTIVE
    "cancelled" -> FloeBadgeTone.SECONDARY
    "cancelling", "associationPending" -> FloeBadgeTone.PENDING
    else -> FloeBadgeTone.ACCENT
}

@Composable
private fun actionsErrorText(code: String, engineError: String?): String = when (code) {
    "gitNeedsAccount", "gitCredentialUnavailable" -> stringResource(R.string.git_actions_credential_unavailable)
    "gitTrustUnavailable" -> stringResource(R.string.git_actions_trust_unavailable)
    "gitActionsReviewStale" -> stringResource(R.string.git_actions_review_stale)
    "gitActionsWorkflowNotRegistered" -> stringResource(R.string.git_actions_workflow_not_registered)
    "gitActionsRecordMissing" -> stringResource(R.string.git_actions_record_missing)
    "gitActionsArtifactNotReady" -> stringResource(R.string.git_actions_artifact_not_ready)
    "gitActionsRemote" -> stringResource(R.string.git_actions_remote_error,
        engineError?.take(160) ?: "")
    "dirtyDocument", "workspaceBusy" -> stringResource(R.string.workspace_conflict_error)
    "notAdmitted", "escapesRoot", "secretFile" -> stringResource(R.string.workspace_access_error)
    "retired", "ownerChanged", "ownerUnavailable", "ownerStopping" -> stringResource(R.string.workspace_owner_error)
    else -> stringResource(R.string.git_actions_failed)
}

/** Small bounded selector row reused for repositories; renders labels only,
 * identity stays with the native projection. */
@Composable
private fun FloePageSheetList(title: String, rows: List<String>, selected: String?,
                              enabled: Boolean, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    FloeCapsuleButton(title, enabled = enabled, onClick = { open = true })
    FloePageSheet(visible = open, onDismiss = { open = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(title, style = Floe.typography.toolbarTitle)
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleButton(row.take(60), enabled = enabled, prominent = row == selected,
                        onClick = { onPick(row); open = false })
                }
            }
        }
    }
}
