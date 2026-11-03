// SPDX-License-Identifier: MPL-2.0
//
// C03 non-secret voice selection codec + read-only legacy adoption.
//
// The canonical document lives in the EXISTING `app_settings` table through
// SQLiteSettingsStore (Swift `c03.settings.load/save`, root-epoch fenced and
// revision CAS). This Kotlin file never writes SharedPreferences: it only
// reads the prior standalone `floe.voice` document when the canonical row is
// absent, and only when it decodes completely. Unreadable/future bytes are
// preserved untouched and are never overwritten by an automatic migration.
//
// Credentials are never present: cloud routes reference existing provider/
// model IDs and the Swift domain resolves the provider's existing secretRef.
package com.floe.android.host.voice

import android.content.Context
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

/** One decoded canonical document plus its compare-and-swap revision. */
data class C03SettingsDocument(
    val settings: C03VoiceSettings,
    val revision: Long,
)

data class C03SettingsDecode(
    val document: C03SettingsDocument?,
    val unreadable: Boolean,
)

/** One present legacy document. `settings == null` means unreadable. */
data class C03LegacySettingsLoad(
    val present: Boolean,
    val settings: C03VoiceSettings?,
    val unreadable: Boolean,
)

/** Canonical JSON shape. Shared by the legacy reader and JVM tests. */
internal object C03VoiceSettingsCodec {
    fun decode(raw: String): C03SettingsDecode {
        val root = C03Json.parse(raw)
            ?: return C03SettingsDecode(null, unreadable = true)
        if (containsSecretKey(root)) {
            return C03SettingsDecode(null, unreadable = true)
        }
        val schema = root.int("schema")
            ?: return C03SettingsDecode(null, unreadable = true)
        if (schema !in 1..C03VoiceSettings.CURRENT_SCHEMA) {
            // A future schema is preserved, never imported or overwritten.
            return C03SettingsDecode(null, unreadable = true)
        }
        val revision = root.long("revision") ?: 0L
        if (revision < 0L) return C03SettingsDecode(null, unreadable = true)
        val cloudInput = decodeSelection(root.obj("cloudInput"))
        val cloudOutput = decodeSelection(root.obj("cloudOutput"))
        val settings = C03VoiceSettings(
            schema = schema,
            inputLanguage = root.string("inputLanguage"),
            // Schema 1 had no interactive engine field: system is the
            // documented default, and an existing output choice is preserved.
            inputEngine = if (schema >= 2) {
                C03VoiceEngine.fromWire(root.string("inputEngine"))
            } else {
                C03VoiceEngine.SYSTEM
            },
            outputEngine = C03VoiceEngine.fromWire(root.string("outputEngine")),
            systemVoiceName = root.string("systemVoiceName"),
            systemVoiceLocale = root.string("systemVoiceLocale"),
            rate = root.double("rate") ?: 1.0,
            pitch = root.double("pitch") ?: 0.0,
            cloudInput = cloudInput,
            cloudOutput = cloudOutput,
            transcriptionProviderID = root.string("transcriptionProviderID"),
            transcriptionModelID = root.string("transcriptionModelID"),
            transcriptionLanguage = root.string("transcriptionLanguage"),
            replaceTranscribedCaptions = root.bool("replaceTranscribedCaptions") ?: true,
        ).normalized()
        return C03SettingsDecode(C03SettingsDocument(settings, revision), unreadable = false)
    }

    fun encode(settings: C03VoiceSettings, revision: Long): String {
        val clean = settings.normalized()
        return buildJsonObject {
            put("schema", clean.schema)
            put("revision", revision.coerceAtLeast(0L))
            put("inputLanguage", clean.inputLanguage)
            put("inputEngine", clean.inputEngine.wire)
            put("outputEngine", clean.outputEngine.wire)
            put("systemVoiceName", clean.systemVoiceName)
            put("systemVoiceLocale", clean.systemVoiceLocale)
            put("rate", clean.rate)
            put("pitch", clean.pitch)
            put("cloudInput", encodeSelection(clean.cloudInput))
            put("cloudOutput", encodeSelection(clean.cloudOutput))
            put("transcriptionProviderID", clean.transcriptionProviderID)
            put("transcriptionModelID", clean.transcriptionModelID)
            put("transcriptionLanguage", clean.transcriptionLanguage)
            put("replaceTranscribedCaptions", clean.replaceTranscribedCaptions)
        }.toString()
    }

    private fun decodeSelection(value: JsonObject?): C03CloudVoiceSelection =
        if (value == null) {
            C03CloudVoiceSelection()
        } else {
            C03CloudVoiceSelection(
                providerID = value.string("providerID"),
                modelID = value.string("modelID"),
                voiceID = value.string("voiceID").orEmpty(),
                language = value.string("language"),
                rate = value.double("rate") ?: 1.0,
            ).normalized()
        }

    private fun encodeSelection(value: C03CloudVoiceSelection): JsonObject =
        buildJsonObject {
            put("providerID", value.providerID)
            put("modelID", value.modelID)
            put("voiceID", value.voiceID)
            put("language", value.language)
            put("rate", value.rate)
        }

    private fun containsSecretKey(value: JsonObject): Boolean {
        for ((key, element) in value) {
            val lower = key.lowercase()
            if (lower.contains("apikey") || lower.contains("api_key") ||
                lower.contains("secret") || lower.contains("token") ||
                lower.contains("password") || lower == "authorization"
            ) {
                return true
            }
            val nested = element as? JsonObject ?: continue
            if (containsSecretKey(nested)) return true
        }
        return false
    }
}

/**
 * Read-only access to the prior standalone SharedPreferences document.
 * It has no save method by construction: canonical writes go through the
 * Swift app_settings bridge only.
 */
class C03LegacyVoiceSettingsReader(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun load(): C03LegacySettingsLoad {
        val keys = listOf(KEY) + LEGACY_KEYS
        for (key in keys) {
            val raw = preferences.getString(key, null) ?: continue
            val decoded = C03VoiceSettingsCodec.decode(raw)
            return C03LegacySettingsLoad(
                present = true,
                settings = decoded.document?.settings,
                unreadable = decoded.unreadable,
            )
        }
        return C03LegacySettingsLoad(present = false, settings = null, unreadable = false)
    }

    companion object {
        const val FILE = "floe.voice"
        const val KEY = "voice.settings.v1"
        /** Candidate historical keys; adopted only when they decode fully. */
        val LEGACY_KEYS = listOf(
            "voice.output.settings.v1",
            "voice.input.settings.v1",
            "voice.settings",
        )
    }
}
