// SPDX-License-Identifier: MPL-2.0
//
// Per-model settings (⇄ ModelEditorView): identity (display name / wire id /
// enabled / hidden-from-picker / default), capability switches by service
// role, reasoning effort (conversation roles) and token limits with preset
// chips + exact numeric input. Save is gated by the same view-availability
// conditions as the iPad toolbar (non-blank name + wire id, valid limits);
// final validation stays with the host's Swift authority.
//
// The working copy lives in the session holder (RAM) so a config change does
// not lose edits; Cancel drops it, Save applies it to the provider draft.
// The DeepSeek-specific reasoning note from the iOS form is intentionally not
// hardcoded here: provider-family notes must come from host capability data,
// not from a wire-id substring check (contract: no hardcoded vendor alias as
// current-service truth).

package com.floe.android.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeFormChoiceField
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun ModelEditorContent(
    identity: ProviderEditorIdentity,
    holder: ProviderFlowHolder,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = holder.modelEditorWorkingCopy.value ?: return
    val row = model
    val role = identity.role
    val canSave = ProviderFormLogic.modelEditorCanSave(row, role)
    val reasoningExpanded = androidx.compose.runtime.remember(identity.editorId, row.draftModelId) {
        androidx.compose.runtime.mutableStateOf(false)
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .testTag("provider.modelEditor"),
    ) {
        ProviderInlineEditorToolbar(
            title = stringResource(R.string.model_editor_title),
            cancelLabel = stringResource(R.string.action_cancel),
            saveLabel = stringResource(R.string.action_save),
            saveEnabled = canSave,
            onCancel = onCancel,
            onSave = { holder.commitModelEditor(identity) },
        )

        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .testTag("provider.modelEditorForm")
                .verticalScroll(rememberScrollState()),
        ) {
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.model_section_identity)) {
                    FloeFormTextField(
                        label = stringResource(R.string.model_display_name),
                        value = row.displayName,
                        onValueChange = { value ->
                            holder.editModelWorkingCopy { it.copy(displayName = value) }
                        },
                    )
                    FloeFormTextField(
                        label = stringResource(R.string.model_remote_id),
                        value = row.remoteModelID,
                        onValueChange = { value ->
                            holder.editModelWorkingCopy { it.copy(remoteModelID = value) }
                        },
                        monospaced = true,
                    )
                    FloeSwitchRow(
                        title = stringResource(R.string.model_enabled_cd),
                        checked = row.enabled,
                        onCheckedChange = { value ->
                            holder.editModelWorkingCopy { it.copy(enabled = value) }
                        },
                    )
                    if (role == ProviderServiceRoleUi.CONVERSATION) {
                        FloeSwitchRow(
                            title = stringResource(
                                if (row.hiddenFromPrimaryPicker) {
                                    R.string.model_show_in_picker
                                } else {
                                    R.string.model_hide_from_picker
                                },
                            ),
                            checked = row.hiddenFromPrimaryPicker,
                            onCheckedChange = { value ->
                                holder.editModelWorkingCopy { it.copy(hiddenFromPrimaryPicker = value) }
                            },
                        )
                        val isDefault = holder.drafts.slot(identity.editorId)
                            ?.snapshot?.value?.defaultModelDraftId == row.draftModelId
                        if (isDefault) {
                            FloeSectionRow(
                                title = {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        com.floe.android.design.IconGlyph(
                                            FloeIcons.CheckCircle,
                                            Floe.colors.accent,
                                            18.dp,
                                        )
                                        FloeText(
                                            stringResource(R.string.model_default),
                                            style = Floe.typography.body,
                                            color = Floe.colors.accent,
                                        )
                                    }
                                },
                            )
                        } else {
                            FloeActionRow(
                                label = stringResource(R.string.model_set_default),
                                onClick = { holder.setDefaultModel(identity, row.draftModelId) },
                                enabled = row.selectedForSave,
                            )
                        }
                    }
                }
            }

            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.model_section_capabilities)) {
                    when (role) {
                        ProviderServiceRoleUi.CONVERSATION -> {
                            FloeSectionRow(
                                title = {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        com.floe.android.design.IconGlyph(
                                            FloeIcons.Bubble,
                                            Floe.colors.accent,
                                            18.dp,
                                        )
                                        FloeText(
                                            stringResource(R.string.model_capability_text),
                                            style = Floe.typography.body,
                                        )
                                    }
                                },
                            )
                            CapabilitySwitch(
                                label = stringResource(R.string.model_capability_vision),
                                checked = ModelCapabilityUi.VISION in row.capabilities,
                            ) { holder.toggleCapability(ModelCapabilityUi.VISION, it) }
                            CapabilitySwitch(
                                label = stringResource(R.string.model_capability_tools),
                                checked = ModelCapabilityUi.TOOLS in row.capabilities,
                            ) { holder.toggleCapability(ModelCapabilityUi.TOOLS, it) }
                        }
                        ProviderServiceRoleUi.IMAGE -> {
                            CapabilitySwitch(
                                label = stringResource(R.string.model_capability_image_generation),
                                checked = ModelCapabilityUi.IMAGE_GENERATION in row.capabilities,
                            ) { holder.toggleCapability(ModelCapabilityUi.IMAGE_GENERATION, it) }
                            CapabilitySwitch(
                                label = stringResource(R.string.model_capability_image_editing),
                                checked = ModelCapabilityUi.IMAGE_EDITING in row.capabilities,
                            ) { holder.toggleCapability(ModelCapabilityUi.IMAGE_EDITING, it) }
                        }
                        ProviderServiceRoleUi.VIDEO -> {
                            FloeSectionRow(
                                title = {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        com.floe.android.design.IconGlyph(
                                            FloeIcons.VideoPlus,
                                            Floe.colors.accent,
                                            18.dp,
                                        )
                                        FloeText(
                                            stringResource(R.string.purpose_video),
                                            style = Floe.typography.body,
                                        )
                                    }
                                },
                            )
                            CapabilitySwitch(
                                label = stringResource(R.string.model_capability_reference_images),
                                checked = ModelCapabilityUi.VISION in row.capabilities,
                            ) { holder.toggleCapability(ModelCapabilityUi.VISION, it) }
                        }
                    }
                }
            }

            if (role == ProviderServiceRoleUi.CONVERSATION) {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    FloeSettingsSectionCard(title = stringResource(R.string.model_section_reasoning)) {
                        FloeFormChoiceField(
                            label = stringResource(R.string.model_reasoning_effort),
                            options = ReasoningEffortUi.entries.map {
                                FloeChoiceOption(it.name, reasoningLabel(it))
                            },
                            selectedKey = row.reasoningEffort.name,
                            expanded = reasoningExpanded.value,
                            onExpandedChange = { reasoningExpanded.value = it },
                            onSelect = { key ->
                                ReasoningEffortUi.entries.firstOrNull { it.name == key }?.let { effort ->
                                    holder.editModelWorkingCopy { it.copy(reasoningEffort = effort) }
                                }
                            },
                            enabled = true,
                        )
                    }
                    ProviderSectionFooter(stringResource(R.string.model_reasoning_hint))
                }

                Column(Modifier.padding(horizontal = 16.dp)) {
                    FloeSettingsSectionCard(title = stringResource(R.string.model_section_limits)) {
                        TokenLimitRow(
                            title = stringResource(R.string.model_context_tokens),
                            value = row.contextTokens,
                            presets = listOf(32_768, 65_536, 131_072, 262_144, 1_048_576),
                            allowsEmpty = false,
                            onChange = { tokens ->
                                holder.editModelWorkingCopy { it.copy(contextTokens = tokens) }
                            },
                        )
                        TokenLimitRow(
                            title = stringResource(R.string.model_max_output_tokens),
                            value = row.maxOutputTokens,
                            presets = listOf(4_096, 8_192, 16_384, 32_768, 65_536),
                            allowsEmpty = true,
                            onChange = { tokens ->
                                holder.editModelWorkingCopy { it.copy(maxOutputTokens = tokens) }
                            },
                        )
                    }
                    ProviderSectionFooter(stringResource(R.string.model_limits_hint))
                }
            } else {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    FloeSettingsSectionCard(
                        title = stringResource(
                            if (role == ProviderServiceRoleUi.VIDEO) {
                                R.string.model_video_capabilities
                            } else {
                                R.string.model_image_capabilities
                            },
                        ),
                    ) {
                        if (row.mediaFacts.isEmpty()) {
                            FloeSectionRow(
                                title = {
                                    FloeText(
                                        stringResource(R.string.model_media_custom_note),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                },
                            )
                        } else {
                            row.mediaFacts.forEach { fact ->
                                FloeSectionRow(
                                    title = {
                                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                            FloeText(fact.label, style = Floe.typography.body)
                                            FloeText(
                                                fact.value,
                                                style = Floe.typography.metadata,
                                                color = Floe.colors.secondaryLabel,
                                                modifier = Modifier.widthIn(max = 220.dp),
                                            )
                                        }
                                    },
                                )
                            }
                        }
                    }
                    ProviderSectionFooter(stringResource(R.string.model_media_footer))
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

private fun ProviderFlowHolder.toggleCapability(capability: ModelCapabilityUi, enabled: Boolean) {
    editModelWorkingCopy { row ->
        row.copy(
            capabilities = if (enabled) row.capabilities + capability else row.capabilities - capability,
        )
    }
}

@Composable
private fun SectionScope.CapabilitySwitch(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    FloeSwitchRow(title = label, checked = checked, onCheckedChange = onCheckedChange)
}

@Composable
private fun SectionScope.TokenLimitRow(
    title: String,
    value: Int,
    presets: List<Int>,
    allowsEmpty: Boolean,
    onChange: (Int) -> Unit,
) {
    FloeSectionRow(
        title = {
            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(title, style = Floe.typography.body, modifier = Modifier.weight(1f))
                    FloeText(
                        text = if (value == 0 && allowsEmpty) {
                            stringResource(R.string.model_limit_not_set)
                        } else {
                            ProviderFormLogic.shortTokenLabel(value)
                        },
                        style = Floe.typography.evidence,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    presets.forEach { preset ->
                        TokenPresetChip(
                            label = ProviderFormLogic.shortTokenLabel(preset),
                            selected = preset == value,
                            onClick = { onChange(preset) },
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                FloePlainFormField(
                    label = title,
                    value = if (value == 0) "" else value.toString(),
                    onValueChange = { input -> onChange(ProviderFormLogic.parseTokenInput(input)) },
                    monospaced = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                if (allowsEmpty && value != 0) {
                    Box(
                        modifier = Modifier
                            .heightIn(min = 48.dp)
                            .clickable(role = Role.Button) { onChange(0) }
                            .semantics { contentDescription = title },
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        FloeText(
                            stringResource(R.string.model_limit_use_provider_default),
                            style = Floe.typography.metadata,
                            color = Floe.colors.accent,
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun TokenPresetChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier = Modifier
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 8.dp)
            .clip(shape)
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.groupedSurface)
            .border(0.5.dp, if (selected) Floe.colors.accent else Floe.colors.separator, shape)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = if (selected) Floe.colors.accent else Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun reasoningLabel(effort: ReasoningEffortUi): String = when (effort) {
    ReasoningEffortUi.AUTOMATIC -> stringResource(R.string.model_reasoning_automatic)
    ReasoningEffortUi.LOW -> stringResource(R.string.model_reasoning_low)
    ReasoningEffortUi.MEDIUM -> stringResource(R.string.model_reasoning_medium)
    ReasoningEffortUi.HIGH -> stringResource(R.string.model_reasoning_high)
    ReasoningEffortUi.MAXIMUM -> stringResource(R.string.model_reasoning_maximum)
}
