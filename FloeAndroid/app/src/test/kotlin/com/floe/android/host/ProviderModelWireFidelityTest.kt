// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Real production decoder -> exact seed -> edited draft -> real candidate. */
class ProviderModelWireFidelityTest {
    private val provider = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private val pricing = "{\"currency\":\"USD\",\"inputPerMillion\":0.1234567890123456789,\"outputPerMillion\":1.25}"
    private fun page(caps: Int, own: Int?, revision: String = "\"revision\":{\"resourceID\":\"model.$id\",\"version\":\"v1\"},"): String =
        """{"rows":[{"id":"$id","providerID":"$provider", "remoteModelID":"r","displayName":"Saved","limits":{"contextTokens":4096,"maxOutputTokens":0},"capabilities":$caps,"pricing":$pricing,"useSurfaces":5,${if (own == null) "" else "\"explicitCapabilities\":$own,"}$revision"isEnabled":true,"isHiddenFromPrimaryPicker":false}]}"""
    private fun seed(caps: Int = 5, own: Int? = 0): ModelDraftRowUi =
        ProviderWire.savedModelDraft(
            ProviderWire.decodeModelRows(Json.parseToJsonElement(page(caps, own)))!!.single())
    private fun candidate(row: ModelDraftRowUi,
        role: ProviderServiceRoleUi = ProviderServiceRoleUi.CONVERSATION): JsonObject =
        ProviderWire.candidateJson(
            providerID = provider, kind = "openAI", createIntent = false,
            draft = ProviderDraftSnapshot(role = role,
                baseUrl = "https://api.example.invalid/v1", models = listOf(row)), modelUUID = { id })
    private fun encoded(row: ModelDraftRowUi,
        role: ProviderServiceRoleUi = ProviderServiceRoleUi.CONVERSATION) =
        candidate(row, role)["selectedModels"]!!.jsonArray.single().jsonObject
    private fun reread(row: ModelDraftRowUi): ModelDraftRowUi = ProviderWire.savedModelDraft(
        ProviderWire.decodeModelRows(JsonObject(mapOf("rows" to JsonArray(listOf(encoded(row))))))!!.single())

