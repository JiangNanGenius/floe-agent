// SPDX-License-Identifier: MPL-2.0
//
// Synthetic unit tests for the pure presentation logic: catalog search/filter,
// staging defaults, model-editor availability gate, offer visibility and the
// non-secret header projection. These mirror the iPad view behavior only; the
// business authority stays with Swift validation.

package com.floe.android.feature.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderFormLogicTest {

    private fun preset(
        id: String = "openai",
        name: String = "OpenAI",
        host: String = "api.openai.com",
        custom: Boolean = false,
    ) = SupplierPresetUi(
        presetId = id,
        displayName = name,
        defaultProtocol = WireProtocolUi.OPENAI_RESPONSES,
        supportedProtocols = WireProtocolUi.entries,
        defaultEndpointHost = host,
        defaultEndpointAbsoluteString = "https://$host/v1",
        defaultEndpointSchemeIsHttp = false,
        routeFamily = id,
        authStyle = "bearer",
        isCustom = custom,
    )

    private fun entry(
        id: String = "deepseek",
        name: String = "DeepSeek",
        aliases: List<String> = listOf("深度求索"),
        host: String = "api.deepseek.com",
        keywords: List<String> = listOf("deepseek-chat", "deepseek-reasoner"),
        configured: Boolean = false,
        available: Boolean = true,
        local: Boolean = false,
    ) = OfficialSupplierUi(
        catalogEntryId = id,
        name = name,
        aliases = aliases,
        defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
        kindPresetName = "OpenAI",
        endpointHost = host,
        endpointAbsoluteString = "https://$host/v1",
        routeFamily = id,
        authStyle = "bearer",
        modelCount = 2,
        modelKeywords = keywords,
        availability = if (available) SupplierAvailabilityUi.SUPPORTED else SupplierAvailabilityUi.UNSUPPORTED,
        unsupportedReason = if (available) null else "Requires AWS SigV4 request signing",
        servedRoles = listOf(ProviderServiceRoleUi.CONVERSATION),
        isLocalEndpoint = local,
        isConfigured = configured,
        suggestsToolNameCompatibility = true,
    )

    /* ------------------------------ search ------------------------------ */

    @Test
    fun presetSearchMatchesNameOrHostAndKeepsCustomChoice() {
        val presets = listOf(
            preset(),
            preset(id = "custom", name = "Custom", host = "", custom = true),
            preset(id = "deepseek", name = "DeepSeek", host = "api.deepseek.com"),
        )

        assertEquals(presets, ProviderFormLogic.matchingPresets(presets, ""))
        assertEquals(listOf("deepseek"), ProviderFormLogic.matchingPresets(presets, "deep").map { it.presetId })
        assertEquals(listOf("deepseek"), ProviderFormLogic.matchingPresets(presets, "api.deepseek").map { it.presetId })
    }

    @Test
    fun officialSearchMatchesAliasHostAndModelKeywords() {
        val entries = listOf(entry())

        assertEquals(entries, ProviderFormLogic.matchingOfficial(entries, "", CatalogFilterUi.ALL))
        assertEquals(entries, ProviderFormLogic.matchingOfficial(entries, "深度", CatalogFilterUi.ALL))
        assertEquals(entries, ProviderFormLogic.matchingOfficial(entries, "reasoner", CatalogFilterUi.ALL))
        assertEquals(entries, ProviderFormLogic.matchingOfficial(entries, "api.deepseek", CatalogFilterUi.ALL))
        assertTrue(ProviderFormLogic.matchingOfficial(entries, "nothing", CatalogFilterUi.ALL).isEmpty())
    }

    @Test
    fun officialFiltersNarrowByConfiguredAvailabilityAndLocal() {
        val entries = listOf(
            entry(id = "a", configured = true),
            entry(id = "b", available = false),
            entry(id = "c", local = true),
        )

        assertEquals(listOf("a"), ProviderFormLogic.matchingOfficial(entries, "", CatalogFilterUi.CONFIGURED).map { it.catalogEntryId })
        assertEquals(listOf("a", "c"), ProviderFormLogic.matchingOfficial(entries, "", CatalogFilterUi.AVAILABLE).map { it.catalogEntryId })
        assertEquals(listOf("c"), ProviderFormLogic.matchingOfficial(entries, "", CatalogFilterUi.LOCAL).map { it.catalogEntryId })
    }

    /* ------------------------------ staging ------------------------------ */

    @Test
    fun manualAddValidatesTrimmedWireId() {
        assertFalse(ProviderFormLogic.isManualModelAddValid("   "))
        assertTrue(ProviderFormLogic.isManualModelAddValid(" gpt-5 "))
    }

    @Test
    fun manualAddUsesRoleDefaultsAndWireIdFallbackName() {
        assertNull(ProviderFormLogic.stageManualModel(emptyList(), "  ", "", "staged-1", ProviderServiceRoleUi.CONVERSATION))

        val conversation = ProviderFormLogic.stageManualModel(
            emptyList(), " gpt-5 ", "", "staged-1", ProviderServiceRoleUi.CONVERSATION,
        )!!.single()
        assertEquals("gpt-5", conversation.remoteModelID)
        assertEquals("gpt-5", conversation.displayName)
        assertEquals("staged-1", conversation.draftModelId)
        assertNull(conversation.savedModelId)
        assertEquals(128_000, conversation.contextTokens)
        assertEquals(8_192, conversation.maxOutputTokens)
        assertFalse(conversation.hiddenFromPrimaryPicker)
        assertTrue(conversation.selectedForSave)
        assertTrue(ModelCapabilityUi.TEXT in conversation.capabilities)
        assertTrue(ModelCapabilityUi.TOOLS in conversation.capabilities)

        val image = ProviderFormLogic.stageManualModel(
            emptyList(), "gpt-image-1", "Image one", "staged-2", ProviderServiceRoleUi.IMAGE,
        )!!.single()
        assertTrue(image.hiddenFromPrimaryPicker)
        assertTrue(ModelCapabilityUi.IMAGE_GENERATION in image.capabilities)
    }

    @Test
    fun officialStagingReusesExistingWireRowInsteadOfDuplicating() {
        val existing = ProviderFormLogic.stageManualModel(
            emptyList(), "gpt-image-1", "Image", "staged-1", ProviderServiceRoleUi.IMAGE,
        )!!
        val official = OfficialMediaModelUi(
            displayName = "GPT Image",
            remoteModelID = "gpt-image-1",
            template = existing.single().copy(selectedForSave = false),
        )

        val merged = ProviderFormLogic.stageOfficialMediaModel(
            existing = existing.map { it.copy(selectedForSave = false) },
            official = official,
            newDraftId = { "should-not-be-used" },
            role = ProviderServiceRoleUi.IMAGE,
        )

        assertEquals("no duplicate row", 1, merged.size)
        assertTrue(merged.single().selectedForSave)
        assertEquals("staged-1", merged.single().draftModelId)
    }

    /* ------------------------------ model gate ------------------------------ */

    @Test
    fun modelEditorGateMirrorsToolbarAvailability() {
        val base = ModelDraftRowUi(
            draftModelId = "staged-1",
            savedModelId = null,
            remoteModelID = "gpt-5",
            displayName = "GPT-5",
            contextTokens = 128_000,
            maxOutputTokens = 8_192,
        )

        assertTrue(ProviderFormLogic.modelEditorCanSave(base, ProviderServiceRoleUi.CONVERSATION))
        assertFalse(ProviderFormLogic.modelEditorCanSave(base.copy(displayName = " "), ProviderServiceRoleUi.CONVERSATION))
        assertFalse(ProviderFormLogic.modelEditorCanSave(base.copy(remoteModelID = " "), ProviderServiceRoleUi.CONVERSATION))
        assertFalse(ProviderFormLogic.modelEditorCanSave(base.copy(contextTokens = 0), ProviderServiceRoleUi.CONVERSATION))
        assertFalse(ProviderFormLogic.modelEditorCanSave(base.copy(maxOutputTokens = -1), ProviderServiceRoleUi.CONVERSATION))
        assertFalse(
            ProviderFormLogic.modelEditorCanSave(
                base.copy(maxOutputTokens = 200_000), ProviderServiceRoleUi.CONVERSATION,
            ),
        )
        assertTrue(ProviderFormLogic.modelEditorCanSave(base.copy(maxOutputTokens = 0), ProviderServiceRoleUi.CONVERSATION))
        // Media roles do not use conversation limits.
        assertTrue(ProviderFormLogic.modelEditorCanSave(base.copy(contextTokens = 0), ProviderServiceRoleUi.IMAGE))
    }

    @Test
    fun hidingTheDefaultModelClearsDefaultAndOnlySelectedModelsBecomeDefault() {
        val models = listOf(
            ModelDraftRowUi("staged-1", null, "a", "A", selectedForSave = true),
            ModelDraftRowUi("staged-2", null, "b", "B", selectedForSave = true),
        )

        val (hidden, defaultAfterHide) = ProviderFormLogic.applyModelEdit(
            models, models[0].copy(hiddenFromPrimaryPicker = true), "staged-1",
        )
        assertNull(defaultAfterHide)
        assertTrue(hidden[0].hiddenFromPrimaryPicker)

        assertEquals("staged-2", ProviderFormLogic.setDefaultModel(models, "staged-1", "staged-2"))
        assertEquals("staged-1", ProviderFormLogic.setDefaultModel(models, "staged-1", "not-selected"))
    }

    /* ------------------------------ offers ------------------------------ */

    @Test
    fun offerVisibilityAndDraftDecisions() {
        val shared = ServiceOfferUi(
            role = ProviderServiceRoleUi.IMAGE,
            isEnabled = false,
            isUsable = true,
            connection = OfferConnectionUi.SHARED,
            modelCount = 3,
            requiresDiscovery = false,
            discoveryState = ConnectionTestUi.Idle,
            discoveryError = null,
            reason = null,
            note = null,
            canConfigureSeparately = false,
            separateOfferSeed = null,
        )
        val distinct = shared.copy(role = ProviderServiceRoleUi.VIDEO, connection = OfferConnectionUi.DISTINCT)
        val unusable = shared.copy(role = ProviderServiceRoleUi.VIDEO, isUsable = false, reason = "Requires SigV4")

        // Undecided disabled shared offers are hidden (raised once via prompt).
        assertTrue(ProviderFormLogic.visibleOffers(listOf(shared), emptyMap()) { false }.isEmpty())
        // Distinct and unusable offers stay visible with their reason.
        assertEquals(2, ProviderFormLogic.visibleOffers(listOf(distinct, unusable), emptyMap()) { false }.size)
        // A user decision keeps the shared offer visible and reflects it.
        val decided = ProviderFormLogic.visibleOffers(listOf(shared), mapOf(shared.role to false)) { false }
        assertEquals(1, decided.size)
        assertFalse(decided.single().isEnabled)
    }

    /* ------------------------------ misc ------------------------------ */

    @Test
    fun headerLinesProjectWithoutJudgeingClassification() {
        val parsed = ProviderFormLogic.parseNonSecretHeaderLines(
            "X-Trace: abc\n\nno-colon-line\nAuthorization: should-not-be-here",
        )
        assertEquals("abc", parsed["X-Trace"])
        assertEquals("", parsed["no-colon-line"])
        assertEquals("should-not-be-here", parsed["Authorization"])
        assertEquals(3, parsed.size)
    }

    @Test
    fun tokenLabelsAndNumericParsing() {
        assertEquals("1M", ProviderFormLogic.shortTokenLabel(1_048_576))
        assertEquals("128K", ProviderFormLogic.shortTokenLabel(131_072))
        assertEquals("1000", ProviderFormLogic.shortTokenLabel(1000))
        assertEquals(12_345, ProviderFormLogic.parseTokenInput("12,345"))
        assertEquals(0, ProviderFormLogic.parseTokenInput(""))
    }

    @Test
    fun protocolLabelsAreProductTerms() {
        assertEquals("OpenAI Responses", ProviderFormLogic.protocolLabel(WireProtocolUi.OPENAI_RESPONSES))
        assertEquals("OpenAI Chat Completions", ProviderFormLogic.protocolLabel(WireProtocolUi.OPENAI_CHAT_COMPLETIONS))
        assertEquals("Anthropic Messages", ProviderFormLogic.protocolLabel(WireProtocolUi.ANTHROPIC_MESSAGES))
    }
}
