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
import com.floe.android.host.RuntimeHost
import kotlinx.serialization.json.*

private enum class GitSheetAction(val wire: String, val title: Int) {
    INITIALIZE("initialize", R.string.git_workspace_initialize),
    COMMIT("commit", R.string.git_workspace_commit),
    CREATE_BRANCH("createBranch", R.string.git_workspace_create_branch),
    SWITCH_BRANCH("switchBranch", R.string.git_workspace_switch_branch),
    MERGE("merge", R.string.git_workspace_merge),
    ABORT_MERGE("abortMerge", R.string.git_workspace_abort_merge),
    DISCARD("discard", R.string.git_workspace_discard),
    CLONE("clone", R.string.git_workspace_clone),
    FETCH("fetch", R.string.git_workspace_fetch),
    PULL("pull", R.string.git_workspace_pull),
    PULL_MERGE("pullMerge", R.string.git_workspace_pull_merge),
    PUSH("push", R.string.git_workspace_push),
}

/** Native Git projections in the existing task inspector. Commands are
 * application-owned, with secondary menus/forms on the shared Floe sheets. */
@Composable
internal fun WorkspaceGitPane(host: RuntimeHost?, taskID: String?) {
    val task = taskID?.let { host?.conversations?.entryFor(it) }
    if (host == null || taskID == null || task == null || task.isTemporary) {
        FloeUnavailableView(FloeIcons.Folder, stringResource(R.string.inspector_changes),
            stringResource(R.string.workspace_temporary_unavailable))
        return
    }
    val readiness by host.readiness.collectAsState()
    val rows by host.workspaceGit.state.collectAsState()
    val state = rows[taskID]?.takeIf {
        it.epoch == host.nativeRootEpoch() && it.generation == host.commandClient.generation()
    }
    LaunchedEffect(taskID, readiness.storeReady, host.commandClient.generation()) {
        if (readiness.storeReady) host.workspaceGit.refresh(taskID)
    }
    val snapshot = state?.snapshot
    val repository = (snapshot?.get("isRepository") as? JsonPrimitive)?.booleanOrNull == true
    val busy = state?.busy == true
    var menu by remember(taskID) { mutableStateOf(false) }
    var cloudOpen by remember(taskID) { mutableStateOf(false) }
    var action by remember(taskID) { mutableStateOf<GitSheetAction?>(null) }
    var primary by remember(taskID) { mutableStateOf("") }
    var secondary by remember(taskID) { mutableStateOf("") }
    fun choose(value: GitSheetAction, path: String = "") {
        action = value; primary = path; secondary = ""; menu = false
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleButton(stringResource(R.string.git_workspace_refresh),
                onClick = { host.workspaceGit.refresh(taskID) }, enabled = !busy)
            FloeCapsuleButton(stringResource(R.string.git_workspace_menu),
                onClick = { menu = true }, enabled = !busy)
            // The durable Actions flow belongs to the same saved task; it
            // opens as a wide secondary page over the inspector.
            FloeCapsuleButton(stringResource(R.string.git_workspace_actions),
                onClick = { cloudOpen = true }, enabled = !busy)
        }
        if (busy) FloeActivityIndicator()
        state?.error?.let { code ->
            val message = when (code) {
                "dirtyDocument", "workspaceBusy" -> R.string.workspace_conflict_error
                "gitNeedsAccount", "gitCredentialUnavailable" -> R.string.git_workspace_account_required
                "gitTrustUnavailable" -> R.string.git_workspace_trust_unavailable
                "notAdmitted", "escapesRoot", "secretFile" -> R.string.workspace_access_error
                "retired", "ownerChanged", "ownerUnavailable", "ownerStopping" -> R.string.workspace_owner_error
                else -> R.string.git_workspace_failed
            }
            FloeText(stringResource(message), color = Floe.colors.secondaryLabel)
        }
        if (snapshot == null) {
            if (!busy && state?.error == null) FloeText(stringResource(R.string.inspector_runtime_pending))
        } else if (!repository) {
            FloeText(stringResource(R.string.git_workspace_no_repository), color = Floe.colors.secondaryLabel)
            FloeCapsuleButton(stringResource(R.string.git_workspace_initialize), onClick = { choose(GitSheetAction.INITIALIZE) }, enabled = !busy)
            FloeCapsuleButton(stringResource(R.string.git_workspace_clone), onClick = { choose(GitSheetAction.CLONE) }, enabled = !busy)
        } else {
            FloeText(snapshot.stringField("branch") ?: stringResource(R.string.git_workspace_detached),
                style = Floe.typography.toolbarTitle)
            snapshot.stringField("remoteURL")?.let { FloeText(it, color = Floe.colors.secondaryLabel) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleButton(stringResource(R.string.git_workspace_stage_all), enabled = !busy,
                    onClick = { host.workspaceGit.perform(taskID, "stage", buildJsonObject { put("paths", JsonArray(emptyList())) }) })
                FloeCapsuleButton(stringResource(R.string.git_workspace_commit), enabled = !busy,
                    onClick = { choose(GitSheetAction.COMMIT) })
            }
            val changes = (snapshot["changes"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            if (changes.isEmpty()) FloeText(stringResource(R.string.git_workspace_clean), color = Floe.colors.secondaryLabel)
            changes.forEach { change ->
                val path = change.stringField("path") ?: return@forEach
                val staged = (change["staged"] as? JsonPrimitive)?.booleanOrNull == true
                FloeDivider()
                FloeText(path, maxLines = 3)
                FloeText(stringResource(if (staged) R.string.git_workspace_staged else R.string.git_workspace_unstaged),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloeCapsuleButton(stringResource(if (staged) R.string.git_workspace_unstage else R.string.git_workspace_stage), enabled = !busy,
                        onClick = { host.workspaceGit.perform(taskID, if (staged) "unstage" else "stage",
                            buildJsonObject { put("paths", JsonArray(listOf(JsonPrimitive(path)))) }) })
                    FloeCapsuleButton(stringResource(R.string.git_workspace_diff), enabled = !busy,
                        onClick = { host.workspaceGit.perform(taskID, if (staged) "diffStaged" else "diff",
                            buildJsonObject { put("path", path) }) })
                    FloeCapsuleButton(stringResource(R.string.git_workspace_discard), enabled = !busy,
                        onClick = { choose(GitSheetAction.DISCARD, path) })
                }
            }
            FloeDivider()
            FloeText(stringResource(R.string.git_workspace_history), style = Floe.typography.toolbarTitle)
            (snapshot["recentCommits"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.forEach { commit ->
                FloeText(listOfNotNull(commit.stringField("shortOID"), commit.stringField("message")).joinToString("  "))
            }
            if (state?.editorRefreshUnavailable.orEmpty().isNotEmpty()) {
                FloeText(stringResource(R.string.git_workspace_removed_tabs), color = Floe.colors.secondaryLabel)
                state?.editorRefreshUnavailable.orEmpty().forEach { FloeText(it, style = Floe.typography.metadata) }
            }
        }
    }
    FloePageSheet(visible = menu, onDismiss = { menu = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.git_workspace_menu), style = Floe.typography.toolbarTitle)
            GitSheetAction.entries.filter { repository || it in setOf(GitSheetAction.INITIALIZE, GitSheetAction.CLONE) }.forEach { item ->
                FloeCapsuleButton(stringResource(item.title), onClick = { choose(item) }, modifier = Modifier.fillMaxWidth(), enabled = !busy)
            }
        }
    }
    FloePageSheet(visible = action != null, onDismiss = { action = null }) {
        val chosen = action ?: return@FloePageSheet
        val primaryLabel = when (chosen) {
            GitSheetAction.COMMIT -> R.string.git_workspace_message
            GitSheetAction.CLONE -> R.string.git_workspace_remote_url
            GitSheetAction.DISCARD -> R.string.workspace_relative_path
            else -> R.string.git_workspace_branch
        }
        val requiresPrimary = chosen in setOf(GitSheetAction.COMMIT, GitSheetAction.CLONE, GitSheetAction.DISCARD,
            GitSheetAction.CREATE_BRANCH, GitSheetAction.SWITCH_BRANCH, GitSheetAction.MERGE)
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(stringResource(chosen.title), style = Floe.typography.toolbarTitle)
            if (requiresPrimary || chosen == GitSheetAction.INITIALIZE) {
                FloePlainFormField(stringResource(primaryLabel), primary, { primary = it }, monospaced = chosen != GitSheetAction.COMMIT,
                    singleLine = chosen != GitSheetAction.COMMIT, maxLines = if (chosen == GitSheetAction.COMMIT) 6 else 1)
            }
            if (chosen in setOf(GitSheetAction.SWITCH_BRANCH, GitSheetAction.MERGE)) {
                (snapshot?.get("branches") as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.forEach { branch ->
                    FloeCapsuleButton(branch, onClick = { primary = branch })
                }
            }
            if (chosen == GitSheetAction.CLONE) FloePlainFormField(stringResource(R.string.workspace_destination_path), secondary,
                { secondary = it }, monospaced = true)
            FloeText(stringResource(when (chosen) {
                GitSheetAction.DISCARD -> R.string.git_workspace_discard_confirmation
                GitSheetAction.PUSH -> R.string.git_workspace_push_confirmation
                GitSheetAction.ABORT_MERGE -> R.string.git_workspace_abort_confirmation
                else -> R.string.git_workspace_action_caption
            }), color = Floe.colors.secondaryLabel)
            FloeCapsuleButton(stringResource(chosen.title), prominent = true,
                enabled = !busy && (!requiresPrimary || primary.isNotBlank()) && (chosen != GitSheetAction.CLONE || secondary.isNotBlank()),
                onClick = {
                    val args = buildJsonObject {
                        when (chosen) {
                            GitSheetAction.INITIALIZE -> if (primary.isNotBlank()) put("branch", primary.trim())
                            GitSheetAction.COMMIT -> put("message", primary)
                            GitSheetAction.CREATE_BRANCH, GitSheetAction.SWITCH_BRANCH -> put("name", primary.trim())
                            GitSheetAction.MERGE -> put("reference", primary.trim())
                            GitSheetAction.DISCARD -> { put("paths", JsonArray(listOf(JsonPrimitive(primary.trim())))); put("includeStaged", true) }
                            GitSheetAction.CLONE -> { put("remoteURL", primary.trim()); put("destination", secondary.trim()) }
                            else -> Unit
                        }
                    }
                    host.workspaceGit.perform(taskID, chosen.wire, args)
                    action = null
                })
            FloeCapsuleButton(stringResource(R.string.cancel), onClick = { action = null })
        }
    }
    FloePageSheet(visible = cloudOpen, onDismiss = { cloudOpen = false }) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween) {
                FloeText(stringResource(R.string.git_workspace_actions), style = Floe.typography.toolbarTitle)
                FloeCapsuleButton(stringResource(R.string.git_workspace_actions_close), onClick = { cloudOpen = false })
            }
            WorkspaceActionsPane(host, taskID)
        }
    }
    FloePageSheet(visible = state?.diff != null, onDismiss = { host.workspaceGit.dismissDiff(taskID) }) {
        SelectionContainer {
            FloeText(state?.diff.orEmpty(), Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                style = Floe.typography.body.copy(fontFamily = FontFamily.Monospace))
        }
    }
}

private fun JsonObject.stringField(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
