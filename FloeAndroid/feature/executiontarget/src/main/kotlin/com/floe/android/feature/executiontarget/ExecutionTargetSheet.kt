// SPDX-License-Identifier: MPL-2.0
//
// C02 execution-target sheet. The target is shown as a durable task property,
// never as a transient global setting. A move is a separate explicit flow:
// choose destination -> check -> see affected work -> confirm the drain ->
// commit. Phone-safe: one column, full-width rows and a scrollable sheet.
package com.floe.android.feature.executiontarget

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSelectionSlot
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionItem

private data class TargetChoice(
    val key: String,
    val kind: String,
    val environmentID: String?,
    val hostID: String?,
    val title: String,
    val detail: String,
    val enabled: Boolean,
    val isCurrent: Boolean,
)

/**
 * Compact entry for an existing conversation toolbar. Main places it in the
 * task header; the label states whether the task target is already pinned.
 */
@Composable
public fun ExecutionTargetButton(
    state: ExecutionTargetUiState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = if (state.currentTarget == null) {
        stringResource(R.string.executiontarget_title)
    } else {
        stringResource(R.string.executiontarget_current)
    }
    FloeCapsuleAction(label = label, onClick = onClick, modifier = modifier)
}

@Composable
public fun ExecutionTargetSheet(
    visible: Boolean,
    state: ExecutionTargetUiState,
    compact: Boolean,
    onDismiss: () -> Unit,
    onInitialize: (kind: String, environmentID: String?, remoteHostID: String?) -> Unit,
    onCheckMigration: (kind: String, environmentID: String?, remoteHostID: String?) -> Unit,
    onBeginMigration: (kind: String, environmentID: String?, remoteHostID: String?) -> Unit,
    onCancelMigration: () -> Unit,
    onApproveHostKey: (String, Boolean, Boolean, String?) -> Unit,
    onDismissError: () -> Unit,
    onDismissNotice: () -> Unit,
    onRefresh: () -> Unit,
    onDestinationChanged: () -> Unit,
) {
    FloePageSheet(
        visible = visible,
        onDismiss = onDismiss,
        widthFraction = if (compact) 1f else 0.72f,
        heightFraction = if (compact) 1f else 0.9f,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    stringResource(R.string.executiontarget_title),
                    style = Floe.typography.title,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.executiontarget_dismiss),
                    onClick = onDismiss,
                )
            }

            if (state.loading) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator()
                    Spacer(Modifier.width(10.dp))
                    FloeText(stringResource(R.string.executiontarget_checking))
                }
                return@Column
            }

            state.errorCode?.let { code ->
                ErrorCard(
                    code = code,
                    retryable = state.retryable,
                    onRetry = onRefresh,
                    onDismiss = onDismissError,
                )
            }
            state.notice?.let { notice ->
                NoticeCard(notice = notice, onDismiss = onDismissNotice)
            }

            val snapshot = state.snapshot
            if (snapshot == null) {
                FloeText(
                    stringResource(R.string.executiontarget_runtime_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                return@Column
            }

            CurrentTargetCard(state)

            val choices = buildChoices(snapshot)
            var selectedKey by rememberSaveable(snapshot.taskID, snapshot.target?.revision) {
                mutableStateOf(ExecutionLocationChoices.initialKey(snapshot))
            }
            LaunchedEffect(snapshot.taskID, snapshot.target?.revision, choices.map { it.key }) {
                if (choices.none { it.key == selectedKey }) {
                    selectedKey = ExecutionLocationChoices.initialKey(snapshot)
                }
            }
            val selected = choices.firstOrNull { it.key == selectedKey }

            FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_choose)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (choices.isEmpty()) {
                            FloeText(
                                stringResource(R.string.executiontarget_no_local),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        choices.forEach { choice ->
                            ChoiceRow(
                                choice = choice.copy(enabled = choice.enabled && !state.busy),
                                selected = choice.key == selectedKey,
                                onSelect = {
                                    if (selectedKey != choice.key) {
                                        selectedKey = choice.key
                                        onDestinationChanged()
                                    }
                                },
                            )
                        }
                        if (!snapshot.remoteExecutionAllowed) {
                            FloeText(
                                stringResource(R.string.executiontarget_remote_off),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                })
            }

            if (snapshot.target == null) {
                FloePrimaryAction(
                    label = stringResource(R.string.executiontarget_set),
                    enabled = selected?.enabled == true && !state.busy,
                    onClick = {
                        selected?.let {
                            onInitialize(it.kind, it.environmentID, it.hostID)
                        }
                    },
                )
            } else if (selected != null && !selected.isCurrent) {
                MoveTaskSection(
                    state = state,
                    choices = choices,
                    selected = selected,
                    onCheck = {
                        selected?.let {
                            onCheckMigration(it.kind, it.environmentID, it.hostID)
                        }
                    },
                    onBegin = {
                        selected?.let {
                            onBeginMigration(it.kind, it.environmentID, it.hostID)
                        }
                    },
                )
            } else {
                FloeText(
                    stringResource(R.string.executiontarget_choose_other),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            state.challenge?.let { challenge ->
                HostKeyCard(
                    challenge = challenge,
                    busy = state.busy,
                    onApprove = { replace ->
                        onApproveHostKey(
                            challenge.id, true, replace, challenge.expectedFingerprintSHA256)
                    },
                    onReject = { onApproveHostKey(challenge.id, false, false, null) },
                )
            }

            state.activeMigration?.let { migration ->
                MigrationCard(
                    migration = migration,
                    busy = state.busy,
                    onCancel = onCancelMigration,
                )
            }
        }
    }
}

@Composable
private fun CurrentTargetCard(state: ExecutionTargetUiState) {
    val target = state.currentTarget
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_current)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (target == null) {
                    FloeText(
                        stringResource(R.string.executiontarget_not_set),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    FloeText(targetTitle(target, state), style = Floe.typography.bodyEmphasized)
                    FloeText(
                        targetDetail(target, state),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeText(
                        stringResource(R.string.executiontarget_revision, target.revision),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        })
    }
}

@Composable
private fun MoveTaskSection(
    state: ExecutionTargetUiState,
    choices: List<TargetChoice>,
    selected: TargetChoice?,
    onCheck: () -> Unit,
    onBegin: () -> Unit,
) {
    val current = state.currentTarget ?: return
    val preview = state.preview
    val previewMatches = preview != null &&
        selected != null &&
        preview.destination.kind == selected.kind &&
        preview.destination.environmentID == (selected.environmentID ?: preview.destination.environmentID) &&
        preview.destination.remoteHostID == selected.hostID
    var confirmed by rememberSaveable(state.taskID, preview?.generatedAt) {
        mutableStateOf(false)
    }
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_move)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeText(
                    stringResource(R.string.executiontarget_drain_warning),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeCapsuleAction(
                    label = if (state.busy) {
                        stringResource(R.string.executiontarget_checking)
                    } else {
                        stringResource(R.string.executiontarget_check)
                    },
                    onClick = { if (!state.busy) onCheck() },
                )
                if (preview != null && previewMatches) {
                    FloeDivider()
                    FloeText(
                        stringResource(R.string.executiontarget_affected),
                        style = Floe.typography.bodyEmphasized,
                    )
                    AffectedWork(preview)
                    if (preview.requiresDrain) {
                        FloeCheckboxRow(
                            label = stringResource(R.string.executiontarget_confirm_stop),
                            checked = confirmed,
                            onCheckedChange = { confirmed = it },
                        )
                    }
                    FloePrimaryAction(
                        label = stringResource(R.string.executiontarget_commit_move),
                        enabled = preview.canCommit &&
                            state.snapshot?.migration == null &&
                            (!preview.requiresDrain || confirmed) &&
                            !state.busy,
                        onClick = onBegin,
                    )
                }
                if (state.snapshot?.migration == null && preview == null) {
                    FloeText(
                        stringResource(R.string.executiontarget_check_required),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (current.kind == "ssh" && choices.none { it.kind == "ssh" }) {
                    FloeText(
                        stringResource(R.string.executiontarget_error_host),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        })
    }
}

@Composable
private fun AffectedWork(preview: C02MigrationPreviewUi) {
    val work = preview.affectedWork
    if (!work.hasLiveWork) {
        FloeText(
            stringResource(R.string.executiontarget_affected_none),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        return
    }
    FloeText(
        stringResource(
            R.string.executiontarget_affected_counts,
            work.liveRuns + work.liveChildRuns,
            work.activeJobs,
            work.shellSessions,
            work.managedServices,
        ),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
    if (work.unknownOutcomes > 0) {
        FloeText(
            stringResource(R.string.executiontarget_unknown, work.unknownOutcomes),
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
        )
    }
}

@Composable
private fun ChoiceRow(
    choice: TargetChoice,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(enabled = choice.enabled) { onSelect() }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeSelectionSlot(
            checked = selected,
            onCheckedChange = { if (choice.enabled) onSelect() },
            description = choice.title,
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            FloeText(
                choice.title,
                style = Floe.typography.body,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = if (choice.enabled) Floe.colors.label else Floe.colors.secondaryLabel,
            )
            FloeText(
                choice.detail,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun HostKeyCard(
    challenge: C02HostKeyChallengeUi,
    busy: Boolean,
    onApprove: (replaceChanged: Boolean) -> Unit,
    onReject: () -> Unit,
) {
    val changed = challenge.kind == "changed"
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_host_key_title)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    if (changed) {
                        stringResource(R.string.executiontarget_host_key_changed)
                    } else {
                        stringResource(R.string.executiontarget_host_key_body)
                    },
                    style = Floe.typography.metadata,
                    color = if (changed) Floe.colors.destructive else Floe.colors.secondaryLabel,
                )
                FloeText(
                    "${challenge.address}:${challenge.port}",
                    style = Floe.typography.bodyEmphasized,
                )
                FloeText(
                    challenge.fingerprintSHA256,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.executiontarget_trust),
                        onClick = { if (!busy) onApprove(changed) },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.executiontarget_reject),
                        onClick = { if (!busy) onReject() },
                    )
                }
            }
        })
    }
}

