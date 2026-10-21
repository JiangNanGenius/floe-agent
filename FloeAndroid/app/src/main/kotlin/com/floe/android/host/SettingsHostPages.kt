// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
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
import com.floe.android.design.FloeSelectionSlot
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow
import com.floe.android.design.IconGlyph

/**
 * Honest bulk-delete failure classes: [Refused] proves the write did not
 * land; [Unconfirmed] must never be rendered as "nothing was changed".
 */
private sealed interface BulkDeleteFailure {
    data class Refused(val code: String) : BulkDeleteFailure
    data class Unconfirmed(val code: String) : BulkDeleteFailure
    data class Local(val code: String) : BulkDeleteFailure
}

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
        val roles by settings.roles.state.collectAsState()
        androidx.compose.runtime.LaunchedEffect(Unit) {
            // Idempotent: the host start already loads it when admitted;
            // opening the page must also recover when admission raced the
            // first composition.
            settings.roles.refresh()
        }
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
            ModelRolesCard(settings.roles)
        }
    }

    // --------------------------------------------------------- model roles

    /**
     * R4 — the full original model-role preferences surface. Grouped like
     * the iOS presenter: primary routes, assistance routes, then the media
     * block (shared/separate mode + media slots + autonomous routing).
     * Every secondary menu is the existing modal dialog framing; every
     * value row states its honest inherit/unavailable state.
     */
    @Composable
    private fun ModelRolesCard(roles: SettingsRoleModelController) {
        val state by roles.state.collectAsState()
        var pickerSlot by remember { mutableStateOf<SettingsRoleModelController.RoleSlot?>(null) }
        FloeSettingsSectionCard(title = stringResource(R.string.settings_model_roles)) {
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    FloeText(
                        stringResource(R.string.settings_model_roles_primary),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            })
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.DEFAULT_AGENT) {
                pickerSlot = SettingsRoleModelController.RoleSlot.DEFAULT_AGENT
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.CANVAS_AGENT) {
                pickerSlot = SettingsRoleModelController.RoleSlot.CANVAS_AGENT
            }
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    FloeText(
                        stringResource(R.string.settings_model_roles_auxiliary),
                        color = Floe.colors.secondaryLabel,
                    )
                }
            })
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM) {
                pickerSlot = SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.VISION) {
                pickerSlot = SettingsRoleModelController.RoleSlot.VISION
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.CANVAS_VISION) {
                pickerSlot = SettingsRoleModelController.RoleSlot.CANVAS_VISION
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.APPROVAL) {
                pickerSlot = SettingsRoleModelController.RoleSlot.APPROVAL
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW) {
                pickerSlot = SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW
            }
            FloeSectionRow(title = {
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    FloeText(
                        stringResource(R.string.settings_model_roles_media),
                        color = Floe.colors.secondaryLabel,
                    )
                }
            })
            val separate = state.auxiliaryImageMode ==
                SettingsRoleModelController.MODE_SEPARATE
            FloeSectionRow(
                description = stringResource(R.string.settings_role_media_mode_footer),
                title = {
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        FloeText(
                            stringResource(R.string.settings_role_media_mode),
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                        )
                        Spacer(Modifier.height(8.dp))
                        FloeSegmented(
                            options = listOf(
                                stringResource(R.string.settings_role_mode_shared),
                                stringResource(R.string.settings_role_mode_separate),
                            ),
                            selectedIndex = if (separate) 1 else 0,
                            onSelect = { index ->
                                roles.setAuxiliaryMode(separate = index == 1)
                            },
                        )
                    }
                },
            )
            if (separate) {
                RoleSlotRow(state, SettingsRoleModelController.RoleSlot.IMAGE_GENERATION) {
                    pickerSlot = SettingsRoleModelController.RoleSlot.IMAGE_GENERATION
                }
                RoleSlotRow(state, SettingsRoleModelController.RoleSlot.IMAGE_EDITING) {
                    pickerSlot = SettingsRoleModelController.RoleSlot.IMAGE_EDITING
                }
            } else {
                RoleSlotRow(state, SettingsRoleModelController.RoleSlot.SHARED_IMAGE) {
                    pickerSlot = SettingsRoleModelController.RoleSlot.SHARED_IMAGE
                }
            }
            RoleSlotRow(state, SettingsRoleModelController.RoleSlot.DEFAULT_VIDEO) {
                pickerSlot = SettingsRoleModelController.RoleSlot.DEFAULT_VIDEO
            }
            FloeSectionRow(title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        stringResource(R.string.settings_role_autonomous_routing),
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                    )
                    FloeInlineSwitch(
                        checked = state.autonomousImageRouting,
                        onCheckedChange = { checked ->
                            roles.setAutonomousImageRouting(checked)
                        },
                        description = stringResource(R.string.settings_role_autonomous_routing),
                    )
                }
            })
            if (state.hasDraftChanges) {
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_save),
                        enabled = !state.saving,
                        onClick = { roles.save() },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.cancel),
                        enabled = !state.saving,
                        onClick = { roles.discardDraft() },
                    )
                }
            }
            state.saveError?.let {
                // Concise recovery copy; the typed code stays diagnostics-only.
                FloeSectionRow(title = {
                    StatusLine(stringResource(R.string.settings_role_save_failed))
                })
            }
            state.error?.let {
                FloeSectionRow(title = {
                    StatusLine(stringResource(R.string.settings_role_load_failed))
                })
                FloeActionRow(
                    label = stringResource(R.string.settings_retry),
                    onClick = { roles.refresh() },
                )
            }
        }
        pickerSlot?.let { slot ->
            RolePickerDialog(
                roles = roles,
                state = state,
                slot = slot,
                onDismiss = { pickerSlot = null },
            )
        }
    }

    @Composable
    private fun io.github.robinpcrd.cupertino.section.SectionScope.RoleSlotRow(
        state: SettingsRoleModelController.RoleModelState,
        slot: SettingsRoleModelController.RoleSlot,
        onOpen: () -> Unit,
    ) {
        val slotState = state.slotState(slot)
        val inheritLabel = roleInheritLabel(slot)
        val valueText = when (slotState.status) {
            SettingsRoleModelController.SelectionStatus.EMPTY -> inheritLabel
            SettingsRoleModelController.SelectionStatus.AVAILABLE ->
                slotState.selectionLabel ?: inheritLabel
            SettingsRoleModelController.SelectionStatus.UNAVAILABLE ->
                stringResource(R.string.settings_role_selection_unavailable)
        }
        FloeValueRow(
            title = roleSlotTitle(slot),
            value = valueText,
            onClick = onOpen,
        )
    }

    @Composable
    private fun roleSlotTitle(
        slot: SettingsRoleModelController.RoleSlot,
    ): String = stringResource(
        when (slot) {
            SettingsRoleModelController.RoleSlot.DEFAULT_AGENT ->
                R.string.settings_role_default_agent
            SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM ->
                R.string.settings_role_general_auxiliary
            SettingsRoleModelController.RoleSlot.CANVAS_AGENT ->
                R.string.settings_role_canvas_agent
            SettingsRoleModelController.RoleSlot.VISION ->
                R.string.settings_role_vision
            SettingsRoleModelController.RoleSlot.CANVAS_VISION ->
                R.string.settings_role_canvas_vision
            SettingsRoleModelController.RoleSlot.APPROVAL ->
                R.string.settings_role_approval
            SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW ->
                R.string.settings_role_package_review
            SettingsRoleModelController.RoleSlot.SHARED_IMAGE ->
                R.string.settings_role_shared_image
            SettingsRoleModelController.RoleSlot.IMAGE_GENERATION ->
                R.string.settings_role_image_generation
            SettingsRoleModelController.RoleSlot.IMAGE_EDITING ->
                R.string.settings_role_image_editing
            SettingsRoleModelController.RoleSlot.DEFAULT_VIDEO ->
                R.string.settings_role_default_video
        },
    )

    /**
     * The model picker secondary menu (existing Floe sheet framing — a
     * centered rounded pane on wide windows, a bottom sheet on compact):
     * the honest unavailable selection stays listed until the user replaces
     * or clears it; the inherit/clear option restores the original default.
     */
    @Composable
    private fun RolePickerDialog(
        roles: SettingsRoleModelController,
        state: SettingsRoleModelController.RoleModelState,
        slot: SettingsRoleModelController.RoleSlot,
        onDismiss: () -> Unit,
    ) {
        val choices = state.choices[slot] ?: emptyList()
        val slotState = state.slotState(slot)
        val inheritLabel = roleInheritLabel(slot)
        val configuration = androidx.compose.ui.platform.LocalConfiguration.current
        val wide = configuration.screenWidthDp >= 700
        FloePageSheet(
            visible = true,
            onDismiss = onDismiss,
            widthFraction = if (wide) 0.56f else 1f,
            heightFraction = if (wide) 0.66f else 0.72f,
            placement = if (wide) {
                FloeSheetPlacement.CENTER
            } else {
                FloeSheetPlacement.BOTTOM
            },
            topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset,
        ) {
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(horizontal = 20.dp, vertical = 12.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FloeText(
                        roleSlotTitle(slot),
                        style = Floe.typography.title,
                        color = Floe.colors.label,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.cancel),
                        onClick = onDismiss,
                    )
                }
                Spacer(Modifier.height(10.dp))
                // Minimal large-catalog paging glue (Main large-profile read
                // fidelity): a valid provider may legally carry up to 512
                // models, so the picker must stay smooth on the supported
                // tail instead of composing every row eagerly. Same rows,
                // same order, same behavior — now lazily measured.
                LazyColumn(
                    Modifier
                        .fillMaxWidth()
                        .weight(1f),
                ) {
                    // Clear/inherit option (the original default behavior).
                    item {
                        PickerOptionRow(
                            label = inheritLabel,
                            selected = slotState.selection == null,
                            onClick = {
                                roles.select(slot, null)
                                onDismiss()
                            },
                        )
                    }
                    // Honest unavailable selection: preserved, not replaced.
                    if (slotState.status ==
                        SettingsRoleModelController.SelectionStatus.UNAVAILABLE &&
                        slotState.selection != null
                    ) {
                        item {
                            PickerOptionRow(
                                label = stringResource(
                                    R.string.settings_role_selection_unavailable),
                                selected = true,
                                enabled = false,
                                onClick = { },
                            )
                        }
                    }
                    if (choices.isEmpty()) {
                        item {
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = 48.dp)
                                    .padding(horizontal = 4.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                StatusLine(stringResource(R.string.settings_role_no_choices))
                            }
                        }
                    }
                    items(
                        count = choices.size,
                        key = { index -> choices[index].modelId },
                    ) { index ->
                        val choice = choices[index]
                        PickerOptionRow(
                            label = "${choice.displayName} · ${choice.providerName}",
                            selected = slotState.selection.equals(
                                choice.modelId, ignoreCase = true),
                            onClick = {
                                roles.select(slot, choice.modelId)
                                onDismiss()
                            },
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun roleInheritLabel(
        slot: SettingsRoleModelController.RoleSlot,
    ): String = when (slot) {
        SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM ->
            stringResource(R.string.settings_role_follow_main)
        SettingsRoleModelController.RoleSlot.CANVAS_AGENT ->
            stringResource(R.string.settings_role_inherit_default)
        SettingsRoleModelController.RoleSlot.CANVAS_VISION ->
            stringResource(R.string.settings_role_inherit_auxiliary)
        SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW ->
            stringResource(R.string.settings_role_follow_auxiliary)
        else -> stringResource(R.string.settings_role_not_configured)
    }

    @Composable
    private fun PickerOptionRow(
        label: String,
        selected: Boolean,
        onClick: () -> Unit,
        enabled: Boolean = true,
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(enabled = enabled, onClick = onClick)
                .padding(horizontal = 4.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                label,
                style = Floe.typography.body,
                color = when {
                    !enabled -> Floe.colors.tertiaryLabel
                    selected -> Floe.colors.accent
                    else -> Floe.colors.label
                },
                modifier = Modifier.weight(1f),
                maxLines = 2,
            )
            if (selected) {
                IconGlyph(FloeIcons.Checkmark, Floe.colors.accent, 18.dp)
            }
        }
    }

    // -------------------------------------------------------------- memory

    @Composable
    fun MemoryPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val memory = state.memory
        var search by remember { mutableStateOf("") }
        var selectionMode by remember { mutableStateOf(false) }
        var selectedIDs by remember { mutableStateOf<Set<String>>(emptySet()) }
        // The explicit intent is frozen at confirmation opening: its batch
        // identity, ids and digests cannot be recomputed while the dialog
        // is up or after an uncertain terminal.
        var bulkIntent by remember {
            mutableStateOf<SettingsHostController.MemoryBulkDeleteIntent?>(null)
        }
        var bulkRetryIntent by remember {
            mutableStateOf<SettingsHostController.MemoryBulkDeleteIntent?>(null)
        }
        var bulkFailure by remember { mutableStateOf<BulkDeleteFailure?>(null) }
        // The controller-owned identity of the CURRENT bulk interaction.
        // Any new selection, edited selection or cancel issues a new token,
        // so a late terminal of an older write never publishes into this UI.
        var bulkInteraction by remember {
            mutableStateOf<SettingsHostController.MemoryBulkInteraction?>(null)
        }
        val newBulkInteraction: () -> SettingsHostController.MemoryBulkInteraction = {
            settings.beginMemoryBulkInteraction().also { bulkInteraction = it }
        }
        val entries = if (memory.searchActive) {
            memory.searchItems.mapNotNull { it.current }
        } else {
            memory.entries
        }
        val editor = state.memoryEditor
        // Only the typed terminal of THIS editor generation is rendered;
        // the controller drops results for a dismissed/replaced editor.
        val editorMutation = state.memoryEditorMutation
            ?.takeIf { it.generation == editor?.generation }
        // Leaving the page owns no editor read or add dialog: a late
        // `memory.get`/`memory.add` must not reopen/close UI after
        // navigation, and the next visit starts from a closed dialog.
        DisposableEffect(Unit) {
            onDispose {
                settings.closeMemoryEditor()
                settings.dismissAddMemory()
            }
        }
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
                            selectionMode = false
                            selectedIDs = emptySet()
                            bulkFailure = null
                            bulkRetryIntent = null
                            // Changing the visible set is a NEW interaction:
                            // a write dispatched from the previous selection
                            // must not clear this one when it settles.
                            newBulkInteraction()
                            if (next.isBlank()) settings.clearMemorySearch()
                            else settings.searchMemory(next)
                        },
                        placeholder = stringResource(R.string.settings_memory_search_placeholder),
                    )
                }
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memories)) {
                if (entries.isEmpty()) {
                    FloeSectionRow(title = {
                        StatusLine(
                            stringResource(
                                if (memory.searchActive) {
                                    R.string.settings_memory_search_empty
                                } else {
                                    R.string.settings_memory_empty
                                },
                            ),
                        )
                    })
                }
                entries.forEach { entry ->
                    val selected = entry.id in selectedIDs
                    // Explicit composable type: the selection slot only
                    // exists in multi-select mode and keeps its own 48dp
                    // hit target independent of the row tap.
                    val selectionMarker:
                        (@Composable androidx.compose.foundation.layout.RowScope.() -> Unit)? =
                        if (selectionMode) {
                            {
                                FloeSelectionSlot(
                                    checked = selected,
                                    onCheckedChange = {
                                        selectedIDs = if (selected) {
                                            selectedIDs - entry.id
                                        } else {
                                            selectedIDs + entry.id
                                        }
                                        newBulkInteraction()
                                    },
                                    description = entry.content,
                                )
                            }
                        } else {
                            null
                        }
                    FloeSectionRow(
                        onClick = {
                            if (selectionMode) {
                                selectedIDs = if (selected) {
                                    selectedIDs - entry.id
                                } else {
                                    selectedIDs + entry.id
                                }
                                newBulkInteraction()
                            } else {
                                // ONE owned editor: a failed/superseded
                                // `memory.get` never opens, and a newer tap
                                // fences a late reply for the previous row.
                                settings.openMemoryEditor(entry.id)
                            }
                        },
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
                        trailing = selectionMarker,
                    )
                }
                if (state.memoryEditorLoading) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_memory_opening))
                    })
                }
                state.memoryEditorError?.let {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_memory_open_failed))
                    })
                }
                editor?.let { snapshot ->
                    // Typed terminal of THIS generation only. The controller
                    // never publishes a save/delete result for a dismissed or
                    // replaced editor, so a late A can neither close nor show
                    // its error on a newer B (including an ABA re-open).
                    val outcome = editorMutation?.outcome
                    val operation = editorMutation?.operation
                    val staleRefusal =
                        outcome is SettingsHostController.MemoryMutationOutcome.Refused &&
                            outcome.code == "staleRevision"
                    key(snapshot.generation) {
                        MemoryEntryDialog(
                            entry = snapshot.entry,
                            errorRes = when (outcome) {
                                is SettingsHostController.MemoryMutationOutcome.Refused ->
                                    if (staleRefusal) {
                                        if (operation ==
                                            SettingsHostController.MemoryEditorOperation.Delete
                                        ) {
                                            R.string.settings_memory_delete_stale
                                        } else {
                                            R.string.settings_memory_edit_stale
                                        }
                                    } else if (operation ==
                                        SettingsHostController.MemoryEditorOperation.Delete
                                    ) {
                                        R.string.settings_memory_delete_failed
                                    } else {
                                        R.string.settings_memory_save_failed
                                    }
                                is SettingsHostController.MemoryMutationOutcome.Unconfirmed ->
                                    if (operation ==
                                        SettingsHostController.MemoryEditorOperation.Delete
                                    ) {
                                        R.string.settings_memory_delete_uncertain
                                    } else {
                                        R.string.settings_memory_edit_uncertain
                                    }
                                else -> null
                            },
                            onReload = if (staleRefusal) {
                                {
                                    settings.closeMemoryEditor()
                                    settings.openMemoryEditor(snapshot.entry.id)
                                }
                            } else {
                                null
                            },
                            onSave = { content, pinned ->
                                settings.saveMemoryEditor(snapshot, content, pinned)
                            },
                            onDelete = { settings.deleteMemoryEditor(snapshot) },
                            onDismiss = { settings.closeMemoryEditor() },
                        )
                    }
                }
                bulkFailure?.let { failure ->
                    val message = when (failure) {
                        is BulkDeleteFailure.Unconfirmed ->
                            R.string.settings_memory_bulk_delete_uncertain
                        is BulkDeleteFailure.Refused ->
                            if (failure.code == "staleRevision") {
                                R.string.settings_memory_bulk_delete_changed
                            } else {
                                R.string.settings_memory_bulk_delete_refused
                            }
                        is BulkDeleteFailure.Local ->
                            R.string.settings_memory_bulk_delete_selection_changed
                    }
                    FloeSectionRow(title = {
                        StatusLine(stringResource(message))
                    })
                    bulkRetryIntent?.let { intent ->
                        FloeActionRow(
                            label = stringResource(R.string.settings_retry),
                            onClick = {
                                bulkFailure = null
                                // Retry belongs to the SAME UI interaction
                                // (and the same batch identity): a terminal
                                // is still published only while this token
                                // remains current.
                                val interaction = bulkInteraction
                                    ?: newBulkInteraction()
                                settings.bulkDeleteMemory(intent, interaction) { result ->
                                    when (result) {
                                        SettingsHostController.MemoryMutationOutcome.Applied -> {
                                            selectionMode = false
                                            selectedIDs = emptySet()
                                            bulkRetryIntent = null
                                            bulkFailure = null
                                        }
                                        is SettingsHostController.MemoryMutationOutcome.Refused -> {
                                            bulkFailure = BulkDeleteFailure.Refused(result.code)
                                            if (result.code == "staleRevision") {
                                                bulkRetryIntent = null
                                            }
                                        }
                                        is SettingsHostController.MemoryMutationOutcome.Unconfirmed -> {
                                            bulkFailure =
                                                BulkDeleteFailure.Unconfirmed(result.code)
                                        }
                                    }
                                }
                            },
                        )
                    }
                    FloeActionRow(
                        label = stringResource(R.string.settings_memory_refresh),
                        onClick = {
                            bulkFailure = null
                            bulkRetryIntent = null
                            // A manual refresh is a new interaction; it must
                            // not be rewritten by an older in-flight terminal.
                            newBulkInteraction()
                            settings.refreshMemory()
                        },
                    )
                }
                if (memory.searchActive) {
                    if (memory.searchChangedCount > 0) {
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(
                                    R.string.settings_memory_search_changed,
                                    memory.searchChangedCount,
                                ),
                            )
                        })
                    }
                    if (memory.searchHasMore) {
                        FloeActionRow(
                            label = stringResource(R.string.settings_memory_load_more),
                            enabled = !memory.searchLoadingMore,
                            onClick = { settings.loadMoreMemorySearch() },
                        )
                    }
                } else {
                    if (memory.nextCursor != null) {
                        FloeActionRow(
                            label = stringResource(R.string.settings_memory_load_more),
                            enabled = !memory.loadingMore,
                            onClick = { settings.loadMoreMemory() },
                        )
                    }
                    if (entries.isNotEmpty()) {
                        if (selectionMode) {
                            val selectedVisible = entries.count { it.id in selectedIDs }
                            FloeActionRow(
                                label = stringResource(
                                    R.string.settings_memory_delete_selected,
                                    selectedVisible,
                                ),
                                enabled = selectedVisible > 0,
                                onClick = {
                                    // Freeze the confirmed set HERE from the
                                    // rows the user actually sees. A selected
                                    // row that vanished in the background
                                    // invalidates the whole intent (never a
                                    // silently narrowed batch).
                                    val selectedEntries = entries.filter {
                                        it.id in selectedIDs
                                    }
                                    if (selectedEntries.size != selectedIDs.size) {
                                        bulkFailure =
                                            BulkDeleteFailure.Local("selectionChanged")
                                    } else {
                                        when (val prepared =
                                            settings.prepareMemoryBulkDelete(
                                                selectedEntries.map {
                                                    it.id to it.revision
                                                },
                                            )) {
                                            is SettingsHostController.MemoryBulkDeletePreparation.Ready -> {
                                                bulkFailure = null
                                                bulkRetryIntent = null
                                                bulkIntent = prepared.intent
                                            }
                                            is SettingsHostController.MemoryBulkDeletePreparation.Invalid -> {
                                                bulkFailure =
                                                    BulkDeleteFailure.Local(prepared.code)
                                            }
                                        }
                                    }
                                },
                            )
                            FloeActionRow(
                                label = stringResource(R.string.settings_memory_cancel_selection),
                                onClick = {
                                    selectionMode = false
                                    selectedIDs = emptySet()
                                    bulkFailure = null
                                    bulkRetryIntent = null
                                    // Cancelling the selection supersedes any
                                    // write that was dispatched from it.
                                    newBulkInteraction()
                                },
                            )
                        } else {
                            FloeActionRow(
                                label = stringResource(R.string.settings_memory_select),
                                onClick = {
                                    selectionMode = true
                                    selectedIDs = emptySet()
                                    bulkFailure = null
                                    bulkRetryIntent = null
                                    newBulkInteraction()
                                },
                            )
                        }
                    }
                }
                FloeActionRow(
                    label = stringResource(R.string.settings_memory_add),
                    onClick = { settings.openAddMemory() },
                )
            }
            FloeSettingsSectionCard(title = stringResource(R.string.settings_memory_candidates)) {
                if (memory.candidatesSweepApplied) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_candidates_sweep_applied))
                    })
                }
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
                            FloeCapsuleAction(
                                label = stringResource(R.string.settings_candidate_reject),
                                tint = Floe.colors.destructive,
                                onClick = {
                                    settings.resolveCandidate(candidate.id, candidate.revision, false) {}
                                },
                            )
                        },
                    )
                }
                if (memory.candidatesNextCursor != null) {
                    FloeActionRow(
                        label = stringResource(R.string.settings_candidates_load_more),
                        enabled = !memory.candidatesLoadingMore,
                        onClick = { settings.loadMoreCandidates() },
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
                    var confirmSuggestion by remember { mutableStateOf<String?>(null) }
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
                    // Honest automatic-cleanup outcome from the proposal.
                    organize.autoDelete?.let { autoDelete ->
                        val autoDeleteLine = when (autoDelete.status) {
                            "applied" -> stringResource(
                                R.string.settings_organize_auto_deleted,
                                organize.autoDeletedCount,
                            )
                            "staleRejected" ->
                                stringResource(R.string.settings_organize_auto_delete_stale)
                            else -> stringResource(R.string.settings_organize_auto_delete_none)
                        }
                        FloeSectionRow(title = { StatusLine(autoDeleteLine) })
                    }
                    if (organize.suggestions.isEmpty()) {
                        FloeSectionRow(title = {
                            StatusLine(stringResource(R.string.settings_organize_empty))
                        })
                    }
                    organize.suggestions.forEach { suggestion ->
                        val affected = organize.entries.filter {
                            it.id in suggestion.memoryIDs
                        }
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
                                    if (affected.isNotEmpty()) {
                                        Spacer(Modifier.height(4.dp))
                                        FloeText(
                                            stringResource(
                                                R.string.settings_organize_affected,
                                                affected.size,
                                            ),
                                            style = Floe.typography.metadata,
                                            color = Floe.colors.secondaryLabel,
                                        )
                                        affected.take(3).forEach { entry ->
                                            FloeText(
                                                entry.content,
                                                style = Floe.typography.metadata,
                                                color = Floe.colors.tertiaryLabel,
                                                maxLines = 1,
                                            )
                                        }
                                    }
                                }
                            },
                            trailing = {
                                FloeCapsuleAction(
                                    label = stringResource(R.string.settings_organize_apply),
                                    enabled = !organize.applying && !organize.stale,
                                    onClick = { confirmSuggestion = suggestion.id },
                                )
                            },
                        )
                    }
                    if (organize.stale) {
                        FloeSectionRow(title = {
                            StatusLine(stringResource(R.string.settings_organize_stale))
                        })
                    }
                    organize.applyError?.let {
                        // Concise recovery copy; the typed code stays
                        // diagnostics-only.
                        FloeSectionRow(title = {
                            StatusLine(stringResource(R.string.settings_organize_apply_failed))
                        })
                    }
                    FloeActionRow(
                        label = stringResource(R.string.settings_organize_cancel),
                        enabled = !organize.applying,
                        onClick = { settings.cancelOrganize {} },
                    )
                    confirmSuggestion?.let { suggestionID ->
                        FloeConfirmDialog(
                            title = stringResource(R.string.settings_organize_apply),
                            message = stringResource(R.string.settings_organize_apply_message),
                            confirmLabel = stringResource(R.string.settings_organize_apply),
                            dismissLabel = stringResource(R.string.cancel),
                            onConfirm = {
                                confirmSuggestion = null
                                settings.applyOrganizeSuggestion(suggestionID) {}
                            },
                            onDismiss = { confirmSuggestion = null },
                        )
                    }
                }
            }
            SettingsStatus(state.memoryStatus, onRetry = { settings.refreshMemory() })
        }
        if (state.memoryAdd.open) {
            // The dialog generation owns its draft: a cancel/new dialog
            // re-keys it even if both state changes land in one frame.
            key(state.memoryAdd.generation) {
                AddMemoryDialog(
                    inFlight = state.memoryAdd.inFlight,
                    failureRes = when (state.memoryAdd.failure) {
                        is SettingsHostController.MemoryMutationOutcome.Unconfirmed ->
                            R.string.settings_memory_add_uncertain
                        is SettingsHostController.MemoryMutationOutcome.Refused ->
                            R.string.settings_memory_add_failed
                        else -> null
                    },
                    onAdd = { content -> settings.submitAddMemory(content, "user") },
                    onDismiss = { settings.dismissAddMemory() },
                )
            }
        }
        bulkIntent?.let { intent ->
            // The dialog renders the FROZEN intent only: background list
            // refreshes cannot change the count or the confirmed targets.
            FloeConfirmDialog(
                title = stringResource(R.string.settings_memory_bulk_delete_title),
                message = stringResource(
                    R.string.settings_memory_bulk_delete_message,
                    intent.entries.size,
                ),
                confirmLabel = stringResource(R.string.settings_delete),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = {
                    val frozen = intent
                    bulkIntent = null
                    // Confirm dispatches under the CURRENT interaction token;
                    // starting a new selection afterwards supersedes it.
                    val interaction = bulkInteraction
                        ?: newBulkInteraction()
                    settings.bulkDeleteMemory(frozen, interaction) { result ->
                        when (result) {
                            SettingsHostController.MemoryMutationOutcome.Applied -> {
                                selectionMode = false
                                selectedIDs = emptySet()
                                bulkRetryIntent = null
                                bulkFailure = null
                            }
                            is SettingsHostController.MemoryMutationOutcome.Refused -> {
                                // A typed refusal proves nothing landed. A
                                // stale digest needs a refresh before a new
                                // intent; other refusals may retry the SAME
                                // batch identity.
                                bulkFailure = BulkDeleteFailure.Refused(result.code)
                                bulkRetryIntent =
                                    if (result.code == "staleRevision") null else frozen
                            }
                            is SettingsHostController.MemoryMutationOutcome.Unconfirmed -> {
                                // Transport/ack truth is unknown: never claim
                                // "nothing was changed"; keep the exact batch
                                // identity for a same-write retry.
                                bulkFailure =
                                    BulkDeleteFailure.Unconfirmed(result.code)
                                bulkRetryIntent = frozen
                            }
                        }
                    }
                },
                onDismiss = { bulkIntent = null },
            )
        }
    }

    @Composable
    private fun AddMemoryDialog(
        inFlight: Boolean,
        failureRes: Int?,
        onAdd: (String) -> Unit,
        onDismiss: () -> Unit,
    ) {
        // The draft lives with THIS dialog generation: a typed failure keeps
        // the dialog (and its text) open; a cancel/new dialog resets it.
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
                failureRes?.let { message ->
                    Spacer(Modifier.height(8.dp))
                    StatusLine(stringResource(message))
                }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_save),
                        // One in-flight add at a time; a refusal/unconfirmed
                        // result keeps the draft for review or retry.
                        enabled = content.isNotBlank() && !inFlight,
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
        errorRes: Int?,
        onReload: (() -> Unit)?,
        onSave: (String, Boolean) -> Unit,
        onDelete: () -> Unit,
        onDismiss: () -> Unit,
    ) {
        // The snapshot is frozen for this editor's lifetime (the caller
        // re-keys the dialog per open generation); a background list
        // refresh can never rewrite this draft or its base digest.
        var content by remember(entry.id, entry.revision) {
            mutableStateOf(entry.content)
        }
        var pinned by remember(entry.id, entry.revision) {
            mutableStateOf(entry.isPinned)
        }
        var confirmDelete by remember { mutableStateOf(false) }
        if (confirmDelete) {
            FloeConfirmDialog(
                title = stringResource(R.string.settings_memory_delete),
                message = stringResource(R.string.settings_memory_delete_message),
                confirmLabel = stringResource(R.string.settings_delete),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = {
                    // Close the confirmation first so a typed delete failure
                    // is visible on the editor instead of behind this alert.
                    confirmDelete = false
                    onDelete()
                },
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
                errorRes?.let { message ->
                    Spacer(Modifier.height(8.dp))
                    StatusLine(stringResource(message))
                }
                onReload?.let { reload ->
                    // This composable is inside a Dialog, not a SectionScope,
                    // so use a capsule action rather than FloeActionRow.
                    Row(Modifier.padding(top = 4.dp)) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.settings_memory_reload),
                            onClick = reload,
                        )
                    }
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
        val loading = surface.contentLoading || state.personalizationStatus.loading
        // A draft owns its text AND the active-slot token it was written on.
        // It is never re-keyed by a background content change: only an
        // explicit kind switch or a clean (not dirty) base change adopts.
        var draftKind by remember { mutableStateOf(surface.kind) }
        var draft by remember { mutableStateOf(surface.content) }
        var baseContent by remember { mutableStateOf(surface.content) }
        var baseRevisionToken by remember { mutableStateOf(surface.revisionToken) }
        var draftDirty by remember { mutableStateOf(false) }
        var baseMoved by remember { mutableStateOf(false) }
        var saving by remember { mutableStateOf(false) }
        // The save terminal is UI-owned by the submission that dispatched
        // it: a late result for an older kind/view may clear only its own
        // flag, never the newer view's saving state or dirty draft.
        var savingGeneration by remember { mutableStateOf(0L) }
        var confirmRollback by remember { mutableStateOf<Int?>(null) }
        LaunchedEffect(
            surface.kind,
            surface.content,
            surface.revisionToken,
            surface.contentLoading,
        ) {
            if (draftKind != surface.kind) {
                // Explicit kind switch: the old kind's draft/token must
                // never be saved into the new document. The old save keeps
                // running service-side; its UI terminal is superseded here.
                savingGeneration += 1
                saving = false
                draftKind = surface.kind
                draft = surface.content
                baseContent = surface.content
                baseRevisionToken = surface.revisionToken
                draftDirty = false
                baseMoved = false
            } else if (!surface.contentLoading &&
                (surface.content != baseContent ||
                    surface.revisionToken != baseRevisionToken)
            ) {
                if (draftDirty) {
                    // Refresh/active-handle read landed under an unsaved
                    // draft: keep the user's text and its ORIGINAL base
                    // token. The new content is not adopted and the CAS is
                    // never silently upgraded.
                    baseMoved = true
                } else {
                    draft = surface.content
                    baseContent = surface.content
                    baseRevisionToken = surface.revisionToken
                    baseMoved = false
                }
            }
        }
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
                if (surface.contentLoading) {
                    Row(
                        Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeActivityIndicator()
                        Spacer(Modifier.height(0.dp))
                        StatusLine(
                            stringResource(R.string.settings_personalization_content_loading))
                    }
                }
                if (surface.contentLoadFailed) {
                    FloeSectionRow(title = {
                        StatusLine(
                            stringResource(R.string.settings_personalization_content_failed))
                    })
                    FloeActionRow(
                        label = stringResource(R.string.settings_retry),
                        onClick = { settings.refreshPersonalization(surface.kind) },
                    )
                }
                androidx.compose.foundation.layout.Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    FloePlainFormField(
                        label = stringResource(R.string.settings_personalization_placeholder),
                        value = draft,
                        onValueChange = {
                            draft = it
                            draftDirty = true
                        },
                        // Editing stays closed until the COMPLETE active
                        // document is owned: an unfinished chunk read must
                        // never accept text and then replace it.
                        enabled = !loading && !surface.contentLoadFailed && !saving &&
                            draftKind == surface.kind,
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
                        enabled = !loading && !surface.contentLoadFailed && !saving &&
                            draftKind == surface.kind &&
                            baseRevisionToken.isNotBlank(),
                        onClick = {
                            val text = draft
                            val request = savingGeneration + 1
                            savingGeneration = request
                            saving = true
                            settings.savePersonalization(
                                draftKind,
                                text,
                                baseRevisionToken,
                            ) { error ->
                                // Only the submission that still owns this
                                // view may publish its terminal; a late
                                // result must not clear a newer save.
                                if (savingGeneration == request) {
                                    saving = false
                                    if (error == null && draft == text) {
                                        draftDirty = false
                                    }
                                }
                            }
                        },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.settings_personalization_generate),
                        onClick = { settings.generatePersonalization(surface.kind) {} },
                        enabled = !surface.generating,
                    )
                    if (surface.generating) {
                        // Real cancel: only enabled once the operation was
                        // ACCEPTED and its receipt captured — before that
                        // there is nothing to cancel.
                        FloeCapsuleAction(
                            label = stringResource(
                                R.string.settings_personalization_cancel_generate),
                            enabled = surface.generateReceipt != null,
                            onClick = { settings.cancelPersonalizationGenerate {} },
                        )
                    }
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
                val baseConflict = baseMoved || surface.saveError == "staleRevision"
                if (baseConflict) {
                    // The active slot moved while this draft was unsaved.
                    // Keep the user's text and the OLD token (the writer
                    // will refuse rather than overwrite); reload is an
                    // explicit discard of this draft.
                    FloeSectionRow(title = {
                        StatusLine(
                            stringResource(R.string.settings_personalization_stale))
                    })
                    FloeActionRow(
                        label = stringResource(R.string.settings_personalization_reload),
                        onClick = {
                            draft = surface.content
                            baseContent = surface.content
                            baseRevisionToken = surface.revisionToken
                            draftDirty = false
                            baseMoved = false
                            settings.refreshPersonalization(surface.kind)
                        },
                    )
                } else {
                    surface.saveError?.let {
                        // The typed code stays in diagnostics; the draft
                        // remains in the field so the user can retry.
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(R.string.settings_personalization_save_failed))
                        })
                    }
                }
                surface.generateError?.let { error ->
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_action_failed, error))
                    })
                }
                // Explicit terminal outcome: the generated text may have been
                // stored as a DRAFT because the active version/source moved.
                val generateOutcome = when (surface.lastGenerateOutcome) {
                    "active" -> R.string.settings_personalization_generate_active
                    "storedAsDraft" -> when (surface.lastGenerateDraftReason) {
                        "sourceChanged" ->
                            R.string.settings_personalization_generate_draft_source
                        "both" -> R.string.settings_personalization_generate_draft_both
                        else ->
                            R.string.settings_personalization_generate_draft_active
                    }
                    else -> null
                }
                generateOutcome?.let { message ->
                    FloeSectionRow(title = { StatusLine(stringResource(message)) })
                }
            }
            FloeSettingsSectionCard(
                title = stringResource(R.string.settings_personalization_history),
            ) {
                if (surface.revisions.isEmpty() && !surface.revisionsLoadingMore) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_personalization_revision_empty))
                    })
                }
                if (surface.revisionReadInFlight && surface.openRevision == null) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(
                            R.string.settings_personalization_revision_loading))
                    })
                }
                surface.revisions.forEach { meta ->
                    FloeSectionRow(
                        title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    FloeText(
                                        stringResource(
                                            R.string.settings_personalization_revision,
                                            meta.revision,
                                        ),
                                        style = Floe.typography.body,
                                        color = Floe.colors.label,
                                    )
                                    if (meta.isActive) {
                                        Spacer(Modifier.height(0.dp))
                                        FloeText(
                                            " · " + stringResource(
                                                R.string.settings_personalization_revision_active),
                                            style = Floe.typography.metadata,
                                            color = Floe.colors.accent,
                                        )
                                    }
                                }
                                FloeText(
                                    "${meta.source} · ${meta.createdAt}",
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                    maxLines = 1,
                                )
                            }
                        },
                        trailing = {
                            FloeCapsuleAction(
                                label = stringResource(
                                    R.string.settings_personalization_revision_view),
                                enabled = !surface.revisionReadInFlight &&
                                    !surface.rollingBack,
                                onClick = {
                                    settings.readPersonalizationRevision(
                                        surface.kind, meta.revision)
                                },
                            )
                            if (!meta.isActive) {
                                FloeCapsuleAction(
                                    label = stringResource(
                                        R.string.settings_personalization_revision_restore),
                                    enabled = !surface.revisionReadInFlight &&
                                        !surface.rollingBack,
                                    onClick = { confirmRollback = meta.revision },
                                )
                            }
                        },
                    )
                }
                surface.revisionsNextCursor?.let {
                    FloeActionRow(
                        label = stringResource(R.string.settings_personalization_load_more),
                        enabled = !surface.revisionsLoadingMore,
                        onClick = { settings.loadMoreRevisions(surface.kind) },
                    )
                }
                surface.rollbackError?.let {
                    // Concise recovery copy; the typed code stays
                    // diagnostics-only.
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_personalization_rollback_failed))
                    })
                }
            }
            SettingsStatus(state.personalizationStatus, onRetry = { settings.refreshPersonalization() })
        }
        // One open revision read: a sheet fenced by the controller epoch
        // (opening another revision/kind replaces it).
        surface.openRevision?.let { revision ->
            val configuration = androidx.compose.ui.platform.LocalConfiguration.current
            val wide = configuration.screenWidthDp >= 700
            FloePageSheet(
                visible = true,
                onDismiss = { settings.closePersonalizationRevision() },
                widthFraction = if (wide) 0.72f else 1f,
                heightFraction = if (wide) 0.8f else 0.9f,
                placement = if (wide) {
                    FloeSheetPlacement.CENTER
                } else {
                    FloeSheetPlacement.BOTTOM
                },
                topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset,
            ) {
                Column(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = 20.dp, vertical = 12.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            stringResource(
                                R.string.settings_personalization_revision,
                                revision.revision,
                            ),
                            style = Floe.typography.title,
                            color = Floe.colors.label,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                        FloeCapsuleAction(
                            label = stringResource(
                                R.string.settings_personalization_revision_close),
                            onClick = { settings.closePersonalizationRevision() },
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .verticalScroll(rememberScrollState()),
                    ) {
                        FloeText(
                            revision.content,
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                        )
                    }
                }
            }
        }
        surface.revisionReadError?.let {
            // Concise recovery copy — the exact typed code stays in
            // diagnostics and is never rendered as a user label.
            FloeInfoDialog(
                title = stringResource(R.string.settings_action_failed_title),
                message = stringResource(R.string.settings_personalization_revision_failed),
                confirmLabel = stringResource(R.string.settings_personalization_revision_close),
                onDismiss = { settings.closePersonalizationRevision() },
            )
        }
        confirmRollback?.let { target ->
            FloeConfirmDialog(
                title = stringResource(R.string.settings_personalization_revision_restore),
                message = stringResource(
                    R.string.settings_personalization_revision_restore_message,
                    target,
                ),
                confirmLabel = stringResource(R.string.settings_personalization_revision_restore),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = {
                    confirmRollback = null
                    settings.rollbackPersonalization(surface.kind, target) {}
                },
                onDismiss = { confirmRollback = null },
            )
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
            FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_dimension)) {
                FloeSectionRow(title = {
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                        FloeSegmented(
                            options = listOf(
                                stringResource(R.string.settings_usage_dimension_total),
                                stringResource(R.string.settings_usage_dimension_conversation),
                                stringResource(R.string.settings_usage_dimension_model),
                                stringResource(R.string.settings_usage_dimension_provider),
                            ),
                            selectedIndex = when (usage.dimension) {
                                "conversation" -> 1
                                "model" -> 2
                                "provider" -> 3
                                else -> 0
                            },
                            onSelect = { index ->
                                settings.refreshUsage(
                                    when (index) {
                                        1 -> "conversation"
                                        2 -> "model"
                                        3 -> "provider"
                                        else -> "total"
                                    },
                                )
                            },
                        )
                    }
                })
            }
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
                        stringResource(R.string.settings_usage_total),
                        totals.totalTokens.toString(),
                    )
                    FloeValueRow(
                        stringResource(R.string.settings_usage_runs),
                        totals.runs.toString(),
                    )
                    // Nullable metrics are shown ONLY when the store really
                    // reported them: null is "not reported", never zero.
                    totals.cacheReadTokens?.let {
                        FloeValueRow(stringResource(R.string.settings_usage_cache_read), it.toString())
                    }
                    totals.cacheWriteTokens?.let {
                        FloeValueRow(stringResource(R.string.settings_usage_cache_write), it.toString())
                    }
                    totals.reasoningTokens?.let {
                        FloeValueRow(stringResource(R.string.settings_usage_reasoning), it.toString())
                    }
                    totals.averageTokensPerSecond?.let {
                        FloeValueRow(
                            stringResource(R.string.settings_usage_avg_tps),
                            decimal(it),
                        )
                    }
                    totals.averageTimeToFirstTokenMs?.let {
                        FloeValueRow(
                            stringResource(R.string.settings_usage_avg_ttft),
                            decimal(it),
                        )
                    }
                    totals.averageDurationMs?.let {
                        FloeValueRow(
                            stringResource(R.string.settings_usage_avg_duration),
                            decimal(it),
                        )
                    }
                }
            }
            if (usage.byDay.isNotEmpty()) {
                FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_by_day)) {
                    usage.byDay.forEach { day ->
                        FloeValueRow(day.date, "${day.inputTokens} / ${day.outputTokens}")
                    }
                }
            }
            if (usage.rows.isNotEmpty() || usage.nextCursor != null) {
                FloeSettingsSectionCard(title = stringResource(R.string.settings_usage_breakdown)) {
                    usage.rows.forEach { row ->
                        FloeValueRow(row.label, "${row.inputTokens} / ${row.outputTokens}")
                    }
                    if (usage.nextCursor != null) {
                        FloeActionRow(
                            label = stringResource(R.string.settings_usage_load_more),
                            enabled = !usage.loadingMore,
                            onClick = { settings.loadMoreUsage() },
                        )
                    }
                }
            }
            SettingsStatus(state.usageStatus, onRetry = { settings.refreshUsage() })
        }
    }

    /** One concise decimal for reported averages (never an invented zero). */
    private fun decimal(value: Double): String =
        java.lang.String.format(java.util.Locale.US, "%.1f", value)

    // ---------------------------------------------------------------- privacy

    @Composable
    fun PrivacyPage(settings: SettingsHostController) {
        val state by settings.state.collectAsState()
        val privacy = state.privacy
        val summary = privacy.summary
        val clearStatus = state.privacyClear
        // The immutable preview captured at the FIRST tap. Recomposition,
        // refreshes and Root changes never rewrite it; a stale preview is
        // refused by the controller at confirm time with a typed code.
        var confirmPreview by remember {
            mutableStateOf<SettingsHostController.PrivacyClearPreview?>(null)
        }
        val busy = clearStatus?.inFlight == true
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
                    FloeValueRow(
                        stringResource(R.string.settings_privacy_active_grants),
                        summary.inMemoryGrantCount.toString(),
                    )
                    val remaining = summary.remaining
                    if (remaining != null) {
                        FloeValueRow(
                            stringResource(R.string.settings_privacy_remaining),
                            remaining.conversationCount.toString(),
                        )
                    } else if (summary.remainingFailure != null) {
                        // remaining == null ONLY with a typed remainingFailure
                        // from an ACTUAL history-clear report (partial).
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(
                                    R.string.settings_privacy_recount_unavailable,
                                    summary.remainingFailure,
                                ),
                            )
                        })
                    }
                    // No report has settled yet: nothing to show — never a
                    // fabricated "recount unavailable".
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
                    val modelRemaining = summary.modelRemaining
                    if (modelRemaining != null) {
                        FloeValueRow(
                            stringResource(R.string.settings_privacy_remaining),
                            modelRemaining.providerCount.toString(),
                        )
                    } else if (summary.modelRemainingFailure != null) {
                        FloeSectionRow(title = {
                            StatusLine(
                                stringResource(
                                    R.string.settings_privacy_recount_unavailable,
                                    summary.modelRemainingFailure,
                                ),
                            )
                        })
                    }
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
                    enabled = !busy,
                    onClick = {
                        // First tap freezes the immutable preview for THIS
                        // tap on the CURRENT root/projection only.
                        confirmPreview = settings.createPrivacyClearPreview(
                            SettingsHostController.PrivacyClearAction.HISTORY)
                    },
                )
                FloeActionRow(
                    label = stringResource(R.string.settings_privacy_clear_model_config),
                    enabled = !busy,
                    onClick = {
                        confirmPreview = settings.createPrivacyClearPreview(
                            SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION)
                    },
                )
                if (busy) {
                    FloeSectionRow(title = {
                        StatusLine(stringResource(R.string.settings_privacy_clearing))
                    })
                }
                clearStatus?.error?.let { code ->
                    FloeSectionRow(title = {
                        StatusLine(
                            when (code) {
                                "inFlight" ->
                                    stringResource(R.string.settings_privacy_clear_busy)
                                "previewStale", "previewUnavailable", "rootChanged" ->
                                    stringResource(R.string.settings_privacy_preview_changed)
                                "reportUnavailable" ->
                                    stringResource(R.string.settings_privacy_report_unavailable)
                                "confirmationUnavailable", "rootUnavailable", "unavailable" ->
                                    stringResource(R.string.settings_privacy_confirm_unavailable)
                                else ->
                                    stringResource(R.string.settings_privacy_clear_failed, code)
                            },
                        )
                    })
                }
            }
            SettingsStatus(state.privacyStatus, onRetry = { settings.refreshPrivacySummary() })
        }
        confirmPreview?.let { preview ->
            FloeConfirmDialog(
                title = stringResource(
                    if (preview.action == SettingsHostController.PrivacyClearAction.HISTORY) {
                        R.string.settings_privacy_clear_history
                    } else {
                        R.string.settings_privacy_clear_model_config
                    },
                ),
                message = stringResource(R.string.settings_privacy_clear_message),
                confirmLabel = stringResource(R.string.settings_delete),
                dismissLabel = stringResource(R.string.cancel),
                onConfirm = {
                    val current = confirmPreview
                    confirmPreview = null
                    if (current != null) {
                        // Failures surface through the owned privacyClear
                        // status below; the typed outcome also reaches the
                        // caller for tests and diagnostics.
                        when (current.action) {
                            SettingsHostController.PrivacyClearAction.HISTORY ->
                                settings.clearPrivacyHistory(current) {}
                            SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION ->
                                settings.clearPrivacyModelConfiguration(current) {}
                        }
                    }
                },
                onDismiss = { confirmPreview = null },
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
