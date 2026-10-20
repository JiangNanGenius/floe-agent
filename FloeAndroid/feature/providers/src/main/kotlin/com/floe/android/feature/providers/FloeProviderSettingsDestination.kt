// SPDX-License-Identifier: MPL-2.0
//
// Root presentation destination for the provider/model flow. The host embeds
// this inside the existing settings detail section (the app does not depend on
// this module yet; the binder stage wires it), supplies an immutable
// [ProviderDestinationState] and owns a caller-retained [ProviderFlowHolder]
// across configuration changes.
//
// Layout contract (measured from the current iPad captures):
//  - provider editor: a large rounded grouped sheet ≈82% of the usable window,
//    centered, with the retained settings context visible (dimmed) behind;
//  - nested model manager: a narrower pane ≈51% of the window (≈63% of the
//    editor width), same centered rounded treatment;
//  - model editor: a smaller nested form surface;
//  - supplier chooser / purpose chooser: anchored popover-style cards (wide)
//    with the measured source sizes and full-width sheets on compact, always
//    clamped to the real window and consumed IME space;
//  - protocol: a compact right-aligned floating menu over the row (not an
//    inline form or a supplier-card-sized popover).
// Fractions, not hard-coded pixels: insets, density and font scale govern the
// actual size. The wide threshold reuses the shell's 600dp persistent-column
// boundary from the frozen foundation contract.

package com.floe.android.feature.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePopoverCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsHostGeometry
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

/** Measured wide-window fractions from the current iPad reference. */
internal object ProviderSheetMetrics {
    const val EDITOR_WIDTH_FRACTION = 0.82f
    const val EDITOR_HEIGHT_FRACTION = 0.90f
    const val MODEL_MANAGER_WIDTH_FRACTION = 0.51f
    /** ≈63% of the editor width as measured; kept as its own viewport ratio. */
    const val MODEL_MANAGER_HEIGHT_FRACTION = 0.85f
    const val MODEL_EDITOR_WIDTH_FRACTION = 0.46f
    const val MODEL_EDITOR_HEIGHT_FRACTION = 0.66f
    /** Supplier popover source sizing (min420/ideal520 wide,
     * min540/ideal680 high) — clamped to the actual window in the caller. */
    const val SUPPLIER_POPOVER_MIN_WIDTH_DP = 420
    const val SUPPLIER_POPOVER_WIDTH_DP = 520
    const val SUPPLIER_POPOVER_MIN_HEIGHT_DP = 540
    const val SUPPLIER_POPOVER_HEIGHT_DP = 680
}

