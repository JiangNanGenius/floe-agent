// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.OfficialSupplierUi
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderFormLogic
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.SupplierAvailabilityUi
import com.floe.android.feature.providers.SupplierCatalogUiState
import com.floe.android.feature.providers.SupplierChoice
import com.floe.android.feature.providers.WireProtocolUi
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * REAL producer regression for the observed alpha24-candidate04 refusal
 * (Samsung API33, UI trees 228-236): an official Volcengine Ark IMAGE provider
 * on the Agent Plan endpoint with one manually-added Seedream row refused to
 * save as `invalidEnvelope` (`provider_refused:invalidEnvelope:
 * invalidProviderSettings`). Established cause: every media-role staging path
 * seeded the model row with `contextTokens = 0`, and the closed native
 * validation requires `contextTokens > 0` for EVERY selected model
 * (`ProviderConfigurationValidation.issues(for:)` → `modelLimitsInvalid`),
 * which the host surfaces as `invalidEnvelope` before any effect. iOS seeds
 * all manual rows with 128k/8192 regardless of role
 * (ProviderEditorViewModel.addManualModel). These cases pin the producer so
 * media candidates are saveable. SECRET-FREE: no credential value appears
 * anywhere in this file.
 */
class ProviderMediaSaveWireTest {

    private fun arkCatalog(servedRole: ProviderServiceRoleUi, models: List<String>) =
        SupplierCatalogUiState(
            builtInPresets = emptyList(),
            officialProviders = listOf(
                OfficialSupplierUi(
                    catalogEntryId = "volcengine-ark",
                    name = "Volcengine Ark",
                    aliases = emptyList(),
                    defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
                    kindPresetName = "Volcengine Ark",
                    endpointHost = "ark.cn-beijing.volces.com",
                    endpointAbsoluteString = "https://ark.cn-beijing.volces.com/api/v3",
                    routeFamily = "volcengineArk",
                    authStyle = "bearer",
                    modelCount = 0,
                    modelKeywords = emptyList(),
                    availability = SupplierAvailabilityUi.SUPPORTED,
                    unsupportedReason = null,
                    servedRoles = listOf(servedRole),
                    serviceOfferModels = mapOf(servedRole to models),
                    isLocalEndpoint = false,
                    isConfigured = false,
                    suggestsToolNameCompatibility = false,
                ),
            ),
            configuredPresetIds = emptySet(),
            footer = null,
            refreshAvailable = false,
            refreshInFlight = false,
            networkActionsAvailable = true,
        )

    @Test
    fun officialMediaTemplatesSeedPositiveLimitsForMediaRoles() {
        // Regression: the official-media template used the ModelDraftRowUi
        // data-class default (0), which the native save validation refuses.
        val image = ProviderWire.officialMediaModels(
            arkCatalog(ProviderServiceRoleUi.IMAGE, listOf("doubao-seedream-5.0-flash")),
            ProviderServiceRoleUi.IMAGE,
        )
        assertEquals(1, image.size)
        assertEquals(128_000, image.single().template.contextTokens)
        assertEquals(8_192, image.single().template.maxOutputTokens)

        val video = ProviderWire.officialMediaModels(
            arkCatalog(ProviderServiceRoleUi.VIDEO, listOf("seedance-2.5")),
            ProviderServiceRoleUi.VIDEO,
        )
        assertEquals(1, video.size)
        assertEquals(128_000, video.single().template.contextTokens)
        assertEquals(8_192, video.single().template.maxOutputTokens)
    }

