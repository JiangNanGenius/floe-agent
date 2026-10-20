// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow

/**
 * G02 Settings pages: native-style scoped editors for the surfaces the G01
 * rows never covered. All copy is concise, bilingual and user-facing —
 * implementation terms stay in diagnostics. Loading, typed errors with
 * Retry, and genuinely unavailable surfaces are explicit.
 */
object SettingsHostPages {

    // ------------------------------------------------------------- defaults

    @Composable
    fun DefaultsPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val defaults = state.defaults
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_agent_defaults)) {
                FloeSectionRow(
                    description = stringResource(R.string.settings_default_agent_mode),
                    title = {
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            FloeText(
                                stringResource(R.string.settings_default_agent_mode),
                                style = Floe.typography.body,
                                color = Floe.colors.label,
                            )
                            Spacer(Modifier.height(8.dp))
                            FloeSegmented(
                                options = listOf(
                                    stringResource(R.string.agent_mode_human),
                                    stringResource(R.string.agent_mode_approval),
                                    stringResource(R.string.agent_mode_full),
                                ),
                                selectedIndex = when (defaults.defaultAgentMode) {
                                    "approvalModel" -> 1
                                    "fullControl" -> 2
                                    else -> 0
                                },
                                onSelect = { index ->
                                    settings.saveDefaults(
                                        defaultAgentMode = when (index) {
                                            1 -> "approvalModel"
                                            2 -> "fullControl"
                                            else -> "human"
                                        },
                                    ) {}
                                },
                            )
                        }
                    },
                )
                FloeSectionRow(
                    description = stringResource(R.string.settings_running_input_mode),
                    title = {
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            FloeText(
                                stringResource(R.string.settings_running_input_mode),
                                style = Floe.typography.body,
                                color = Floe.colors.label,
                            )
                            Spacer(Modifier.height(8.dp))
                            FloeSegmented(
                                options = listOf(
                                    stringResource(R.string.input_mode_queue),
                                    stringResource(R.string.input_mode_steer),
                                ),
                                selectedIndex = if (defaults.runningInputMode == "steer") 1 else 0,
                                onSelect = { index ->
                                    settings.saveDefaults(
                                        runningInputMode = if (index == 1) "steer" else "queue",
                                    ) {}
                                },
                            )
                        }
                    },
                )
                FloeSectionRow(
                    title = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FloeText(
                                stringResource(R.string.settings_verify_final),
                                style = Floe.typography.body,
                                color = Floe.colors.label,
                                modifier = Modifier.weight(1f),
                            )
                            FloeInlineSwitch(
                                checked = defaults.verifyFinalAnswer,
                                onCheckedChange = { checked ->
                                    settings.saveDefaults(verifyFinalAnswer = checked) {}
                                },
                                description = stringResource(R.string.settings_verify_final),
                            )
                        }
                    },
                )
            }
            SettingsStatus(
                status = state.defaultsStatus,
                onRetry = { settings.refreshDefaults() },
            )
        }
    }

    // -------------------------------------------------------------- memory

    @Composable
    fun MemoryPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val memory = state.memory
        var addOpen by remember { mutableStateOf(false) }
        var search by remember { mutableStateOf("") }
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memory_search)) {
                androidx.compose.foundation.layout.Box(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    FloeSearchField(
                        value = search,
                        onValueChange = { next ->
                            search = next
                            if (next.isBlank()) settings.clearMemorySearch()
                            else settings.searchMemory(next)
                        },
                        placeholder = stringResource(R.string.settings_memory_search_placeholder),
                    )
                }
            }
            val entries = if (memory.searchActive) {
                memory.searchItems.mapNotNull { it.current }
            } else {
                memory.entries
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memories)) {
                if (entries.isEmpty()) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_memory_empty))
                    })
                }
                entries.forEach { entry ->
                    var editOpen by remember(entry.id) { mutableStateOf(false) }
                    FloeSectionRow(
                        onClick = { editOpen = true },
                        description = entry.content,
                        title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                FloeText(
                                    entry.content,
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                    maxLines = 2,
                                )
                                FloeText(
                                    entry.scopeKind,
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        },
                    )
                    if (editOpen) {
                        MemoryEntryDialog(
                            entry = entry,
                            onSave = { content, pinned ->
                                settings.updateMemory(entry.id, entry.revision, content, null, pinned) {
                                    editOpen = false
                                }
                            },
                            onDelete = {
                                settings.deleteMemory(entry.id, entry.revision) { editOpen = false }
                            },
                            onDismiss = { editOpen = false },
                        )
                    }
                }
                FloeActionRow(
                    label = stringResource(R.string.settings_memory_add),
                    onClick = { addOpen = true },
                )
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memory_candidates)) {
                if (memory.candidates.isEmpty()) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_candidates_empty))
                    })
                }
                memory.candidates.forEach { candidate ->
                    FloeSectionRow(
                        description = candidate.content,
                        title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                FloeText(
                                    candidate.content,
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                    maxLines = 2,
                                )
                            }
                        },
                        trailing = {
                            FloeCapsuleAction(
                                label = stringResource(R.string.settings_candidate_activate),
                                onClick = {
                                    settings.resolveCandidate(candidate.id, candidate.revision, true) {}
                                },
                            )
                        },
                    )
                }
                FloeActionRow(
                    label = stringResource(R.string.settings_candidates_refresh),
                    onClick = { settings.listCandidates() },
                )
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memory_organize)) {
                val organize = memory.organize
                if (organize == null) {
                    FloeActionRow(
                        label = stringResource(R.string.settings_organize_start),
                        onClick = { settings.startOrganize(includeSemantic = false) {} },
                    )
                } else {
                    FloeSectionRow(title = {
                        FloeText(
                            stringResource(
                                R.string.settings_organize_scanned,
                                organize.scannedCount,
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    })
                    organize.suggestions.forEach { suggestion ->
                        FloeSectionRow(
                            description = suggestion.reason,
                            title = {
                                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                    FloeText(
                                        suggestion.kind,
                                        style = Floe.typography.body,
                                        color = Floe.colors.label,
                                    )
                                    FloeText(
                                        suggestion.reason,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 3,
                                    )
                                }
                            },
                        )
                    }
                    if (organize.stale) {
                        StatusLine(stringResource(R.string.settings_organize_stale))
                    }
                }
            }
            SettingsStatus(state.memoryStatus, onRetry = { settings.refreshMemory() })
        }
        if (addOpen) {
            AddMemoryDialog(
                onAdd = { content ->
                    settings.addMemory(content, "user") { addOpen = false }
                },
                onDismiss = { addOpen = false },
            )
        }
    }

    @Composable
    private fun AddMemoryDialog(onAdd: (String) -> Unit, onDismiss: () -> Unit) {
        var content by remember { mutableStateOf("") }
        androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
            ) {
                FloeText(
                    stringResource(R.string.settings_memory_add),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.height(10.dp))
                FloePlainFormField(
                    label = stringResource(R.string.settings_memory_placeholder),
                    value = content,
                    onValueChange = { content = it },
                    singleLine = false,
                    maxLines = 6,
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_save),
                        enabled = content.isNotBlank(),
                        onClick = { onAdd(content) },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.cancel),
                        onClick = onDismiss,
                    )
                }
            }
        }
    }

    @Composable
    private fun MemoryEntryDialog(
        entry: SettingsHostController.MemoryEntryProjection,
        onSave: (String, Boolean) -> Unit,
        onDelete: () -> Unit,
        onDismiss: () -> Unit,
    ) {
        var content by remember(entry.id) { mutableStateOf(entry.content) }
        var pinned by remember(entry.id) { mutableStateOf(entry.isPinned) }
        var confirmDelete by remember { mutableStateOf(false) }
        if (confirmDelete) {
            FloeConfirmDialog(
                title = stringResource(R.string.settings_memory_delete),
                message = stringResource(R.string.settings_memory_delete_message),
                confirmLabel = stringResource(R.string.settings_delete),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = onDelete,
                onDismiss = { confirmDelete = false },
            )
            return
        }
        androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
            ) {
                FloeText(
                    stringResource(R.string.settings_memory_edit),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.height(10.dp))
                FloePlainFormField(
                    label = stringResource(R.string.settings_memory_placeholder),
                    value = content,
                    onValueChange = { content = it },
                    singleLine = false,
                    maxLines = 6,
                )
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        stringResource(R.string.settings_memory_pin),
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                    )
                    FloeInlineSwitch(
                        checked = pinned,
                        onCheckedChange = { pinned = it },
                        description = stringResource(R.string.settings_memory_pin),
                    )
                }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_save),
                        onClick = { onSave(content, pinned) },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_delete),
                        tint = Floe.colors.destructive,
                        onClick = { confirmDelete = true },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.cancel),
                        onClick = onDismiss,
                    )
                }
            }
        }
    }

    // ------------------------------------------------------- personalization

    @Composable
    fun PersonalizationPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val surface = state.personalization
        var draft by remember(surface.kind, surface.content) { mutableStateOf(surface.content) }
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_personalization_kind)) {
                FloeSectionRow(title = {
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        FloeSegmented(
                            options = listOf(
                                stringResource(R.string.personalization_soul),
                                stringResource(R.string.personalization_profile),
                            ),
                            selectedIndex = if (surface.kind == "userProfile") 1 else 0,
                            onSelect = { index ->
                                settings.refreshPersonalization(
                                    if (index == 1) "userProfile" else "soul",
                                )
                            },
                        )
                    }
                })
                FloeSectionRow(title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            stringResource(R.string.settings_personalization_auto),
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                            modifier = Modifier.weight(1f),
                        )
                        FloeInlineSwitch(
                            checked = surface.automaticUpdatesEnabled,
                            onCheckedChange = { checked ->
                                settings.setPersonalizationAutomatic(surface.kind, checked) {}
                            },
                            description = stringResource(R.string.settings_personalization_auto),
                        )
                    }
                })
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_personalization_content)) {
                androidx.compose.foundation.layout.Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    FloePlainFormField(
                        label = stringResource(R.string.settings_personalization_placeholder),
                        value = draft,
                        onValueChange = { draft = it },
                        singleLine = false,
                        minLines = 5,
                        maxLines = 12,
                    )
                }
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_save),
                        onClick = {
                            settings.savePersonalization(surface.kind, draft) {}
                        },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_personalization_generate),
                        onClick = { settings.generatePersonalization(surface.kind) {} },
                        enabled = !surface.generating,
                    )
                }
                if (surface.generating) {
                    Row(
                        Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeActivityIndicator()
                        Spacer(Modifier.height(0.dp))
                        StatusLine(stringResource(R.string.settings_personalization_generating))
                    }
                }
                surface.generateError?.let { error ->
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_action_failed, error))
                    })
                }
            }
            SettingsStatus(state.personalizationStatus, onRetry = { settings.refreshPersonalization() })
        }
    }

    // ------------------------------------------------------------------ usage

    @Composable
    fun UsagePage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val usage = state.usage
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_totals)) {
                val totals = usage.totals
                if (totals == null) {
                    FloeSectionRow(title = { StatusLine(stringResource(R.string.settings_usage_empty)) })
                } else {
                    FloeValueRow(
                        stringResource(R.string.settings_usage_input),
                        totals.inputTokens.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_usage_output),
                        totals.outputTokens.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_usage_runs),
                        totals.runs.toString(),
                    )
                }
            }
            if (usage.byDay.isNotEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_by_day)) {
                    usage.byDay.forEach { day ->
                        FloeValueRow(day.date, "${day.inputTokens} / ${day.outputTokens}")
                    }
                }
            }
            if (usage.rows.isNotEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_breakdown)) {
                    usage.rows.forEach { row ->
                        FloeValueRow(row.label, "${row.inputTokens} / ${row.outputTokens}")
                    }
                }
            }
            SettingsStatus(state.usageStatus, onRetry = { settings.refreshUsage() })
        }
    }

    // ---------------------------------------------------------------- privacy

    @Composable
    fun PrivacyPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val privacy = state.privacy
        val summary = privacy.summary
        var confirmAction by remember { mutableStateOf<SettingsHostController.PrivacyClearAction?>(null) }
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FloeSettingsSectionCard(title = stringResource(R.string.settings_privacy_history)) {
                if (summary == null) {
                    FloeSectionRow(title = { StatusLine(stringResource(R.string.settings_privacy_loading)) })
                } else {
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_conversations),
                        summary.conversationCount.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_runs),
                        summary.runCount.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_grants),
                        summary.persistedGrantCount.toString(),
                    )
                    val remaining = summary.remaining
                    if (remaining != null) {
                        FloeValueRow(
                            stringResource(R.string.settings_privacy_remaining),
                            remaining.conversationCount.toString(),
                        )
                    } else {
                        // remaining == null ONLY with remainingFailure + partial.
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(
                                    R.string.settings_privacy_recount_unavailable,
                                    summary.remainingFailure ?: "unknown",
                                ),
                            )
                        })
                    }
                }
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_privacy_model_config)) {
                if (summary != null) {
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_providers),
                        summary.providerCount.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_models),
                        summary.modelCount.toString(),
                    )
                    summary.preferencesFailure?.let { failure ->
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(R.string.settings_privacy_prefs_failure, failure),
                            )
                        })
                    }
                }
            }
            val failures = privacy.historyFailures + privacy.modelConfigFailures
            if (failures.isNotEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.settings_privacy_failures)) {
                    failures.take(8).forEach { failure ->
                        FloeSectionRow(
                            description = failure.reason,
                            title = {
                                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                    FloeText(
                                        failure.phase,
                                        style = Floe.typography.body,
                                        color = Floe.colors.label,
                                    )
                                    FloeText(
                                        failure.reason,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 2,
                                    )
                                }
                            },
                        )
                    }
                    privacy.reportPage?.let { page ->
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(
                                    R.string.settings_privacy_report_page,
                                    page.items.size,
                                    page.total,
                                ),
                            )
                        })
                        if (!page.done && page.nextCursor != null) {
                            FloeActionRow(
                                label = stringResource(R.string.settings_privacy_more),
                                onClick = {
                                    settings.readPrivacyReportPage(
                                        page.handle, page.kind, page.nextCursor, 50,
                                    ) {}
                                },
                            )
                        }
                    }
                }
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_privacy_actions)) {
                FloeActionRow(
                    label = stringResource(R.string.settings_privacy_clear_history),
                    onClick = {
                        // First tap previews; the confirmation dialog mints the
                        // trusted token only from THIS tap on the CURRENT epoch.
                        confirmAction = SettingsHostController.PrivacyClearAction.HISTORY
                    },
                )
                FloeActionRow(
                    label = stringResource(R.string.settings_privacy_clear_model_config),
                    onClick = {
                        confirmAction = SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION
                    },
                )
            }
            SettingsStatus(state.privacyStatus, onRetry = { settings.refreshPrivacySummary() })
        }
        confirmAction?.let { action ->
            val tappedEpoch = settings.privacyPreviewEpoch
            FloeConfirmDialog(
                title = stringResource(
                    if (action == SettingsHostController.PrivacyClearAction.HISTORY) {
                        R.string.settings_privacy_clear_history
                    } else {
                        R.string.settings_privacy_clear_model_config
                    },
                ),
                message = stringResource(R.string.settings_privacy_clear_message),
                confirmLabel = stringResource(R.string.settings_delete),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = {
                    val token = settings.mintClearConfirmation(action, tappedEpoch)
                    if (token != null) {
                        when (action) {
                            SettingsHostController.PrivacyClearAction.HISTORY ->
                                settings.clearPrivacyHistory(token) {}
                            SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION ->
                                settings.clearPrivacyModelConfiguration(token) {}
                        }
                    }
                    confirmAction = null
                },
                onDismiss = { confirmAction = null },
            )
        }
    }

    // --------------------------------------------------------------- shared

    @Composable
    private fun SettingsStatus(
        status: SettingsHostController.SurfaceStatus,
        onRetry: () -> Unit,
    ) {
        if (status.loading) {
            Row(
                Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator()
            }
            return
        }
        status.error?.let { error ->
            FloeSettingsSectionCard(title = stringResource(R.string.settings_action_failed_title)) {
                FloeSectionRow(title = {
                    StatusLine(stringResource(R.string.settings_action_failed, error))
                })
                FloeActionRow(
                    label = stringResource(R.string.settings_retry),
                    onClick = onRetry,
                )
            }
        }
    }

    @Composable
    internal fun StatusLine(text: String) {
        FloeStatusLine(
            icon = FloeIcons.InfoCircle,
            text = text,
            color = Floe.colors.secondaryLabel,
        )
    }
}
