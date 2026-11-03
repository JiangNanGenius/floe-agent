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

    /** Capability bits the model editor exposes as user decisions
     * (⇄ iPad `userEditable`: vision/tools/image/video). TEXT and APPROVAL are
     * role-forced and can never be toggled here. */
    val editableCapabilityBits: Int = listOf(
        ModelCapabilityUi.VISION,
        ModelCapabilityUi.TOOLS,
        ModelCapabilityUi.IMAGE_GENERATION,
        ModelCapabilityUi.IMAGE_EDITING,
        ModelCapabilityUi.VIDEO_GENERATION,
    ).fold(0) { bits, item -> bits or item.swiftBit }

    /** Every capability bit this pinned presentation knows about. Bits
     * outside this mask are future/unknown and must be preserved verbatim. */
    val knownCapabilityBits: Int =
        ModelCapabilityUi.entries.fold(0) { bits, item -> bits or item.swiftBit }

    /** The required text role bit (⇄ ModelCapabilities.text). */
    const val TEXT_CAPABILITY_BIT: Int = 1

    /** The legacy approval role bit (⇄ ModelCapabilities.approval). */
    const val APPROVAL_CAPABILITY_BIT: Int = 32

    /**
     * The OLD Android producer encoded `explicitCapabilities` as an
     * OWNERSHIP/changed mask, not as selected values: it recorded every
     * user-editable bit that had ever been toggled, regardless of whether the
     * resulting value was ON or OFF.
     *
     * This is only the bit SHAPE of that mask (non-zero, no non-editable or
     * unknown bit). It is never sufficient on its own: a complete media
     * override may legitimately be editable-only too (e.g. explicit 8 on
     * base 24 = image generation on, image editing off). Legacy inference
     * must also require a conversational base row — see
     * [isLegacyConversationCapabilityOverride].
     */
    fun isLegacyPartialCapabilityOverride(explicit: Int?): Boolean =
        explicit != null && explicit != 0 &&
            (explicit and editableCapabilityBits.inv()) == 0

    /**
     * The ONLY provable legacy conversational row: the complete base row owns
     * the required text role AND the persisted explicit is exactly a non-zero
     * editable-only ownership signature.
     *
     * Reviewed values stay authoritative: an empty explicit (reviewed all
     * off), approval-only/no-text 32, a valid text override (35 with Tools
     * off), every media override (8 on base 24) and any unknown
     * non-editable/unknown mask are NOT this shape and are never inferred or
     * repaired. Only known ownership deltas (2/4/6/8… of the editable mask
     * 94) can be the old Android encoder's output.
     */
    fun isLegacyConversationCapabilityOverride(
        baseCapabilities: Int?,
        explicitCapabilities: Int?,
    ): Boolean {
        val base = baseCapabilities ?: return false
        return (base and TEXT_CAPABILITY_BIT) != 0 &&
            isLegacyPartialCapabilityOverride(explicitCapabilities)
    }

    /**
     * The selected editable state a row really has before any new edit.
     * A proven legacy ownership mask carries no selected-value authority, so
     * its values are derived FROM the complete base row. Every other
     * persisted explicit — reviewed 0, approval-only 32, media 8, valid 35 —
     * is a complete authoritative override and is returned unchanged.
     */
    fun effectiveSelectedCapabilities(
        baseCapabilities: Int?,
        explicitCapabilities: Int?,
    ): Int? {
        val selected = explicitCapabilities ?: return baseCapabilities
        if (isLegacyConversationCapabilityOverride(baseCapabilities, selected)) {
            return baseCapabilities
        }
        return selected
    }

    /**
     * Strongly targeted repair for one proven legacy conversational row:
     * derive the full selected value FROM the complete base mask (never from
     * the ownership mask) and preserve only non-editable/unknown bits. It
     * never ORs an owned mutable bit back on, so a Tools/Vision OFF that is
     * absent from base stays OFF. Rows outside the narrow predicate return
     * null and are left untouched.
     *
     * Main cases: base37/owned2 -> 37; base39/owned2 -> 39;
     * base35/owned6 -> 35; base33/owned4 -> 33.
     */
    fun repairedLegacyExplicitCapabilities(
        baseCapabilities: Int?,
        explicitCapabilities: Int?,
    ): Int? {
        if (!isLegacyConversationCapabilityOverride(
                baseCapabilities, explicitCapabilities,
            )
        ) return null
        val base = baseCapabilities ?: return null
        val explicit = explicitCapabilities ?: return null
        val repaired = base or (explicit and editableCapabilityBits.inv())
        return repaired.takeIf { it != explicit }
    }

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
     * defaults (media rows hidden from the primary picker) and selects it.
     * Limits are the SAME generic 128k/8192 every manual row gets on iOS —
     * the closed native validation requires `contextTokens > 0` for every
     * selected model (ProviderConfigurationValidation.issues(for:)), so a
     * media row seeded with 0 refused the whole provider save as
     * `invalidEnvelope` (`modelLimitsInvalid`) before any effect
     * (alpha24-candidate04 Samsung ArkPlanImageQA observation, UI trees
     * 228-236). Presentation defaults only — the host's Swift validation is
     * authoritative at save.
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
        // iOS addManualModel seeds 128_000/8_192 for EVERY role; the native
        // save validation requires a positive context for all models, media
        // rows included (0 refused the save as invalidEnvelope).
        contextTokens = 128_000,
        maxOutputTokens = 8_192,
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

    /** ⇄ updateModel presentation mirror: the view keeps exactly what the
     * user edited. Hiding a model that is the default clears the default
     * (⇄ setModelHiddenFromPrimaryPicker). */
    fun applyModelEdit(
        models: List<ModelDraftRowUi>,
        edited: ModelDraftRowUi,
        defaultModelDraftId: String?,
    ): Pair<List<ModelDraftRowUi>, String?> {
        val index = models.indexOfFirst { it.draftModelId == edited.draftModelId }
        if (index < 0) return models to defaultModelDraftId
        val previous = models[index]
        fun bits(row: ModelDraftRowUi) = row.capabilities.fold(0) { value, item -> value or item.swiftBit }
        val changed = (bits(previous) xor bits(edited)) and editableCapabilityBits
        val old = previous.savedMetadata
        val metadata = if (old != null || changed != 0) {
            val base = old ?: ModelSavedMetadataUi(reasoningEffortRaw = previous.reasoningEffort.swiftRaw)
            val baseBits = base.capabilitiesRaw ?: bits(previous)
            // A proven legacy ownership mask is re-encoded from the complete
            // base row even on a no-capability-change Save (rename/metadata),
            // so an existing row heals without losing its role bits.
            val repaired = repairedLegacyExplicitCapabilities(
                baseCapabilities = baseBits,
                explicitCapabilities = base.explicitCapabilitiesRaw,
            )
            when {
                // `explicitCapabilities` is a COMPLETE authoritative override
                // downstream (RunModelAssembly.effectiveCapabilities =
                // explicit ?? capabilities). Only this Save's actual selected
                // editable decisions are written — never a delta, and never
                // stale catalog TEXT/APPROVAL forced back into a row the user
                // deliberately reviewed as empty. Unknown future bits the
                // pinned presentation does not represent are retained.
                changed != 0 -> {
                    val unknownBits = (baseBits or (base.explicitCapabilitiesRaw ?: 0)) and
                        knownCapabilityBits.inv()
                    val complete = bits(edited) or unknownBits
                    base.copy(
                        capabilitiesRaw = complete,
                        explicitCapabilitiesRaw = complete,
                        explicitCapabilitiesJSON = complete.toString(),
                    )
                }
                // No capability decision in this Save: a proven legacy mask
                // heals to the complete base; any other persisted override
                // (reviewed 0, 32, media 8, valid 35, nil) is retained as is.
                repaired != null -> base.copy(
                    capabilitiesRaw = repaired,
                    explicitCapabilitiesRaw = repaired,
                    explicitCapabilitiesJSON = repaired.toString(),
                )
                else -> base
            }
        } else null
        val next = models.toMutableList()
        // Noneditable metadata belongs to the exact original row, even if
        // an editor callback reconstructs the editable values without it.
        next[index] = edited.copy(savedMetadata = metadata)
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