    @Test fun unchangedSavedModelKeepsPricingPrecisionSurfaceZeroAndNilReasoning() {
        val row = seed().copy(displayName = "Renamed")
        val value = encoded(row)
        assertEquals(Json.parseToJsonElement(pricing), value["pricing"])
        assertEquals(5, value["useSurfaces"]!!.jsonPrimitive.int)
        // A reviewed-zero explicit is a complete authoritative decision: it is
        // preserved exactly (never promoted from the TEXT-capable base row,
        // never replaced by the new-row default 37).
        assertEquals(0, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(5, value["capabilities"]!!.jsonPrimitive.int)
        assertFalse(value.containsKey("reasoningEffort"))
        assertEquals("Renamed", value["displayName"]!!.jsonPrimitive.content)
        // A later decode cannot replace the exact older editor metadata.
        seed(caps = 1, own = 4)
        assertEquals(value, encoded(row))
    }

    @Test fun savedZeroAndUnrepresentedBitsNeverReceiveDefaultCapabilities() {
        assertEquals(0, encoded(seed(caps = 0))["capabilities"]!!.jsonPrimitive.int)
        val futureBit = 1 shl 25
        // Unknown base bits are retained verbatim in the complete base row.
        assertEquals(1 or futureBit,
            encoded(seed(caps = 1 or futureBit))["capabilities"]!!.jsonPrimitive.int)
        val original = seed(caps = 37, own = 2)
        val edited = ProviderFormLogic.applyModelEdit(listOf(original),
            original.copy(capabilities = original.capabilities - ModelCapabilityUi.TOOLS), null).first.single()
        // Base 37 has Tools ON; turning it OFF yields the complete selected
        // row TEXT(1) + APPROVAL(32) = 33 (the old ownership mask was 2/4).
        assertEquals(33, encoded(edited)["explicitCapabilities"]!!.jsonPrimitive.int)
    }

    @Test fun legacyPartialExplicitIsHealedToCompleteMaskOnPlainProviderSave() {
        // The exact persisted shape produced by the old Android producer:
        // capabilities = 39 (text|vision|tools|approval), explicit = 2 (the
        // Vision delta only). No model-editor interaction here.
        val row = seed(caps = 39, own = 2)
        // Ownership mask 2 means "Vision was toggled", NOT "only Vision is
        // selected": the complete base row 39 is the real selected value.
        assertEquals(setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION,
            ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL), row.capabilities)
        val value = encoded(row.copy(displayName = "Renamed"))
        assertEquals(39, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(39, value["capabilities"]!!.jsonPrimitive.int)
        assertEquals(Json.parseToJsonElement(pricing), value["pricing"])
        assertEquals(5, value["useSurfaces"]!!.jsonPrimitive.int)
    }

    @Test fun legacyOwnershipDeltaRowsHealFromTheCompleteBaseSelectedValue() {
        // Main's exact cases: the ownership mask records which bits were
        // toggled, never which values are selected.
        assertEquals(37, encoded(seed(caps = 37, own = 2).copy(displayName = "r"))
            ["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(39, encoded(seed(caps = 39, own = 2).copy(displayName = "r"))
            ["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(35, encoded(seed(caps = 35, own = 6).copy(displayName = "r"))
            ["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(33, encoded(seed(caps = 33, own = 4).copy(displayName = "r"))
            ["explicitCapabilities"]!!.jsonPrimitive.int)
    }

    @Test fun explicitToolsOffSurvivesPlainProviderSaveAndReload() {
        val row = seed(caps = 39, own = 35)
        assertEquals(setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION,
            ModelCapabilityUi.APPROVAL), row.capabilities)
        val value = encoded(row.copy(displayName = "Renamed"))
        // The valid complete override is preserved; the persisted base row is
        // not narrowed by a plain provider save.
        assertEquals(35, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(39, value["capabilities"]!!.jsonPrimitive.int)
        // A real re-read of the emitted row keeps the same authoritative mask
        // and does not drift back to Tools ON.
        val again = encoded(reread(row))
        assertEquals(35, again["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(39, again["capabilities"]!!.jsonPrimitive.int)
    }

    @Test fun reviewedZeroOverrideSurvivesRenameAndReload() {
        val row = seed(caps = 37, own = 0)
        assertEquals(emptySet<ModelCapabilityUi>(), row.capabilities)
        val value = encoded(row.copy(displayName = "Renamed"))
        assertEquals(0, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(37, value["capabilities"]!!.jsonPrimitive.int)
        val again = encoded(reread(row))
        assertEquals(0, again["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(37, again["capabilities"]!!.jsonPrimitive.int)
    }

    @Test fun approvalOnlyOverrideStaysAuthoritative() {
        val row = seed(caps = 37, own = 32)
        assertEquals(setOf(ModelCapabilityUi.APPROVAL), row.capabilities)
        val value = encoded(row.copy(displayName = "Renamed"))
        assertEquals(32, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(37, value["capabilities"]!!.jsonPrimitive.int)
        assertEquals(32, encoded(reread(row))["explicitCapabilities"]!!.jsonPrimitive.int)
    }

    @Test fun mediaOverrideKeepsImageEditingOff() {
        val row = seed(caps = 24, own = 8)
        assertEquals(setOf(ModelCapabilityUi.IMAGE_GENERATION), row.capabilities)
        val value = encoded(row.copy(displayName = "Renamed"), ProviderServiceRoleUi.IMAGE)
        // Base 24 (generation + editing) with explicit 8: the media override
        // is complete and image editing stays OFF.
        assertEquals(8, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(24, value["capabilities"]!!.jsonPrimitive.int)
        assertEquals(0, value["explicitCapabilities"]!!.jsonPrimitive.int and
            ModelCapabilityUi.IMAGE_EDITING.swiftBit)
        // Even an editable-only mask on a non-conversation row is never the
        // conversational legacy shape.
        val legacyLooking = encoded(seed(caps = 24, own = 2).copy(displayName = "r"),
            ProviderServiceRoleUi.IMAGE)
        assertEquals(2, legacyLooking["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(24, legacyLooking["capabilities"]!!.jsonPrimitive.int)
    }

    @Test fun unknownNonEditableExplicitIsNeverRepaired() {
        val futureBit = 1 shl 25
        val row = seed(caps = 37, own = 2 or futureBit)
        val value = encoded(row.copy(displayName = "Renamed"))
        // Unknown non-editable bits make the mask unprovable: it stays exactly
        // as persisted, base included.
        assertEquals(2 or futureBit, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(37, value["capabilities"]!!.jsonPrimitive.int)
    }

    @Test fun missingProvenanceEmptySavedRowStaysClosed() {
        val row = seed(caps = 0, own = null)
        assertNull(row.savedMetadata!!.explicitCapabilitiesRaw)
        val value = encoded(row)
        // A saved row with no explicit decision and no represented capability
        // must not resurrect the new-row default 37: no override is invented
        // and the row stays unusable (fails closed) until the user edits it.
        assertFalse(value.containsKey("explicitCapabilities"))
        assertEquals(0, value["capabilities"]!!.jsonPrimitive.int)
    }

    @Test fun manualConversationVisionToggleEmitsACompleteTextCapableOverride() {
        // The exact Run28 failing shape: a manual conversation row starts at
        // the correct staged default TEXT|TOOLS|APPROVAL = 37, the user turns
        // Vision on, and the old producer persisted only the ownership delta
        // 2. Run admission (explicit is authoritative) then refused with
        // needsConfiguration/modelDisabled before any network call.
        val manual = ModelDraftRowUi(
            draftModelId = "manual-1", savedModelId = null, remoteModelID = "gpt-5",
            displayName = "GPT-5", source = ModelSourceUi.MANUAL, selectedForSave = true,
            capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS,
                ModelCapabilityUi.APPROVAL),
        )
        val vision = ProviderFormLogic.applyModelEdit(listOf(manual),
            manual.copy(capabilities = manual.capabilities + ModelCapabilityUi.VISION), null)
            .first.single()
        val value = encoded(vision)
        // TEXT(1) | VISION(2) | TOOLS(4) | APPROVAL(32) = 39, not the delta 2.
        assertEquals(39, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertEquals(39, value["capabilities"]!!.jsonPrimitive.int)
        assertNotEquals(0, value["explicitCapabilities"]!!.jsonPrimitive.int and
            ProviderFormLogic.TEXT_CAPABILITY_BIT)
    }

    @Test fun stagedModelBodyEqualsCompleteInlineBodyIncludingRetainedMetadata() {
        val original = seed()
        val rows = List(300) { index -> original.copy(draftModelId = "m$index", savedModelId = id,
            remoteModelID = "r$index", displayName = "Model $index") }
        val body = ProviderWire.candidateJson(provider, "openAI", false,
            ProviderDraftSnapshot(role = ProviderServiceRoleUi.CONVERSATION,
                baseUrl = "https://api.example.invalid/v1", models = rows)) { it }
        val wireRows = body["selectedModels"]!!.jsonArray.map { it.jsonObject }
        val received = ArrayList<JsonObject>()
        val stager = object : HostModelSetStager {
            override fun begin(providerID: String, baseResourceID: String, baseVersion: String,
                createIntent: Boolean, routeToken: String) = "msb:v1:" + "a".repeat(32)
            override fun append(stageID: String, index: Int, chunk: ByteArray, routeToken: String): Boolean {
                when (val decoded = Json.parseToJsonElement(chunk.decodeToString())) {
                    is JsonArray -> received.addAll(decoded.map { it.jsonObject })
                    is JsonObject -> received.add(decoded)
                    else -> throw AssertionError("bad trusted chunk")
                }; return true
            }
            override fun seal(stageID: String, expectedCount: Int, routeToken: String) = "ms:v1:" + "a".repeat(32) + "." + "b".repeat(64)
            override fun cancel(stageID: String, routeToken: String) = true
        }
        assertTrue(ProviderModelSetStagingController(stager).stage("editor", provider,
            "provider.$provider", "3", false, "rt:v1:" + "c".repeat(32), wireRows) is StagedModelSet.Frozen)
        assertEquals(wireRows, received)
        assertTrue(received.all { it["pricing"] == Json.parseToJsonElement(pricing) &&
            it["useSurfaces"]!!.jsonPrimitive.int == 5 && it["explicitCapabilities"]!!.jsonPrimitive.int == 0 })
    }
}
