// SPDX-License-Identifier: MPL-2.0
//
// Provider add/edit form (⇄ ProviderEditorView.swift), section-for-section in
// the iPad order: purpose → enable/name/supplier → applicable service offers →
// protocol → endpoint/non-secret headers → credentials → compatibility →
// test connection → models → contextual errors. Cancel is leading and Save
// trailing in the sheet chrome, the large title sits below, and the form
// scrolls independently. The whole content consumes IME insets so Save and
// fields stay reachable at small widths.
//
// Every outcome is HOST state: connection test, discovery, save success,
// credential requirement and field issues come from the projection; the
// module never renders a synthetic success. The draft fields themselves are
// the retained RAM snapshot (non-secret) plus the slot's secure field.

package com.floe.android.feature.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionRow
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeAnchoredPopoverCard
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeFormChooserRow
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun ProviderEditorPage(
    identity: ProviderEditorIdentity,
    slot: ProviderDraftSlot,
    editor: ProviderEditorUiState?,
    holder: ProviderFlowHolder,
    onCancel: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
    catalog: SupplierCatalogUiState? = null,
    supplierChooserOpen: Boolean = false,
    onDismissSupplierChooser: () -> Unit = {},
) {
    val draft = slot.snapshot.value
    val projected = editor?.takeIf { it.identity.isCurrentFor(identity) }
    val inFlight = projected?.saveInFlight == true || slot.saveDispatched
    var protocolMenuOpen by remember(identity.editorId) { mutableStateOf(false) }
    // Real anchor geometry of the protocol row and the unified supplier field
    // inside this sheet's window. Both menus are children of this editor
    // composition so they point at their measured rows instead of the window
    // centre, and each clamps itself against the real window.
    var protocolAnchorBounds by remember(identity.editorId) { mutableStateOf<Rect?>(null) }
    var supplierAnchorBounds by remember(identity.editorId) { mutableStateOf<Rect?>(null) }
    val networkAvailable = projected?.networkActionsAvailable == true
    val networkUnavailableReason = projected?.networkActionsUnavailableReason
    val discoverySupported = projected?.discoverySupported == true
    val testState = projected?.testState ?: ConnectionTestUi.Idle
    val saveError = projected?.saveError
    val saveFailureSequence = projected?.saveFailureSequence ?: 0L
    val saveOutcome = projected?.saveOutcome
    val formMessage = projected?.formMessage
    val credentialRequirementMessage = projected?.credentialRequirementMessage
    val testing = testState == ConnectionTestUi.Testing
    val protocolOptions = (projected?.availableProtocols ?: listOf(draft.protocol)).map {
        ProviderProtocolOption(it.name, ProviderFormLogic.protocolLabel(it))
    }

    // Save-path failures open an immediate alert over the retained editor.
    // The tracker is keyed by the editor identity+epoch (a new editor starts
    // unacknowledged), and the projection is filtered by the same identity so
    // a late failure from a previous generation can never raise it.
    val saveFailureMessage = currentSaveFailureMessage(editor, identity)
    var saveAlert by remember(identity.editorId, identity.epoch) {
        mutableStateOf(ProviderSaveAlertUi())
    }
    LaunchedEffect(
        identity.editorId,
        identity.epoch,
        saveFailureMessage,
        saveFailureSequence,
        inFlight,
    ) {
        saveAlert = saveAlert.observe(
            failureMessage = saveFailureMessage,
            // The local dispatch latch is a real attempt boundary even when
            // the host projection does not expose saveInFlight. It releases
            // on the failure outcome, so the shown alert still corresponds to
            // the finished attempt.
            saveInFlight = inFlight,
            // A retry may fail synchronously inside the save dispatch, so the
            // begin/failure projection can coalesce into one frame with the
            // same text. The host's monotonic failure sequence still moves;
            // keying the effect on it guarantees the new attempt is observed
            // instead of being mistaken for the acknowledged old failure.
            failureSequence = saveFailureSequence,
        )
    }

    // Back closes only the innermost menu; the retained provider editor, its
    // draft and the holder session stay untouched. The popup consumes its own
    // back first, and this enabled handler is the same-window safeguard.
    BackHandler(enabled = protocolMenuOpen) {
        protocolMenuOpen = false
    }

    // Save is possible only with an authoritative host projection and the
    // shared-core save path actually available.
    val saveEnabled = projected != null && networkAvailable && !inFlight

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .testTag("provider.editorPage")
            .imePadding()
            .navigationBarsPadding(),
    ) {
        ProviderEditorToolbar(
            saveLabel = stringResource(R.string.action_save),
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = inFlight,
            saveEnabled = saveEnabled,
            onCancel = onCancel,
            onSave = onSave,
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .testTag("provider.editorForm")
                .verticalScroll(rememberScrollState()),
        ) {
            FloeText(
                text = stringResource(
                    if (projected?.isEditingExisting == true) R.string.editor_edit_title else R.string.editor_add_title,
                ),
                style = Floe.typography.navLargeTitle,
                color = Floe.colors.label,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 18.dp),
            )

            if (projected == null) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(R.string.editor_waiting_host),
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
                )
            } else if (!networkAvailable) {
                FloeStatusLine(
                    icon = FloeIcons.WarningTriangle,
                    text = networkUnavailableReason
                        ?: stringResource(R.string.network_actions_unavailable_cd),
                    color = Floe.colors.pending,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
                )
            }

            // 1. Service purpose (fixed for this editor, ⇄ initialRole).
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.purpose_section)) {
                    FloeSectionRow(
                        title = {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                com.floe.android.design.IconGlyph(roleIcon(draft.role), Floe.colors.accent, 20.dp)
                                FloeText(rolePurposeTitle(draft.role), style = Floe.typography.body)
                            }
                        },
                    )
                }
                if (draft.role == ProviderServiceRoleUi.VIDEO) {
                    ProviderSectionFooter(stringResource(R.string.purpose_video_note))
                }
            }

            // 2. Enable / name / supplier (one unified chooser).
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = null) {
                    FloeSwitchRow(
                        title = stringResource(R.string.providers_enabled),
                        checked = draft.enabled,
                        onCheckedChange = { holder.setEnabled(identity, it) },
                    )
                    FloeFormTextField(
                        label = stringResource(R.string.providers_display_name),
                        value = draft.displayName,
                        onValueChange = { holder.setDisplayName(identity, it) },
                        isError = projected.hasIssue(ProviderFieldUi.DISPLAY_NAME),
                    )
                    FloeFormChooserRow(
                        label = stringResource(R.string.providers_supplier_field),
                        valueSummary = draft.supplier?.displayName.orEmpty(),
                        onClick = {
                            holder.openSupplierChooser(identity)
                        },
                        modifier = Modifier
                            .onGloballyPositioned { coordinates ->
                                supplierAnchorBounds = coordinates.boundsInWindow()
                            }
                            .testTag("provider.supplierRow"),
                    )
                }
                projected.issueMessages(ProviderFieldUi.SUPPLIER).forEach { ProviderIssueLine(it) }
            }

            // 3. Applicable additional service offers (opt-in roles only).
            if (projected != null) {
                val visibleOffers = ProviderFormLogic.visibleOffers(
                    offers = projected.offers,
                    draftDecisions = draft.offerDecisions,
                    roleDiscoveryPending = { role ->
                        projected.offers.any {
                            it.role == role && it.discoveryState == ConnectionTestUi.Testing
                        }
                    },
                )
                if (visibleOffers.isNotEmpty()) {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        FloeSettingsSectionCard(title = stringResource(R.string.offers_section)) {
                            visibleOffers.forEach { offer ->
                                ProviderOfferRow(
                                    offer = offer,
                                    onEnabledChange = { holder.setOfferDecision(identity, offer.role, it) },
                                    onConfigureSeparately = { seed ->
                                        holder.openSeparateOffer(seed, offer.role)
                                    },
                                )
                            }
                        }
                        ProviderSectionFooter(stringResource(R.string.offers_footer))
                    }
                }
            }

            // 4. Protocol — the three real protocol types, locked only when
            // the selected supplier offers one. The picker opens the compact
            // right-aligned floating menu over the retained row; it never
            // expands inline and is not a supplier-card-sized popover.
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.providers_protocol)) {
                    ProviderProtocolMenuField(
                        label = stringResource(R.string.providers_protocol),
                        options = protocolOptions,
                        selectedKey = draft.protocol.name,
                        enabled = (projected?.availableProtocols?.size ?: 0) > 1,
                        onClick = { protocolMenuOpen = true },
                        onAnchorChanged = { protocolAnchorBounds = it },
                    )
                }
                projected.issueMessages(ProviderFieldUi.PROTOCOL).forEach { ProviderIssueLine(it) }
            }

            // 5. Endpoint + non-secret headers (+ plain-HTTP acknowledgement).
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.providers_endpoint)) {
                    FloeFormTextField(
                        label = stringResource(R.string.providers_base_url),
                        value = draft.baseUrl,
                        onValueChange = { holder.setBaseUrl(identity, it) },
                        monospaced = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        isError = projected.hasIssue(ProviderFieldUi.BASE_URL),
                    )
                    FloeFormTextField(
                        label = stringResource(R.string.providers_headers_placeholder),
                        value = draft.nonSecretHeaders,
                        onValueChange = { holder.setHeaders(identity, it) },
                        singleLine = false,
                        minLines = 2,
                        maxLines = 5,
                        monospaced = true,
                        isError = projected.hasIssue(ProviderFieldUi.HEADERS),
                    )
                    if (draft.supplier?.supportsPlainHttpChoice == true) {
                        FloeSwitchRow(
                            title = stringResource(R.string.providers_allow_plain_http),
                            checked = draft.allowsPlainHttp,
                            onCheckedChange = { holder.setAllowsPlainHttp(identity, it) },
                        )
                    }
                }
                ProviderSectionFooter(stringResource(R.string.providers_headers_hint))
                projected.issueMessages(ProviderFieldUi.BASE_URL).forEach { ProviderIssueLine(it) }
                projected.issueMessages(ProviderFieldUi.HEADERS).forEach { ProviderIssueLine(it) }
            }

            // 6. Credentials — secure input stays in RAM only.
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.providers_credentials)) {
                    FloeSecureFormField(
                        label = stringResource(R.string.providers_api_key),
                        value = slot.secureInput.value.orEmpty(),
                        onValueChange = { holder.setSecureInput(identity, it) },
                        revealed = slot.revealSecureInput.value,
                        onRevealedChange = { holder.toggleReveal(identity) },
                        revealOnLabel = stringResource(R.string.providers_show_api_key),
                        revealOffLabel = stringResource(R.string.providers_hide_api_key),
                        isError = projected.hasIssue(ProviderFieldUi.CREDENTIAL),
                    )
                    if (projected?.credentialState == ProviderCredentialStateUi.AWAITING_CONFIGURATION) {
                        ProviderHintRow(
                            icon = FloeIcons.Key,
                            text = stringResource(R.string.providers_waiting_key_hint),
                            color = Floe.colors.pending,
                        )
                    }
                    if (credentialRequirementMessage != null) {
                        ProviderHintRow(
                            icon = FloeIcons.WarningTriangle,
                            text = credentialRequirementMessage,
                            color = Floe.colors.pending,
                        )
                    }
                }
                ProviderSectionFooter(stringResource(R.string.providers_api_key_hint))
                projected.issueMessages(ProviderFieldUi.CREDENTIAL).forEach { ProviderIssueLine(it) }
            }

            // 7. Tool-name compatibility.
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = null) {
                    FloeSwitchRow(
                        title = stringResource(R.string.providers_tool_name_compatibility),
                        checked = draft.toolNameCompatibility,
                        onCheckedChange = { holder.setToolNameCompatibility(identity, it) },
                    )
                }
                ProviderSectionFooter(stringResource(R.string.providers_tool_name_compatibility_hint))
                projected.issueMessages(ProviderFieldUi.COMPATIBILITY).forEach { ProviderIssueLine(it) }
            }

            // 8. Test connection — explicit network action with honest state.
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = null) {
                    FloeActionRow(
                        label = stringResource(R.string.providers_test_connection),
                        onClick = { holder.testConnection(identity, testing) },
                        enabled = projected != null && networkAvailable && !testing,
                        trailing = {
                            when (testState) {
                                ConnectionTestUi.Idle -> Unit
                                ConnectionTestUi.Testing -> FloeActivityIndicator()
                                is ConnectionTestUi.Succeeded -> FloeStatusLine(
                                    icon = FloeIcons.CheckCircle,
                                    text = "${stringResource(R.string.providers_test_ok)} (${testState.discoveredModelCount})",
                                    color = Floe.colors.success,
                                )
                                is ConnectionTestUi.Failed -> FloeStatusLine(
                                    icon = FloeIcons.XOctagon,
                                    text = stringResource(R.string.providers_test_failed),
                                    color = Floe.colors.destructive,
                                )
                            }
                        },
                    )
                    if (testing) {
                        FloeActionRow(
                            label = stringResource(R.string.providers_cancel_test),
                            onClick = { holder.cancelConnectionTest(identity) },
                        )
                    }
                    (testState as? ConnectionTestUi.Failed)?.let { failed ->
                        ProviderHintRow(
                            icon = FloeIcons.WarningTriangle,
                            text = failed.reason,
                            color = Floe.colors.destructive,
                        )
                    }
                }
            }

            // 9. Models: selected rows + manage + explicit refresh.
            Column(Modifier.padding(horizontal = 16.dp)) {
                FloeSettingsSectionCard(title = stringResource(R.string.providers_models_section)) {
                    val selectedModels = draft.models.filter { it.selectedForSave }
                    if (selectedModels.isEmpty()) {
                        FloeSectionRow(
                            title = {
                                FloeText(
                                    stringResource(R.string.providers_no_models),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            },
                        )
                    } else {
                        selectedModels.forEach { model ->
                            ProviderModelRow(
                                model = model,
                                isDefault = draft.defaultModelDraftId == model.draftModelId,
                                onOpen = { holder.openModelEditor(identity, model.draftModelId) },
                                onEnabledChange = { holder.setModelEnabled(identity, model.draftModelId, it) },
                            )
                        }
                    }
                    FloeActionRow(
                        label = stringResource(R.string.providers_manage_models),
                        onClick = { holder.openModelManager(identity) },
                    )
                    if (discoverySupported) {
                        FloeActionRow(
                            label = stringResource(R.string.providers_refresh_models),
                            onClick = { holder.discoverModels(identity, testing) },
                            enabled = networkAvailable && !testing,
                            trailing = {
                                if (testing) {
                                    FloeActivityIndicator()
                                }
                            },
                        )
                    }
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
                projected.issueMessages(ProviderFieldUi.MODELS).forEach { ProviderIssueLine(it) }
            }

            // 10. Inline contextual errors (⇄ errorMessage section).
            if (formMessage != null) {
                Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    FloeText(
                        formMessage,
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    // Unified supplier chooser: a genuinely anchored popover over the retained
    // editor (source capture 04). It lives inside this dialog so the measured
    // supplier-row bounds and the popup share one window coordinate space;
    // the card clamps to that visible window and flips below only when the
    // upper side cannot hold a useful height. Compact windows use the
    // full-width sheet in the destination instead (same hierarchy).
    val anchor = supplierAnchorBounds
    if (supplierChooserOpen && catalog != null && anchor != null) {
        FloeAnchoredPopoverCard(
            visible = true,
            onDismiss = onDismissSupplierChooser,
            anchorBounds = anchor,
            modifier = Modifier.testTag("provider.supplierPopover"),
        ) {
            SupplierChooserContent(
                identity = identity,
                slot = slot,
                catalog = catalog,
                holder = holder,
                onCancel = onDismissSupplierChooser,
            )
        }
    }

    // Protocol picker: the compact right-aligned floating menu. The row is
    // measured in this dialog's window; the popup policy right-aligns to the
    // row's trailing edge and clamps to the real window. Selection and
    // dismissal are presentation-only and never close the provider editor or
    // mutate the draft except for an explicit choice.
    val protocolAnchor = protocolAnchorBounds
    if (protocolMenuOpen && protocolAnchor != null) {
        ProviderProtocolMenuPopup(
            anchorBounds = protocolAnchor,
            options = protocolOptions,
            selectedKey = draft.protocol.name,
            onSelect = { key ->
                protocolMenuOpen = false
                val protocol = WireProtocolUi.entries.firstOrNull { it.name == key }
                if (protocol != null) holder.setProtocol(identity, protocol)
            },
            onDismiss = { protocolMenuOpen = false },
        )
    }

    // Save-only failure alert (⇄ ProviderEditorView.swift:134-148). It sits
    // over the retained editor; dismissing it acknowledges the current
    // failure without closing the editor or discarding the draft.
    val alertMessage = saveAlert.message
    if (alertMessage != null) {
        FloeInfoDialog(
            title = stringResource(R.string.providers_save_failed_cd),
            message = alertMessage,
            confirmLabel = stringResource(R.string.providers_save_failed_ok),
            onDismiss = { saveAlert = saveAlert.acknowledge() },
        )
    }

    // A save that reaches a host-confirmed success closes this editor; a
    // failed or in-flight save never does (the projection stays open). A
    // failure (structured outcome or plain saveError) releases the duplicate
    // dispatch latch so the user can actually retry.
    LaunchedEffect(saveOutcome) {
        when (saveOutcome) {
            SaveOutcomeUi.Succeeded -> holder.finalizeSavedEditor(identity)
            is SaveOutcomeUi.Failed -> holder.noteSaveAttemptFinished(identity)
            null -> Unit
        }
    }
    LaunchedEffect(saveError, projected?.saveInFlight) {
        if (saveError != null && projected?.saveInFlight != true) {
            holder.noteSaveAttemptFinished(identity)
        }
    }
    // A same-frame retry failure can leave saveError/saveInFlight unchanged
    // from the previous attempt (the host cleared and republished the same
    // text before the next composition). The monotonic host failure sequence
    // is still a real outcome for the dispatched attempt, so release the
    // duplicate-save latch even when the other two keys did not move.
    LaunchedEffect(saveFailureSequence) {
        if (saveFailureSequence > 0L) {
            holder.noteSaveAttemptFinished(identity)
        }
    }
}

/**
 * Protocol chooser row. The row measures its own real bounds so the compact
 * floating menu can right-align to the actual row/value trailing edge. A
 * single available protocol keeps the row disabled, exactly like the native
 * `.disabled(availableProtocols.count == 1)`.
 */
@Composable
private fun SectionScope.ProviderProtocolMenuField(
    label: String,
    options: List<ProviderProtocolOption>,
    selectedKey: String,
    enabled: Boolean,
    onClick: () -> Unit,
    onAnchorChanged: (Rect) -> Unit,
) {
    val selectedLabel = options.firstOrNull { it.key == selectedKey }?.label.orEmpty()
    FloeFormChooserRow(
        label = label,
        valueSummary = selectedLabel,
        onClick = { if (enabled) onClick() },
        enabled = enabled,
        modifier = Modifier
            .onGloballyPositioned { coordinates ->
                onAnchorChanged(coordinates.boundsInWindow())
            }
            .testTag("provider.protocolField"),
    )
}

@Composable
private fun ProviderHintRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    color: androidx.compose.ui.graphics.Color,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        com.floe.android.design.IconGlyph(icon, color, 14.dp)
        FloeText(text, style = Floe.typography.metadata, color = color, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SectionScope.ProviderOfferRow(
    offer: ServiceOfferUi,
    onEnabledChange: (Boolean) -> Unit,
    onConfigureSeparately: (SeparateOfferSeedUi) -> Unit,
) {
    val roleTitle = rolePurposeTitle(offer.role)
    if (offer.isUsable && offer.connection == OfferConnectionUi.SHARED) {
        FloeSwitchRow(
            title = roleTitle,
            checked = offer.isEnabled,
            onCheckedChange = onEnabledChange,
            caption = when {
                offer.discoveryState == ConnectionTestUi.Testing -> null
                offer.modelCount > 0 -> stringResource(R.string.offers_model_count, offer.modelCount)
                offer.requiresDiscovery -> stringResource(R.string.offers_requires_discovery)
                else -> null
            },
        )
        if (offer.discoveryState == ConnectionTestUi.Testing) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.offers_requires_discovery),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        val discoveryError = offer.discoveryError
        if (discoveryError != null) {
            ProviderHintRow(FloeIcons.WarningTriangle, discoveryError, Floe.colors.destructive)
        }
    } else {
        FloeSectionRow(
            title = {
                Column {
                    FloeText(roleTitle, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
                    val reason = offer.reason
                    if (reason != null) {
                        FloeText(reason, style = Floe.typography.metadata, color = Floe.colors.pending)
                    }
                    val note = offer.note
                    if (note != null) {
                        FloeText(note, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                }
            },
        )
        if (offer.isUsable && offer.connection == OfferConnectionUi.DISTINCT && offer.canConfigureSeparately) {
            val seed = offer.separateOfferSeed
            FloeActionRow(
                label = stringResource(R.string.offers_configure_separately),
                onClick = { if (seed != null) onConfigureSeparately(seed) },
                enabled = seed != null,
            )
        }
    }
}

@Composable
private fun SectionScope.ProviderModelRow(
    model: ModelDraftRowUi,
    isDefault: Boolean,
    onOpen: () -> Unit,
    onEnabledChange: (Boolean) -> Unit,
) {
    // stringResource is composable; semantics lambdas are not, so resolve the
    // localized descriptions once in the composable body.
    val hiddenDescription = stringResource(R.string.model_hidden_cd)
    val visionDescription = stringResource(R.string.model_vision_verified_cd)
    FloeSectionRow(
        onClick = onOpen,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Column(Modifier.weight(1f, fill = false)) {
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
                if (isDefault) {
                    FloeBadgePill(stringResource(R.string.model_default), FloeBadgeTone.ACCENT)
                }
                if (model.hiddenFromPrimaryPicker) {
                    Box(Modifier.semantics { contentDescription = hiddenDescription }) {
                        com.floe.android.design.IconGlyph(
                            FloeIcons.EyeSlash,
                            Floe.colors.secondaryLabel,
                            14.dp,
                        )
                    }
                }
                if (model.verifiedVision) {
                    Box(Modifier.semantics { contentDescription = visionDescription }) {
                        com.floe.android.design.IconGlyph(FloeIcons.Photo, Floe.colors.accent, 14.dp)
                    }
                }
                com.floe.android.design.IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp)
            }
        },
        trailing = {
            FloeInlineSwitch(
                checked = model.enabled,
                onCheckedChange = onEnabledChange,
                description = stringResource(R.string.model_enabled_cd),
            )
        },
    )
}

@Composable
fun rolePurposeTitle(role: ProviderServiceRoleUi): String = when (role) {
    ProviderServiceRoleUi.CONVERSATION -> stringResource(R.string.purpose_conversation)
    ProviderServiceRoleUi.IMAGE -> stringResource(R.string.purpose_image)
    ProviderServiceRoleUi.VIDEO -> stringResource(R.string.purpose_video)
}

fun roleIcon(role: ProviderServiceRoleUi) = when (role) {
    ProviderServiceRoleUi.CONVERSATION -> FloeIcons.ChatRole
    ProviderServiceRoleUi.IMAGE -> FloeIcons.ImageRole
    ProviderServiceRoleUi.VIDEO -> FloeIcons.VideoPlus
}

private fun ProviderEditorUiState?.hasIssue(field: ProviderFieldUi): Boolean =
    this?.fieldIssues?.any { it.field == field } == true

private fun ProviderEditorUiState?.issueMessages(field: ProviderFieldUi): List<String> =
    this?.fieldIssues?.filter { it.field == field }?.map { it.message }.orEmpty()