@Composable
fun FloeProviderSettingsDestination(
    state: ProviderDestinationState,
    holder: ProviderFlowHolder,
    modifier: Modifier = Modifier,
    /**
     * Measured Settings host snapshot, supplied by the actual SettingsSheet
     * content slot. Null is the standalone component fixture: the list keeps
     * its measured + trigger fallback and this destination chooses wide or
     * compact from the live window. Production full-host binding must pass
     * the geometry (and the provider list merges its own + trigger bounds).
     */
    hostGeometry: FloeSettingsHostGeometry? = null,
) {
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    // Actual container width, not Configuration.screenWidthDp: this is also
    // the size the anchored popover clamps to. A not-yet-published size (0)
    // takes the compact path until the observable container size arrives.
    val windowWidthDp = with(density) { windowInfo.containerSize.width.toDp() }
    val wide = hostGeometry?.wideLayout ?: (windowWidthDp >= FloeLayout.PersistentTwoColumnMinWidth)
    val panes = holder.navigation.snapshot()
    val editorEntry = panes.lastOrNull { it.pane == ProviderPane.EDITOR }
    val editorSlot = editorEntry?.let { holder.drafts.slot(it.key) }
    val editorIdentity = editorSlot?.identity

    // A pending multi-role prompt becomes its own innermost pane, exactly once.
    LaunchedEffect(state.editor?.identity, state.editor?.pendingOfferPrompt) {
        val projected = state.editor
        if (projected != null && editorIdentity != null && projected.identity.isCurrentFor(editorIdentity)) {
            holder.syncOfferPromptPane(editorIdentity, projected.pendingOfferPrompt != null)
        }
    }

    // Host-published discovery results merge into the staging list (idempotent
    // by wire id, so recomposition cannot duplicate rows). The host remains
    // the source of the discovered set; the draft only stages selection.
    LaunchedEffect(state.editor?.identity, state.editor?.hostCandidateModels) {
        val projected = state.editor ?: return@LaunchedEffect
        if (editorIdentity != null &&
            projected.identity.isCurrentFor(editorIdentity) &&
            projected.hostCandidateModels.isNotEmpty()
        ) {
            holder.mergeHostCandidateModels(editorIdentity, projected.hostCandidateModels)
        }
    }

    fun back(): Boolean {
        val top = holder.navigation.top
        if (top.pane == ProviderPane.LIST) return false
        when (top.pane) {
            ProviderPane.ROLE_CHOOSER -> holder.cancelRoleChooser()
            ProviderPane.EDITOR -> holder.drafts.slot(top.key)?.let { holder.cancelEditor(it.identity) }
            ProviderPane.SUPPLIER_CHOOSER -> holder.drafts.slot(top.key)?.let {
                holder.cancelSupplierChooser(it.identity)
            }
            ProviderPane.MODEL_MANAGER -> holder.drafts.slot(top.key)?.let {
                holder.closeModelManager(it.identity)
            }
            ProviderPane.MODEL_EDITOR -> holder.closeModelEditor()
            ProviderPane.OFFER_PROMPT -> holder.drafts.slot(top.key)?.let {
                holder.declineOfferPrompt(it.identity)
            }
            ProviderPane.LIST -> Unit
        }
        return true
    }

    BackHandler(enabled = holder.navigation.depth > 1) {
        back()
    }

    // Base: the provider list inside the settings detail. On wide windows the
    // list owns the anchored purpose menu because it owns the measured add
    // control; compact keeps the destination's bottom action sheet below.
    val roleChooserOpen = panes.any { it.pane == ProviderPane.ROLE_CHOOSER }
    ProviderListPage(
        state = state.list,
        onAdd = { holder.openRoleChooser() },
        onOpen = { role, providerId -> holder.openExisting(role, providerId) },
        onToggleEnabled = { providerId, enabled -> holder.setProviderEnabled(providerId, enabled) },
        onDeleteConfirmed = { providerId -> holder.deleteProvider(providerId) },
        modifier = modifier,
        anchoredRoleChooserVisible = wide && roleChooserOpen,
        onRoleChosen = { role -> holder.chooseRole(role) },
        onRoleChooserDismiss = { holder.cancelRoleChooser() },
        hostGeometry = hostGeometry,
    )

    panes.forEach { entry ->
        when (entry.pane) {
            ProviderPane.LIST -> Unit

            ProviderPane.ROLE_CHOOSER -> {
                // Wide: ProviderListPage renders the anchored menu over the
                // measured + button (rendering a second centred card here
                // would duplicate the chooser and lose the anchor). Compact:
                // the reference keeps the bottom action sheet.
                if (!wide) {
                    FloePageSheet(
                        visible = true,
                        onDismiss = { holder.cancelRoleChooser() },
                        widthFraction = 1f,
                        heightFraction = 0.52f,
                        placement = FloeSheetPlacement.BOTTOM,
                    ) {
                        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                            ProviderPurposeChooserContent(
                                onRoleChosen = { role -> holder.chooseRole(role) },
                            )
                        }
                    }
                }
            }

            ProviderPane.EDITOR -> {
                val slot = holder.drafts.slot(entry.key) ?: return@forEach
                val top = panes.lastOrNull()
                val supplierOpenHere = wide &&
                    top?.pane == ProviderPane.SUPPLIER_CHOOSER &&
                    top.key == slot.identity.editorId
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.cancelEditor(slot.identity) },
                    widthFraction = if (wide) ProviderSheetMetrics.EDITOR_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) ProviderSheetMetrics.EDITOR_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    ProviderEditorPage(
                        identity = slot.identity,
                        slot = slot,
                        editor = state.editor,
                        holder = holder,
                        onCancel = { holder.cancelEditor(slot.identity) },
                        onSave = {
                            val projected = state.editor
                                ?.takeIf { it.identity.isCurrentFor(slot.identity) }
                            holder.save(slot.identity, projected?.saveInFlight == true)
                        },
                        catalog = state.catalog,
                        supplierChooserOpen = supplierOpenHere,
                        onDismissSupplierChooser = {
                            holder.cancelSupplierChooser(slot.identity)
                        },
                    )
                }
            }

            ProviderPane.SUPPLIER_CHOOSER -> {
                val slot = holder.drafts.slot(entry.key) ?: return@forEach
                if (wide) {
                    // Wide presentation is the real anchored popover rendered
                    // inside ProviderEditorPage, measured against the supplier
                    // row. Rendering a second centered dialog here would both
                    // duplicate the chooser and lose the anchor.
                } else {
                    FloePageSheet(
                        visible = true,
                        onDismiss = { holder.cancelSupplierChooser(slot.identity) },
                        widthFraction = 1f,
                        heightFraction = 1f,
                        placement = FloeSheetPlacement.BOTTOM,
                    ) {
                        SupplierChooserContent(
                            identity = slot.identity,
                            slot = slot,
                            catalog = state.catalog,
                            holder = holder,
                            onCancel = { holder.cancelSupplierChooser(slot.identity) },
                        )
                    }
                }
            }

            ProviderPane.MODEL_MANAGER -> {
                val slot = holder.drafts.slot(entry.key) ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.closeModelManager(slot.identity) },
                    widthFraction = if (wide) ProviderSheetMetrics.MODEL_MANAGER_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) ProviderSheetMetrics.MODEL_MANAGER_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    ModelManagerContent(
                        identity = slot.identity,
                        slot = slot,
                        editor = state.editor,
                        holder = holder,
                        onDone = { holder.closeModelManager(slot.identity) },
                    )
                }
            }

            ProviderPane.MODEL_EDITOR -> {
                val slot = editorIdentity?.let { holder.drafts.slot(it.editorId) } ?: return@forEach
                FloePageSheet(
                    visible = true,
                    onDismiss = { holder.closeModelEditor() },
                    widthFraction = if (wide) ProviderSheetMetrics.MODEL_EDITOR_WIDTH_FRACTION else 1f,
                    heightFraction = if (wide) ProviderSheetMetrics.MODEL_EDITOR_HEIGHT_FRACTION else 1f,
                    placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
                ) {
                    ModelEditorContent(
                        identity = slot.identity,
                        holder = holder,
                        onCancel = { holder.closeModelEditor() },
                    )
                }
            }

            ProviderPane.OFFER_PROMPT -> {
                val identity = holder.drafts.slot(entry.key)?.identity ?: return@forEach
                val prompt = state.editor
                    ?.takeIf { it.identity.isCurrentFor(identity) }
                    ?.pendingOfferPrompt ?: return@forEach
                if (wide) {
                    FloePopoverCard(
                        visible = true,
                        onDismiss = { holder.declineOfferPrompt(identity) },
                        widthDp = 420.dp,
                        heightDp = 420.dp,
                    ) {
                        ServiceOfferPromptContent(
                            identity = identity,
                            prompt = prompt,
                            holder = holder,
                        )
                    }
                } else {
                    FloePageSheet(
                        visible = true,
                        onDismiss = { holder.declineOfferPrompt(identity) },
                        widthFraction = 1f,
                        heightFraction = 0.6f,
                        placement = FloeSheetPlacement.BOTTOM,
                    ) {
                        ServiceOfferPromptContent(
                            identity = identity,
                            prompt = prompt,
                            holder = holder,
                        )
                    }
                }
            }
        }
    }
}