    @Test
    fun arkPlanImageProviderCandidateCarriesSaveableModelLimits() {
        // The EXACT observed flow: image purpose, official Ark preset,
        // Agent Plan base URL, one manually staged Seedream row, no default
        // (media rows are hidden from the primary picker).
        val providerID = UUID.randomUUID().toString()
        val staged = ProviderFormLogic.stageManualModel(
            existing = emptyList(),
            remoteModelID = " doubao-seedream-5.0-flash ",
            displayName = "SeedreamFlashQA",
            draftModelId = "manual-1",
            role = ProviderServiceRoleUi.IMAGE,
        )!!.single()
        assertEquals(128_000, staged.contextTokens)
        assertEquals(8_192, staged.maxOutputTokens)
        assertTrue(staged.hiddenFromPrimaryPicker)

        val draft = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.IMAGE,
            enabled = true,
            displayName = "ArkPlanImageQA",
            supplier = SupplierChoice(
                presetId = "volcengine-ark",
                displayName = "Volcengine Ark",
                catalogEntryId = "volcengine-ark",
                absoluteEndpointDefault = "https://ark.cn-beijing.volces.com/api/v3",
                routeFamily = "volcengineArk",
                authStyle = "bearer",
                supportsPlainHttpChoice = false,
                suggestsToolNameCompatibility = false,
            ),
            protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            baseUrl = "https://ark.cn-beijing.volces.com/api/plan/v3",
            nonSecretHeaders = "",
            models = listOf(staged),
            defaultModelDraftId = null,
        )
        val modelUUID = UUID.randomUUID().toString()
        val candidate = ProviderWire.candidateJson(
            providerID = providerID,
            kind = "volcengineArk",
            createIntent = true,
            draft = draft,
            modelUUID = { modelUUID },
        )

        // Scalar provider envelope: unchanged by the repair.
        assertEquals(providerID, candidate["id"]!!.jsonPrimitive.content)
        assertEquals("volcengineArk", candidate["kind"]!!.jsonPrimitive.content)
        assertEquals("openai-chat-completions",
            candidate["wireProtocol"]!!.jsonPrimitive.content)
        assertEquals("https://ark.cn-beijing.volces.com/api/plan/v3",
            candidate["baseURL"]!!.jsonPrimitive.content)
        assertEquals("ArkPlanImageQA", candidate["displayName"]!!.jsonPrimitive.content)
        assertEquals("volcengine-ark", candidate["presetID"]!!.jsonPrimitive.content)
        assertFalse(candidate["serviceRoleIsConversation"]!!.jsonPrimitive.boolean)
        assertFalse(candidate["syncEnabled"]!!.jsonPrimitive.boolean)
        assertTrue(candidate["createIntent"]!!.jsonPrimitive.boolean)
        assertNotNull(candidate["managedCapabilities"])
        // Empty non-secret header lines -> empty closed OBJECT.
        assertTrue((candidate["nonSecretHeaders"] as JsonObject).isEmpty())

        // The staged media row now carries positive limits (the fix).
        val models = candidate["selectedModels"] as JsonArray
        assertEquals(1, models.size)
        val model = models[0] as JsonObject
        assertEquals(modelUUID, model["id"]!!.jsonPrimitive.content)
        assertEquals(providerID, model["providerID"]!!.jsonPrimitive.content)
        assertEquals("doubao-seedream-5.0-flash", model["remoteModelID"]!!.jsonPrimitive.content)
        assertEquals("SeedreamFlashQA", model["displayName"]!!.jsonPrimitive.content)
        val limits = model["limits"] as JsonObject
        assertEquals(128_000, limits["contextTokens"]!!.jsonPrimitive.int)
        assertEquals(8_192, limits["maxOutputTokens"]!!.jsonPrimitive.int)
        // IMAGE_GENERATION|IMAGE_EDITING = 8|16 = 24.
        assertEquals(24, model["capabilities"]!!.jsonPrimitive.int)
        assertEquals(24, candidate["managedCapabilities"]!!.jsonPrimitive.int)
        assertTrue(model["isEnabled"]!!.jsonPrimitive.boolean)
        assertTrue(model["isHiddenFromPrimaryPicker"]!!.jsonPrimitive.boolean)
        assertEquals("automatic", model["reasoningEffort"]!!.jsonPrimitive.content)
    }
}
