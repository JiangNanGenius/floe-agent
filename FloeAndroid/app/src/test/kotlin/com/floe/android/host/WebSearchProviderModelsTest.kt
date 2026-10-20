// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored NOTRUN. Original web-search model parity and normalization. */
class WebSearchProviderModelsTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun providerJson(
        kind: String,
        id: String = UUID.randomUUID().toString(),
        enabled: Boolean = true,
        priority: Int = 0,
        options: String = """{"summaryEnabled":"true"}""",
    ): JsonObject = json.parseToJsonElement(
        """{"id":"$id","kind":"$kind","displayName":"$kind","credentialAccount":"web-search.$kind","enabled":$enabled,"priority":$priority,"options":$options}""",
    ) as JsonObject

    @Test
    fun allTenOriginalKindsDecode() {
        val expected = listOf(
            "bochaWeb", "bochaAI", "tencentWSA", "volcengine", "brave",
            "tavily", "exa", "googleProgrammable", "searxng", "custom",
        )
        expected.forEach { raw ->
            val decoded = WebSearchProviderConfiguration.fromJson(providerJson(raw))
            assertTrue("$raw must decode", decoded != null)
            assertEquals(raw, decoded!!.kind.raw)
        }
    }

    @Test
    fun unknownKindAndMalformedOptionsAreRejected() {
        assertNull(
            WebSearchProviderConfiguration.fromJson(providerJson("newSearch")),
        )
        assertNull(
            WebSearchProviderConfiguration.fromJson(
                providerJson("brave", options = """{"apiKey":42}"""),
            ),
        )
        val missingId = json.parseToJsonElement(
            """{"kind":"brave","displayName":"Brave","credentialAccount":"web-search.brave","enabled":true,"priority":0,"options":{}}""",
        ) as JsonObject
        assertNull(WebSearchProviderConfiguration.fromJson(missingId))
    }

    @Test
    fun legacyBochaAiCollapsesIntoOneWebProvider() {
        val web = WebSearchProviderConfiguration(
            id = UUID.randomUUID().toString(),
            kind = WebSearchProviderKind.BOCHA_WEB,
            displayName = "Bocha Web",
            endpoint = null,
            credentialAccount = "web-search.bochaWeb",
            enabled = false,
            priority = 0,
        )
        val legacy = WebSearchProviderConfiguration(
            id = UUID.randomUUID().toString(),
            kind = WebSearchProviderKind.BOCHA_AI,
            displayName = "Bocha AI",
            endpoint = null,
            credentialAccount = "web-search.bochaAI",
            enabled = true,
            priority = 1,
        )
        val normalized = normalizeWebSearchConfigurations(listOf(web, legacy))
        assertEquals(1, normalized.size)
        assertEquals(WebSearchProviderKind.BOCHA_WEB, normalized[0].kind)
        assertEquals("Bocha Search", normalized[0].displayName)
        assertEquals("web-search.bochaWeb", normalized[0].credentialAccount)
        assertTrue(normalized[0].enabled)
        assertEquals("true", normalized[0].options["summaryEnabled"])
        assertEquals(web.id, normalized[0].id)
    }

    @Test
    fun legacyBochaAiAloneBecomesWebPreservingItsIdentity() {
        val legacy = WebSearchProviderConfiguration(
            id = UUID.randomUUID().toString(),
            kind = WebSearchProviderKind.BOCHA_AI,
            displayName = "Bocha AI",
            endpoint = null,
            credentialAccount = "web-search.bochaAI",
            enabled = true,
            priority = 0,
            options = mapOf("summaryEnabled" to "false"),
        )
        val normalized = normalizeWebSearchConfigurations(listOf(legacy))
        assertEquals(1, normalized.size)
        assertEquals(legacy.id, normalized[0].id)
        assertEquals(WebSearchProviderKind.BOCHA_WEB, normalized[0].kind)
        assertEquals("web-search.bochaWeb", normalized[0].credentialAccount)
    }

    @Test
    fun credentialRequirementsMirrorTheOriginalProviderSwitch() {
        assertEquals(
            listOf(WebSearchCredentialField.SECRET_ID, WebSearchCredentialField.SECRET_KEY),
            WebSearchProviderKind.TENCENT_WSA.requiredCredentialFields,
        )
        assertEquals(
            listOf(WebSearchCredentialField.API_KEY, WebSearchCredentialField.ENGINE_ID),
            WebSearchProviderKind.GOOGLE_PROGRAMMABLE.requiredCredentialFields,
        )
        assertEquals(
            emptyList<WebSearchCredentialField>(),
            WebSearchProviderKind.SEARXNG.requiredCredentialFields,
        )
        assertEquals(
            listOf(WebSearchCredentialField.API_KEY),
            WebSearchProviderKind.CUSTOM.requiredCredentialFields,
        )
        assertTrue(WebSearchProviderKind.CUSTOM.requiresEndpoint)
        assertTrue(WebSearchProviderKind.SEARXNG.requiresEndpoint)
        assertFalse(WebSearchProviderKind.BRAVE.requiresEndpoint)
        assertFalse(WebSearchProviderKind.SEARXNG.requiresCredential)
        assertTrue(WebSearchProviderKind.CUSTOM.requiresCredential)
    }

    @Test
    fun credentialEncodingIsTheOriginalValuesObject() {
        val bytes = WebSearchCredential(
            mapOf("apiKey" to "key", "engineId" to "engine"),
        ).encoded()
        val text = String(bytes, Charsets.UTF_8)
        val root = json.parseToJsonElement(text) as JsonObject
        val values = root["values"] as JsonObject
        assertEquals(1, root.size)
        assertEquals("key", values["apiKey"].toString().trim('"'))
        assertEquals("engine", values["engineId"].toString().trim('"'))
        assertFalse(text.contains("secret"))
    }

    @Test
    fun credentialSetRequiresEveryMandatoryField() {
        val incomplete = WebSearchCredential(mapOf("secretId" to "id"))
        assertFalse(incomplete.satisfies(WebSearchProviderKind.TENCENT_WSA))
        val complete = WebSearchCredential(mapOf("secretId" to "id", "secretKey" to "key"))
        assertTrue(complete.satisfies(WebSearchProviderKind.TENCENT_WSA))
        val google = WebSearchCredential(mapOf("apiKey" to "key", "engineId" to "engine"))
        assertTrue(google.satisfies(WebSearchProviderKind.GOOGLE_PROGRAMMABLE))
        val anonymous = WebSearchCredential(emptyMap())
        assertFalse(anonymous.satisfies(WebSearchProviderKind.SEARXNG))
    }

    @Test
    fun endpointValidationRejectsUserInfoAndNonHttp() {
        assertEquals(null, normalizeWebSearchEndpoint("  ").getOrNull())
        assertEquals(
            "https://search.example.com/api",
            normalizeWebSearchEndpoint("https://search.example.com/api").getOrNull(),
        )
        assertEquals(
            "http://localhost:8080/search",
            normalizeWebSearchEndpoint("http://localhost:8080/search").getOrNull(),
        )
        assertTrue(normalizeWebSearchEndpoint("https://user:pass@example.com").isFailure)
        assertTrue(normalizeWebSearchEndpoint("ftp://example.com").isFailure)
        assertTrue(normalizeWebSearchEndpoint("https:///missing").isFailure)
    }

    @Test
    fun optionsCannotCarryCredentialShapedKeys() {
        assertTrue(webSearchOptionsCarryNoSecrets(mapOf("summaryEnabled" to "true")))
        assertFalse(webSearchOptionsCarryNoSecrets(mapOf("apiKey" to "x")))
        assertFalse(webSearchOptionsCarryNoSecrets(mapOf("Authorization" to "x")))
        assertFalse(webSearchOptionsCarryNoSecrets(mapOf("client_secret" to "x")))
    }

    @Test
    fun presetsAreTheEightOriginalKindsWithStableIdentity() {
        assertEquals(8, WebSearchProviderPresets.kinds.size)
        assertEquals(
            "bochaWeb",
            WebSearchProviderPresets.kinds.first().raw,
        )
        assertEquals("searxng", WebSearchProviderPresets.kinds.last().raw)
        val ids = WebSearchProviderPresets.kinds.map { WebSearchProviderPresets.presetId(it) }
        assertEquals(ids.size, ids.toSet().size)
        assertEquals(ids, WebSearchProviderPresets.kinds.map { WebSearchProviderPresets.presetId(it) })
        ids.forEach { assertTrue(isCanonicalUUID(it)) }
        assertEquals(
            "web-search.bochaWeb",
            WebSearchProviderPresets.credentialAccount(WebSearchProviderKind.BOCHA_WEB),
        )
    }
}
