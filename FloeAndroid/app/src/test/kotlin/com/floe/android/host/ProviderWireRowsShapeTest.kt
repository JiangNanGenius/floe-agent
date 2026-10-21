// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.ProviderCredentialStateUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the ACTUAL provider-list wire contract after Main's 2026-10-20
 * OBJECT-only carrier decision: the G02 domain-to-carrier binder composes
 * the ConfigPageComposer LIST into the explicit `{"rows":[...]}` OBJECT,
 * and the App reads exactly that shape.
 *
 *  * a bare top-level array decodes to NULL (the carrier can never legally
 *    deliver one; silently decoding it would mask a carrier regression),
 *  * an object without `rows` decodes to NULL (no empty-list substitute),
 *  * `{"rows":[]}` is the honest EMPTY provider list,
 *  * real rows decode with the canonical `provider.<uuid>/<syncRevision>`
 *    CAS revision derived from the persisted values.
 */
class ProviderWireRowsShapeTest {

    private val json = Json { ignoreUnknownKeys = false }

    private fun providerRow(id: String, syncRevision: Long, configured: Boolean,
                            opaque: String?,
                            presetID: String? = null,
                            headers: Map<String, String> = emptyMap()): JsonObject = JsonObject(mapOf(
        "id" to JsonPrimitive(id),
        "kind" to JsonPrimitive("openai"),
        "wireProtocol" to JsonPrimitive("openAIChatCompletions"),
        "baseURL" to JsonPrimitive("https://example.invalid/v1"),
        "displayName" to JsonPrimitive("QA Provider"),
        "region" to JsonPrimitive("global"),
        "isEnabled" to JsonPrimitive(true),
        "allowsPlainHTTP" to JsonPrimitive(false),
        "toolNameCompatibility" to JsonPrimitive("strict"),
        "createdAt" to JsonPrimitive("2026-10-20T00:00:00.000Z"),
        "updatedAt" to JsonPrimitive("2026-10-20T00:00:00.000Z"),
        "syncRevision" to JsonPrimitive(syncRevision),
        "secret" to JsonObject(buildMap {
            put("configured", JsonPrimitive(configured))
            if (opaque != null) put("opaqueReference", JsonPrimitive(opaque))
            put("synchronizable", JsonPrimitive(true))
        }),
    ) + buildMap {
        if (presetID != null) put("presetID", JsonPrimitive(presetID))
        if (headers.isNotEmpty()) {
            put("nonSecretHeaders", JsonObject(headers.mapValues { JsonPrimitive(it.value) }))
        }
    })

    @Test
    fun bareArrayIsNotADecodableProviderCarrier() {
        val bare = json.parseToJsonElement("[]")
        assertNull(ProviderWire.decodeProviderRows(bare))
        val oneRow = json.parseToJsonElement(
            providerRow("3F6A8C0E-1111-4D2B-9B1A-0A0A0A0A0001", 1, false, null)
                .toString())
        assertNull("a top-level array must never be silently accepted",
            ProviderWire.decodeProviderRows(JsonArray(listOf(oneRow))))
    }

    @Test
    fun objectWithoutRowsMemberIsADecodeFailureNotAnEmptyFallback() {
        assertNull(ProviderWire.decodeProviderRows(JsonObject(emptyMap())))
        assertNull(ProviderWire.decodeProviderRows(
            JsonObject(mapOf("items" to JsonArray(emptyList())))))
    }

    @Test
    fun emptyRowsObjectIsTheHonestEmptyList() {
        val rows = ProviderWire.decodeProviderRows(
            json.parseToJsonElement("{\"rows\":[]}"))
        assertNotNull(rows)
        assertEquals(0, rows!!.conversationProviders.size)
        assertEquals(0, rows.imageProviders.size)
        assertEquals(0, rows.videoProviders.size)
    }

    @Test
    fun realRowsObjectDecodesIdentityStatusAndCanonicalRevision() {
        val id = "3F6A8C0E-2222-4D2B-9B1A-0A0A0A0A0002"
        val opaque = "ref:v1:0123456789abcdef0123456789abcdef"
        val value = JsonObject(mapOf(
            "rows" to JsonArray(listOf(
                providerRow(id, 7, true, opaque),
            )),
        ))
        val rows = assertNotNull(ProviderWire.decodeProviderRows(value))
        val decoded = ProviderWire.decodeProviderRows(value)!!
        assertEquals(1, decoded.conversationProviders.size)
        val ui = decoded.conversationProviders.first()
        assertEquals(id, ui.providerId)
        assertEquals("QA Provider", ui.displayName)
        assertEquals("https://example.invalid/v1", ui.endpointSummary)
        assertEquals(ProviderCredentialStateUi.CONFIGURED, ui.credentialState)
        // Canonical persisted CAS revision (ConfigRevision.provider): the
        // follow-up save/delete must use provider.<uuid> / <syncRevision>.
        val revision = ProviderHostControllerRevisions.revision(id)
        assertNotNull("canonical revision must be derived", revision)
        assertEquals("provider.$id", revision!!.resourceID)
        assertEquals("7", revision.version)
    }

    @Test
    fun additiveProjectionFeedsLosslessEditorMetadata() {
        val id = "3F6A8C0E-3333-4D2B-9B1A-0A0A0A0A0003"
        val value = JsonObject(mapOf(
            "rows" to JsonArray(listOf(
                providerRow(id, 2, true, null, presetID = "deepseek",
                    headers = mapOf("X-Org" to "qa", "X-Route" to "direct")),
            )),
        ))
        ProviderWire.decodeProviderRows(value)
        val extras = ProviderWire.extrasFor(id)
        assertNotNull(extras)
        assertEquals("deepseek", extras!!.presetID)
        assertEquals("X-Org: qa\nX-Route: direct", extras.nonSecretHeaders)
        assertEquals("QA Provider", extras.displayName)

        // Absent additive fields stay honest: no invented preset/headers, and
        // the null display name is not replaced by the row-id fallback.
        val legacyID = "3F6A8C0E-4444-4D2B-9B1A-0A0A0A0A0004"
        ProviderWire.decodeProviderRows(JsonObject(mapOf(
            "rows" to JsonArray(listOf(providerRow(legacyID, 1, false, null))))))
        val legacy = ProviderWire.extrasFor(legacyID)
        assertNotNull(legacy)
        assertNull(legacy!!.presetID)
        assertEquals("", legacy.nonSecretHeaders)
        assertEquals("QA Provider", legacy.displayName)
    }
}
