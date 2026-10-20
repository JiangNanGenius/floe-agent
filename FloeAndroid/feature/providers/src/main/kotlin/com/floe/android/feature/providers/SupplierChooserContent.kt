// SPDX-License-Identifier: MPL-2.0
//
// Unified supplier chooser (⇄ ProviderCatalogPicker): ONE searchable surface
// where the built-in presets and the verified official catalog live together,
// plus the explicit manual/custom preset. Search is a pure local computation
// over the immutable projection (typing never sends anything); selecting hands
// the choice back to the editor, which owns duplicate checks, custom-name
// preservation and pre-fill. The refresh action is an explicit network action
// and is shown only when the host reports it available.

package com.floe.android.feature.providers

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun SupplierChooserContent(
    identity: ProviderEditorIdentity,
    slot: ProviderDraftSlot,
    catalog: SupplierCatalogUiState,
    holder: ProviderFlowHolder,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var filter by remember(identity.editorId) { mutableStateOf(CatalogFilterUi.ALL) }
    val query = slot.supplierQuery.value
    val presets = ProviderFormLogic.matchingPresets(catalog.builtInPresets, query)
    val official = ProviderFormLogic.matchingOfficial(
        entries = catalog.officialProviders,
        query = query,
        filter = filter,
    )
    val selectedPresetId = slot.snapshot.value.supplier?.presetId
    val selectedFromCatalog = slot.snapshot.value.supplier?.catalogEntryId != null
    val filterDescription = stringResource(R.string.catalog_filter_cd)

    Column(modifier = modifier.fillMaxSize().testTag("provider.supplierChooser")) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleAction(
                label = stringResource(R.string.action_cancel),
                onClick = onCancel,
                tint = Floe.colors.label,
            )
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                FloeText(
                    stringResource(R.string.catalog_title),
                    style = Floe.typography.toolbarTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (catalog.refreshAvailable && catalog.networkActionsAvailable) {
                if (catalog.refreshInFlight) {
                    Row(
                        modifier = Modifier.heightIn(min = 48.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) { FloeActivityIndicator() }
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.Refresh,
                        contentDescription = stringResource(R.string.catalog_refresh),
                        onClick = { holder.refreshSupplierCatalog() },
                        visualSize = 38.dp,
                        iconSize = 18.dp,
                    )
                }
            }
        }

        Column(Modifier.padding(horizontal = 12.dp)) {
            FloeSearchField(
                value = query,
                onValueChange = { slot.supplierQuery.value = it },
                placeholder = stringResource(R.string.catalog_search_hint),
            )
            Spacer(Modifier.height(10.dp))
            Box(Modifier.semantics { contentDescription = filterDescription }) {
            FloeSegmented(
                options = listOf(
                    stringResource(R.string.catalog_filter_all),
                    stringResource(R.string.catalog_filter_configured),
                    stringResource(R.string.catalog_filter_available),
                    stringResource(R.string.catalog_filter_local),
                ),
                selectedIndex = filter.ordinal,
                onSelect = { index -> filter = CatalogFilterUi.entries[index] },
            )
            }
        }

        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(top = 8.dp),
        ) {
            if (presets.isNotEmpty()) {
                Column(Modifier.padding(horizontal = 12.dp)) {
                    FloeSettingsSectionCard(title = stringResource(R.string.catalog_builtin)) {
                        presets.forEach { preset ->
                            FloeSectionRow(
                                onClick = { holder.choosePreset(identity, preset) },
                                title = {
                                    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                                        FloeText(
                                            preset.displayName,
                                            style = Floe.typography.body,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        FloeText(
                                            "${ProviderFormLogic.protocolLabel(preset.defaultProtocol)} · ${preset.defaultEndpointHost ?: "—"}",
                                            style = Floe.typography.evidence,
                                            color = Floe.colors.secondaryLabel,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                },
                                trailing = {
                                    if (!selectedFromCatalog && selectedPresetId == preset.presetId) {
                                        com.floe.android.design.IconGlyph(
                                            FloeIcons.Checkmark,
                                            Floe.colors.accent,
                                            18.dp,
                                        )
                                    }
                                },
                            )
                        }
                    }
                }
            }

            if (official.isNotEmpty()) {
                Column(Modifier.padding(horizontal = 12.dp)) {
                    FloeSettingsSectionCard(title = stringResource(R.string.catalog_official)) {
                        official.forEach { entry ->
                            OfficialSupplierRow(
                                entry = entry,
                                selected = selectedFromCatalog && selectedPresetId == entry.catalogEntryId,
                                matchedAlias = matchedAlias(entry, query),
                                onClick = { holder.chooseCatalogEntry(identity, entry) },
                            )
                        }
                    }
                    if (catalog.footer != null) {
                        CatalogFooter(catalog.footer)
                    } else {
                        Spacer(Modifier.height(12.dp))
                    }
                }
            }

            if (presets.isEmpty() && official.isEmpty()) {
                Box(Modifier.fillMaxWidth().height(260.dp)) {
                    FloeUnavailableView(
                        icon = FloeIcons.Magnifier,
                        title = stringResource(R.string.catalog_empty_title),
                        description = stringResource(R.string.catalog_empty_hint),
                    )
                }
            } else if (official.isEmpty() && query.isNotBlank()) {
                FloeText(
                    stringResource(R.string.catalog_no_matching),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                )
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun SectionScope.OfficialSupplierRow(
    entry: OfficialSupplierUi,
    selected: Boolean,
    matchedAlias: String?,
    onClick: () -> Unit,
) {
    val unsupported = entry.availability == SupplierAvailabilityUi.UNSUPPORTED
    // Resolve localized role tokens outside the non-composable join lambda.
    val resources = LocalResources.current
    val servedTokens = entry.servedRoles.joinToString(", ") {
        resources.getString(roleTokenRes(it))
    }
    FloeSectionRow(
        onClick = onClick,
        enabled = !unsupported,
        title = {
            Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    FloeText(
                        entry.name,
                        style = Floe.typography.body,
                        color = if (unsupported) Floe.colors.secondaryLabel else Floe.colors.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (entry.isConfigured) {
                        FloeBadgePill(
                            stringResource(R.string.catalog_badge_configured),
                            FloeBadgeTone.ACCENT,
                        )
                    }
                    if (unsupported) {
                        FloeBadgePill(
                            stringResource(R.string.catalog_badge_unsupported),
                            FloeBadgeTone.SECONDARY,
                        )
                    }
                }
                if (matchedAlias != null) {
                    FloeText(
                        stringResource(R.string.catalog_alias, matchedAlias),
                        style = Floe.typography.metadata,
                        color = Floe.colors.accent,
                    )
                }
                FloeText(
                    "${ProviderFormLogic.protocolLabel(entry.defaultProtocol)} · ${entry.kindPresetName} · ${entry.endpointHost ?: "—"} · " +
                        stringResource(R.string.row_models_count, entry.modelCount),
                    style = Floe.typography.evidence,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (entry.servedRoles.isNotEmpty()) {
                    FloeText(
                        stringResource(R.string.catalog_also_serves, servedTokens),
                        style = Floe.typography.metadata,
                        color = Floe.colors.success,
                    )
                }
                if (unsupported && entry.unsupportedReason != null) {
                    FloeText(
                        entry.unsupportedReason,
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
            }
        },
        trailing = {
            if (selected) {
                com.floe.android.design.IconGlyph(FloeIcons.Checkmark, Floe.colors.accent, 18.dp)
            }
        },
    )
}

@Composable
private fun CatalogFooter(footer: CatalogFooterUi) {
    Column(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
        FloeText(
            stringResource(R.string.catalog_source_footer, footer.sourceProject, footer.offeredProviderCount),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeText(
            stringResource(R.string.catalog_provider_count, footer.documentCount),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (footer.shortDocumentSha256 != null) {
            FloeText(
                stringResource(R.string.catalog_document_hash, footer.shortDocumentSha256),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (footer.fetchedAtDisplay != null) {
            FloeText(
                stringResource(R.string.catalog_fetched_at, footer.fetchedAtDisplay),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

/** ⇄ matchingAlias: the alias that the current query matches, if the display
 * name itself is not the match (pure local search projection). */
private fun matchedAlias(entry: OfficialSupplierUi, query: String): String? {
    val needle = ProviderFormLogic.normalizeQuery(query)
    if (needle.isEmpty()) return null
    if (ProviderFormLogic.normalizeQuery(entry.name).contains(needle)) return null
    return entry.aliases.firstOrNull { ProviderFormLogic.normalizeQuery(it).contains(needle) }
}

private fun roleTokenRes(role: ProviderServiceRoleUi): Int = when (role) {
    ProviderServiceRoleUi.CONVERSATION -> R.string.role_token_text
    ProviderServiceRoleUi.IMAGE -> R.string.role_token_images
    ProviderServiceRoleUi.VIDEO -> R.string.role_token_video
}
