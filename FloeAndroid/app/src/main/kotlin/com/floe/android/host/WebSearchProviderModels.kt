// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.net.URI
import java.util.UUID
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Secret-free mirror of the ORIGINAL FloeAgent web-search metadata
 * (`FloeAgent/Sources/FloeExecution/WebRetrievalModels.swift`). All ten
 * persisted kinds are decodable, including the legacy `bochaAI`; the
 * settings/runtime boundary normalizes Bocha AI and Web into one provider,
 * exactly like `WebSearchSettingsCenter.normalizedProviders`.
 *
 * `credentialAccount` is an account IDENTIFIER, never a value. The encoded
 * `WebSearchCredential` value map is created only inside the editor's RAM
 * attempt and travels only as one-shot native ingress bytes.
 */
enum class WebSearchProviderKind(val raw: String) {
    BOCHA_WEB("bochaWeb"),
    BOCHA_AI("bochaAI"),
    TENCENT_WSA("tencentWSA"),
    VOLCENGINE("volcengine"),
    BRAVE("brave"),
    TAVILY("tavily"),
    EXA("exa"),
    GOOGLE_PROGRAMMABLE("googleProgrammable"),
    SEARXNG("searxng"),
    CUSTOM("custom");

    val requiresCredential: Boolean
        get() = this != SEARXNG

    /** SearXNG must be self-hosted; Volcengine/custom are endpoint-addressed. */
    val requiresEndpoint: Boolean
        get() = this == SEARXNG || this == VOLCENGINE || this == CUSTOM

    /**
     * Exact credential field requirements from the ORIGINAL provider switch:
     * Tencent uses SecretId+SecretKey; Google uses API key+engine ID; every
     * other credential-requiring kind uses API key. SearXNG is anonymous by
     * default and may optionally carry an API key.
     */
    val requiredCredentialFields: List<WebSearchCredentialField>
        get() = when (this) {
            TENCENT_WSA -> listOf(
                WebSearchCredentialField.SECRET_ID,
                WebSearchCredentialField.SECRET_KEY,
            )
            GOOGLE_PROGRAMMABLE -> listOf(
                WebSearchCredentialField.API_KEY,
                WebSearchCredentialField.ENGINE_ID,
            )
            SEARXNG -> emptyList()
            else -> listOf(WebSearchCredentialField.API_KEY)
        }

    val editableCredentialFields: List<WebSearchCredentialField>
        get() = when (this) {
            TENCENT_WSA -> listOf(
                WebSearchCredentialField.SECRET_ID,
                WebSearchCredentialField.SECRET_KEY,
            )
            GOOGLE_PROGRAMMABLE -> listOf(
                WebSearchCredentialField.API_KEY,
                WebSearchCredentialField.ENGINE_ID,
            )
            else -> listOf(WebSearchCredentialField.API_KEY)
        }

    companion object {
        fun fromRaw(value: String): WebSearchProviderKind? =
            entries.firstOrNull { it.raw == value }
    }
}

enum class WebSearchCredentialField(val key: String) {
    API_KEY("apiKey"),
    SECRET_ID("secretId"),
    SECRET_KEY("secretKey"),
    ENGINE_ID("engineId"),
}

/** Typed credential presence projected by the native get reply. */
enum class WebSearchCredentialState(val raw: String) {
    AVAILABLE("available"),
    NO_CREDENTIAL_REQUIRED("noCredentialRequired"),
    GATEWAY_UNREGISTERED("gatewayUnregistered"),
    SECRET_MISSING("secretMissing"),
    SECRET_LOCKED("secretLocked"),
    SECRET_INVALIDATED("secretInvalidated"),
    OUTCOME_UNKNOWN("outcomeUnknown"),
    UNKNOWN("unknown");

    val isPresent: Boolean
        get() = this == AVAILABLE || this == NO_CREDENTIAL_REQUIRED

    companion object {
        fun fromRaw(value: String?): WebSearchCredentialState =
            entries.firstOrNull { it.raw == value } ?: UNKNOWN
    }
}

