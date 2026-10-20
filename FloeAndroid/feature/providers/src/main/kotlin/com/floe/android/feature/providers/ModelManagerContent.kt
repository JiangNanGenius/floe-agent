// SPDX-License-Identifier: MPL-2.0
//
// Nested model manager (⇄ ModelPickerView): narrower pane above the editor
// with refresh (leading), title, Done (trailing), a persistent search field,
// official media presets, the staged/discovered candidate selection list and
// the manual wire-id entry whose Add row stays disabled until the trimmed id
// is non-empty. Discovery results and errors are host state; nothing here
// fabricates a discovered model.

package com.floe.android.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSelectionSlot
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText

@Composable
fun ModelManagerContent(
    identity: ProviderEditorIdentity,
    slot: ProviderDraftSlot,
    editor: ProviderEditorUiState?,
    holder: ProviderFlowHolder,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val projected = editor?.takeIf { it.identity.isCurrentFor(identity) }
    val draft = slot.snapshot.value
    val discoveryTesting = projected?.testState == ConnectionTestUi.Testing
    val networkAvailable = projected?.networkActionsAvailable == true
    val discoverySupported = projected?.discoverySupported == true
    val candidates = ProviderFormLogic.filterCandidateModels(draft.models, slot.modelSearchQuery.value)
    val official = projected?.officialMediaModels.orEmpty()
    val manualRemote = holder.manualModelRemote.value
    val manualValid = ProviderFormLogic.isManualModelAddValid(manualRemote)

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .testTag("provider.modelManager"),
    ) {
        ProviderInlinePaneToolbar(
            title = stringResource(R.string.providers_models_section),
            leadingDescription = stringResource(R.string.providers_refresh_models),
            leadingEnabled = discoverySupported && networkAvailable && !discoveryTesting,
            onLeading = { holder.discoverModels(identity, discoveryTesting) },
            leadingInFlight = discoveryTesting,
            trailingLabel = stringResource(R.string.action_done),
            onTrailing = onDone,
            showLeading = discoverySupported,
        )

        Column(Modifier.padding(horizontal = 12.dp)) {
            com.floe.android.design.FloeSearchField(
                value = slot.modelSearchQuery.value,
                onValueChange = { slot.modelSearchQuery.value = it },
                placeholder = stringResource(R.string.manager_search_models_cd),
            )
            Spacer(Modifier.height(8.dp))
        }

        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .testTag("provider.modelManagerForm")
                .verticalScroll(rememberScrollState()),
        ) {
        if (official.isNotEmpty()) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.manager_official_models)) {
                    official.forEach { media ->
                        val staged = draft.models.any {
                            it.remoteModelID == media.remoteModelID && it.selectedForSave
                        }
                        FloeSectionRow(
                            onClick = { holder.stageOfficialModel(identity, media) },
                            title = {
                                Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                                    FloeText(
                                        media.displayName,
                                        style = Floe.typography.body,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    FloeText(
                                        media.remoteModelID,
                                        style = Floe.typography.evidence,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            },
                            trailing = {
                                com.floe.android.design.IconGlyph(
                                    if (staged) FloeIcons.CheckCircle else FloeIcons.PlusCircle,
                                    if (staged) Floe.colors.accent else Floe.colors.secondaryLabel,
                                    20.dp,
                                )
                            },
                        )
                    }
                }
            }
        }

        if (candidates.isNotEmpty()) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.manager_discovered)) {
                    candidates.forEach { model ->
                        FloeSectionRow(
                            title = {
                                Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                                    FloeText(
                                        model.displayName,
                                        style = Floe.typography.body,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    FloeText(
                                        model.remoteModelID,
                                        style = Floe.typography.evidence,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            },
                            trailing = {
                                FloeSelectionSlot(
                                    checked = model.selectedForSave,
                                    onCheckedChange = {
                                        holder.setModelSelected(identity, model.draftModelId, it)
                                    },
                                    description = model.remoteModelID,
                                )
                            },
                        )
                    }
                }
            }
        }

        Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
            FloeSettingsSectionCard(title = stringResource(R.string.manager_manual_entry)) {
                FloeFormTextField(
                    label = stringResource(R.string.manager_model_id),
                    value = manualRemote,
                    onValueChange = { holder.manualModelRemote.value = it },
                    monospaced = true,
                )
                FloeFormTextField(
                    label = stringResource(R.string.manager_model_name),
                    value = holder.manualModelName.value,
                    onValueChange = { holder.manualModelName.value = it },
                )
                FloeActionRow(
                    label = stringResource(R.string.manager_add_model),
                    onClick = { holder.addManualModel(identity) },
                    enabled = manualValid,
                    testTag = "provider.addModelAction",
                )
            }
            ProviderSectionFooter(
                stringResource(
                    if (discoverySupported) {
                        R.string.providers_manual_entry_hint
                    } else {
                        R.string.providers_manual_fallback_hint
                    },
                )
            )
        }

        val failedTest = projected?.testState as? ConnectionTestUi.Failed
        if (failedTest != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeStatusLine(
                    icon = FloeIcons.WarningTriangle,
                    text = failedTest.reason,
                    color = Floe.colors.destructive,
                )
            }
        }
        Spacer(Modifier.height(16.dp))
        }
    }
}
