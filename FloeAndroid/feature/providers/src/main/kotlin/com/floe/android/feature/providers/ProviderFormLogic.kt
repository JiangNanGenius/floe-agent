// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation logic: search/filter, draft staging edits, and the
// view-side availability gates. These mirror the CURRENT iPad composition's
// UI behaviour (line references in comments) so the Android view reacts like
// the original — but they are NOT the business authority:
//  - final validation is Swift `ProviderConfigurationValidation` via the host;
//  - final save/commit/test/discovery results come back only as host state
//    projections;
//  - catalog model counts/ids remain directory metadata, never wire truth.

package com.floe.android.feature.providers

import java.util.Locale

object ProviderFormLogic {

    /** ⇄ ProviderCatalogIndex.normalized (lowercase + trim): the view-search
     * mirror on the immutable projection. Typing never performs network I/O. */
    fun normalizeQuery(query: String): String =
        query.trim().lowercase(Locale.ROOT)

    /** ⇄ ProviderCatalogPicker.matchingPresets: built-in presets match on
     * display name or host; manual/custom stays present for an explicit,
     * non-catalog choice (empty query → everything). */
    fun matchingPresets(presets: List<SupplierPresetUi>, query: String): List<SupplierPresetUi> {
        val needle = normalizeQuery(query)
        if (needle.isEmpty()) return presets
        return presets.filter { preset ->
            normalizeQuery(preset.displayName).contains(needle) ||
                (preset.defaultEndpointHost?.lowercase(Locale.ROOT)?.contains(needle) == true)
        }
    }

    /** ⇄ catalog.search(query, filter, configuredPresetIDs) presentation
     * mirror: name, aliases, host and model keywords match; filter narrows. */
    fun matchingOfficial(
        entries: List<OfficialSupplierUi>,
        query: String,
        filter: CatalogFilterUi,
    ): List<OfficialSupplierUi> {
        val needle = normalizeQuery(query)
        return entries.filter { entry ->
            val matchesQuery = needle.isEmpty() ||
                normalizeQuery(entry.name).contains(needle) ||
                entry.aliases.any { normalizeQuery(it).contains(needle) } ||
                (entry.endpointHost?.lowercase(Locale.ROOT)?.contains(needle) == true) ||
                entry.modelKeywords.any { normalizeQuery(it).contains(needle) }
            val matchesFilter = when (filter) {
                CatalogFilterUi.ALL -> true
                CatalogFilterUi.CONFIGURED -> entry.isConfigured
                CatalogFilterUi.AVAILABLE -> entry.availability == SupplierAvailabilityUi.SUPPORTED
                CatalogFilterUi.LOCAL -> entry.isLocalEndpoint
            }
            matchesQuery && matchesFilter
        }
    }

    /** ⇄ ModelPickerView manual Add `.disabled(remoteID blank)`. */
    fun isManualModelAddValid(remoteModelID: String): Boolean =
        remoteModelID.trim().isNotEmpty()

    /**
     * Stages one manual model row (⇄ addManualModel): trims the wire id, uses
     * it as display name when no name is typed, applies the role's staging
     * defaults (conversation 128k/8192 limits and visible; media hidden from
     * the primary picker) and selects it. Presentation defaults only — the
     * host's Swift validation is authoritative at save.
     */
    fun stageManualModel(
        existing: List<ModelDraftRowUi>,
        remoteModelID: String,
        displayName: String,
        draftModelId: String,
        role: ProviderServiceRoleUi,
    ): List<ModelDraftRowUi>? {
        val trimmed = remoteModelID.trim()
        if (trimmed.isEmpty()) return null
        val row = defaultStagedRow(draftModelId, trimmed, displayName.ifBlank { trimmed }, role)
        return existing + row
    }

