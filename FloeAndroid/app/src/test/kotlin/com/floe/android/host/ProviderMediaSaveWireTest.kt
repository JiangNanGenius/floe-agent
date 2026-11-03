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
import kotlinx.serialization.json.JsonPrimitive
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

    /* --------------------- purpose roundtrip regressions ---------------------
     * Device evidence (Samsung, signed Alpha25 candidate02): ArkPlanImageQA
     * saved as an IMAGE provider (UI trees alpha25-056/067/068) reopened with
     * the editor purpose showing 对话模型/conversation instead of
     * 图片生成与编辑/image (alpha25-069). Established cause: the native
     * `config.providers.list` summary never emitted the provider's service
     * roles, so the App reader defaulted every row to conversation and the
     * reopened editor seeded the conversation purpose. The save side was
     * already correct — the staged Seedream row persists IMAGE capabilities
     * (bits 8|16 = 24) and the runtime image.models discovery derives its
     * role from those persisted bits. These cases pin the App reader half of
     * the contract: the emitted `serviceRoles` array must bucket each row
     * into EVERY section it serves, preserving multi-role providers, the
     * disabled state and older-native compatibility. SECRET-FREE.
     * --------------------------------------------------------------------- */

    private fun providerRowJson(
        id: String,
        displayName: String,
        serviceRoles: List<String>? = null,
        enabled: Boolean = true,
        syncRevision: Long = 7L,
    ): JsonObject {
        val members = mutableMapOf<String, kotlinx.serialization.json.JsonElement>(
            "providerID" to JsonPrimitive(id),
            "kind" to JsonPrimitive("volcengineArk"),
            "wireProtocol" to JsonPrimitive("openai-chat-completions"),
            "baseURL" to JsonPrimitive("https://ark.cn-beijing.volces.com/api/plan/v3"),
            "displayName" to JsonPrimitive(displayName),
            "isEnabled" to JsonPrimitive(enabled),
            "syncRevision" to JsonPrimitive(syncRevision),
            "secret" to JsonObject(mapOf("configured" to JsonPrimitive(true))),
        )
        if (serviceRoles != null) {
            members["serviceRoles"] = JsonArray(serviceRoles.map { JsonPrimitive(it) })
        }
        return JsonObject(members)
    }

    private fun pageOf(vararg rows: JsonObject): JsonObject =
        JsonObject(mapOf("rows" to JsonArray(rows.toList())))

    @Test
    fun imageProviderRowRoundTripsIntoImageSectionOnly() {
        // alpha25-069 regression: an image-role row must come back in the
        // image bucket — never collapse into conversation.
        val id = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(providerRowJson(id, "ArkPlanImageQA", serviceRoles = listOf("image"))),
            mapOf(id.uppercase() to 1),
        )!!
        assertEquals(emptyList<Any>(), rows.conversationProviders)
        assertEquals(emptyList<Any>(), rows.videoProviders)
        assertEquals(1, rows.imageProviders.size)
        val row = rows.imageProviders.single()
        assertEquals(id, row.providerId)
        assertEquals("ArkPlanImageQA", row.displayName)
        assertEquals(1, row.modelCount)
        assertTrue(row.enabled)
        assertEquals("7", row.revisionVersion)
    }

    @Test
    fun videoProviderRowRoundTripsIntoVideoSectionOnly() {
        val id = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(providerRowJson(id, "ArkPlanVideoQA", serviceRoles = listOf("video"))),
        )!!
        assertEquals(emptyList<Any>(), rows.conversationProviders)
        assertEquals(emptyList<Any>(), rows.imageProviders)
        assertEquals(1, rows.videoProviders.size)
        assertEquals(id, rows.videoProviders.single().providerId)
    }

    @Test
    fun multiRoleProviderAppearsInEveryServedSection() {
        // iOS list parity: a provider serving conversation AND image is
        // listed in both sections; a first-match bucket would hide it from
        // the image section and reopen with the wrong purpose.
        val id = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(
                providerRowJson(id, "OmniQA", serviceRoles = listOf("conversation", "image")),
            ),
        )!!
        assertEquals(1, rows.conversationProviders.size)
        assertEquals(id, rows.conversationProviders.single().providerId)
        assertEquals(1, rows.imageProviders.size)
        assertEquals(id, rows.imageProviders.single().providerId)
        assertEquals(emptyList<Any>(), rows.videoProviders)
    }

    @Test
    fun absentServiceRolesKeepsConversationDefaultForOlderNative() {
        // Older native builds omit the additive field entirely: the reader
        // must behave exactly as before (conversation bucket), never refuse
        // or drop the row.
        val id = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(providerRowJson(id, "SamsungCloudQA")),
        )!!
        assertEquals(1, rows.conversationProviders.size)
        assertEquals(id, rows.conversationProviders.single().providerId)
        assertEquals(emptyList<Any>(), rows.imageProviders)
        assertEquals(emptyList<Any>(), rows.videoProviders)
    }

    @Test
    fun emptyOrUnknownServiceRolesNeverDropTheRow() {
        // An empty array or foreign entries sanitize to the conversation
        // default: a provider must never vanish from every section.
        val emptyId = UUID.randomUUID().toString()
        val emptyRows = ProviderWire.decodeProviderRows(
            pageOf(providerRowJson(emptyId, "EmptyQA", serviceRoles = emptyList())),
        )!!
        assertEquals(1, emptyRows.conversationProviders.size)

        val foreignId = UUID.randomUUID().toString()
        val foreignRoles = ProviderWire.decodeServiceRoles(
            providerRowJson(foreignId, "ForeignQA",
                serviceRoles = listOf("hologram", "image"))["serviceRoles"],
        )
        // The unknown entry is dropped, the known role survives.
        assertEquals(listOf("image"), foreignRoles)
    }

    @Test
    fun disabledImageProviderStaysInImageSectionWithDisabledState() {
        // alpha25-070 regression: disabling ONLY the new QA provider must
        // keep it discoverable under its real role with enabled = false.
        val id = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(
                providerRowJson(id, "ArkPlanImageQA", serviceRoles = listOf("image"),
                    enabled = false),
            ),
        )!!
        assertEquals(1, rows.imageProviders.size)
        val row = rows.imageProviders.single()
        assertFalse(row.enabled)
    }

    @Test
    fun existingChatRowsArePreservedAlongsideMediaRows() {
        // The original SamsungCloudQA conversation row and the Ark agent row
        // must stay in the conversation section while the new image row
        // lands in its own section — the repair must not reshuffle or evict
        // pre-existing chat providers.
        val chatId = UUID.randomUUID().toString()
        val agentId = UUID.randomUUID().toString()
        val imageId = UUID.randomUUID().toString()
        val rows = ProviderWire.decodeProviderRows(
            pageOf(
                providerRowJson(chatId, "SamsungCloudQA"),
                providerRowJson(agentId, "ArkAgentPlanQA"),
                providerRowJson(imageId, "ArkPlanImageQA", serviceRoles = listOf("image")),
            ),
            mapOf(chatId.uppercase() to 1, agentId.uppercase() to 1,
                imageId.uppercase() to 1),
        )!!
        assertEquals(listOf(chatId, agentId),
            rows.conversationProviders.map { it.providerId })
        assertEquals(listOf(imageId), rows.imageProviders.map { it.providerId })
        assertEquals(emptyList<Any>(), rows.videoProviders)
    }
}
