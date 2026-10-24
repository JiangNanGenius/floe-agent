// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.host.PickPurpose
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.host.WorkspaceSourceAcceptedPick
import com.floe.android.host.WorkspaceSourceBrowseOutcome
import com.floe.android.host.WorkspaceSourceHostController
import com.floe.android.host.WorkspaceSourceLaneState
import com.floe.android.host.WorkspaceSourceRecoveryUi
import com.floe.android.host.WorkspaceSourceResult
import com.floe.android.host.WorkspaceSourceRowUi
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.SafPickerIntents
import kotlinx.coroutines.launch

/**
 * G04-R1 reusable provider-source UI (Files inspector mount).
 *
 * A PRESENTATION of the Application-owned `WorkspaceSourceHostController.Lane`
 * state only. Nothing here decides grants, paths, revisions or durability:
 *
 *  * the panel launches the SYSTEM picker through `SafPickerIntents.from(spec)`
 *    + StartActivityForResult so the ACTUAL returned intent flags survive
 *    (the Uri-only wrapper would lose them), and dispatches the result ONLY
 *    through the accepted `PlatformLaunchOwnership` rules (persisted
 *    `namespace:incarnation`; a superseded, foreign or restored-after-death
 *    callback drops with no controller call and no state write);
 *  * a cancel is a user dismissal — never a grant, never a release;
 *  * every outcome string maps ONE frozen typed token from the source-host
 *    contract (MODULE_API.json): the UI never claims a write, read-back or
 *    commit the native journal did not settle, never invents a permission,
 *    and never shows statistics it did not observe;
 *  * while the lane is unbound (no accepted root/epoch, a legacy .so without
 *    the source-host CABI, or a retired generation) the panel renders the
 *    honest unavailable state and FAILS CLOSED — ordinary workspace editing
 *    continues untouched.
 *
 * Mount (Main): embed [WorkspaceSourcePanel] in the Files inspector wide
 * column, or present it inside the existing compact secondary sheet. Floe
 * theme + owned icon vocabulary, EN/zh strings aligned.
 */
