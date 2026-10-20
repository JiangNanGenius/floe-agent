// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.providers

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf

/* ------------------------------ result types ------------------------------ */

/**
 * Outcome of one module action. Results NEVER carry secrets and never get
 * logged. `Stale` means a callback addressed to an identity the store no
 * longer accepts (late result cannot replace another editor — contract).
 */
sealed interface ProviderFlowResult {
    data object Accepted : ProviderFlowResult
    data object Stale : ProviderFlowResult
    data class Rejected(val reason: RejectedReason) : ProviderFlowResult
}

enum class RejectedReason {
    /** A save is already in flight for this editor identity+epoch. */
    SAVE_IN_FLIGHT,
    /** A connection test is already running. */
    TEST_IN_FLIGHT,
    /** Model discovery is already running. */
    DISCOVERY_IN_FLIGHT,
    /** The draft cannot support this action right now (blank endpoint / no seed). */
    INPUT_INSUFFICIENT,
    /** No editor session exists for that identity. */
    NO_SESSION,
}

private fun rejected(reason: RejectedReason): ProviderFlowResult =
    ProviderFlowResult.Rejected(reason)

/* ------------------------------- state holder ------------------------------ */

/**
 * Root presentation holder for the provider/model flow. It owns the draft
 * store and the navigation stack; every UI mutation flows through the host
 * seam and produces an explicit result the caller can act on. No
 * SavedStateHandle, no Bundle, no rememberSaveable, no database:
 *  - the host retains the holder in RAM across configuration changes;
 *  - process death restores NOTHING credential-related (the user re-enters
 *    keys against the host's committed metadata);
 *  - the credential lives only in [ProviderDraftSlot.secureInput] and is
 *    passed straight to the host action that needs it (never into the draft
 *    snapshot, never into a result).
 *
 * The holder never fabricates save/test/discovery/catalog outcomes: host
 * projections are the only source of truth, and the epoch guards reject late
 * results.
 */