@Composable
private fun MigrationCard(
    migration: C02MigrationUi,
    busy: Boolean,
    onCancel: () -> Unit,
) {
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_move)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    stringResource(
                        R.string.executiontarget_migration_status,
                        phaseLabel(migration.phase),
                    ),
                    style = Floe.typography.bodyEmphasized,
                )
                if (migration.failureCode != null) {
                    FloeText(
                        stringResource(R.string.executiontarget_error_drain),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                if (migration.phase != "committed" &&
                    migration.phase != "completed" &&
                    migration.phase != "cancelled" &&
                    migration.phase != "failed"
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.executiontarget_cancel_move),
                        onClick = { if (!busy) onCancel() },
                    )
                }
            }
        })
    }
}

@Composable
private fun ErrorCard(
    code: String,
    retryable: Boolean,
    onRetry: () -> Unit,
    onDismiss: () -> Unit,
) {
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_title)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    errorCopy(code),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (retryable) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.executiontarget_retry),
                            onClick = onRetry,
                        )
                    }
                    FloeCapsuleAction(
                        label = stringResource(R.string.executiontarget_dismiss),
                        onClick = onDismiss,
                    )
                }
            }
        })
    }
}

@Composable
private fun NoticeCard(notice: String, onDismiss: () -> Unit) {
    FloeSettingsSectionCard(title = stringResource(R.string.executiontarget_title)) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(noticeCopy(notice), style = Floe.typography.metadata)
                FloeCapsuleAction(
                    label = stringResource(R.string.executiontarget_dismiss),
                    onClick = onDismiss,
                )
            }
        })
    }
}

