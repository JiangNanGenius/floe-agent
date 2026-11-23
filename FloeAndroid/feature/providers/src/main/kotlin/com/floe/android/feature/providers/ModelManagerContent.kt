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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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

// Keep existing grouped cards while only composing rows near the viewport.
internal const val PROVIDER_MODEL_GROUP_SIZE = 8

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
    val discovery = projected?.discoveryState ?: ConnectionTestUi.Idle
    val discoveryTesting = discovery == ConnectionTestUi.Testing
    val busy = discoveryTesting || projected?.testState == ConnectionTestUi.Testing
    val networkAvailable = projected?.networkActionsAvailable == true
    val discoverySupported = projected?.discoverySupported == true
    val query = slot.modelSearchQuery.value
    val candidateGroups = remember(draft.models, query) {
        ProviderFormLogic.filterCandidateModels(draft.models, query).chunked(PROVIDER_MODEL_GROUP_SIZE)
    }
    val selectedIDs = remember(draft.models) {
        draft.models.filter { it.selectedForSave }.mapTo(HashSet()) { it.remoteModelID }
    }
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
            leadingEnabled = discoverySupported && networkAvailable && !busy && draft.baseUrl.isNotBlank(),
            onLeading = { holder.discoverModels(identity, busy) },
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
            ProviderDiscoveryFeedback(discovery, Modifier.padding(top = 4.dp))
            Spacer(Modifier.height(8.dp))
        }

        LazyColumn(
            Modifier.fillMaxWidth().weight(1f).testTag("provider.modelManagerForm"),
        ) {
            if (official.isNotEmpty()) item(key = "official") {
                Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                    FloeSettingsSectionCard(title = stringResource(R.string.manager_official_models)) {
                        official.forEach { media ->
                            val staged = media.remoteModelID in selectedIDs
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

            itemsIndexed(candidateGroups, key = { _, models -> "candidates-" + models.first().draftModelId }) { index, models ->
                Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                    FloeSettingsSectionCard(
                        title = if (index == 0) stringResource(R.string.manager_discovered) else null,
                    ) {
                        models.forEach { model ->
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

            item(key = "manual") {
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

            }
            item(key = "end") { Spacer(Modifier.height(16.dp)) }
        }
    }
}

@Composable
internal fun ProviderDiscoveryFeedback(state: ConnectionTestUi, modifier: Modifier = Modifier) {
    when (state) {
        is ConnectionTestUi.Failed -> FloeStatusLine(
            icon = FloeIcons.WarningTriangle,
            text = state.reason,
            color = Floe.colors.destructive,
            modifier = modifier,
        )
        is ConnectionTestUi.Succeeded -> FloeStatusLine(
            icon = FloeIcons.CheckCircle,
            text = when {
                state.discoveredModelCount == 0 -> stringResource(R.string.providers_discovery_empty)
                state.fromCatalog -> stringResource(R.string.providers_discovery_catalog, state.discoveredModelCount)
                else -> stringResource(R.string.providers_discovery_count, state.discoveredModelCount)
            },
            color = if (state.discoveredModelCount == 0) Floe.colors.secondaryLabel else Floe.colors.success,
            modifier = modifier,
        )
        ConnectionTestUi.Idle, ConnectionTestUi.Testing -> Unit
    }
}
