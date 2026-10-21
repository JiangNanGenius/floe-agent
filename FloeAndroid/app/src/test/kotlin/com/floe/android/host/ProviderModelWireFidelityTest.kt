// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Real production decoder -> exact seed -> edited draft -> real candidate.
 * Source-only until the coherent Root/App batch is ready to compile. */
class ProviderModelWireFidelityTest {
    private val provider = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private val pricing = "{\"currency\":\"USD\",\"inputPerMillion\":0.1234567890123456789,\"outputPerMillion\":1.25}"
    private fun seed(caps: Int = 5, own: Int = 0): ModelDraftRowUi {
        val page = Json.parseToJsonElement("""{"rows":[{"id":"$id","providerID":"$provider", "remoteModelID":"r","displayName":"Saved","limits":{"contextTokens":4096,"maxOutputTokens":0},"capabilities":$caps,"pricing":$pricing,"useSurfaces":5,"explicitCapabilities":$own,"isEnabled":true,"isHiddenFromPrimaryPicker":false}]}""")
        return ProviderWire.savedModelDraft(ProviderWire.decodeModelRows(page)!!.single())
    }
    private fun candidate(row: ModelDraftRowUi): JsonObject = ProviderWire.candidateJson(
        providerID = provider, kind = "openAI", createIntent = false,
        draft = ProviderDraftSnapshot(role = ProviderServiceRoleUi.CONVERSATION,
            baseUrl = "https://api.example.invalid/v1", models = listOf(row)), modelUUID = { id })
    private fun encoded(row: ModelDraftRowUi) = candidate(row)["selectedModels"]!!.jsonArray.single().jsonObject

    @Test fun unchangedSavedModelKeepsPricingPrecisionSurfaceZeroAndNilReasoning() {
        val row = seed().copy(displayName = "Renamed")
        val value = encoded(row)
        assertEquals(Json.parseToJsonElement(pricing), value["pricing"])
        assertEquals(5, value["useSurfaces"]!!.jsonPrimitive.int)
        assertEquals(0, value["explicitCapabilities"]!!.jsonPrimitive.int)
        assertFalse(value.containsKey("reasoningEffort"))
        assertEquals("Renamed", value["displayName"]!!.jsonPrimitive.content)
        // A later decode cannot replace the exact older editor metadata.
        seed(caps = 1, own = 4)
        assertEquals(value, encoded(row))
    }

    @Test fun savedZeroAndUnrepresentedBitsNeverReceiveDefaultCapabilities() {
        assertEquals(0, encoded(seed(caps = 0))["capabilities"]!!.jsonPrimitive.int)
        val futureBit = 1 shl 25
        assertEquals(1 or futureBit, encoded(seed(caps = 1 or futureBit))["capabilities"]!!.jsonPrimitive.int)
        val original = seed(caps = 37, own = 2)
        val edited = ProviderFormLogic.applyModelEdit(listOf(original),
            original.copy(capabilities = original.capabilities - ModelCapabilityUi.TOOLS), null).first.single()
        assertEquals(6, encoded(edited)["explicitCapabilities"]!!.jsonPrimitive.int)
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
