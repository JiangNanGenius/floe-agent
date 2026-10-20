// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * Settings-domain P0 typed projection of the accepted rev3 contract.
 *
 * This file contains no JSON decoder, no binder, no SQLite access, no network
 * client and no business handler. Swift remains the single structural
 * authority. The Kotlin mirror exists so the Android host, tests and later
 * facade packages share closed enums, request/result names and deterministic
 * value helpers without guessing.
 *
 * The five labels are additive to [BridgeProtocolV3.CONFIGURATION_SCOPES].
 * The closed matrix in [BridgeV3CommandMatrix] remains the authority for the
 * command/label tuple; this file validates the payload grammar and the exact
 * per-command createIntent policy.
 */
object SettingsDomainV1 {
    const val PAGE_BUDGET_BYTES = 48 * 1024
    const val MAXIMUM_FRAME_BYTES = BridgeProtocolV3.MAX_REQUEST_BYTES
    const val MAXIMUM_MEMORY_CONTENT_CHARACTERS = 4_096
    const val MAXIMUM_PERSONALIZATION_CONTENT_CHARACTERS = 24_000
    const val MAXIMUM_MEMORY_PAGE = 500
    const val MAXIMUM_CANDIDATE_PAGE = 100
    const val MAXIMUM_ORGANIZE_PROPOSAL_PAGE = 100
    const val MAXIMUM_USAGE_PAGE = 100
    const val MAXIMUM_BULK_ENTRIES = 500
    const val MAXIMUM_CHUNK_BYTES = 32_768
    const val MAXIMUM_SEARCH_ITEMS = 20
    const val MAXIMUM_SEARCH_QUERY_CHARACTERS = 8_000
    const val MAXIMUM_HANDLE_CHARACTERS = 256
    const val MAXIMUM_RECEIPT_CHARACTERS = 256
    const val MAXIMUM_FACT_IDENTITY_CHARACTERS = 160

    val LABELS = listOf("settings.defaults", "memory", "personalization", "usage", "privacy")

    enum class Label(val wire: String) {
        SETTINGS_DEFAULTS("settings.defaults"),
        MEMORY("memory"),
        PERSONALIZATION("personalization"),
        USAGE("usage"),
        PRIVACY("privacy"),
    }

    private val COMMAND_OWNER = mapOf(
        "config.defaults.get" to "settings.defaults",
        "config.defaults.save" to "settings.defaults",
        "memory.list" to "memory",
        "memory.get" to "memory",
        "memory.add" to "memory",
        "memory.update" to "memory",
        "memory.delete" to "memory",
        "memory.delete.bulk" to "memory",
        "memory.search" to "memory",
        "memory.candidates.list" to "memory",
        "memory.candidate.resolve" to "memory",
        "memory.organize.start" to "memory",
        "memory.organize.proposal.read" to "memory",
        "memory.organize.apply" to "memory",
        "memory.organize.cancel" to "memory",
        "personalization.get" to "personalization",
        "personalization.revision.read" to "personalization",
        "personalization.save" to "personalization",
        "personalization.rollback" to "personalization",
        "personalization.automatic.set" to "personalization",
        "personalization.generate" to "personalization",
        "personalization.generate.cancel" to "personalization",
        "usage.statistics.get" to "usage",
        "privacy.summary.get" to "privacy",
        "privacy.history.clear" to "privacy",
        "privacy.modelConfiguration.clear" to "privacy",
    )

    fun owns(command: String, label: String): Boolean {
        if (label !in LABELS) return false
        if (command == "content.read") return label == Label.PERSONALIZATION.wire
        return COMMAND_OWNER[command] == label
    }

    enum class IntentPolicy { READ_ONLY, REVISION_REQUIRED, CREATE_ONLY }

    val INTENT_POLICY: Map<String, IntentPolicy> = mapOf(
        "config.defaults.get" to IntentPolicy.READ_ONLY,
        "config.defaults.save" to IntentPolicy.REVISION_REQUIRED,
        "memory.list" to IntentPolicy.READ_ONLY,
        "memory.get" to IntentPolicy.READ_ONLY,
        "memory.add" to IntentPolicy.CREATE_ONLY,
        "memory.update" to IntentPolicy.REVISION_REQUIRED,
        "memory.delete" to IntentPolicy.REVISION_REQUIRED,
        "memory.delete.bulk" to IntentPolicy.CREATE_ONLY,
        "memory.search" to IntentPolicy.READ_ONLY,
        "memory.candidates.list" to IntentPolicy.READ_ONLY,
        "memory.candidate.resolve" to IntentPolicy.REVISION_REQUIRED,
        "memory.organize.start" to IntentPolicy.CREATE_ONLY,
        "memory.organize.proposal.read" to IntentPolicy.READ_ONLY,
        "memory.organize.apply" to IntentPolicy.CREATE_ONLY,
        "memory.organize.cancel" to IntentPolicy.READ_ONLY,
        "personalization.get" to IntentPolicy.READ_ONLY,
        "personalization.revision.read" to IntentPolicy.READ_ONLY,
        "personalization.save" to IntentPolicy.REVISION_REQUIRED,
        "personalization.rollback" to IntentPolicy.REVISION_REQUIRED,
        "personalization.automatic.set" to IntentPolicy.REVISION_REQUIRED,
        "personalization.generate" to IntentPolicy.CREATE_ONLY,
        "personalization.generate.cancel" to IntentPolicy.READ_ONLY,
        "content.read" to IntentPolicy.READ_ONLY,
        "usage.statistics.get" to IntentPolicy.READ_ONLY,
        "privacy.summary.get" to IntentPolicy.READ_ONLY,
        "privacy.history.clear" to IntentPolicy.REVISION_REQUIRED,
        "privacy.modelConfiguration.clear" to IntentPolicy.REVISION_REQUIRED,
    )

    val CREATE_ONLY_COMMANDS: Set<String> =
        INTENT_POLICY.filterValues { it == IntentPolicy.CREATE_ONLY }.keys

    data class ValidationFailure(val code: String, val reason: String) {
        companion object {
            fun invalid(reason: String) = ValidationFailure("invalidEnvelope", reason)
            fun payloadTooLarge(maxChars: Int) =
                ValidationFailure("payloadTooLarge", "maxChars:$maxChars")
        }
    }

    private class PayloadFailure(reason: String, val code: String = "invalidEnvelope") :
        Exception(reason)

    private fun fail(reason: String, code: String = "invalidEnvelope"): Nothing =
        throw PayloadFailure(reason, code)