/** Secret-free provider metadata; one persisted configuration. */
data class WebSearchProviderConfiguration(
    val id: String,
    val kind: WebSearchProviderKind,
    val displayName: String,
    val endpoint: String?,
    val credentialAccount: String,
    val enabled: Boolean,
    val priority: Int,
    val region: String? = null,
    val options: Map<String, String> = emptyMap(),
) {
    fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonElement>(
            "id" to JsonPrimitive(id),
            "kind" to JsonPrimitive(kind.raw),
            "displayName" to JsonPrimitive(displayName),
            "credentialAccount" to JsonPrimitive(credentialAccount),
            "enabled" to JsonPrimitive(enabled),
            "priority" to JsonPrimitive(priority),
            "options" to JsonObject(options.toSortedMap().mapValues { JsonPrimitive(it.value) }),
        )
        endpoint?.let { members["endpoint"] = JsonPrimitive(it) }
        region?.let { members["region"] = JsonPrimitive(it) }
        return JsonObject(members)
    }

    companion object {
        fun fromJson(value: JsonObject): WebSearchProviderConfiguration? {
            val id = value.stringStrict("id") ?: return null
            if (!isCanonicalUUID(id)) return null
            val kind = value.stringStrict("kind")?.let(WebSearchProviderKind::fromRaw) ?: return null
            val displayName = value.stringStrict("displayName") ?: return null
            if (displayName.isBlank() ||
                displayName.toByteArray(Charsets.UTF_8).size > 256
            ) return null
            val credentialAccount = value.stringStrict("credentialAccount") ?: return null
            if (credentialAccount.isBlank() ||
                credentialAccount.toByteArray(Charsets.UTF_8).size > 128
            ) return null
            val enabled = value.boolStrict("enabled") ?: return null
            val priorityLong = value.longStrict("priority") ?: return null
            if (priorityLong < 0 || priorityLong > Int.MAX_VALUE) return null
            val endpoint = value.stringStrict("endpoint")
            val region = value.stringStrict("region")
            val options = decodeOptions(value["options"]) ?: return null
            return WebSearchProviderConfiguration(
                id = id,
                kind = kind,
                displayName = displayName,
                endpoint = endpoint,
                credentialAccount = credentialAccount,
                enabled = enabled,
                priority = priorityLong.toInt(),
                region = region,
                options = options,
            )
        }

        private fun decodeOptions(element: JsonElement?): Map<String, String>? {
            if (element == null || element is JsonNull) return emptyMap()
            val objectValue = element as? JsonObject ?: return null
            val result = LinkedHashMap<String, String>()
            for ((key, raw) in objectValue) {
                val prim = raw as? JsonPrimitive ?: return null
                if (!prim.isString) return null
                val text = prim.contentOrNull ?: return null
                if (key.isBlank() || key.length > 64 || text.length > 512) return null
                result[key] = text
            }
            return result
        }
    }
}