class ProviderFlowHolder(
    private val host: ProviderUiCallbacks,
) {
    val drafts = ProviderDraftStore()
    val navigation = ProviderNavStack()

    /** Model draft id being edited in the nested MODEL_EDITOR pane. */
    val editingModelDraftId: MutableState<String?> = mutableStateOf(null)

    /**
     * Working copy of the model row being edited (⇄ ModelEditorView @State
     * model). Held by the session holder so config changes do not lose edits;
     * Cancel drops it and Save applies it to the draft staging list. Never
     * persisted and never part of a save payload until the model editor
     * commits into the provider draft.
     */
    val modelEditorWorkingCopy: MutableState<ModelDraftRowUi?> = mutableStateOf(null)

    /** One-time offer-prompt selection (RAM-only; rebuilt when the prompt opens). */
    val offerPromptSelection: MutableState<Set<ProviderServiceRoleUi>> = mutableStateOf(emptySet())

    /** Model-manager manual-add fields (RAM-only, cleared after a successful add). */
    val manualModelRemote: MutableState<String> = mutableStateOf("")
    val manualModelName: MutableState<String> = mutableStateOf("")

    private var openCounter = 0L
    private var stagingCounter = 0L

    /* ------------------------------- list ------------------------------- */

    fun openRoleChooser() {
        navigation.push(ProviderPane.ROLE_CHOOSER, "chooser")
    }

    fun cancelRoleChooser() {
        navigation.closeTopIf(ProviderPane.ROLE_CHOOSER, "chooser")
    }

    /** Purpose chosen: host notification + local seed + editor pane. */
    fun chooseRole(role: ProviderServiceRoleUi): ProviderFlowResult {
        if (!navigation.closeTopIf(ProviderPane.ROLE_CHOOSER, "chooser")) return rejected(RejectedReason.NO_SESSION)
        host.requestNewProvider(role)
        val seed = host.seedEditorFor(role, null) ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        openCounter += 1
        val identity = ProviderEditorIdentity(
            editorId = "new-${role.swiftRaw}-$openCounter",
            epoch = 1,
            role = role,
        )
        drafts.open(identity, seed)
        navigation.push(ProviderPane.EDITOR, identity.editorId)
        host.editorOpened(identity)
        return ProviderFlowResult.Accepted
    }

    /** Row tap / Edit for a saved provider. */
    fun openExisting(role: ProviderServiceRoleUi, providerId: String): ProviderFlowResult {
        val seed = host.seedEditorFor(role, providerId) ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        openCounter += 1
        val identity = ProviderEditorIdentity(
            editorId = "$providerId-${role.swiftRaw}-$openCounter",
            epoch = 1,
            role = role,
        )
        drafts.open(identity, seed)
        navigation.push(ProviderPane.EDITOR, identity.editorId)
        host.editorOpened(identity)
        return ProviderFlowResult.Accepted
    }

    /** ⇄ SeparateOfferRoute: a distinct-connection offer gets its own editor. */
    fun openSeparateOffer(seed: SeparateOfferSeedUi, role: ProviderServiceRoleUi): ProviderFlowResult {
        val editorSeed = host.seedSeparateOfferEditor(seed, role)
            ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        openCounter += 1
        val identity = ProviderEditorIdentity(
            editorId = "separate-${seed.presetId}-${role.swiftRaw}-$openCounter",
            epoch = 1,
            role = role,
        )
        drafts.open(identity, editorSeed)
        navigation.push(ProviderPane.EDITOR, identity.editorId)
        host.editorOpened(identity)
        return ProviderFlowResult.Accepted
    }

    fun setProviderEnabled(providerId: String, enabled: Boolean): Boolean =
        host.setProviderEnabled(providerId, enabled)

    fun deleteProvider(providerId: String): Boolean = host.deleteProvider(providerId)

    /** Open the editor for a saved row (host may publish additional state). */
    fun requestOpenExisting(role: ProviderServiceRoleUi, providerId: String): ProviderFlowResult =
        openExisting(role, providerId)

    /* ----------------------------- editor fields ----------------------------- */

    fun currentEditorIdentity(): ProviderEditorIdentity? =
        navigation.snapshot().lastOrNull { it.pane == ProviderPane.EDITOR }
            ?.let { drafts.slot(it.key)?.identity }

    fun setDisplayName(identity: ProviderEditorIdentity, value: String): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(displayName = value) } }

    fun setEnabled(identity: ProviderEditorIdentity, enabled: Boolean): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(enabled = enabled) } }

    fun setBaseUrl(identity: ProviderEditorIdentity, value: String): ProviderFlowResult =
        withSlot(identity) { it.onEndpointEdited(value) }

    fun setHeaders(identity: ProviderEditorIdentity, value: String): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(nonSecretHeaders = value) } }

    fun setAllowsPlainHttp(identity: ProviderEditorIdentity, allowed: Boolean): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(allowsPlainHttp = allowed) } }

    fun setToolNameCompatibility(identity: ProviderEditorIdentity, enabled: Boolean): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(toolNameCompatibility = enabled) } }

    fun setSecureInput(identity: ProviderEditorIdentity, value: String?): ProviderFlowResult =
        withSlot(identity) { it.setSecureInput(value) }

    fun toggleReveal(identity: ProviderEditorIdentity): ProviderFlowResult =
        withSlot(identity) { it.revealSecureInput.value = !it.revealSecureInput.value }

    fun setProtocol(identity: ProviderEditorIdentity, protocol: WireProtocolUi): ProviderFlowResult =
        withSlot(identity) { it.update { s -> s.copy(protocol = protocol) } }

    /* ------------------------------ offers ------------------------------ */

    fun setOfferDecision(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi, enabled: Boolean): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        if (enabled && host.serviceOfferRequiresDiscovery(identity, role)) {
            // ⇄ enableServiceOfferWithDiscovery: the role turns on only after a
            // real discovery round trip succeeds (host publishes that state).
            if (!host.requestOfferDiscovery(identity, role)) {
                return rejected(RejectedReason.INPUT_INSUFFICIENT)
            }
            return ProviderFlowResult.Accepted
        }
        slot.update { it.copy(offerDecisions = it.offerDecisions + (role to enabled)) }
        host.offerDecisionChanged(identity, role, enabled)
        return ProviderFlowResult.Accepted
    }

    fun toggleOfferPromptRole(role: ProviderServiceRoleUi) {
        val current = offerPromptSelection.value
        offerPromptSelection.value =
            if (role in current) current - role else current + role
    }

    fun confirmOfferPrompt(identity: ProviderEditorIdentity): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val roles = offerPromptSelection.value
        slot.update { s -> s.copy(offerDecisions = s.offerDecisions + roles.associateWith { true }) }
        host.offerPromptConfirmed(identity, roles)
        offerPromptSelection.value = emptySet()
        navigation.closeTopIf(ProviderPane.OFFER_PROMPT, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    fun declineOfferPrompt(identity: ProviderEditorIdentity): ProviderFlowResult {
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        host.offerPromptDeclined(identity)
        offerPromptSelection.value = emptySet()
        navigation.closeTopIf(ProviderPane.OFFER_PROMPT, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    /** The host publishes a pending prompt; the destination mirrors it into
     * the pane stack exactly once (called from composition effects). */
    fun syncOfferPromptPane(identity: ProviderEditorIdentity?, hasPrompt: Boolean) {
        val existing = navigation.entryFor(ProviderPane.OFFER_PROMPT)
        if (hasPrompt && identity != null && existing == null) {
            navigation.push(ProviderPane.OFFER_PROMPT, identity.editorId)
        } else if (!hasPrompt && existing != null) {
            navigation.closeTopIf(ProviderPane.OFFER_PROMPT, existing.key)
        }
    }

    /* --------------------------- draft models --------------------------- */

    fun setModelSelected(identity: ProviderEditorIdentity, draftId: String, selected: Boolean): ProviderFlowResult =
        withSlot(identity) { slot ->
            slot.update { s ->
                val models = ProviderFormLogic.setModelSelected(s.models, draftId, selected)
                val default = if (selected || s.defaultModelDraftId != draftId) {
                    s.defaultModelDraftId
                } else {
                    null
                }
                s.copy(models = models, defaultModelDraftId = default)
            }
        }

    fun setModelEnabled(identity: ProviderEditorIdentity, draftId: String, enabled: Boolean): ProviderFlowResult =
        withSlot(identity) { slot ->
            slot.update { s -> s.copy(models = ProviderFormLogic.setModelEnabled(s.models, draftId, enabled)) }
        }

    fun setDefaultModel(identity: ProviderEditorIdentity, draftId: String): ProviderFlowResult =
        withSlot(identity) { slot ->
            slot.update { s ->
                s.copy(defaultModelDraftId = ProviderFormLogic.setDefaultModel(s.models, s.defaultModelDraftId, draftId))
            }
        }

    fun addManualModel(identity: ProviderEditorIdentity): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val remote = manualModelRemote.value
        if (!ProviderFormLogic.isManualModelAddValid(remote)) {
            return rejected(RejectedReason.INPUT_INSUFFICIENT)
        }
        val staged = ProviderFormLogic.stageManualModel(
            existing = slot.snapshot.value.models,
            remoteModelID = remote,
            displayName = manualModelName.value,
            draftModelId = nextDraftId(),
            role = identity.role,
        ) ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        slot.update { it.copy(models = staged) }
        manualModelRemote.value = ""
        manualModelName.value = ""
        return ProviderFlowResult.Accepted
    }

    fun stageOfficialModel(identity: ProviderEditorIdentity, official: OfficialMediaModelUi): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val staged = ProviderFormLogic.stageOfficialMediaModel(
            existing = slot.snapshot.value.models,
            official = official,
            newDraftId = { nextDraftId() },
            role = identity.role,
        )
        slot.update { it.copy(models = staged) }
        return ProviderFlowResult.Accepted
    }

    /** Merge a host-published discovery result into the staging list (IDs are
     * re-staged so wire id, saved id and draft id never collide). */
    fun mergeHostCandidateModels(identity: ProviderEditorIdentity, discovered: List<ModelDraftRowUi>): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val existingByWire = slot.snapshot.value.models.associateBy { it.remoteModelID }
        val merged = slot.snapshot.value.models.toMutableList()
        discovered.forEach { candidate ->
            val existing = existingByWire[candidate.remoteModelID]
            if (existing == null) {
                merged += candidate.copy(draftModelId = nextDraftId())
            }
        }
        slot.update { it.copy(models = merged) }
        return ProviderFlowResult.Accepted
    }

    private fun nextDraftId(): String {
        stagingCounter += 1
        return "staged-$stagingCounter"
    }

    /* ---------------------------- nested panes ---------------------------- */

    fun openSupplierChooser(identity: ProviderEditorIdentity): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        slot.supplierQuery.value = ""
        navigation.push(ProviderPane.SUPPLIER_CHOOSER, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    fun cancelSupplierChooser(identity: ProviderEditorIdentity) {
        navigation.closeTopIf(ProviderPane.SUPPLIER_CHOOSER, identity.editorId)
    }

    /** ⇄ applyPreset — presets are prefill; the editor owns duplicate checks
     * and custom-name preservation, so this only applies the choice (pure). */
    fun choosePreset(identity: ProviderEditorIdentity, preset: SupplierPresetUi): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val choice = SupplierChoice(
            presetId = preset.presetId,
            displayName = preset.displayName,
            catalogEntryId = null,
            absoluteEndpointDefault = preset.defaultEndpointAbsoluteString,
            routeFamily = preset.routeFamily,
            authStyle = preset.authStyle,
            supportsPlainHttpChoice = preset.defaultEndpointSchemeIsHttp,
            suggestsToolNameCompatibility = false,
        )
        slot.applySupplierChoice(choice, preset.defaultProtocol)
        host.supplierPresetChosen(preset)
        navigation.closeTopIf(ProviderPane.SUPPLIER_CHOOSER, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    /** ⇄ applyCatalogEntry — same prefill rules; the catalog flag turns the
     * compatibility rewrite on. */
    fun chooseCatalogEntry(identity: ProviderEditorIdentity, entry: OfficialSupplierUi): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val choice = SupplierChoice(
            presetId = entry.catalogEntryId,
            displayName = entry.name,
            catalogEntryId = entry.catalogEntryId,
            absoluteEndpointDefault = entry.endpointAbsoluteString.orEmpty(),
            routeFamily = entry.routeFamily,
            authStyle = entry.authStyle,
            supportsPlainHttpChoice = entry.endpointAbsoluteString?.startsWith("http://") == true,
            suggestsToolNameCompatibility = entry.suggestsToolNameCompatibility,
        )
        slot.applySupplierChoice(
            choice = choice,
            newProtocol = entry.defaultProtocol,
            endpointOverride = entry.endpointAbsoluteString?.ifBlank { null },
        )
        host.supplierCatalogEntryChosen(entry)
        navigation.closeTopIf(ProviderPane.SUPPLIER_CHOOSER, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    /** Explicit catalog refresh (host-owned network action). */
    fun refreshSupplierCatalog(): Boolean = host.requestCatalogRefresh()

    fun openModelManager(identity: ProviderEditorIdentity): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        slot.modelSearchQuery.value = ""
        navigation.push(ProviderPane.MODEL_MANAGER, identity.editorId)
        return ProviderFlowResult.Accepted
    }

    fun closeModelManager(identity: ProviderEditorIdentity) {
        navigation.closeTopIf(ProviderPane.MODEL_MANAGER, identity.editorId)
    }

    fun openModelEditor(identity: ProviderEditorIdentity, draftModelId: String): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        val row = slot.snapshot.value.models.firstOrNull { it.draftModelId == draftModelId }
            ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        editingModelDraftId.value = draftModelId
        modelEditorWorkingCopy.value = row
        navigation.push(ProviderPane.MODEL_EDITOR, draftModelId)
        return ProviderFlowResult.Accepted
    }

    /** Edit the working copy in place (local presentation only). */
    fun editModelWorkingCopy(transform: (ModelDraftRowUi) -> ModelDraftRowUi) {
        val current = modelEditorWorkingCopy.value ?: return
        modelEditorWorkingCopy.value = transform(current)
    }

    /** Commit the working copy into the draft staging list (⇄ updateModel),
     * then close the model editor. The host's Swift authority validates the
     * whole provider at save time. */
    fun commitModelEditor(identity: ProviderEditorIdentity): ProviderFlowResult {
        val editing = modelEditorWorkingCopy.value ?: return rejected(RejectedReason.NO_SESSION)
        val result = updateModelRow(identity, editing)
        if (result is ProviderFlowResult.Accepted) {
            navigation.closeTopIf(ProviderPane.MODEL_EDITOR, editing.draftModelId)
            editingModelDraftId.value = null
            modelEditorWorkingCopy.value = null
        }
        return result
    }

    fun closeModelEditor() {
        navigation.closeTopIf(ProviderPane.MODEL_EDITOR, navigation.top.key)
        if (navigation.top.pane != ProviderPane.MODEL_EDITOR) {
            editingModelDraftId.value = null
            modelEditorWorkingCopy.value = null
        }
    }

    fun updateModelRow(identity: ProviderEditorIdentity, edited: ModelDraftRowUi): ProviderFlowResult =
        withSlot(identity) { slot ->
            slot.update { s ->
                val (models, default) = ProviderFormLogic.applyModelEdit(s.models, edited, s.defaultModelDraftId)
                s.copy(models = models, defaultModelDraftId = default)
            }
        }

    /* --------------------------- save / test / discovery --------------------------- */

    /**
     * Save. Gate: no duplicate dispatch for the epoch; in-flight disables
     * further Saves (contract). The credential text is handed straight to the
     * host (which must route it to the Keystore gateway) and is NOT stored
     * into the draft snapshot. The host returning false means nothing started:
     * the dispatched flag is not set and the caller sees Rejected.
     */
    fun save(identity: ProviderEditorIdentity, hostInFlight: Boolean): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        if (!drafts.canDispatchSave(identity, hostInFlight)) {
            return rejected(RejectedReason.SAVE_IN_FLIGHT)
        }
        val started = host.saveProvider(
            identity = identity,
            draft = slot.snapshot.value,
            credentialDraft = slot.secureInput.value,
        )
        if (!started) return rejected(RejectedReason.INPUT_INSUFFICIENT)
        drafts.markSaveDispatched(identity)
        return ProviderFlowResult.Accepted
    }

    /** Cancel closes the editor and discards the draft (never commits). */
    fun cancelEditor(identity: ProviderEditorIdentity): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        slot.discard()
        drafts.close(identity)
        // pop every pane belonging to this editor (innermost first), then the
        // editor itself; leave LIST as the settings-detail base.
        while (navigation.depth > 1) {
            val top = navigation.top
            if (top.pane == ProviderPane.EDITOR && top.key == identity.editorId) break
            navigation.back()
        }
        navigation.closeTopIf(ProviderPane.EDITOR, identity.editorId)
        editingModelDraftId.value = null
        modelEditorWorkingCopy.value = null
        host.editorClosed(identity, discarded = true)
        return ProviderFlowResult.Accepted
    }

    /** Connection test — explicit network action; the host reports the state. */
    fun testConnection(identity: ProviderEditorIdentity, hostInFlight: Boolean): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        if (hostInFlight) return rejected(RejectedReason.TEST_IN_FLIGHT)
        if (slot.snapshot.value.baseUrl.isBlank()) return rejected(RejectedReason.INPUT_INSUFFICIENT)
        val started = host.testConnection(identity, probeFor(slot))
        return if (started) ProviderFlowResult.Accepted else rejected(RejectedReason.INPUT_INSUFFICIENT)
    }

    fun discoverModels(identity: ProviderEditorIdentity, hostInFlight: Boolean): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        if (hostInFlight) return rejected(RejectedReason.DISCOVERY_IN_FLIGHT)
        if (slot.snapshot.value.baseUrl.isBlank()) return rejected(RejectedReason.INPUT_INSUFFICIENT)
        val started = host.discoverModels(identity, probeFor(slot))
        return if (started) ProviderFlowResult.Accepted else rejected(RejectedReason.INPUT_INSUFFICIENT)
    }

    fun cancelConnectionTest(identity: ProviderEditorIdentity) {
        if (drafts.accepts(identity)) host.cancelConnectionTest(identity)
    }

    fun cancelModelDiscovery(identity: ProviderEditorIdentity) {
        if (drafts.accepts(identity)) host.cancelModelDiscovery(identity)
    }

    /* ---------------------------- host outcomes ---------------------------- */

    /** True when [identity] is still the live session for its editor id. */
    fun isCurrent(identity: ProviderEditorIdentity): Boolean = drafts.accepts(identity)

    /**
     * Consume a host save outcome: the epoch must still match, otherwise the
     * result belongs to a closed/replaced editor and is ignored (contract).
     * Success is a HOST statement — the module only closes the editor after
     * that confirmed transition (see [finalizeSavedEditor]).
     */
    fun applyHostSaveOutcome(identity: ProviderEditorIdentity, outcome: SaveOutcomeUi): ProviderFlowResult {
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        drafts.resolveSaveOutcome(identity)
        return ProviderFlowResult.Accepted
    }

    /**
     * Host reported the attempt finished WITHOUT a structured outcome (for
     * example a supplied `saveError` string): clear only the duplicate-save
     * latch so Retry can dispatch again. Never marks success.
     */
    fun noteSaveAttemptFinished(identity: ProviderEditorIdentity): ProviderFlowResult {
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        drafts.resolveSaveOutcome(identity)
        return ProviderFlowResult.Accepted
    }

    /** After the host confirmed a verified save: close + notify. */
    fun finalizeSavedEditor(identity: ProviderEditorIdentity) {
        if (!drafts.accepts(identity)) return
        drafts.resolveSaveOutcome(identity)
        drafts.close(identity)
        while (navigation.depth > 1) {
            val top = navigation.top
            if (top.pane == ProviderPane.EDITOR && top.key == identity.editorId) break
            navigation.back()
        }
        navigation.closeTopIf(ProviderPane.EDITOR, identity.editorId)
        editingModelDraftId.value = null
        modelEditorWorkingCopy.value = null
        host.editorClosed(identity, discarded = false)
    }

    private fun probeFor(slot: ProviderDraftSlot): ConnectionProbeUi {
        val snapshot = slot.snapshot.value
        return ConnectionProbeUi(
            endpointAbsoluteString = snapshot.baseUrl.trim(),
            wireProtocol = snapshot.protocol,
            nonSecretHeaders = ProviderFormLogic.parseNonSecretHeaderLines(snapshot.nonSecretHeaders),
            credentialDraft = slot.secureInput.value,
            allowsPlainHttp = snapshot.allowsPlainHttp,
            toolNameCompatibility = snapshot.toolNameCompatibility,
        )
    }

    private fun withSlot(identity: ProviderEditorIdentity, block: (ProviderDraftSlot) -> Unit): ProviderFlowResult {
        val slot = drafts.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!drafts.accepts(identity)) return ProviderFlowResult.Stale
        block(slot)
        return ProviderFlowResult.Accepted
    }

    /** Leaving settings: drop every open editor slot and pane. */
    fun closeAll() {
        drafts.closeAll()
        navigation.resetToBase()
        editingModelDraftId.value = null
        modelEditorWorkingCopy.value = null
        offerPromptSelection.value = emptySet()
        manualModelRemote.value = ""
        manualModelName.value = ""
    }
}
