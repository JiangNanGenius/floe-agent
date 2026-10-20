// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.ModelCapabilityUi
import com.floe.android.feature.providers.ModelDraftRowUi
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.ReasoningEffortUi
import com.floe.android.feature.providers.SupplierChoice
import com.floe.android.feature.providers.WireProtocolUi
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Producer-to-reader contract pins for the observed 2026-10-20 UI blockers
 * (Main dumps ui-012/013/014): the provider chooser showed "No matching
 * providers" and the editor stayed on "Loading configuration…".
 *
 * These tests pin the REAL wire shapes:
 *  * `config.catalog.search` accepts ONLY the closed {query,filter} payload
 *    (the previous {"operation":"catalog.refresh"} payload was refused as
 *    invalidEnvelope/catalogQueryMissing);
 *  * its completed page is the ConfigPageComposer LIST delivered as the
 *    frozen OBJECT {"rows":[...]} of ORIGINAL ProviderCatalogEntry rows —
 *    NOT the authored officialProviders/presets document;
 *  * the save candidate is the EXACT closed ProviderSaveCandidate grammar
 *    (UUID id, ProviderKind kind, object headers, integer capability bits,
 *    full ModelProfile rows, UUID default model) so the real save cannot be
 *    refused after a successful form entry.
 */
class ProviderEditorCatalogContractTest {