    /**
     * Validates a closed payload map. `null` means the envelope had no payload;
     * an explicit JSON null reaches callers as `containsKey=true, value=null`
     * and is rejected wherever the contract does not declare a nullable field.
     */
    fun validate(
        command: String,
        label: String,
        createIntent: Boolean,
        revisionPresent: Boolean,
        payload: Map<String, Any?>?,
    ): ValidationFailure? {
        if (!owns(command, label)) return ValidationFailure.invalid("unknownCommand")
        val policy = INTENT_POLICY[command] ?: return ValidationFailure.invalid("unknownCommand")
        when (policy) {
            IntentPolicy.CREATE_ONLY -> {
                if (!createIntent) return ValidationFailure.invalid("createIntentRequired")
                if (revisionPresent) return ValidationFailure.invalid("revisionForNewIdentity")
            }
            IntentPolicy.READ_ONLY, IntentPolicy.REVISION_REQUIRED -> {
                if (createIntent) return ValidationFailure.invalid("createIntentNotAllowed")
            }
        }
        return try {
            when (command) {
                "config.defaults.get", "privacy.summary.get" -> validateEmpty(payload)
                "config.defaults.save" -> validateDefaultsSave(payload)
                "memory.list" -> validateMemoryList(payload)
                "memory.get" -> validateMemoryGet(payload)
                "memory.add" -> validateMemoryAdd(payload)
                "memory.update" -> validateMemoryUpdate(payload)
                "memory.delete" -> validateMemoryDelete(payload)
                "memory.delete.bulk" -> validateMemoryDeleteBulk(payload)
                "memory.search" -> validateMemorySearch(payload)
                "memory.candidates.list" -> validateCandidatesList(payload)
                "memory.candidate.resolve" -> validateCandidateResolve(payload)
                "memory.organize.start" -> validateOrganizeStart(payload)
                "memory.organize.proposal.read" -> validateOrganizeProposalRead(payload)
                "memory.organize.apply" -> validateOrganizeApply(payload)
                "memory.organize.cancel" -> validateCancel(payload, "unknownMemoryField")
                "personalization.get" -> validatePersonalizationGet(payload)
                "personalization.revision.read" -> validatePersonalizationRevisionRead(payload)
                "personalization.save" -> validatePersonalizationSave(payload)
                "personalization.rollback" -> validatePersonalizationRollback(payload)
                "personalization.automatic.set" -> validatePersonalizationAutomaticSet(payload)
                "personalization.generate" -> validatePersonalizationGenerate(payload)
                "personalization.generate.cancel" ->
                    validateCancel(payload, "unknownPersonalizationField")
                "content.read" -> validateContentRead(payload)
                "usage.statistics.get" -> validateUsageStatistics(payload)
                "privacy.history.clear", "privacy.modelConfiguration.clear" ->
                    validatePrivacyClear(payload)
                else -> fail("unknownCommand")
            }
            null
        } catch (failure: PayloadFailure) {
            ValidationFailure(failure.code, failure.message ?: "invalidPayload")
        } catch (_: Exception) {
            ValidationFailure.invalid("invalidPayload")
        }
    }

    private class Reader(val values: Map<String, Any?>, val unknownReason: String) {
        private val used = mutableSetOf<String>()

        fun has(key: String): Boolean = values.containsKey(key)

        fun take(key: String): Any? {
            used += key
            return values[key]
        }

        fun finish() {
            for (key in values.keys) {
                if (key !in used) fail(unknownReason)
            }
        }
    }

    private fun reader(
        payload: Map<String, Any?>?,
        required: Set<String> = emptySet(),
        unknownReason: String,
    ): Reader {
        if (payload == null) fail("missingPayload")
        for (key in required) {
            if (!payload.containsKey(key)) fail("missingPayloadField:$key")
        }
        return Reader(payload, unknownReason)
    }

    private fun validateEmpty(payload: Map<String, Any?>?) {
        if (payload != null && payload.isNotEmpty()) fail("invalidPayload")
    }

    @Suppress("UNCHECKED_CAST")
    private fun objectValue(value: Any?, field: String): Map<String, Any?> {
        if (value !is Map<*, *>) fail("invalidPayloadField:$field")
        if (value.keys.any { it !is String }) fail("invalidPayloadField:$field")
        return value as Map<String, Any?>
    }

    private fun stringValue(
        value: Any?,
        field: String,
        maxCharacters: Int? = null,
        allowControlCharacters: Boolean = false,
    ): String {
        if (value !is String) fail("invalidPayloadField:$field")
        if (value.trim().isEmpty()) fail("emptyPayloadField:$field")
        if (maxCharacters != null && value.length > maxCharacters) {
            fail("payloadFieldTooLong:$field")
        }
        if (!allowControlCharacters && value.any { it.isISOControl() }) {
            fail("controlCharacterInField:$field")
        }
        return value
    }

    private fun booleanValue(value: Any?, field: String): Boolean {
        if (value !is Boolean) fail("invalidPayloadField:$field")
        return value
    }

    private fun intValue(value: Any?, field: String): Long {
        if (value !is Number) fail("invalidPayloadField:$field")
        if (value is Double || value is Float) fail("invalidPayloadField:$field")
        return (value as Number).toLong()
    }

    private fun optionalInt(
        value: Any?,
        present: Boolean,
        field: String,
        range: IntRange,
    ): Int? {
        if (!present) return null
        val raw = intValue(value, field)
        if (raw < range.first || raw > range.last) fail("payloadFieldOutOfRange:$field")
        return raw.toInt()
    }

    private fun numberValue(value: Any?, field: String, range: ClosedFloatingPointRange<Double>): Double {
        if (value !is Number || value is Boolean) fail("invalidPayloadField:$field")
        val number = value.toDouble()
        if (!number.isFinite() || number !in range) fail("payloadFieldOutOfRange:$field")
        return number
    }

    private fun uuidValue(value: Any?, field: String): UUID {
        if (value !is String) fail("invalidPayloadField:$field")
        val uuid = try {
            UUID.fromString(value)
        } catch (_: IllegalArgumentException) {
            fail("invalidPayloadField:$field")
        }
        if (uuid == ZERO_UUID) fail("invalidPayloadField:$field")
        return uuid
    }

    private fun optionalUuid(reader: Reader, key: String): UUID? {
        if (!reader.has(key)) {
            reader.take(key)
            return null
        }
        return uuidValue(reader.take(key), key)
    }

    private fun optionalString(
        reader: Reader,
        key: String,
        maxCharacters: Int? = null,
    ): String? {
        if (!reader.has(key)) {
            reader.take(key)
            return null
        }
        return stringValue(reader.take(key), key, maxCharacters)
    }

    private fun <T : Enum<T>> enumValue(value: Any?, field: String, values: List<T>): T {
        if (value !is String) fail("invalidPayloadField:$field")
        return values.firstOrNull { it.name == value }
            ?: fail("invalidPayloadField:$field")
    }