/** One exact editor credential value map; RAM-only until native ingress. */
data class WebSearchCredential(
    val values: Map<String, String>,
) {
    fun encoded(): ByteArray {
        val valuesObject = JsonObject(
            values.toSortedMap().mapValues { JsonPrimitive(it.value) })
        val root = JsonObject(mapOf("values" to valuesObject))
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    fun satisfies(kind: WebSearchProviderKind): Boolean {
        if (kind == WebSearchProviderKind.SEARXNG) {
            // Anonymous SearXNG uses Keep; an explicit Set must carry a key.
            return values[WebSearchCredentialField.API_KEY.key]?.isNotBlank() == true
        }
        return kind.requiredCredentialFields.all { field ->
            values[field.key]?.isNotBlank() == true
        }
    }

    companion object {
        fun forKind(kind: WebSearchProviderKind, raw: Map<String, String>): WebSearchCredential {
            val allowed = kind.editableCredentialFields.map { it.key }.toSet()
            val cleaned = raw.entries
                .filter { it.key in allowed }
                .associate { it.key to it.value.trim() }
                .filterValues { it.isNotBlank() }
            return WebSearchCredential(cleaned)
        }
    }
}

/** One list row: persisted configuration plus typed credential projection. */
data class WebSearchProviderRow(
    val configuration: WebSearchProviderConfiguration,
    val credentialState: WebSearchCredentialState,
    val configured: Boolean,
)

/**
 * The eight original iOS presets. IDs are deterministic so an unsaved preset
 * edited on this device is the same identity on the next list recomposition;
 * a saved row keeps whatever UUID the native store returns.
 */
object WebSearchProviderPresets {
    val kinds: List<WebSearchProviderKind> = listOf(
        WebSearchProviderKind.BOCHA_WEB,
        WebSearchProviderKind.TENCENT_WSA,
        WebSearchProviderKind.VOLCENGINE,
        WebSearchProviderKind.BRAVE,
        WebSearchProviderKind.TAVILY,
        WebSearchProviderKind.EXA,
        WebSearchProviderKind.GOOGLE_PROGRAMMABLE,
        WebSearchProviderKind.SEARXNG,
    )

    fun presetId(kind: WebSearchProviderKind): String =
        UUID.nameUUIDFromBytes(
            "floe.android.websearch.preset.${kind.raw}".toByteArray(Charsets.UTF_8),
        ).toString()

    fun displayName(kind: WebSearchProviderKind): String = when (kind) {
        WebSearchProviderKind.BOCHA_WEB, WebSearchProviderKind.BOCHA_AI -> "Bocha Search"
        WebSearchProviderKind.TENCENT_WSA -> "Tencent Cloud WSA"
        WebSearchProviderKind.VOLCENGINE -> "Volcengine Web Search"
        WebSearchProviderKind.BRAVE -> "Brave Search"
        WebSearchProviderKind.TAVILY -> "Tavily"
        WebSearchProviderKind.EXA -> "Exa"
        WebSearchProviderKind.GOOGLE_PROGRAMMABLE -> "Google Programmable Search"
        WebSearchProviderKind.SEARXNG -> "SearXNG"
        WebSearchProviderKind.CUSTOM -> "Custom"
    }

    fun configuration(kind: WebSearchProviderKind, priority: Int): WebSearchProviderConfiguration =
        WebSearchProviderConfiguration(
            id = presetId(kind),
            kind = kind,
            displayName = displayName(kind),
            endpoint = null,
            credentialAccount = credentialAccount(kind),
            enabled = false,
            priority = priority,
        )

    fun all(): List<WebSearchProviderConfiguration> =
        kinds.mapIndexed { index, kind -> configuration(kind, index) }

    fun credentialAccount(kind: WebSearchProviderKind): String =
        if (kind == WebSearchProviderKind.BOCHA_AI) "web-search.bochaWeb"
        else "web-search.${kind.raw}"
}

/**
 * Original settings-boundary normalization: legacy `bochaAI` collapses into
 * the single `bochaWeb` provider (merged enabled flag, summary option, stable
 * display name/account). Custom and every other kind are preserved.
 */
fun normalizeWebSearchConfigurations(
    source: List<WebSearchProviderConfiguration>,
): List<WebSearchProviderConfiguration> {
    val legacyAI = source.filter { it.kind == WebSearchProviderKind.BOCHA_AI }
    val result = source.filter { it.kind != WebSearchProviderKind.BOCHA_AI }.toMutableList()
    val webIndex = result.indexOfFirst { it.kind == WebSearchProviderKind.BOCHA_WEB }
    if (webIndex >= 0) {
        val current = result[webIndex]
        val options = if (legacyAI.isNotEmpty()) {
            current.options + (
                "summaryEnabled" to (current.options["summaryEnabled"] ?: "true")
                )
        } else {
            current.options
        }
        result[webIndex] = current.copy(
            kind = WebSearchProviderKind.BOCHA_WEB,
            displayName = "Bocha Search",
            credentialAccount = "web-search.bochaWeb",
            enabled = current.enabled || legacyAI.any { it.enabled },
            options = options,
        )
    } else if (legacyAI.isNotEmpty()) {
        val legacy = legacyAI.first()
        result += legacy.copy(
            kind = WebSearchProviderKind.BOCHA_WEB,
            displayName = "Bocha Search",
            credentialAccount = "web-search.bochaWeb",
            options = legacy.options + (
                "summaryEnabled" to (legacy.options["summaryEnabled"] ?: "true")
                ),
        )
    }
    return result.sortedWith(
        compareBy<WebSearchProviderConfiguration>(
            { it.priority },
            { it.displayName.lowercase() },
            { it.id },
        ),
    )
}

/** True for a parseable UUID string. Canonical case is preserved. */
fun isCanonicalUUID(value: String): Boolean =
    value.length == 36 && runCatching { UUID.fromString(value) }.isSuccess

/**
 * Validate and normalize the editor's endpoint text. Blank means "use the
 * provider default" (nil). `http` stays allowed because the original service
 * accepts it for self-hosted/custom endpoints; userinfo is never allowed.
 */
fun normalizeWebSearchEndpoint(raw: String): Result<String?> {
    val text = raw.trim()
    if (text.isEmpty()) return Result.success(null)
    if (text.any { it.isISOControl() || it.isWhitespace() }) {
        return Result.failure(IllegalArgumentException("endpointInvalid"))
    }
    val uri = try {
        URI(text)
    } catch (t: Throwable) {
        return Result.failure(IllegalArgumentException("endpointInvalid"))
    }
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") {
        return Result.failure(IllegalArgumentException("endpointInvalid"))
    }
    if (uri.host.isNullOrBlank()) {
        return Result.failure(IllegalArgumentException("endpointInvalid"))
    }
    if (uri.userInfo != null) {
        return Result.failure(IllegalArgumentException("endpointInvalid"))
    }
    return Result.success(text)
}

/**
 * The native settings store refuses credential-shaped option keys so a value
 * can never be smuggled through metadata JSON. Mirror that closed rule early.
 */
fun webSearchOptionsCarryNoSecrets(options: Map<String, String>): Boolean {
    val banned = listOf("apikey", "api_key", "secret", "token", "password",
        "credential", "authorization", "bearer")
    return options.keys.none { key ->
        val lower = key.lowercase()
        banned.any { lower.contains(it) }
    }
}
