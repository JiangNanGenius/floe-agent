// SPDX-License-Identifier: MPL-2.0
//
// C07 reachable settings surface. Presentation only: backup bytes, restore
// staging, archive validation, journals, project/note/settings writes and SAF
// IO are App-host/Swift authority. Copy states the real scope and never claims
// a cloud, provider or two-device sync path.
package com.floe.android.feature.dataexchange

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionItem

@Composable
public fun DataExchangeSettingsPage(
    state: DataExchangeUiState,
    onCreateBackup: () -> Unit,
    onCancelBackup: () -> Unit,
    onPickRestore: () -> Unit,
    onPickNoteImport: () -> Unit,
    onPickCanvasImport: () -> Unit,
    onPickDocumentImport: () -> Unit,
    onExportCanvas: (String) -> Unit,
    onConfirmRestore: () -> Unit,
    onCancelRestore: () -> Unit,
    onRecover: () -> Unit,
    onRefresh: () -> Unit,
    onDismissStatus: () -> Unit,
    onOpenRestoredDocument: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirm by remember(state.plan) { mutableStateOf(false) }
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (!state.coreReady) {
            FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_title)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (state.loading) {
                            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                                FloeActivityIndicator()
                                Spacer(Modifier.width(10.dp))
                                FloeText(stringResource(R.string.dataexchange_checking))
                            }
                        } else {
                            FloeText(
                                stringResource(R.string.dataexchange_unavailable_body),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                            state.errorCode?.let { code ->
                                FloeText(
                                    errorCopy(code),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.destructive,
                                )
                            }
                            FloeCapsuleAction(
                                label = stringResource(R.string.dataexchange_retry),
                                onClick = onRefresh,
                            )
                        }
                    }
                })
            }
            return@Column
        }

        FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_scope_title)) {
            SectionItem(title = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeText(
                        stringResource(R.string.dataexchange_scope_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeDivider()
                    FloeText(
                        stringResource(R.string.dataexchange_included),
                        style = Floe.typography.bodyEmphasized,
                    )
                    Bullet(stringResource(R.string.dataexchange_included_projects))
                    Bullet(stringResource(R.string.dataexchange_included_retained))
                    Bullet(stringResource(R.string.dataexchange_included_notes))
                    Bullet(stringResource(R.string.dataexchange_included_tasks))
                    Bullet(stringResource(R.string.dataexchange_included_canvas))
                    Bullet(stringResource(R.string.dataexchange_included_files))
                    Bullet(stringResource(R.string.dataexchange_included_office))
                    Bullet(stringResource(R.string.dataexchange_included_config))
                    Bullet(stringResource(R.string.dataexchange_included_schedules))
                    Bullet(stringResource(R.string.dataexchange_included_receipts))
                    Bullet(stringResource(R.string.dataexchange_included_settings))
                    FloeText(
                        stringResource(R.string.dataexchange_floecad_note),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeText(
                        stringResource(R.string.dataexchange_note_export_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloeDivider()
                    FloeText(
                        stringResource(R.string.dataexchange_excluded),
                        style = Floe.typography.bodyEmphasized,
                    )
                    FloeText(
                        stringResource(R.string.dataexchange_excluded_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    state.capabilities?.excluded?.forEach { item ->
                        FloeText(
                            "• " + excludedCopy(item.id),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    FloeText(
                        stringResource(
                            R.string.dataexchange_no_database,
                            state.capabilities?.formatVersion ?: 1,
                            state.capabilities?.backupExtension ?: "floebackup",
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            })
        }

        FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_backup_title)) {
            SectionItem(title = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeText(
                        stringResource(R.string.dataexchange_backup_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    if (state.phase == DataExchangePhase.BACKING_UP) {
                        ProgressRow(state)
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_cancel),
                            onClick = onCancelBackup,
                        )
                    } else {
                        FloePrimaryAction(
                            label = stringResource(R.string.dataexchange_backup_action),
                            onClick = onCreateBackup,
                            enabled = !state.busy &&
                                state.phase != DataExchangePhase.REVIEWING,
                        )
                    }
                    state.backupBytes?.let { bytes ->
                        FloeText(
                            stringResource(R.string.dataexchange_backup_saved, bytes),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    state.backupSha256?.let { sha ->
                        FloeText(
                            stringResource(R.string.dataexchange_backup_hash, sha.take(16)),
                            style = Floe.typography.evidence,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    if (state.backupWarnings.isNotEmpty()) {
                        FloeDivider()
                        FloeText(
                            stringResource(
                                R.string.dataexchange_backup_warnings,
                                state.backupWarnings.size,
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.destructive,
                        )
                        state.backupWarnings.take(6).forEach { warning ->
                            FloeText(
                                "• " + warning,
                                style = Floe.typography.evidence,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                }
            })
        }

        FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_restore_title)) {
            SectionItem(title = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeText(
                        stringResource(R.string.dataexchange_restore_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    if (state.phase == DataExchangePhase.INSPECTING) {
                        ProgressRow(state)
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_cancel),
                            onClick = onCancelRestore,
                        )
                    } else if (state.phase == DataExchangePhase.REVIEWING) {
                        state.plan?.let { plan ->
                            PlanReview(plan, state.importMode)
                            FloeDivider()
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                FloePrimaryAction(
                                    label = if (state.importMode) {
                                        stringResource(R.string.dataexchange_import_confirm)
                                    } else {
                                        stringResource(R.string.dataexchange_restore_confirm)
                                    },
                                    onClick = { confirm = true },
                                    enabled = !state.busy,
                                    modifier = Modifier.weight(1f),
                                )
                                FloeCapsuleAction(
                                    label = stringResource(R.string.dataexchange_cancel),
                                    onClick = onCancelRestore,
                                )
                            }
                        }
                    } else if (state.phase == DataExchangePhase.RESTORING) {
                        ProgressRow(state)
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_cancel),
                            onClick = onCancelRestore,
                        )
                    } else {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            FloePrimaryAction(
                                label = stringResource(R.string.dataexchange_restore_action),
                                onClick = onPickRestore,
                                enabled = !state.busy,
                                modifier = Modifier.weight(1f),
                            )
                            FloeCapsuleAction(
                                label = stringResource(R.string.dataexchange_import_note_action),
                                onClick = onPickNoteImport,
                                enabled = !state.busy,
                            )
                        }
                    }
                }
            })
        }

        FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_package_title)) {
            SectionItem(title = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeText(
                        stringResource(R.string.dataexchange_package_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_package_canvas_import),
                            onClick = onPickCanvasImport,
                            enabled = !state.busy,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_package_document_import),
                            onClick = onPickDocumentImport,
                            enabled = !state.busy,
                        )
                    }
                    if (state.canvases.isNotEmpty()) {
                        FloeDivider()
                        FloeText(
                            stringResource(R.string.dataexchange_package_canvas_export),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        state.canvases.take(8).forEach { canvas ->
                            FloeCapsuleAction(
                                label = canvas.name,
                                onClick = { onExportCanvas(canvas.canvasID) },
                                enabled = !state.busy,
                            )
                        }
                    }
                }
            })
        }

        if (state.pendingRecoveries > 0) {
            FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_recovery_title)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        FloeText(
                            stringResource(
                                R.string.dataexchange_recovery_body,
                                state.pendingRecoveries,
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        FloePrimaryAction(
                            label = stringResource(R.string.dataexchange_recovery_action),
                            onClick = onRecover,
                            enabled = !state.busy,
                        )
                    }
                })
            }
        }

        state.receipt?.let { receipt ->
            FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_result_title)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        FloeText(
                            if (receipt.isEmpty) {
                                stringResource(R.string.dataexchange_result_empty)
                            } else {
                                stringResource(R.string.dataexchange_result_body)
                            },
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        FloeText(
                            stringResource(
                                R.string.dataexchange_result_counts,
                                receipt.projects,
                                receipt.noteDocuments,
                                receipt.notebooks,
                                receipt.settings,
                            ),
                            style = Floe.typography.metadata,
                        )
                        if (receipt.conversations > 0 || receipt.messages > 0) {
                            FloeText(
                                stringResource(
                                    R.string.dataexchange_result_tasks,
                                    receipt.conversations,
                                    receipt.messages,
                                    receipt.runs,
                                ),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.canvasProjects > 0 || receipt.mediaProjects > 0) {
                            FloeText(
                                stringResource(
                                    R.string.dataexchange_result_canvas,
                                    receipt.canvasProjects,
                                    receipt.mediaProjects,
                                ),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.skippedProjects > 0) {
                            FloeText(
                                stringResource(
                                    R.string.dataexchange_result_skipped,
                                    receipt.skippedProjects,
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        if (receipt.todos > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_todos,
                                    receipt.todos),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.toolResults > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_tool_results,
                                    receipt.toolResults),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.appArtifacts > 0 || receipt.captureFiles > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_artifacts,
                                    receipt.appArtifacts, receipt.captureFiles),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.configSections > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_config,
                                    receipt.configSections),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.mcpDefinitions > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_mcp,
                                    receipt.mcpDefinitions),
                                style = Floe.typography.metadata,
                            )
                            FloeText(
                                stringResource(R.string.dataexchange_mcp_restored_notice),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        if (receipt.managedFonts > 0) {
                            FloeText(stringResource(R.string.c07_restored_fonts, receipt.managedFonts),
                                style = Floe.typography.metadata)
                        }
                        if (receipt.officeDrafts > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_office,
                                    receipt.officeDrafts),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.memoryEntries > 0 || receipt.memoryCandidates > 0 ||
                            receipt.personalizationDocuments > 0
                        ) {
                            FloeText(
                                stringResource(
                                    R.string.dataexchange_result_memory,
                                    receipt.memoryEntries, receipt.memoryCandidates,
                                    receipt.personalizationDocuments,
                                ),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.checklistRevisions > 0 || receipt.skills > 0 ||
                            receipt.modelPreferences > 0
                        ) {
                            FloeText(
                                stringResource(
                                    R.string.dataexchange_result_userdata,
                                    receipt.checklistRevisions, receipt.skills,
                                    receipt.modelPreferences,
                                ),
                                style = Floe.typography.metadata,
                            )
                        }
                        if (receipt.partial) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_partial),
                                style = Floe.typography.metadata,
                                color = Floe.colors.destructive,
                            )
                        }
                        if (receipt.noteDocuments > 0) {
                            FloeText(
                                stringResource(R.string.dataexchange_result_notes_hint),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        state.resultWarnings.take(6).forEach { warning ->
                            FloeText(
                                "• " + warning,
                                style = Floe.typography.evidence,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                })
            }
        }

        if (state.restoredDocuments.isNotEmpty()) {
            FloeSettingsSectionCard(
                title = stringResource(R.string.dataexchange_office_restored_title),
            ) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeText(
                            stringResource(R.string.dataexchange_office_restored_body),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        state.restoredDocuments.forEach { document ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    FloeText(
                                        document.displayName,
                                        style = Floe.typography.bodyEmphasized,
                                    )
                                    FloeText(
                                        stringResource(
                                            R.string.dataexchange_office_kind_line,
                                            document.format.uppercase(),
                                            stringResource(
                                                if (document.kind == "verifiedOutput") {
                                                    R.string.dataexchange_office_kind_verified
                                                } else {
                                                    R.string.dataexchange_office_kind_working
                                                },
                                            ),
                                        ),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                }
                                FloeCapsuleAction(
                                    label = stringResource(
                                        R.string.dataexchange_office_open),
                                    onClick = {
                                        onOpenRestoredDocument(document.documentID)
                                    },
                                    enabled = !state.busy &&
                                        state.restoredBusyId == null,
                                )
                            }
                        }
                    }
                })
            }
        }

        state.errorCode?.let { code ->
            FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_error_title)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        FloeText(
                            errorCopy(code),
                            style = Floe.typography.metadata,
                            color = Floe.colors.destructive,
                        )
                        FloeText(
                            code,
                            style = Floe.typography.evidence,
                            color = Floe.colors.secondaryLabel,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_error_dismiss),
                            onClick = onDismissStatus,
                        )
                    }
                })
            }
        }

        state.noticeCode?.let { code ->
            FloeSettingsSectionCard(title = stringResource(R.string.dataexchange_result_title)) {
                SectionItem(title = {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        FloeText(
                            noticeCopy(code),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.dataexchange_error_dismiss),
                            onClick = onDismissStatus,
                        )
                    }
                })
            }
        }
    }

    if (confirm) state.plan?.let { plan ->
        FloeConfirmDialog(
            title = stringResource(
                if (state.importMode) R.string.dataexchange_import_title
                else R.string.dataexchange_restore_title_confirm,
            ),
            message = if (state.importMode) {
                stringResource(
                    R.string.dataexchange_import_message,
                    plan.noteDocuments,
                    plan.noteResources,
                )
            } else {
                stringResource(
                    R.string.dataexchange_restore_message,
                    plan.projects,
                    plan.projectFiles,
                    plan.noteDocuments,
                    plan.settingsKeys,
                )
            },
            confirmLabel = stringResource(R.string.dataexchange_confirm),
            dismissLabel = stringResource(R.string.dataexchange_cancel),
            onConfirm = {
                confirm = false
                onConfirmRestore()
            },
            onDismiss = { confirm = false },
        )
    }
}