    private fun <T : Enum<T>> optionalEnum(reader: Reader, key: String, values: List<T>): T? {
        if (!reader.has(key)) {
            reader.take(key)
            return null
        }
        return enumValue(reader.take(key), key, values)
    }

    private fun cursor(reader: Reader, key: String = "cursor"): Int? {
        if (!reader.has(key)) {
            reader.take(key)
            return null
        }
        val raw = reader.take(key)
        if (raw !is String || raw.isEmpty() || raw.length > 18 || raw.any { !it.isDigit() }) {
            fail("invalidCursor")
        }
        return raw.toIntOrNull()?.takeIf { it >= 0 } ?: fail("invalidCursor")
    }

    private fun digestValue(value: Any?, field: String): String {
        if (value !is String || !value.startsWith("sha256:") || value.length != 71 ||
            !value.substring(7).all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        ) {
            fail("invalidPayloadField:$field")
        }
        return value
    }

    private fun factIdentity(value: Any?): FactIdentity {
        val identity = objectValue(value, "factIdentity")
        for (key in identity.keys) {
            if (key != "subjectKey" && key != "attributeKey") fail("unknownMemoryField")
        }
        val subject = stringValue(identity["subjectKey"], "subjectKey",
            MAXIMUM_FACT_IDENTITY_CHARACTERS)
        val attribute = stringValue(identity["attributeKey"], "attributeKey",
            MAXIMUM_FACT_IDENTITY_CHARACTERS)
        return FactIdentity(subject, attribute)
    }

    private fun memoryScope(value: Any?): MemoryScope {
        val scope = objectValue(value, "scope")
        for (key in scope.keys) {
            if (key != "kind" && key != "workspaceID" && key != "conversationID") {
                fail("unknownMemoryField")
            }
        }
        val kind = enumValue(scope["kind"], "scope.kind", MemoryScopeKind.entries)
        val workspaceID = if (scope["workspaceID"] == null) null else
            uuidValue(scope["workspaceID"], "workspaceID")
        val conversationID = if (scope["conversationID"] == null) null else
            uuidValue(scope["conversationID"], "conversationID")
        return try {
            MemoryScope(kind, workspaceID, conversationID)
        } catch (_: IllegalArgumentException) {
            fail("invalidPayloadField:scope")
        }
    }

    private fun memoryContent(value: Any?): String {
        if (value !is String) fail("invalidPayloadField:content")
        if (value.trim().isEmpty()) fail("memoryRejected:empty")
        if (value.length > MAXIMUM_MEMORY_CONTENT_CHARACTERS) {
            throw PayloadFailure("maxChars:$MAXIMUM_MEMORY_CONTENT_CHARACTERS", "payloadTooLarge")
        }
        val lower = value.lowercase()
        val markers = listOf(
            "api_key=", "apikey=", "authorization: bearer", "-----begin private key",
            "password:", "password=", "access_token", "refresh_token",
        )
        if (markers.any { lower.contains(it) }) fail("memoryRejected:secretLike")
        return value
    }

    private fun personalizationContent(value: Any?): String {
        if (value !is String) fail("invalidPayloadField:content")
        if (value.contains('\u0000')) fail("invalidPayloadField:content")
        if (value.trim().isEmpty()) fail("documentEmpty")
        if (value.length > MAXIMUM_PERSONALIZATION_CONTENT_CHARACTERS) {
            throw PayloadFailure(
                "maxChars:$MAXIMUM_PERSONALIZATION_CONTENT_CHARACTERS",
                "payloadTooLarge",
            )
        }
        return value
    }