@Composable
private fun buildChoices(
    snapshot: C02TargetSnapshotUi,
): List<TargetChoice> = ExecutionLocationChoices.available(snapshot).map { choice ->
    val title = if (choice.kind == "ssh") {
        choice.name ?: stringResource(R.string.executiontarget_ssh_kind)
    } else {
        val kind = localKindTitle(choice.localKind)
        choice.name?.takeIf { it.isNotBlank() && it != choice.environmentID }
            ?.let { "$kind · $it" } ?: kind
    }
    val scope = if (choice.kind == "ssh") "SSH" else localScopeDetail(choice.localKind)
    TargetChoice(
        key = choice.key, kind = choice.kind,
        environmentID = choice.environmentID, hostID = choice.hostID,
        title = title,
        detail = if (choice.isCurrent) "$scope · ${stringResource(R.string.executiontarget_selected_location)}" else scope,
        enabled = choice.enabled,
        isCurrent = choice.isCurrent,
    )
}

@Composable
private fun localKindTitle(kind: String?): String = stringResource(when (kind) {
    "project" -> R.string.executiontarget_project_kind
    "session" -> R.string.executiontarget_session_kind
    else -> R.string.executiontarget_local_kind
})

@Composable
private fun localScopeDetail(kind: String?): String = stringResource(when (kind) {
    "project" -> R.string.executiontarget_project_detail
    "session" -> R.string.executiontarget_session_detail
    else -> R.string.executiontarget_local_kind
})