    /** ⇄ addOfficialMediaPreset: reuse an existing candidate with the same
     * wire id (just select it); otherwise stage a manual-shaped row. */
    fun stageOfficialMediaModel(
        existing: List<ModelDraftRowUi>,
        official: OfficialMediaModelUi,
        newDraftId: (String) -> String,
        role: ProviderServiceRoleUi,
    ): List<ModelDraftRowUi> {
        val matchIndex = existing.indexOfFirst { it.remoteModelID == official.remoteModelID }
        if (matchIndex >= 0) {
            return existing.toMutableList().also { list ->
                list[matchIndex] = list[matchIndex].copy(selectedForSave = true)
            }
        }
        val template = official.template.copy(
            draftModelId = newDraftId(official.remoteModelID),
            remoteModelID = official.remoteModelID,
            displayName = official.displayName,
            source = ModelSourceUi.OFFICIAL_MEDIA,
            selectedForSave = true,
        )
        return existing + template
    }

    private fun defaultStagedRow(
        draftModelId: String,
        remoteID: String,
        name: String,
        role: ProviderServiceRoleUi,
    ): ModelDraftRowUi = ModelDraftRowUi(
        draftModelId = draftModelId,
        savedModelId = null,
        remoteModelID = remoteID,
        displayName = name,
        enabled = true,
        hiddenFromPrimaryPicker = role != ProviderServiceRoleUi.CONVERSATION,
        capabilities = when (role) {
            ProviderServiceRoleUi.CONVERSATION ->
                setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL)
            ProviderServiceRoleUi.IMAGE ->
                setOf(ModelCapabilityUi.IMAGE_GENERATION, ModelCapabilityUi.IMAGE_EDITING)
            ProviderServiceRoleUi.VIDEO ->
                setOf(ModelCapabilityUi.VIDEO_GENERATION)
        },
        reasoningEffort = ReasoningEffortUi.AUTOMATIC,
        contextTokens = if (role == ProviderServiceRoleUi.CONVERSATION) 128_000 else 0,
        maxOutputTokens = if (role == ProviderServiceRoleUi.CONVERSATION) 8_192 else 0,
        source = ModelSourceUi.MANUAL,
        selectedForSave = true,
    )

    /** ⇄ ModelPickerView.filteredModels: case-insensitive name or wire-id. */
    fun filterCandidateModels(models: List<ModelDraftRowUi>, query: String): List<ModelDraftRowUi> {
        val needle = normalizeQuery(query)
        if (needle.isEmpty()) return models
        return models.filter {
            normalizeQuery(it.displayName).contains(needle) ||
                normalizeQuery(it.remoteModelID).contains(needle)
        }
    }

    /** ⇄ updateModel presentation mirror: role-forced bits are host-side on
     * save; the view keeps exactly what the user edited. Hiding a model that
     * is the default clears the default (⇄ setModelHiddenFromPrimaryPicker). */
    fun applyModelEdit(
        models: List<ModelDraftRowUi>,
        edited: ModelDraftRowUi,
        defaultModelDraftId: String?,
    ): Pair<List<ModelDraftRowUi>, String?> {
        val index = models.indexOfFirst { it.draftModelId == edited.draftModelId }
        if (index < 0) return models to defaultModelDraftId
        val next = models.toMutableList()
        next[index] = edited
        var nextDefault = defaultModelDraftId
        if (edited.hiddenFromPrimaryPicker && defaultModelDraftId == edited.draftModelId) {
            nextDefault = null
        }
        return next to nextDefault
    }

    /** ⇄ setDefaultModel: only a SELECTED model can become the default. */
    fun setDefaultModel(models: List<ModelDraftRowUi>, defaultModelDraftId: String?, draftId: String?): String? =
        if (draftId == null) null
        else if (models.any { it.draftModelId == draftId && it.selectedForSave }) draftId
        else defaultModelDraftId

    /** ⇄ setModelEnabled on the draft staging list. */
    fun setModelEnabled(models: List<ModelDraftRowUi>, draftId: String, enabled: Boolean): List<ModelDraftRowUi> =
        models.map { if (it.draftModelId == draftId) it.copy(enabled = enabled) else it }

    fun setModelSelected(models: List<ModelDraftRowUi>, draftId: String, selected: Boolean): List<ModelDraftRowUi> =
        models.map { if (it.draftModelId == draftId) it.copy(selectedForSave = selected) else it }

    /** ⇄ ModelEditorView Save-toolbar `.disabled(...)` mirror (the gate, not
     * the authority): name/wire-id non-blank; conversation limits
     * context > 0, output >= 0 and output <= context when set. */
    fun modelEditorCanSave(row: ModelDraftRowUi, role: ProviderServiceRoleUi): Boolean {
        if (row.displayName.trim().isEmpty()) return false
        if (row.remoteModelID.trim().isEmpty()) return false
        if (role != ProviderServiceRoleUi.CONVERSATION) return true
        val contextOk = row.contextTokens > 0
        val outputOk = row.maxOutputTokens >= 0 &&
            (row.maxOutputTokens == 0 || row.maxOutputTokens <= row.contextTokens)
        return contextOk && outputOk
    }

    /** ⇄ "Only Save-path errors open the alert; connection/discovery keep
     * their inline context": which host string drives the pinned banner. */
    fun pinnedSaveError(saveError: String?): String? = saveError?.takeIf { it.isNotEmpty() }

    /** ⇄ ProviderEditorView.serviceOffers visible filter + draft decisions:
     * undecided roles never appear (they are raised once through the prompt);
     * shared usable offers reflect the user's in-session toggles. */
    fun visibleOffers(
        offers: List<ServiceOfferUi>,
        draftDecisions: Map<ProviderServiceRoleUi, Boolean>,
        roleDiscoveryPending: (ProviderServiceRoleUi) -> Boolean,
    ): List<ServiceOfferUi> = offers.filter { offer ->
        val effectiveEnabled = draftDecisions[offer.role] ?: offer.isEnabled
        effectiveEnabled ||
            // An explicit in-session decision (including OFF) keeps the row
            // visible so the user can turn it back on; only never-touched
            // disabled shared offers are deferred to the one-time prompt.
            draftDecisions.containsKey(offer.role) ||
            !offer.isUsable ||
            offer.connection == OfferConnectionUi.DISTINCT ||
            offer.discoveryState != ConnectionTestUi.Idle ||
            roleDiscoveryPending(offer.role)
    }.map { offer ->
        val decision = draftDecisions[offer.role] ?: return@map offer
        if (offer.isUsable && offer.connection == OfferConnectionUi.SHARED) {
            offer.copy(isEnabled = decision)
        } else {
            offer
        }
    }

    /** "Header: value" lines ⇄ the host's nonSecretHeadersText split; lines
     * without a colon are kept verbatim for the host to reject with authority. */
    fun parseNonSecretHeaderLines(text: String): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        text.lines().forEach { rawLine ->
            val line = rawLine.trim()
            if (line.isEmpty()) return@forEach
            val colon = line.indexOf(':')
            if (colon > 0) {
                result[line.substring(0, colon).trim()] = line.substring(colon + 1).trim()
            } else {
                result[line] = ""
            }
        }
        return result
    }

    /** ⇄ protocol displayName extension (product terms, locale-stable). */
    fun protocolLabel(protocol: WireProtocolUi): String = when (protocol) {
        WireProtocolUi.OPENAI_RESPONSES -> "OpenAI Responses"
        WireProtocolUi.OPENAI_CHAT_COMPLETIONS -> "OpenAI Chat Completions"
        WireProtocolUi.ANTHROPIC_MESSAGES -> "Anthropic Messages"
    }

    /** ⇄ TokenLimitPicker.shortLabel (K/M with exact multiples only). */
    fun shortTokenLabel(tokens: Int): String = when {
        tokens >= 1_048_576 && tokens % 1_048_576 == 0 -> "${tokens / 1_048_576}M"
        tokens >= 1_024 && tokens % 1_024 == 0 -> "${tokens / 1_024}K"
        else -> tokens.toString()
    }

    /** ⇄ TokenLimitPicker numericText: digits only; empty → 0. */
    fun parseTokenInput(input: String): Int {
        val digits = input.filter { it.isDigit() }
        if (digits.isEmpty()) return 0
        return digits.toIntOrNull() ?: 0
    }
}