/** One-time multi-role prompt (⇄ ServiceOfferPromptSheet). */
@Composable
private fun ServiceOfferPromptContent(
    identity: ProviderEditorIdentity,
    prompt: OfferPromptUi,
    holder: ProviderFlowHolder,
) {
    Column(Modifier.fillMaxWidth()) {
        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f, fill = false)
                .verticalScroll(rememberScrollState())
                .padding(vertical = 8.dp),
        ) {
            FloeText(
                stringResource(R.string.offers_prompt_title),
                style = Floe.typography.title,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            )
            Column(Modifier.padding(horizontal = 12.dp)) {
                FloeSettingsSectionCard(title = null) {
                    FloeSectionRow(
                        title = {
                            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                                IconGlyph(roleIcon(prompt.primaryRole), Floe.colors.secondaryLabel, 18.dp)
                                FloeText(
                                    stringResource(
                                        R.string.offers_prompt_current_role,
                                        rolePurposeTitle(prompt.primaryRole),
                                    ),
                                    style = Floe.typography.body,
                                    color = Floe.colors.secondaryLabel,
                                    modifier = Modifier.padding(start = 8.dp),
                                )
                            }
                        },
                    )
                }
                Spacer(Modifier.height(8.dp))
                FloeSettingsSectionCard(title = null) {
                    prompt.offers.forEach { offer ->
                        FloeSwitchRow(
                            title = rolePurposeTitle(offer.role),
                            checked = offer.role in holder.offerPromptSelection.value,
                            onCheckedChange = { holder.toggleOfferPromptRole(offer.role) },
                            caption = when {
                                offer.requiresDiscovery -> stringResource(R.string.offers_requires_discovery)
                                offer.modelCount > 0 -> stringResource(R.string.offers_model_count, offer.modelCount)
                                else -> null
                            },
                        )
                    }
                }
                ProviderSectionFooter(stringResource(R.string.offers_footer))
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCapsuleButton(
                label = stringResource(R.string.offers_prompt_not_now),
                onClick = { holder.declineOfferPrompt(identity) },
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleButton(
                label = stringResource(R.string.offers_prompt_configure),
                onClick = { holder.confirmOfferPrompt(identity) },
                modifier = Modifier.weight(1f),
                prominent = true,
            )
        }
    }
}