    @Test
    fun catalogRequestPayloadIsTheClosedQueryFilterShape() {
        val payload = ProviderWire.catalogRequestPayload("all")
        assertEquals(setOf("query", "filter"), payload.keys)
        assertEquals("", payload["query"]!!.jsonPrimitive.content)
        assertEquals("all", payload["filter"]!!.jsonPrimitive.content)
        // Every filter the UI offers is one of the ORIGINAL enum raw values.
        for (filter in listOf("all", "configured", "available", "local")) {
            assertEquals(filter,
                ProviderWire.catalogRequestPayload(filter)["filter"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun decodeCatalogRowsReadsTheRealCatalogEntryPage() {
        val page = JsonObject(mapOf(
            "rows" to JsonArray(listOf(
                JsonObject(mapOf(
                    "presetID" to JsonPrimitive("deepseek"),
                    "name" to JsonPrimitive("DeepSeek"),
                    "aliases" to JsonArray(listOf(JsonPrimitive("深度求索"))),
                    "kind" to JsonPrimitive("openAI"),
                    "defaultProtocol" to JsonPrimitive("openai-chat-completions"),
                    "baseURL" to JsonPrimitive("https://api.deepseek.com/v1"),
                    "domains" to JsonArray(listOf(JsonPrimitive("api.deepseek.com"))),
                    "models" to JsonArray(listOf(JsonPrimitive("deepseek-chat"),
                        JsonPrimitive("deepseek-reasoner"))),
                    "availability" to JsonPrimitive("available"),
                    "upstreamID" to JsonPrimitive("deepseek"),
                    "authStyle" to JsonPrimitive("bearer"),
                    "toolNameCompatibility" to JsonPrimitive(true),
                    "serviceOffers" to JsonArray(listOf(
                        JsonObject(mapOf("role" to JsonPrimitive("image"))),
                    )),
                )),
            )),
        ))
        val entry = ProviderWire.decodeCatalogRows(page)!!.single()
        assertEquals("deepseek", entry.catalogEntryId)
        assertEquals("DeepSeek", entry.name)
        assertEquals(WireProtocolUi.OPENAI_CHAT_COMPLETIONS, entry.defaultProtocol)
        assertEquals("api.deepseek.com", entry.endpointHost)
        assertEquals("https://api.deepseek.com/v1", entry.endpointAbsoluteString)
        assertEquals(2, entry.modelCount)
        assertEquals(listOf("deepseek-chat", "deepseek-reasoner"), entry.modelKeywords)
        assertTrue(entry.servedRoles.contains(ProviderServiceRoleUi.CONVERSATION))
        assertTrue(entry.servedRoles.contains(ProviderServiceRoleUi.IMAGE))
        assertFalse(entry.isLocalEndpoint)
        assertTrue(entry.suggestsToolNameCompatibility)
        // The kind mapping the save candidate needs comes from this page.
        assertEquals(mapOf("deepseek" to "openAI"), ProviderWire.catalogKinds(page))
    }

    @Test
    fun decodeCatalogRowsRejectsTheAuthoredShapeAndBareArray() {
        // Old authored document shape: never a valid page.
        val authored = JsonObject(mapOf(
            "officialProviders" to JsonArray(listOf(JsonObject(mapOf(
                "catalogEntryId" to JsonPrimitive("x"), "name" to JsonPrimitive("X"))))),
            "presets" to JsonArray(emptyList()),
        ))
        assertNull(ProviderWire.decodeCatalogRows(authored))
        // Bare array (pre-binder shape) is refused by the OBJECT carrier.
        assertNull(ProviderWire.decodeCatalogRows(JsonArray(emptyList())))
        // A rows object whose entries are not catalog rows decodes to none —
        // never invented rows.
        assertTrue(ProviderWire.decodeCatalogRows(
            JsonObject(mapOf("rows" to JsonArray(listOf(JsonPrimitive("x"))))))
            ?.isEmpty() == true)
    }

    @Test
    fun saveCandidateMatchesTheClosedNativeGrammar() {
        val providerID = UUID.randomUUID().toString()
        val modelUUID = UUID.randomUUID().toString()
        val draft = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            displayName = "Floe G02 QA",
            supplier = SupplierChoice(
                presetId = "custom",
                displayName = "Custom endpoint",
                catalogEntryId = null,
                absoluteEndpointDefault = "",
                routeFamily = "",
                authStyle = "",
                supportsPlainHttpChoice = false,
                suggestsToolNameCompatibility = false,
            ),
            protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            baseUrl = "https://example.invalid/v1",
            nonSecretHeaders = "X-Title: Floe QA\n\nX-Route: qa",
            models = listOf(ModelDraftRowUi(
                draftModelId = "manual-1",
                savedModelId = null,
                remoteModelID = "deepseek-flash",
                displayName = "DeepSeek Flash",
                enabled = true,
                capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS),
                reasoningEffort = ReasoningEffortUi.AUTOMATIC,
                contextTokens = 128_000,
                maxOutputTokens = 8_192,
                selectedForSave = true,
            )),
            defaultModelDraftId = "manual-1",
        )
        val candidate = ProviderWire.candidateJson(
            providerID = providerID,
            kind = "custom",
            createIntent = true,
            draft = draft,
            modelUUID = { modelUUID },
        )
        // EXACT closed key set (RuntimeFacadeConfigIngress allowedKeys).
        val allowed = setOf(
            "id", "kind", "wireProtocol", "baseURL", "displayName", "presetID",
            "nonSecretHeaders", "isEnabled", "allowsPlainHTTP",
            "toolNameCompatibility", "syncEnabled", "selectedModels",
            "managedCapabilities", "serviceRoleIsConversation", "defaultModelID",
            "createIntent",
        )
        assertTrue("unexpected candidate keys: ${candidate.keys - allowed}",
            allowed.containsAll(candidate.keys))
        assertEquals(providerID, candidate["id"]!!.jsonPrimitive.content)
        assertEquals("custom", candidate["kind"]!!.jsonPrimitive.content)
        assertEquals("openai-chat-completions",
            candidate["wireProtocol"]!!.jsonPrimitive.content)
        assertEquals("https://example.invalid/v1", candidate["baseURL"]!!.jsonPrimitive.content)
        assertEquals("Floe G02 QA", candidate["displayName"]!!.jsonPrimitive.content)
        assertEquals("custom", candidate["presetID"]!!.jsonPrimitive.content)
        assertFalse("local sync must stay off", candidate["syncEnabled"]!!.jsonPrimitive.boolean)
        assertTrue(candidate["createIntent"]!!.jsonPrimitive.boolean)
        assertEquals(5, candidate["managedCapabilities"]!!.jsonPrimitive.int) // TEXT|TOOLS
        // Headers are the closed OBJECT, not the previous raw string.
        val headers = candidate["nonSecretHeaders"] as JsonObject
        assertEquals("Floe QA", headers["X-Title"]!!.jsonPrimitive.content)
        assertEquals("qa", headers["X-Route"]!!.jsonPrimitive.content)
        // The staged model is a FULL ModelProfile row.
        val models = candidate["selectedModels"] as JsonArray
        assertEquals(1, models.size)
        val model = models[0] as JsonObject
        assertEquals(modelUUID, model["id"]!!.jsonPrimitive.content)
        assertEquals(providerID, model["providerID"]!!.jsonPrimitive.content)
        assertEquals("deepseek-flash", model["remoteModelID"]!!.jsonPrimitive.content)
        val limits = model["limits"] as JsonObject
        assertEquals(128_000, limits["contextTokens"]!!.jsonPrimitive.int)
        assertEquals(8_192, limits["maxOutputTokens"]!!.jsonPrimitive.int)
        assertEquals(5, model["capabilities"]!!.jsonPrimitive.int) // TEXT|TOOLS
        assertEquals("automatic", model["reasoningEffort"]!!.jsonPrimitive.content)
        assertEquals(modelUUID, candidate["defaultModelID"]!!.jsonPrimitive.content)
        UUID.fromString(candidate["id"]!!.jsonPrimitive.content)
        UUID.fromString(candidate["defaultModelID"]!!.jsonPrimitive.content)
    }

    @Test
    fun emptyCapabilitiesDefaultToADefaultTextModelAndNoPhantomDefault() {
        val providerID = UUID.randomUUID().toString()
        val draft = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            displayName = "QA",
            baseUrl = "https://example.invalid/v1",
            models = listOf(ModelDraftRowUi(
                draftModelId = "m1",
                savedModelId = null,
                remoteModelID = "deepseek-flash",
                displayName = "deepseek-flash",
                selectedForSave = true,
            )),
        )
        val candidate = ProviderWire.candidateJson(
            providerID = providerID, kind = "custom", createIntent = true,
            draft = draft, modelUUID = { UUID.randomUUID().toString() })
        val model = (candidate["selectedModels"] as JsonArray)[0] as JsonObject
        // ORIGINAL defaultTextModel: text|tools|approval = 1|4|32 = 37.
        assertEquals(37, model["capabilities"]!!.jsonPrimitive.int)
        assertEquals(37, candidate["managedCapabilities"]!!.jsonPrimitive.int)
        // No default model id is invented when the draft names none.
        assertNull(candidate["defaultModelID"])
        assertFalse(candidate.containsKey("presetID"))
    }

    @Test
    fun unselectedModelsAreNeverSaved() {
        val draft = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            displayName = "QA",
            baseUrl = "https://example.invalid/v1",
            models = listOf(
                ModelDraftRowUi(draftModelId = "a", savedModelId = null,
                    remoteModelID = "a", displayName = "a", selectedForSave = true),
                ModelDraftRowUi(draftModelId = "b", savedModelId = null,
                    remoteModelID = "b", displayName = "b", selectedForSave = false),
            ),
        )
        val candidate = ProviderWire.candidateJson(
            providerID = UUID.randomUUID().toString(), kind = "custom",
            createIntent = true, draft = draft,
            modelUUID = { UUID.randomUUID().toString() })
        val models = candidate["selectedModels"] as JsonArray
        assertEquals(1, models.size)
        assertEquals("a", (models[0] as JsonObject)["remoteModelID"]!!.jsonPrimitive.content)
    }
}