@Composable
private fun targetTitle(
    target: C02TargetUi,
    state: ExecutionTargetUiState,
): String {
    val snapshot = state.snapshot
    if (target.kind == "ssh") {
        val host = snapshot?.remoteHosts?.firstOrNull { it.id == target.remoteHostID }
        return host?.displayName ?: stringResource(R.string.executiontarget_ssh_kind)
    }
    val local = snapshot?.localEnvironments?.firstOrNull { it.id == target.environmentID }
    val kind = localKindTitle(local?.kind)
    return local?.name?.takeIf { it.isNotBlank() && it != target.environmentID }?.let { "$kind · $it" } ?: kind
}

@Composable
private fun targetDetail(target: C02TargetUi, state: ExecutionTargetUiState): String {
    if (target.kind == "ssh") {
        val detail = listOfNotNull(target.remoteOS, target.remoteArchitecture)
            .joinToString(" · ")
        return if (detail.isBlank()) {
            stringResource(R.string.executiontarget_ssh_kind)
        } else {
            detail
        }
    }
    val local = state.snapshot?.localEnvironments?.firstOrNull { it.id == target.environmentID }
    return localScopeDetail(local?.kind)
}

@Composable
private fun phaseLabel(phase: String): String = when (phase) {
    "checking" -> stringResource(R.string.executiontarget_phase_checking)
    "draining" -> stringResource(R.string.executiontarget_phase_draining)
    "verified" -> stringResource(R.string.executiontarget_phase_verified)
    "committed" -> stringResource(R.string.executiontarget_phase_committed)
    "completed" -> stringResource(R.string.executiontarget_phase_completed)
    "failed" -> stringResource(R.string.executiontarget_phase_failed)
    "cancelled" -> stringResource(R.string.executiontarget_phase_cancelled)
    else -> phase
}

@Composable
private fun errorCopy(code: String): String = when {
    code.contains("drainTimedOut", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_drain)
    code.contains("staleRevision", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_stale)
    code.contains("remoteExecutionNotAllowed", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_remote_off)
    code.contains("environment", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_environment)
    code.contains("remoteHost", ignoreCase = true) ||
        code.contains("hostKey", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_host)
    code.contains("schemaUnavailable", ignoreCase = true) ->
        stringResource(R.string.executiontarget_error_schema)
    code.contains("temporaryTaskRefused", ignoreCase = true) ->
        stringResource(R.string.executiontarget_temporary)
    code == "runtime_unavailable" ->
        stringResource(R.string.executiontarget_runtime_unavailable)
    code == "checkRequired" ->
        stringResource(R.string.executiontarget_check_required)
    code == "stalePreview" ->
        stringResource(R.string.executiontarget_stale_preview)
    else -> stringResource(R.string.executiontarget_error_generic)
}

@Composable
private fun noticeCopy(notice: String): String = when (notice) {
    "targetSet" -> stringResource(R.string.executiontarget_notice_set)
    "moved" -> stringResource(R.string.executiontarget_notice_moved)
    "moveCancelled" -> stringResource(R.string.executiontarget_notice_cancelled)
    "hostTrusted" -> stringResource(R.string.executiontarget_notice_trusted)
    "hostRejected" -> stringResource(R.string.executiontarget_notice_rejected)
    else -> stringResource(R.string.executiontarget_notice_set)
}