@Composable
private fun Bullet(text: String) {
    FloeText(
        "• " + text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
}

@Composable
private fun ProgressRow(state: DataExchangeUiState) {
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        FloeActivityIndicator()
        Spacer(Modifier.width(10.dp))
        val text = if (state.progressTotal > 0) {
            stringResource(
                R.string.dataexchange_progress,
                state.progressDone,
                state.progressTotal,
            )
        } else {
            stringResource(R.string.dataexchange_working)
        }
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun PlanReview(plan: DataExchangePlanUi, importMode: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (!importMode) {
            FloeText(
                stringResource(
                    R.string.dataexchange_plan_projects,
                    plan.projects,
                    plan.projectFiles,
                ),
                style = Floe.typography.metadata,
            )
            if (plan.conversations > 0 || plan.messages > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_tasks,
                        plan.conversations,
                        plan.messages,
                        plan.runs,
                    ),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.canvasProjects > 0 || plan.mediaProjects > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_canvas,
                        plan.canvasProjects,
                        plan.mediaProjects,
                        plan.mediaAssets,
                    ),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.schedules > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_schedules,
                        plan.schedules,
                    ),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.actionReceipts > 0 || plan.mailReceipts > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_receipts,
                        plan.actionReceipts,
                        plan.mailReceipts,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.executionEvidence > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_evidence,
                        plan.executionEvidence,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.todos > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_todos, plan.todos),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.toolResults > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_tool_results,
                        plan.toolResults),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.appArtifacts > 0 || plan.captureFiles > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_artifacts,
                        plan.appArtifacts, plan.captureFiles),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.configSections > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_config,
                        plan.configSections),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.mcpDefinitions > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_mcp,
                        plan.mcpDefinitions),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.officeDrafts > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_office,
                        plan.officeDrafts),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (plan.memoryEntries > 0 || plan.memoryCandidates > 0 ||
                plan.personalizationDocuments > 0
            ) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_memory,
                        plan.memoryEntries, plan.memoryCandidates,
                        plan.personalizationDocuments,
                    ),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.checklistRevisions > 0 || plan.skills > 0 ||
                plan.modelPreferences > 0
            ) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_userdata,
                        plan.checklistRevisions, plan.skills,
                        plan.modelPreferences,
                    ),
                    style = Floe.typography.metadata,
                )
            }
            if (plan.partial || plan.omissions > 0) {
                FloeText(
                    stringResource(R.string.dataexchange_plan_partial,
                        plan.omissions),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
        }
        FloeText(
            stringResource(
                R.string.dataexchange_plan_notes,
                plan.noteDocuments,
                plan.noteResources,
                plan.notebooks,
            ),
            style = Floe.typography.metadata,
        )
        if (!importMode) {
            FloeText(
                stringResource(R.string.dataexchange_plan_settings, plan.settingsKeys),
                style = Floe.typography.metadata,
            )
            if (plan.providerAdvisories > 0) {
                FloeText(
                    stringResource(
                        R.string.dataexchange_plan_providers,
                        plan.providerAdvisories,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (plan.trashedNotesExcluded > 0) {
            FloeText(
                stringResource(
                    R.string.dataexchange_plan_trash,
                    plan.trashedNotesExcluded,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (plan.skippedProjects > 0) {
            FloeText(
                stringResource(R.string.dataexchange_plan_skipped, plan.skippedProjects),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
        }
        if (plan.warnings.isNotEmpty()) {
            FloeText(
                stringResource(
                    R.string.dataexchange_plan_warnings,
                    plan.warnings.size,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            plan.warnings.take(6).forEach { warning ->
                FloeText(
                    "• " + warning,
                    style = Floe.typography.evidence,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        FloeText(
            stringResource(R.string.dataexchange_plan_new_copies),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun excludedCopy(id: String): String = when (id) {
    "appDatabase" -> stringResource(R.string.dataexchange_excluded_database)
    "notesDatabase" -> stringResource(R.string.dataexchange_excluded_notes_database)
    "credentials" -> stringResource(R.string.dataexchange_excluded_credentials)
    "deviceKeys" -> stringResource(R.string.dataexchange_excluded_device_keys)
    "sessionSecrets" -> stringResource(R.string.dataexchange_excluded_sessions)
    "cookies" -> stringResource(R.string.dataexchange_excluded_cookies)
    "approvalGrants", "taskPolicies" ->
        stringResource(R.string.dataexchange_excluded_task_policies)
    "executionTargetAuthorization" ->
        stringResource(R.string.dataexchange_excluded_execution_auth)
    "remoteHostTrust" -> stringResource(R.string.dataexchange_excluded_remote_trust)
    "externalWorkspaceTokens", "externalFileBookmarks" ->
        stringResource(R.string.dataexchange_excluded_external_tokens)
    "browserSessions" -> stringResource(R.string.dataexchange_excluded_browser)
    "mailCredentials", "mailDraftsAndTransfers" ->
        stringResource(R.string.dataexchange_excluded_mail_credentials)
    "runCheckpointsAndPendingInputs" ->
        stringResource(R.string.dataexchange_excluded_run_state)
    "mediaGenerationJobs" ->
        stringResource(R.string.dataexchange_excluded_media_jobs)
    "mediaGenerationCandidates" ->
        stringResource(R.string.dataexchange_excluded_media_candidates)
    "creativeAssetIndex" ->
        stringResource(R.string.dataexchange_excluded_derived_index)
    "cloudKeys" -> stringResource(R.string.dataexchange_excluded_cloud_keys)
    "environmentImages" ->
        stringResource(R.string.dataexchange_excluded_environment_images)
    "canvasCADDrafts", "canvasNativeCADPackages" ->
        stringResource(R.string.dataexchange_excluded_canvas_cad)
    "canvasRunContexts" ->
        stringResource(R.string.dataexchange_excluded_canvas_run)
    "realtimeSync" ->
        stringResource(R.string.dataexchange_excluded_realtime)
    "conversationsAndRuns" -> stringResource(R.string.dataexchange_excluded_chats)
    "runOutputs" -> stringResource(R.string.dataexchange_excluded_outputs)
    "privateTaskWorkspaces" -> stringResource(R.string.dataexchange_excluded_tasks)
    "externalWorkspaceRoots" -> stringResource(R.string.dataexchange_excluded_external)
    "systemPersonalData" -> stringResource(R.string.dataexchange_excluded_system)
    "canvasMediaProjects" -> stringResource(R.string.dataexchange_excluded_canvas)
    "captureArtifacts" -> stringResource(R.string.dataexchange_excluded_capture)
    "privilegedPacketCaptureBuffers" ->
        stringResource(R.string.dataexchange_excluded_privileged_capture)
    "voiceTransientStaging" ->
        stringResource(R.string.dataexchange_excluded_voice_staging)
    "rdpTrustPins" -> stringResource(R.string.dataexchange_excluded_rdp_trust)
    "toolResultExecutionReplay" ->
        stringResource(R.string.dataexchange_excluded_tool_replay)
    "cadEditingKernel" -> stringResource(R.string.dataexchange_excluded_cad_kernel)
    "personalizationMemory" ->
        stringResource(R.string.dataexchange_excluded_memory)
    "skillsLibrary" -> stringResource(R.string.dataexchange_excluded_skills)
    "taskChecklistRevisions" ->
        stringResource(R.string.dataexchange_excluded_checklists)
    "modelPreferences" ->
        stringResource(R.string.dataexchange_excluded_model_prefs)
    "workspaceRecentFiles" ->
        stringResource(R.string.dataexchange_excluded_recent_files)
    "runDependencies" ->
        stringResource(R.string.dataexchange_excluded_run_dependencies)
    "officeRecoveryExecutionState" ->
        stringResource(R.string.dataexchange_excluded_office_state)
    "taskContinuityExecutionControl" ->
        stringResource(R.string.dataexchange_excluded_continuity)
    "environmentsAndCaches" -> stringResource(R.string.dataexchange_excluded_environments)
    "trash" -> stringResource(R.string.dataexchange_excluded_trash)
    else -> id
}

@Composable
private fun errorCopy(code: String): String = when (code) {
    "freeSpaceInsufficient" -> stringResource(R.string.dataexchange_error_space)
    "hashMismatch", "sizeMismatch" -> stringResource(R.string.dataexchange_error_hash)
    "corruptArchive" -> stringResource(R.string.dataexchange_error_corrupt)
    "unsupportedVersion", "unsupportedFormat" -> stringResource(R.string.dataexchange_error_version)
    "invalidManifest", "invalidScope", "invalidFormat",
    "entryTooLarge", "totalTooLarge", "tooManyEntries" ->
        stringResource(R.string.dataexchange_error_manifest)
    "unsafePath", "duplicateEntry", "caseCollision", "symlinkUnsupported" ->
        stringResource(R.string.dataexchange_error_unsafe)
    "notesArchive" -> stringResource(R.string.dataexchange_error_notes)
    "documentPackage", "unsupportedFeature" ->
        stringResource(R.string.dataexchange_error_package)
    "duplicateIdentity", "referenceMissing", "artifactCollision" ->
        stringResource(R.string.dataexchange_error_reference)
    "receiptMismatch" -> stringResource(R.string.dataexchange_error_hash)
    "bridgeUnavailable" -> stringResource(R.string.dataexchange_error_storage)
    "cancelled" -> stringResource(R.string.dataexchange_error_cancelled)
    "restoreIncomplete", "rollbackFailed" -> stringResource(R.string.dataexchange_error_recovery)
    "officeDocumentMissing" -> stringResource(R.string.dataexchange_error_office_missing)
    "officePreviewUnavailable" -> stringResource(R.string.dataexchange_error_office_unavailable)
    "storageUnavailable" -> stringResource(R.string.dataexchange_error_storage)
    "timedOut" -> stringResource(R.string.dataexchange_error_timeout)
    else -> stringResource(R.string.dataexchange_error_unknown)
}

@Composable
private fun noticeCopy(code: String): String = when (code) {
    "backupSaved" -> stringResource(R.string.dataexchange_notice_backup_saved)
    "canvasExported" -> stringResource(R.string.dataexchange_notice_canvas_exported)
    "canvasImported" -> stringResource(R.string.dataexchange_notice_canvas_imported)
    "documentImported" -> stringResource(R.string.dataexchange_notice_document_imported)
    "restored" -> stringResource(R.string.dataexchange_notice_restored)
    "imported" -> stringResource(R.string.dataexchange_notice_imported)
    "officeDocumentOpened" ->
        stringResource(R.string.dataexchange_notice_office_opened)
    "recovered" -> stringResource(R.string.dataexchange_notice_recovered)
    "cancelled" -> stringResource(R.string.dataexchange_notice_cancelled)
    "partialFile" -> stringResource(R.string.dataexchange_notice_partial)
    else -> code
}