@Composable
internal fun WorkspaceSourcePanel(
    lane: WorkspaceSourceHostController.Lane?,
    onOpenWorkspaceFile: (String) -> Unit,
    onWorkspaceTreeChanged: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    if (lane == null) {
        Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
               verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.workspace_source_title),
                     style = Floe.typography.toolbarTitle, color = Floe.colors.label)
            FloeText(stringResource(R.string.workspace_source_runtime_unavailable),
                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }
        return
    }
    val state by lane.state.collectAsState()
    var sheet by remember(lane) { mutableStateOf(SourceSheet.NONE) }
    var targetPath by remember(lane) { mutableStateOf("") }
    var displayName by remember(lane) { mutableStateOf("") }
    var browse by remember(lane) { mutableStateOf(WorkspaceSourceBrowseOutcome(WorkspaceSourceResult("unbound"))) }

    // ---- platform launch ownership (persisted, per-lane namespace) -------
    val ledger = remember(lane) { PlatformLaunchOwnership.LaneLedger(lane.launchNamespace) }
    var issuedKey by rememberSaveable(lane) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val ok = result.resultCode == android.app.Activity.RESULT_OK
        val uri = if (ok) SafPickerIntents.resultUriString(result.data) else null
        val flags = if (ok) SafPickerIntents.resultFlags(result.data) else 0
        when (val decision = ledger.onCallback(lane.state.value.pending?.incarnation)) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                lane.onPickerResult(decision.incarnation, uri, flags)
            PlatformLaunchOwnership.CallbackDecision.Drop -> lane.droppedCallback()
        }
        issuedKey = null
    }
    LaunchedEffect(lane, state.pending, issuedKey) {
        if (issuedKey != null && state.pending == null) {
            // Restored (pre-process-death) issue still owns the lane until
            // THAT callback settles; re-adopt it before evaluation.
            ledger.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedKey))
        }
        val pending = state.pending ?: return@LaunchedEffect
        when (val decision = ledger.onPending(pending.incarnation)) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                runCatching { launcher.launch(SafPickerIntents.from(pending.spec)) }
                    .onFailure {
                        // No platform activity available to host the Intent:
                        // settle the lane honestly (no grant, no state write).
                        ledger.release()
                        issuedKey = null
                        lane.cancelPending(pending.incarnation)
                    }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }

    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
           verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeText(stringResource(R.string.workspace_source_title),
                 style = Floe.typography.toolbarTitle, color = Floe.colors.label)
        if (!state.runtimeAvailable) {
            FloeText(stringResource(R.string.workspace_source_runtime_unavailable),
                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }
        FloeDivider()
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleButton(stringResource(R.string.workspace_source_import),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = {
                                  targetPath = suggestedImportPath(state.accepted)
                                  sheet = SourceSheet.IMPORT
                              })
            FloeCapsuleButton(stringResource(R.string.workspace_source_save_as),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = { targetPath = ""; sheet = SourceSheet.SAVE_AS })
            FloeCapsuleButton(stringResource(R.string.workspace_source_export),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = { targetPath = ""; displayName = ""; sheet = SourceSheet.EXPORT })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleButton(stringResource(R.string.workspace_source_browse),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = { sheet = SourceSheet.BROWSE })
            FloeCapsuleButton(stringResource(R.string.workspace_source_reconcile),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = { scope.launch { lane.reconcile() } })
            FloeCapsuleButton(stringResource(R.string.workspace_source_refresh),
                              enabled = !state.busy, modifier = Modifier.weight(1f),
                              onClick = { scope.launch { lane.refresh() } })
        }
        state.accepted?.let { accepted ->
            FloeText(acceptedSummary(context, accepted),
                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            if (accepted.transientOnly || accepted.needsRePick) {
                FloeText(stringResource(R.string.workspace_source_transient),
                         style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            }
            FloeCapsuleButton(stringResource(R.string.workspace_source_forget),
                              enabled = !state.busy, onClick = { lane.clearAccepted() })
        }
        if (state.sources.isEmpty()) {
            FloeText(stringResource(R.string.workspace_source_none),
                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }
        state.sources.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Column(Modifier.weight(1f)) {
                    FloeText(row.path, style = Floe.typography.body, color = Floe.colors.label)
                    FloeText(sourceStateLine(context, row, state),
                             style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                }
                FloeCapsuleButton(stringResource(R.string.workspace_source_open),
                                  enabled = !state.busy, onClick = { onOpenWorkspaceFile(row.path) })
                FloeCapsuleButton(stringResource(R.string.workspace_source_save),
                                  enabled = !state.busy && row.sha256.isNotEmpty(),
                                  onClick = {
                                      scope.launch {
                                          val outcome = lane.savePathToProvider(row.path)
                                          if (outcome.statusEquals("ok")) onWorkspaceTreeChanged()
                                      }
                                  })
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeCapsuleButton(stringResource(R.string.workspace_source_save_as),
                                  enabled = !state.busy,
                                  onClick = { targetPath = row.path; sheet = SourceSheet.SAVE_AS })
                FloeCapsuleButton(stringResource(R.string.workspace_source_revoke),
                                  enabled = !state.busy && row.reference !in state.blockedReferences,
                                  onClick = { scope.launch { lane.revoke(row.reference) } })
                FloeCapsuleButton(stringResource(R.string.workspace_source_repick),
                                  enabled = !state.busy &&
                                      (row.reference in state.expiredReferences ||
                                          row.reference in state.blockedReferences ||
                                          state.accepted?.purpose != PickPurpose.IMPORT),
                                  onClick = {
                                      lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT)
                                  })
            }
        }
        if (state.recoveries.isNotEmpty()) {
            FloeText(stringResource(R.string.workspace_source_recoveries_title),
                     style = Floe.typography.body, color = Floe.colors.label)
            state.recoveries.forEach { recovery ->
                FloeText(recoveryLine(context, recovery),
                         style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            }
        }
        if (state.busy) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeActivityIndicator()
                state.progressBytes?.let { bytes ->
                    FloeText(progressText(context, bytes),
                             style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                }
            }
        }
        state.lastResult?.let { outcome ->
            FloeText(outcomeText(context, outcome),
                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        }
        FloeText(stringResource(R.string.workspace_source_tree_limits),
                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
    }

    FloePageSheet(visible = sheet != SourceSheet.NONE,
                  onDismiss = { if (!state.busy) sheet = SourceSheet.NONE }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
               verticalArrangement = Arrangement.spacedBy(12.dp)) {
            when (sheet) {
                SourceSheet.NONE -> Unit
                SourceSheet.IMPORT -> {
                    FloeText(stringResource(R.string.workspace_source_import_title),
                             style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                    FloePlainFormField(stringResource(R.string.workspace_source_target_path),
                                       targetPath, { targetPath = it }, enabled = !state.busy,
                                       monospaced = true)
                    state.accepted?.takeIf { it.purpose == PickPurpose.IMPORT }?.let { accepted ->
                        FloeText(acceptedSummary(context, accepted),
                                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                        if (accepted.transientOnly) {
                            FloeText(stringResource(R.string.workspace_source_transient),
                                     style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                        }
                    } ?: FloeText(stringResource(R.string.workspace_source_import_hint),
                                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    FloeCapsuleButton(stringResource(R.string.workspace_source_pick_document),
                                      enabled = !state.busy,
                                      onClick = { lane.requestPick(PickKind.OPEN_DOCUMENT, PickPurpose.IMPORT) })
                    FloeCapsuleButton(stringResource(R.string.workspace_source_pick_folder),
                                      enabled = !state.busy,
                                      onClick = { lane.requestPick(PickKind.OPEN_TREE, PickPurpose.IMPORT) })
                    if (state.busy) FloeActivityIndicator()
                    FloeCapsuleButton(stringResource(R.string.workspace_source_import),
                                      prominent = true,
                                      enabled = !state.busy && targetPath.isNotBlank() &&
                                          state.accepted?.purpose == PickPurpose.IMPORT,
                                      onClick = {
                                          val path = targetPath.trim()
                                          scope.launch {
                                              val outcome = lane.importAcceptedToWorkspace(path)
                                              if (outcome.statusEquals("ok")) {
                                                  onWorkspaceTreeChanged()
                                                  sheet = SourceSheet.NONE
                                              }
                                          }
                                      })
                    FloeCapsuleButton(stringResource(R.string.cancel),
                                      enabled = !state.busy, onClick = { sheet = SourceSheet.NONE })
                }
                SourceSheet.SAVE_AS -> {
                    FloeText(stringResource(R.string.workspace_source_save_as_title),
                             style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                    FloePlainFormField(stringResource(R.string.workspace_source_target_path),
                                       targetPath, { targetPath = it }, enabled = !state.busy,
                                       monospaced = true)
                    FloeText(stringResource(R.string.workspace_source_save_as_hint),
                             style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    state.accepted?.takeIf { it.purpose == PickPurpose.SAVE_TARGET }?.let { accepted ->
                        FloeText(acceptedSummary(context, accepted),
                                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    }
                    FloeCapsuleButton(stringResource(R.string.workspace_source_pick_new_file),
                                      enabled = !state.busy && targetPath.isNotBlank(),
                                      onClick = {
                                          lane.requestPick(PickKind.CREATE_DOCUMENT, PickPurpose.SAVE_TARGET,
                                                           emptyList(),
                                                           targetPath.trim().substringAfterLast('/'))
                                      })
                    if (state.busy) FloeActivityIndicator()
                    FloeCapsuleButton(stringResource(R.string.workspace_source_save_as_confirm),
                                      prominent = true,
                                      enabled = !state.busy && targetPath.isNotBlank() &&
                                          state.accepted?.purpose == PickPurpose.SAVE_TARGET,
                                      onClick = {
                                          val path = targetPath.trim()
                                          scope.launch {
                                              val outcome = lane.saveAsAccepted(path)
                                              if (outcome.statusEquals("ok")) {
                                                  onWorkspaceTreeChanged()
                                                  sheet = SourceSheet.NONE
                                              }
                                          }
                                      })
                    FloeText(stringResource(R.string.workspace_source_nondestructive),
                             style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    FloeCapsuleButton(stringResource(R.string.cancel),
                                      enabled = !state.busy, onClick = { sheet = SourceSheet.NONE })
                }
                SourceSheet.EXPORT -> {
                    FloeText(stringResource(R.string.workspace_source_export_title),
                             style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                    FloePlainFormField(stringResource(R.string.workspace_source_target_path),
                                       targetPath, { targetPath = it }, enabled = !state.busy,
                                       monospaced = true)
                    FloePlainFormField(stringResource(R.string.workspace_source_display_name),
                                       displayName, { displayName = it }, enabled = !state.busy)
                    state.accepted?.takeIf { it.purpose == PickPurpose.EXPORT_TARGET }?.let { accepted ->
                        FloeText(acceptedSummary(context, accepted),
                                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    } ?: FloeText(stringResource(R.string.workspace_source_export_hint),
                                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    FloeCapsuleButton(stringResource(R.string.workspace_source_pick_folder),
                                      enabled = !state.busy,
                                      onClick = { lane.requestPick(PickKind.OPEN_TREE, PickPurpose.EXPORT_TARGET) })
                    if (state.busy) FloeActivityIndicator()
                    FloeCapsuleButton(stringResource(R.string.workspace_source_export_confirm),
                                      prominent = true,
                                      enabled = !state.busy && targetPath.isNotBlank() &&
                                          state.accepted?.purpose == PickPurpose.EXPORT_TARGET,
                                      onClick = {
                                          val path = targetPath.trim()
                                          val name = displayName.trim().ifBlank {
                                              path.substringAfterLast('/')
                                          }
                                          scope.launch {
                                              val outcome = lane.exportToAcceptedTree(path, name, null)
                                              if (outcome.statusEquals("ok")) {
                                                  onWorkspaceTreeChanged()
                                                  sheet = SourceSheet.NONE
                                              }
                                          }
                                      })
                    FloeCapsuleButton(stringResource(R.string.cancel),
                                      enabled = !state.busy, onClick = { sheet = SourceSheet.NONE })
                }
                SourceSheet.BROWSE -> {
                    FloeText(stringResource(R.string.workspace_source_browse_title),
                             style = Floe.typography.toolbarTitle, color = Floe.colors.label)
                    FloeText(stringResource(R.string.workspace_source_browse_hint),
                             style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    state.accepted?.takeIf { it.purpose == PickPurpose.IMPORT && it.kind == "TREE" }?.let { tree ->
                        FloeCapsuleButton(stringResource(R.string.workspace_source_browse_go),
                                          enabled = !state.busy,
                                          onClick = {
                                              scope.launch { browse = lane.browseTree(tree.uri, null, null) }
                                          })
                    }
                    browseResult(context, browse, state.busy,
                                 onPickChild = { child ->
                                     lane.selectTreeChild(browseTreeAnchor(state), child.documentId, child.displayName)
                                 },
                                 onMore = { scope.launch {
                                     browse = lane.browseTree(browseTreeAnchor(state), null, browse.nextCursor)
                                 } })
                    FloeCapsuleButton(stringResource(R.string.cancel),
                                      enabled = !state.busy, onClick = { sheet = SourceSheet.NONE })
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// presentation-only helpers (no authority, no IO)
// ---------------------------------------------------------------------------

private enum class SourceSheet { NONE, IMPORT, SAVE_AS, EXPORT, BROWSE }

private fun suggestedImportPath(accepted: WorkspaceSourceAcceptedPick?): String {
    val name = accepted?.displayName ?: accepted?.uri?.substringAfterLast('/')?.substringBefore('?')
    val safe = name?.takeIf { !it.contains('/') && !it.contains('\\') && it != "." && it != ".." }
    return safe?.let { "Imported/$it" } ?: ""
}

private fun browseTreeAnchor(state: WorkspaceSourceLaneState): String {
    val accepted = state.accepted?.takeIf { it.purpose == PickPurpose.IMPORT } ?: return ""
    // The tree pick itself carries the anchor URI; a derived child keeps the
    // original tree as its anchor (children inherit that exact grant).
    return accepted.treeAnchor ?: accepted.uri
}

private fun acceptedSummary(context: Context, accepted: WorkspaceSourceAcceptedPick): String {
    val access = when {
        accepted.granted.contains("WRITE") && accepted.persisted.isNotEmpty() ->
            context.getString(R.string.workspace_source_access_read_write_persisted)
        accepted.granted.contains("WRITE") ->
            context.getString(R.string.workspace_source_access_read_write_session)
        accepted.persisted.isNotEmpty() ->
            context.getString(R.string.workspace_source_access_read_persisted)
        else -> context.getString(R.string.workspace_source_access_read_session)
    }
    return access
}

private fun sourceStateLine(context: Context, row: WorkspaceSourceRowUi,
                            state: WorkspaceSourceLaneState): String {
    val expired = row.reference in state.expiredReferences
    val blocked = row.reference in state.blockedReferences
    return when {
        blocked -> context.getString(R.string.workspace_source_recovery_pending)
        expired -> context.getString(R.string.workspace_source_repick_required)
        else -> context.getString(R.string.workspace_source_bound)
    }
}

private fun recoveryLine(context: Context, recovery: WorkspaceSourceRecoveryUi): String =
    context.getString(R.string.workspace_source_recovery_row, recovery.state)

private fun progressText(context: Context, bytes: Long): String =
    context.getString(R.string.workspace_source_progress, bytes / 1024)

private fun outcomeText(context: Context, outcome: WorkspaceSourceResult): String {
    val key = when (outcome.status) {
        "ok" -> when {
            outcome.facts.containsKey("sourceID") -> R.string.workspace_source_ok_imported
            outcome.facts.containsKey("created") -> R.string.workspace_source_ok_exported
            outcome.facts.containsKey("journal") -> R.string.workspace_source_ok_saved
            else -> R.string.workspace_source_ok_generic
        }
        "cancelled" -> R.string.workspace_source_cancelled
        "rePickRequired", "grantMissing", "revoked" -> R.string.workspace_source_repick_required
        "readOnly" -> R.string.workspace_source_readonly
        "unsupported" -> R.string.workspace_source_unsupported
        "sizeLimit" -> R.string.workspace_source_size_limit
        "conflict" -> R.string.workspace_source_conflict
        "sourceChangedSinceImport" -> R.string.workspace_source_source_changed
        "workingCopyExists" -> R.string.workspace_source_exists
        "journalRefused" -> R.string.workspace_source_journal_refused
        "notFound" -> R.string.workspace_source_missing
        "providerOffline" -> R.string.workspace_source_provider_offline
        "runtimeUnavailable" -> R.string.workspace_source_runtime_unavailable
        "unbound" -> R.string.workspace_source_unbound
        "retained" -> R.string.workspace_source_revoke_retained
        "ioFailed" -> R.string.workspace_source_failed
        else -> R.string.workspace_source_failed
    }
    return context.getString(key)
}

@Composable
private fun browseResult(context: Context, browse: WorkspaceSourceBrowseOutcome, busy: Boolean,
                         onPickChild: (com.floe.android.host.WorkspaceSourceChildUi) -> Unit,
                         onMore: () -> Unit) {
    if (!browse.result.statusEquals("ok")) {
        FloeText(outcomeText(context, browse.result),
                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
        return
    }
    if (browse.children.isEmpty()) {
        FloeText(stringResource(R.string.workspace_source_browse_empty),
                 style = Floe.typography.body, color = Floe.colors.secondaryLabel)
    }
    browse.children.forEach { child ->
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Column(Modifier.weight(1f)) {
                FloeText(child.displayName, style = Floe.typography.body, color = Floe.colors.label)
                FloeText(childNote(context, child),
                         style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            }
            if (!child.isDirectory) {
                FloeCapsuleButton(stringResource(R.string.workspace_source_use_file),
                                  enabled = !busy, onClick = { onPickChild(child) })
            }
        }
    }
    if (browse.nextCursor != null) {
        FloeCapsuleButton(stringResource(R.string.workspace_source_more),
                          enabled = !busy, onClick = onMore)
    }
}

private fun childNote(context: Context, child: com.floe.android.host.WorkspaceSourceChildUi): String {
    val size = child.bytes?.let { context.getString(R.string.workspace_source_size, it / 1024) }
        ?: context.getString(R.string.workspace_source_size_unknown)
    return when {
        child.isDirectory -> context.getString(R.string.workspace_source_folder)
        child.virtual -> context.getString(R.string.workspace_source_virtual, size)
        !child.writable -> context.getString(R.string.workspace_source_readonly_item, size)
        else -> size
    }
}