    private fun validateDefaultsSave(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("values"), "unknownDefaultsField")
        val values = objectValue(reader.take("values"), "values")
        if (values.isEmpty()) fail("invalidPayloadField:values")
        for (key in values.keys) {
            if (key !in setOf("defaultAgentMode", "runningInputMode", "verifyFinalAnswer")) {
                fail("unknownDefaultsField")
            }
        }
        if (values.containsKey("defaultAgentMode")) {
            try {
                enumValue(values["defaultAgentMode"], "defaultAgentMode",
                    DefaultAgentMode.entries)
            } catch (_: PayloadFailure) {
                fail("invalidDefaultsValue:defaultAgentMode")
            }
        }
        if (values.containsKey("runningInputMode")) {
            try {
                enumValue(values["runningInputMode"], "runningInputMode",
                    RunningInputMode.entries)
            } catch (_: PayloadFailure) {
                fail("invalidDefaultsValue:runningInputMode")
            }
        }
        if (values.containsKey("verifyFinalAnswer")) {
            try {
                booleanValue(values["verifyFinalAnswer"], "verifyFinalAnswer")
            } catch (_: PayloadFailure) {
                fail("invalidDefaultsValue:verifyFinalAnswer")
            }
        }
        reader.finish()
    }

    private fun validateMemoryList(payload: Map<String, Any?>?) {
        val reader = reader(payload, unknownReason = "unknownMemoryField")
        if (reader.has("scope")) memoryScope(reader.take("scope"))
        optionalEnum(reader, "status", MemoryEntryStatus.entries)
        optionalUuid(reader, "originConversationID")
        optionalUuid(reader, "originWorkspaceID")
        if (reader.has("factIdentity")) factIdentity(reader.take("factIdentity"))
        if (reader.has("isPinned")) booleanValue(reader.take("isPinned"), "isPinned")
        cursor(reader)
        optionalInt(reader.take("limit"), reader.has("limit"), "limit",
            1..MAXIMUM_MEMORY_PAGE)
        reader.finish()
    }

    private fun validateMemoryGet(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("id"), "unknownMemoryField")
        uuidValue(reader.take("id"), "id")
        reader.finish()
    }

    private fun validateMemoryAdd(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("content", "scope"), "unknownMemoryField")
        memoryContent(reader.take("content"))
        memoryScope(reader.take("scope"))
        optionalUuid(reader, "originConversationID")
        optionalUuid(reader, "originWorkspaceID")
        reader.finish()
    }

    private fun validateMemoryUpdate(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("id", "changes"), "unknownMemoryField")
        uuidValue(reader.take("id"), "id")
        val changes = objectValue(reader.take("changes"), "changes")
        if (changes.isEmpty()) fail("invalidPayloadField:changes")
        for (key in changes.keys) {
            if (key !in setOf("content", "importance", "isPinned", "status",
                    "expiresAt", "factIdentity")) {
                fail("unknownMemoryField")
            }
        }
        if (changes.containsKey("content")) memoryContent(changes["content"])
        if (changes.containsKey("importance")) {
            numberValue(changes["importance"], "importance", 0.0..1.0)
        }
        if (changes.containsKey("isPinned")) booleanValue(changes["isPinned"], "isPinned")
        if (changes.containsKey("status")) {
            enumValue(changes["status"], "status", MemoryUpdateStatus.entries)
        }
        if (changes.containsKey("expiresAt") && changes["expiresAt"] != null) {
            val raw = changes["expiresAt"]
            if (raw !is String || raw.length !in 20..64) fail("invalidPayloadField:expiresAt")
            try {
                java.time.OffsetDateTime.parse(raw)
            } catch (_: Exception) {
                fail("invalidPayloadField:expiresAt")
            }
        }
        if (changes["factIdentity"] != null) factIdentity(changes["factIdentity"])
        reader.finish()
    }

    private fun validateMemoryDelete(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("id"), "unknownMemoryField")
        uuidValue(reader.take("id"), "id")
        reader.finish()
    }

    private fun validateMemoryDeleteBulk(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("batchID", "entries", "syncRevision"),
            "unknownMemoryField")
        uuidValue(reader.take("batchID"), "batchID")
        intValue(reader.take("syncRevision"), "syncRevision")
        val entries = reader.take("entries")
        if (entries !is List<*> || entries.isEmpty()) fail("invalidPayloadField:entries")
        if (entries.size > MAXIMUM_BULK_ENTRIES) fail("bulkLimitExceeded")
        val seen = mutableSetOf<UUID>()
        for (entry in entries) {
            val entryObject = objectValue(entry, "entries")
            for (key in entryObject.keys) {
                if (key != "id" && key != "expectedDigest") fail("unknownMemoryField")
            }
            val id = uuidValue(entryObject["id"], "entries.id")
            if (!seen.add(id)) fail("duplicateBatchEntry")
            digestValue(entryObject["expectedDigest"], "entries.expectedDigest")
        }
        reader.finish()
    }

    private fun validateMemorySearch(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("query"), "unknownMemoryField")
        stringValue(reader.take("query"), "query",
            MAXIMUM_SEARCH_QUERY_CHARACTERS, allowControlCharacters = true)
        optionalUuid(reader, "workspaceID")
        optionalUuid(reader, "conversationID")
        optionalInt(reader.take("limit"), reader.has("limit"), "limit",
            1..MAXIMUM_SEARCH_ITEMS)
        val handle = optionalString(reader, "handle", MAXIMUM_HANDLE_CHARACTERS)
        val offset = cursor(reader)
        if (offset != null && handle == null) fail("invalidCursor")
        reader.finish()
    }

    private fun validateCandidatesList(payload: Map<String, Any?>?) {
        val reader = reader(payload, unknownReason = "unknownMemoryField")
        optionalEnum(reader, "status", CandidateStatus.entries)
        cursor(reader)
        optionalInt(reader.take("limit"), reader.has("limit"), "limit",
            1..MAXIMUM_CANDIDATE_PAGE)
        reader.finish()
    }

    private fun validateCandidateResolve(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("id", "activate"), "unknownMemoryField")
        uuidValue(reader.take("id"), "id")
        booleanValue(reader.take("activate"), "activate")
        reader.finish()
    }

    private fun validateOrganizeStart(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("mode", "includeSemantic"), "unknownMemoryField")
        enumValue(reader.take("mode"), "mode", OrganizeMode.entries)
        booleanValue(reader.take("includeSemantic"), "includeSemantic")
        reader.finish()
    }

    private fun validateOrganizeProposalRead(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("handle"), "unknownMemoryField")
        stringValue(reader.take("handle"), "handle", MAXIMUM_HANDLE_CHARACTERS)
        cursor(reader)
        optionalInt(reader.take("limit"), reader.has("limit"), "limit",
            1..MAXIMUM_ORGANIZE_PROPOSAL_PAGE)
        reader.finish()
    }

    private fun validateOrganizeApply(payload: Map<String, Any?>?) {
        val reader = reader(payload,
            setOf("handle", "suggestionID", "batchID", "syncRevision"),
            "unknownMemoryField")
        stringValue(reader.take("handle"), "handle", MAXIMUM_HANDLE_CHARACTERS)
        uuidValue(reader.take("suggestionID"), "suggestionID")
        uuidValue(reader.take("batchID"), "batchID")
        intValue(reader.take("syncRevision"), "syncRevision")
        reader.finish()
    }

    private fun validateCancel(payload: Map<String, Any?>?, unknownReason: String) {
        val reader = reader(payload, setOf("operationReceiptID"), unknownReason)
        stringValue(reader.take("operationReceiptID"), "operationReceiptID",
            MAXIMUM_RECEIPT_CHARACTERS)
        reader.finish()
    }

    private fun validatePersonalizationGet(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind"), "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        cursor(reader, "revisionsCursor")
        optionalInt(reader.take("revisionsLimit"), reader.has("revisionsLimit"),
            "revisionsLimit", 1..MAXIMUM_USAGE_PAGE)
        reader.finish()
    }

    private fun validatePersonalizationRevisionRead(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind", "revision"), "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        if (intValue(reader.take("revision"), "revision") < 1) {
            fail("invalidPayloadField:revision")
        }
        reader.finish()
    }

    private fun validatePersonalizationSave(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind", "content"), "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        personalizationContent(reader.take("content"))
        reader.finish()
    }

    private fun validatePersonalizationRollback(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind", "targetRevision"),
            "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        if (intValue(reader.take("targetRevision"), "targetRevision") < 1) {
            fail("invalidPayloadField:targetRevision")
        }
        reader.finish()
    }

    private fun validatePersonalizationAutomaticSet(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind", "enabled"), "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        booleanValue(reader.take("enabled"), "enabled")
        reader.finish()
    }

    private fun validatePersonalizationGenerate(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("kind"), "unknownPersonalizationField")
        enumValue(reader.take("kind"), "kind", PersonalizationKind.entries)
        optionalUuid(reader, "workspaceID")
        reader.finish()
    }

    private fun validateContentRead(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("handle", "offsetBytes", "maxBytes"),
            "unknownContentField")
        stringValue(reader.take("handle"), "handle", MAXIMUM_HANDLE_CHARACTERS)
        val offset = intValue(reader.take("offsetBytes"), "offsetBytes")
        val maxBytes = intValue(reader.take("maxBytes"), "maxBytes")
        if (offset < 0 || maxBytes < 1 || maxBytes > MAXIMUM_CHUNK_BYTES ||
            offset > Long.MAX_VALUE - maxBytes
        ) {
            fail("invalidChunkRange")
        }
        reader.finish()
    }

    private fun validateUsageStatistics(payload: Map<String, Any?>?) {
        val reader = reader(payload, unknownReason = "unknownUsageField")
        // The frozen usage contract names an invalid *present* dimension
        // explicitly (`invalidEnvelope reason=unknownDimension`) for bad
        // strings, wrong types and null; an omitted dimension defaults to
        // `total`. Other domains keep the generic enum-field taxonomy.
        if (reader.has("dimension")) {
            val raw = reader.take("dimension")
            if (raw !is String || UsageDimension.entries.none { it.name == raw }) {
                fail("unknownDimension")
            }
        } else {
            reader.take("dimension")
        }
        cursor(reader)
        optionalInt(reader.take("limit"), reader.has("limit"), "limit",
            1..MAXIMUM_USAGE_PAGE)
        reader.finish()
    }

    private fun validatePrivacyClear(payload: Map<String, Any?>?) {
        val reader = reader(payload, setOf("confirmToken"), "unknownPrivacyField")
        digestValue(reader.take("confirmToken"), "confirmToken")
        reader.finish()
    }

    // ---------------------------------------------------------------- enums

    enum class DefaultAgentMode { human, approvalModel, fullControl }
    enum class RunningInputMode { queue, steer }
    enum class MemoryScopeKind { user, agent, workspace, task }
    enum class MemoryEntryStatus { pending, active, rejected, superseded }
    enum class MemoryUpdateStatus { active, superseded }
    enum class MemorySourceKind {
        explicitUserRequest, automaticTurnReview, goalStepReview, planReview,
    }
    enum class MemorySensitivity { none, personal, authenticationSecret }
    enum class MemorySuggestionKind {
        exactDuplicate, sameFactReplacement, possibleDuplicate, expired, missingOwnership,
    }
    enum class CandidateStatus { pending, activated, rejected }
    enum class CandidateOrigin {
        explicitUserRequest, automaticTurnReview, goalStepReview, planReview,
    }
    enum class OrganizeMode { reviewFirst, modelManaged }
    enum class PersonalizationKind { soul, userProfile }
    enum class PersonalizationSource { automatic, oneClick, manual, rollback }
    enum class GenerateDraftReason { activeSlotChanged, sourceChanged, both }
    enum class UsageDimension { total, conversation, model, provider }
    enum class PrivacyCredentialAvailability { AVAILABLE, NEEDS_CONFIGURATION }

    data class FactIdentity(val subjectKey: String, val attributeKey: String) {
        init {
            require(subjectKey.isNotBlank() && attributeKey.isNotBlank())
            require(subjectKey.length <= MAXIMUM_FACT_IDENTITY_CHARACTERS)
            require(attributeKey.length <= MAXIMUM_FACT_IDENTITY_CHARACTERS)
        }
    }

    data class MemoryScope(
        val kind: MemoryScopeKind,
        val workspaceID: UUID? = null,
        val conversationID: UUID? = null,
    ) {
        init {
            when (kind) {
                MemoryScopeKind.user, MemoryScopeKind.agent -> {
                    require(workspaceID == null && conversationID == null)
                }
                MemoryScopeKind.workspace -> {
                    require(workspaceID != null && conversationID == null)
                }
                MemoryScopeKind.task -> {
                    require(conversationID != null && workspaceID == null)
                }
            }
        }
    }

    data class Revision(val resourceID: String, val version: String) {
        init {
            require(resourceID.isNotBlank() && version.isNotBlank())
        }
    }

    data class ContentHandle(val handle: String, val bytes: Int) {
        init { require(handle.isNotBlank() && bytes >= 0) }
    }

    data class ContentChunk(
        val chunk: String,
        val nextOffset: Int?,
        val totalBytes: Int,
        val done: Boolean,
    )

    data class DefaultsValues(
        val defaultAgentMode: DefaultAgentMode = DefaultAgentMode.human,
        val runningInputMode: RunningInputMode = RunningInputMode.queue,
        val verifyFinalAnswer: Boolean = false,
    )

    data class DefaultsExplicitness(
        val defaultAgentMode: Boolean,
        val runningInputMode: Boolean,
        val verifyFinalAnswer: Boolean,
    )

    data class DefaultsReply(
        val values: DefaultsValues,
        val explicit: DefaultsExplicitness,
        val revision: String,
    )

    data class MemoryEntry(
        val id: UUID,
        val scope: MemoryScope,
        val status: MemoryEntryStatus,
        val content: String,
        val confidence: Double,
        val importance: Double,
        val isPinned: Boolean,
        val sourceKind: MemorySourceKind,
        val originConversationID: UUID?,
        val originWorkspaceID: UUID?,
        val factIdentity: FactIdentity?,
        val ownership: Ownership,
        val expiresAt: String?,
        val createdAt: String,
        val updatedAt: String,
        val revision: String,
    )

    data class Ownership(
        val ownerDeletedAt: String?,
        val retainedUntil: String?,
        val originOwnerLabel: String?,
        val lastRecalledAt: String?,
        val recallCount: Int,
    )

    data class MemoryEvidenceReference(
        val id: UUID,
        val messageID: UUID,
        val excerpt: String,
    )

    data class MemoryListReply(val entries: List<MemoryEntry>, val nextCursor: String?)

    data class MemoryMutationReply(
        val status: Status,
        val entry: MemoryEntry?,
        val existingID: UUID?,
    ) {
        enum class Status { added, duplicate }
    }

    data class MemoryUpdateReply(val entry: MemoryEntry)

    data class MemoryDeleteReply(val deleted: Boolean, val tombstoned: Boolean)

    data class MemoryBulkDeleteReply(
        val batchID: UUID,
        val result: BulkResult,
        val deletedCount: Int,
        val replacedCount: Int,
        val appliedCount: Int,
    ) {
        enum class BulkResult { applied, alreadyApplied }
    }

    data class MemorySearchSideEffects(
        val lifecycleMaintained: Boolean = true,
        val reinforcementPathExecuted: Boolean = true,
        val reinforcedCount: Int? = null,
        val digestsRefreshed: Boolean = true,
        val explanation: String =
            "the original API returns no per-item changesCount; an exact reinforced-row count is NOT reported or fabricated",
    )

    data class MemorySearchItem(
        val id: UUID,
        val relevance: Double,
        val lexicalRank: Int?,
        val semanticRank: Int?,
        val semanticSimilarity: Double?,
        val current: MemoryEntry?,
        val deleted: Boolean,
    )

    data class MemorySearchReply(
        val items: List<MemorySearchItem>,
        val semantic: Boolean = false,
        val sideEffects: MemorySearchSideEffects,
        val searchHandle: String?,
        val nextCursor: String?,
        val hasMore: Boolean,
    )

    data class MemoryOrganizeAutoDelete(
        val status: AutoDeleteStatus,
        val batchID: UUID?,
    ) {
        enum class AutoDeleteStatus { applied, none, staleRejected }
    }

    data class MemoryOrganizeStartAutoDelete(
        val status: MemoryOrganizeAutoDelete.AutoDeleteStatus,
        val batchID: UUID?,
        val staleIDs: List<UUID>,
    )

    data class MemoryCandidate(
        val id: UUID,
        val scope: MemoryScope,
        val content: String,
        val confidence: Double,
        val stability: Double,
        val importance: Double,
        val sensitivity: MemorySensitivity,
        val origin: CandidateOrigin,
        val evidence: List<MemoryEvidenceReference>,
        val conflictsWithEntryIDs: List<UUID>,
        val reviewReason: String?,
        val sourceAttachmentID: UUID?,
        val sourceMIMEType: String?,
        val status: CandidateStatus,
        val expiresAt: String?,
        val createdAt: String,
        val updatedAt: String,
        val revision: String,
    )

    data class MemoryCandidatesReply(
        val candidates: List<MemoryCandidate>,
        val nextCursor: String?,
        val expiredSweepApplied: Boolean,
    )

    data class MemoryCandidateResolveReply(
        val status: Status,
        val entry: MemoryEntry?,
    ) {
        enum class Status { activated, rejected }
    }

    data class MemoryOrganizeSuggestion(
        val id: UUID,
        val kind: MemorySuggestionKind,
        val memoryIDs: List<UUID>,
        val preferredMemoryID: UUID?,
        val reason: String,
        val canApplyAutomatically: Boolean,
    )

    data class MemoryOrganizeEntrySummary(
        val id: UUID,
        val scope: MemoryScope,
        val status: MemoryEntryStatus,
        val content: String,
        val factIdentity: FactIdentity?,
        val originConversationID: UUID?,
        val originWorkspaceID: UUID?,
        val updatedAt: String,
    )

    data class MemoryOrganizeProposalReply(
        val proposalID: UUID,
        val generatedAt: String,
        val scannedCount: Int,
        val suggestions: List<MemoryOrganizeSuggestion>,
        val entries: List<MemoryOrganizeEntrySummary>,
        val nextCursor: String?,
        val stale: Boolean,
        val staleIDs: List<UUID>,
        val autoDelete: MemoryOrganizeAutoDelete,
    )

    enum class MemoryOrganizeSemanticUnavailableReason {
        needsConfiguration,
        credentialUnavailable,
        transportUnavailable,
        modelError,
        invalidModelJSON,
    }

    sealed interface MemoryOrganizeSemantic {
        data object Applied : MemoryOrganizeSemantic
        data object Skipped : MemoryOrganizeSemantic
        data class Unavailable(
            val reason: MemoryOrganizeSemanticUnavailableReason,
        ) : MemoryOrganizeSemantic
    }

    data class MemoryOrganizeStartEffect(
        val scannedCount: Int,
        val autoDeletedCount: Int,
        val pendingReviewCount: Int,
        val autoDelete: MemoryOrganizeStartAutoDelete,
        val proposalStale: Boolean,
        val semantic: MemoryOrganizeSemantic,
        val proposalHandle: String,
        val status: String = "completed",
    )

    data class MemoryOrganizeApplyReply(
        val batchID: UUID,
        val result: Result,
        val deletedCount: Int,
    ) {
        enum class Result { applied, alreadyApplied }
    }

    enum class OperationCancelPhase {
        queued, scan, semantic, apply, resolving, streaming, committing, committed,
    }

    data class OperationCancelReply(
        val status: Status,
        val phase: OperationCancelPhase?,
    ) {
        enum class Status { canceled, completed }
    }

    data class PersonalizationRevisionMeta(
        val id: UUID,
        val revision: Int,
        val source: PersonalizationSource,
        val isActive: Boolean,
        val createdAt: String,
        val contentBytes: Int,
        val contentDigest: String,
    )

    data class PersonalizationDocument(
        val id: UUID,
        val kind: PersonalizationKind,
        val workspaceID: UUID?,
        val revision: Int,
        val source: PersonalizationSource,
        val evidenceDigest: String,
        val isActive: Boolean,
        val createdAt: String,
        val contentBytes: Int,
        val contentDigest: String,
        val content: String?,
        val contentHandle: ContentHandle?,
    ) {
        init {
            require((content == null) != (contentHandle == null)) {
                "content is inline xor an owned handle"
            }
        }
    }

    data class PersonalizationCursor(
        val automaticUpdatesEnabled: Boolean,
        val lastGeneratedAt: String?,
        val completedRunsSinceUpdate: Int,
        val userMessagesSinceUpdate: Int,
        val updatedAt: String,
        val revision: String,
    )

    data class PersonalizationGetReply(
        val active: PersonalizationDocument?,
        val latestRevision: Int,
        val revisionsMeta: List<PersonalizationRevisionMeta>,
        val cursor: PersonalizationCursor,
        val revisionToken: String,
        val revisionsNextCursor: String?,
    )

    data class PersonalizationRevisionReply(val document: PersonalizationDocument)

    data class PersonalizationSaveReply(
        val document: PersonalizationDocument,
        val revisionToken: String,
        val latestRevision: Int,
    )

    data class PersonalizationRollbackReply(
        val document: PersonalizationDocument,
        val revisionToken: String,
    )

    data class PersonalizationAutomaticReply(val cursor: PersonalizationCursor)

    data class GeneratedPersonalizationDocument(
        val id: UUID,
        val revision: Int,
        val source: PersonalizationSource = PersonalizationSource.oneClick,
        val isActive: Boolean,
        val contentBytes: Int,
        val contentDigest: String,
        val createdAt: String,
    )

    sealed interface PersonalizationGenerateOutcome {
        data object Active : PersonalizationGenerateOutcome
        data class StoredAsDraft(val reason: GenerateDraftReason) :
            PersonalizationGenerateOutcome
    }

    data class PersonalizationGenerateRoute(
        val providerID: UUID,
        val modelID: UUID,
    )

    data class PersonalizationSourceSnapshot(
        val memoryCount: Int,
        val digest: String,
    )

    data class PersonalizationGenerateCursor(
        val revision: String,
        val countersPreserved: Boolean,
    )

    enum class PersonalizationGenerateStatus { completed }

    data class PersonalizationGenerateEffect(
        val outcome: PersonalizationGenerateOutcome,
        val document: GeneratedPersonalizationDocument,
        val revisionToken: String,
        val draftRevision: Int?,
        val route: PersonalizationGenerateRoute,
        val evidenceDigest: String,
        val sourceSnapshot: PersonalizationSourceSnapshot,
        val cursor: PersonalizationGenerateCursor,
        val status: PersonalizationGenerateStatus =
            PersonalizationGenerateStatus.completed,
    )

    data class UsageMetrics(
        val inputTokens: Int,
        val outputTokens: Int,
        val totalTokens: Int,
        val runs: Int,
        val cacheReadTokens: Int? = null,
        val cacheWriteTokens: Int? = null,
        val reasoningTokens: Int? = null,
        val averageTokensPerSecond: Double? = null,
        val averageTimeToFirstTokenMs: Double? = null,
        val averageDurationMs: Double? = null,
    )

    data class UsageDay(
        val date: String,
        val inputTokens: Int,
        val outputTokens: Int,
        val cacheReadTokens: Int?,
        val cacheWriteTokens: Int?,
        val runs: Int,
        val totalTokens: Int,
    )

    data class UsageBreakdown(
        val id: String,
        val label: String,
        val inputTokens: Int,
        val outputTokens: Int,
        val runs: Int,
        val cacheReadTokens: Int?,
        val cacheWriteTokens: Int?,
        val reasoningTokens: Int?,
        val averageTokensPerSecond: Double?,
        val averageTimeToFirstTokenMs: Double?,
        val averageDurationMs: Double?,
        val totalTokens: Int,
    )

    data class UsageStatisticsReply(
        val totals: UsageMetrics,
        val byDay: List<UsageDay>?,
        val rows: List<UsageBreakdown>?,
        val nextCursor: String?,
    )

    data class PrivacyHistorySummary(
        val conversationCount: Int,
        val runCount: Int,
        val persistedGrantCount: Int,
        val inMemoryGrantCount: Int,
        val revision: String,
    )

    data class PrivacyModelConfigurationSummary(
        val providerCount: Int,
        val modelCount: Int,
        val secretReferenceCount: Int,
        val preferencesSyncRevision: Int,
        val revision: String,
    )

    data class PrivacySnapshotFacts(
        val dbSnapshotTransaction: Boolean = true,
        val inMemoryGrantBracket: String = "g1==g2",
        val retriesBounded: Int = 3,
    )

    data class PrivacySummaryReply(
        val history: PrivacyHistorySummary,
        val modelConfiguration: PrivacyModelConfigurationSummary,
        val credentialAvailability: PrivacyCredentialAvailability,
        val snapshot: PrivacySnapshotFacts = PrivacySnapshotFacts(),
    )

    enum class PrivacyHistoryFailurePhase {
        quiesce, deleteConversation, grantRevoke, drain,
    }

    data class PrivacyFailure(
        val itemID: UUID?,
        val phase: PrivacyHistoryFailurePhase,
        val reason: String,
    )

    data class PrivacyRemaining(
        val conversationCount: Int,
        val runCount: Int,
        val persistedGrantCount: Int,
        val inMemoryGrantCount: Int,
    )

    data class PrivacyHistoryEnumerated(
        val conversations: Int,
        val runs: Int,
        val persistedGrants: Int,
        val inMemoryGrants: Int,
    )

    data class PrivacyGrantDeletionCounts(
        val persisted: Int,
        val inMemory: Int,
    )

    data class PrivacyHistoryDeleted(
        val conversations: Int,
        val runs: Int,
        val grants: PrivacyGrantDeletionCounts,
    )

    data class PrivacyHistoryClearReport(
        val enumerated: PrivacyHistoryEnumerated,
        val deleted: PrivacyHistoryDeleted,
        val failures: List<PrivacyFailure>,
        val partial: Boolean,
        val remaining: PrivacyRemaining,
    )

    enum class PrivacyModelConfigFailurePhase {
        secretReferenceChanged, enqueue, gatewayDelete, complete, record,
    }

    data class PrivacyProviderDeletionFailure(
        val providerID: UUID,
        val phase: PrivacyModelConfigFailurePhase,
        val reason: String,
    )

    data class PrivacyModelConfigEnumerated(
        val providers: Int,
        val models: Int,
        val secretReferences: Int,
    )

    data class PrivacyModelConfigDeleted(
        val providers: Int,
        val models: Int,
        val secrets: Int,
    )

    data class PrivacyModelConfigRemaining(
        val providerCount: Int,
        val modelCount: Int,
        val secretReferenceCount: Int,
    )

    data class PrivacyModelConfigClearReport(
        val enumerated: PrivacyModelConfigEnumerated,
        val deleted: PrivacyModelConfigDeleted,
        val deletionFailures: List<PrivacyProviderDeletionFailure>,
        val preferencesReset: Boolean,
        val preferencesSyncRevision: Int,
        val remaining: PrivacyModelConfigRemaining,
        val partial: Boolean,
    )

    object ContentBudget {
        fun encodedChunkResponseBytes(chunk: ContentChunk): Int {
            val escaped = jsonEncodedStringBytes(chunk.chunk)
            val nextOffset = chunk.nextOffset?.toString() ?: "null"
            val fixed = """{"chunk":,"done":${chunk.done},"nextOffset":$nextOffset,"totalBytes":${chunk.totalBytes}}"""
            return fixed.toByteArray(Charsets.UTF_8).size + escaped
        }

        fun fitsPageBudget(chunk: ContentChunk, pageBudget: Int = PAGE_BUDGET_BYTES): Boolean =
            encodedChunkResponseBytes(chunk) <= pageBudget

        /**
         * Chunk on scalar boundaries with bounded work: scalar ends inside the
         * request window are discovered once, then the longest encoded page
         * that fits `pageBudget` is found with logarithmic encoded-size
         * probes. No prefix is re-serialized once per removed scalar.
         */
        fun chunk(
            content: String,
            offsetBytes: Int,
            maxBytes: Int,
            pageBudget: Int = PAGE_BUDGET_BYTES,
        ): ContentChunk {
            val bytes = content.toByteArray(Charsets.UTF_8)
            require(offsetBytes in 0..bytes.size) { "invalidChunkRange" }
            require(maxBytes in 1..MAXIMUM_CHUNK_BYTES) { "invalidChunkRange" }
            if (offsetBytes == bytes.size) {
                val response = ContentChunk("", null, bytes.size, true)
                // The terminal empty page is a page too.
                require(fitsPageBudget(response, pageBudget)) { "invalidChunkRange" }
                return response
            }
            require((bytes[offsetBytes].toInt() and 0xC0) != 0x80) {
                "invalidChunkRange"
            }
            // Avoid Int overflow when offset sits near Int.MAX_VALUE.
            val limit = if (offsetBytes > bytes.size - maxBytes) bytes.size
            else offsetBytes + maxBytes
            val boundaries = ArrayList<Int>(minOf(maxBytes, bytes.size - offsetBytes))
            var cursor = offsetBytes
            while (cursor < limit) {
                var next = cursor + 1
                while (next < bytes.size && (bytes[next].toInt() and 0xC0) == 0x80) {
                    next += 1
                }
                if (next > limit) break
                boundaries.add(next)
                cursor = next
            }
            require(boundaries.isNotEmpty()) { "invalidChunkRange" }
            fun responseAt(end: Int): ContentChunk = ContentChunk(
                chunk = String(bytes, offsetBytes, end - offsetBytes, Charsets.UTF_8),
                nextOffset = if (end < bytes.size) end else null,
                totalBytes = bytes.size,
                done = end == bytes.size,
            )
            // MAIN_TERMINAL_METADATA_BUDGET_FOLLOWUP_20261019 mirror (Swift
            // SettingsDomainV1.chunk keeps byte-identical semantics): the last
            // candidate may be TERMINAL (nextOffset null + done true), so its
            // metadata shrinks and encoded size is not strictly monotone at
            // that final boundary. Probe the largest available terminal
            // candidate first; otherwise binary-search ONLY the strictly
            // monotone non-terminal range. Never exceeds the budget, never
            // loses data.
            val last = boundaries.size - 1
            val lastIsTerminal = boundaries[last] == bytes.size
            if (lastIsTerminal && fitsPageBudget(responseAt(boundaries[last]), pageBudget)) {
                return responseAt(boundaries[last])
            }
            var low = 0
            var high = if (lastIsTerminal) last - 1 else last
            while (low <= high) {
                val mid = low + (high - low) / 2
                if (fitsPageBudget(responseAt(boundaries[mid]), pageBudget)) {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            require(high >= 0) { "invalidChunkRange" }
            return responseAt(boundaries[high])
        }

        fun encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: Int,
            content: String,
        ): Int {
            require(metadataEncodedBytesWithEmptyContent >= 2) {
                "invalid metadata byte count"
            }
            val base = metadataEncodedBytesWithEmptyContent - 2
            val encoded = jsonEncodedStringBytes(content)
            if (base > Int.MAX_VALUE - encoded) return Int.MAX_VALUE
            return base + encoded
        }

        fun shouldInline(
            content: String,
            metadataEncodedBytesWithEmptyContent: Int,
            pageBudget: Int = PAGE_BUDGET_BYTES,
        ): Boolean = encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent, content) <= pageBudget

        /**
         * JSON escaping byte count matching the actual wire encoder used for
         * the response: quoted string, `\"`/`\\`/`\/`, short escapes for
         * `\b \f \n \r \t`, `\u00XX` for the remaining C0 controls and raw
         * UTF-8 for everything else. A lone UTF-16 surrogate cannot exist in
         * the Swift wire string; if the Kotlin mirror is handed one it counts
         * the same replacement byte the UTF-8 byte path produces, so sizing
         * never throws and never invents a surrogate escape.
         */
        fun jsonEncodedStringBytes(value: String): Int {
            var count = 2 // opening and closing quotes
            var index = 0
            while (index < value.length) {
                val codePoint = value.codePointAt(index)
                var width = Character.charCount(codePoint)
                when {
                    // Foundation's JSONSerialization (the actual wire encoder)
                    // escapes quote, backslash and slash.
                    codePoint == 0x22 || codePoint == 0x5C ||
                        codePoint == 0x2F -> count += 2
                    codePoint == 0x08 || codePoint == 0x0C ||
                        codePoint == 0x0A || codePoint == 0x0D ||
                        codePoint == 0x09 -> count += 2
                    codePoint in 0x00..0x1F -> count += 6
                    codePoint in 0xD800..0xDFFF -> {
                        // Unpaired surrogate: Java's UTF-8 byte path replaces
                        // it with '?' (one byte). A paired surrogate has
                        // already been combined by codePointAt into a scalar.
                        count += 1
                        width = 1
                    }
                    else -> {
                        val text = String(Character.toChars(codePoint))
                        count += text.toByteArray(Charsets.UTF_8).size
                    }
                }
                index += width
            }
            return count
        }
    }

    /**
     * `floe.canonical-digest.v1`: type-tagged, length-prefixed SQL storage
     * classes. No CAST/COALESCE, delimiter join or formatting.
     */
    object CanonicalDigest {
        sealed interface Field {
            data object Null : Field
            data class Integer(val value: Long) : Field
            data class Real(val value: Double) : Field
            data class Text(val value: String) : Field
            data class Blob(val value: ByteArray) : Field
        }

        const val DOMAIN_SETTINGS_DEFAULTS = "floe.settings-defaults.v2"
        const val DOMAIN_MEMORY_ENTRY = "floe.memory-entry.v3"
        const val DOMAIN_MEMORY_CANDIDATE = "floe.memory-candidate.v1"
        const val DOMAIN_PERSONALIZATION_CURSOR = "floe.personalization-cursor.v1"
        const val DOMAIN_PERSONALIZATION_SOURCE = "floe.personalization-source.v1"
        const val DOMAIN_PRIVACY_HISTORY = "floe.privacy-history.v3"
        const val DOMAIN_PRIVACY_MODEL_CONFIG = "floe.privacy-modelconfig.v3"

        fun fieldBytes(field: Field): ByteArray {
            val buffer = java.io.ByteArrayOutputStream()
            when (field) {
                is Field.Null -> buffer.write(0x00)
                is Field.Integer -> {
                    buffer.write(0x01)
                    buffer.write(ByteBuffer.allocate(8).putLong(field.value).array())
                }
                is Field.Real -> {
                    buffer.write(0x02)
                    buffer.write(ByteBuffer.allocate(8)
                        .putLong(java.lang.Double.doubleToRawLongBits(field.value)).array())
                }
                is Field.Text -> {
                    buffer.write(0x03)
                    val bytes = field.value.toByteArray(Charsets.UTF_8)
                    buffer.write(ByteBuffer.allocate(4).putInt(bytes.size).array())
                    buffer.write(bytes)
                }
                is Field.Blob -> {
                    buffer.write(0x04)
                    buffer.write(ByteBuffer.allocate(4).putInt(field.value.size).array())
                    buffer.write(field.value)
                }
            }
            return buffer.toByteArray()
        }

        fun record(fields: List<Field>): ByteArray {
            val buffer = java.io.ByteArrayOutputStream()
            buffer.write(ByteBuffer.allocate(4).putInt(fields.size).array())
            for (field in fields) buffer.write(fieldBytes(field))
            return buffer.toByteArray()
        }

        fun stream(domain: String, records: List<List<Field>>): ByteArray {
            val buffer = java.io.ByteArrayOutputStream()
            buffer.write(domain.toByteArray(Charsets.UTF_8))
            buffer.write(0x00)
            for (row in records) buffer.write(record(row))
            buffer.write(ByteBuffer.allocate(4).putInt(0).array())
            return buffer.toByteArray()
        }

        fun token(domain: String, records: List<List<Field>>): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(stream(domain, records))
            return "sha256:" + digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        fun rowToken(domain: String, fields: List<Field>): String =
            token(domain, listOf(fields))
    }

    private val ZERO_UUID: UUID = UUID(0L, 0L)
}
