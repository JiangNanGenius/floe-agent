// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * G05-R2 Office AI host lane (host20) — the Kotlin mirror of the delivered
 * Swift wire authority (`shared/Sources/FloeAndroidCore/OfficeAI/
 * OfficeAIHostContract.swift` + `office-ai15/API_READY.json` + the fixed
 * Main Amendment/2 keys in
 * `Local/Private/android-g05-20261026/r2/batch07-preparation/
 * OFFICE_AI_SEMANTIC_V2.json`). The C ABI, JNI declarations and the mailbox
 * are READ-ONLY here: this file only parses what the mailbox hands the pump
 * and builds the exact bounded replies the bridge decodes.
 *
 * Discipline (Main contract):
 *  - every descriptor key outside the per-operation closed allowlist refuses
 *    the whole ticket (the delivered WorkspaceSourcePump rule, mirrored);
 *  - values are bounded strings, control-char/NUL/DEL free;
 *  - the `epoch` field must equal the pump's bound epoch string (a mismatch
 *    is a fenced generation, never a retry);
 *  - success replies are bounded JSON (`{"ok":1,...}`), failure replies are
 *    exactly `{"code":token,"detail":bounded}` and are never truncated —
 *    an over-budget success answers a typed failure instead;
 *  - a tool literal is the EXACT wanted string (including `00123` and a
 *    leading `=`); per Main's 2026-10-27 ruling the settled native apostrophe
 *    codec prefixes EVERY non-empty literal before the P-A native LITERAL
 *    (a reinterpret-guess list is incomplete for dates/times/locale number
 *    shapes), case and bytes otherwise preserved; the codec apostrophe is
 *    NOT part of the wanted value, so the verifier always sees the raw
 *    expectation.
 */
internal object OfficeAiWire {

    // ---- bounds (mirrors OfficeAIHostLimits) --------------------------------

    const val MAX_DESCRIPTOR_BYTES = 2048
    const val MAX_STAGED_BYTES = 96 * 1024

    /** Engine `OfficePrecisionProtocol.MAX_TEXT_BYTES` — the apply payload cap. */
    const val MAX_APPLY_TEXT_BYTES = 64 * 1024

    /** Expected-text stage cap for office.verify (same engine content bound). */
    const val MAX_EXPECTED_TEXT_BYTES = 64 * 1024
    const val MAX_REPLY_BYTES = 1_048_576
    const val MAX_FAILURE_REPLY_BYTES = 256
    const val MAX_DETAIL_CHARS = 240

    const val OP = "operation"
    const val EPOCH = "epoch"

    private val OP_ID = Regex("^[A-Za-z0-9_-]{1,64}$")
    private val SHA256_HEX = Regex("^[0-9a-f]{64}$")
    private val CELL_ADDRESS = Regex("^[A-Za-z]{1,3}[0-9]{1,7}$")
    private val HEX32 = Regex("^[0-9a-f]{32}$")

    val OPERATIONS = setOf(
        "office.lookup", "office.open", "office.command", "office.save",
        "office.verify", "office.reconcile", "office.pushOriginal",
    )

    val COMMAND_ACTIONS = setOf(
        "captureTarget", "queryDocumentContext", "queryTextSelection", "queryCellCursor",
        "queryPresentationInfo", "selectSlide", "selectAllText", "applyText", "setCellContent",
    )

    /** Amendment/2 content kinds: the public tool literal, the new explicit
     * finite numeric intent and the real formula. Both literal and number
     * ride the native LITERAL surface (with the codec rule below); formula
     * rides the native FORMULA surface. A literal `=` is NEVER mapped to a
     * formula. */
    val CONTENT_KINDS = setOf("literal", "number", "formula")

    val SAVE_OPERATIONS = setOf("flush", "export")
    val EXPORT_FORMATS = setOf("docx", "xlsx", "pptx")

    /** Private-RPC verification modes (never model parameters). */
    val VERIFICATION_MODES = setOf("liveEffect", "completedJob", "reconcile")

    // ---- closed descriptor allowlists (Swift OfficeAIHostField mirrors;
    // ---- verify carries the fixed Main Amendment/2 ADDITIVE keys) ----------

    fun allowedKeys(operation: String): Set<String>? = when (operation) {
        "office.lookup" -> setOf(
            OP, EPOCH, "taskID", "workspaceID", "workspacePresent", "nativeEpoch",
        )
        "office.open" -> setOf(
            OP, EPOCH, "taskID", "workspaceID", "nativeEpoch", "hostGeneration",
            "logicalPath", "requestID",
        )
        "office.command" -> setOf(
            OP, EPOCH, "sessionToken", "generation", "opId", "action", "targetHandle",
            "cellAddress", "partId", "contentKind", "taskID",
        )
        "office.save" -> setOf(
            OP, EPOCH, "sessionToken", "generation", "opId", "saveOperation", "format",
            "suggestedName",
        )
        "office.verify" -> setOf(
            OP, EPOCH, "path", "sha256", "format", "expectCommand", "cellAddress",
            "contentKind", "expectPartIndex", "preEditSha256",
            // Fixed Main v2 additions (the shared 19 lane sends exactly these;
            // nothing else is admitted):
            "taskID", "verificationMode", "effectOpId", "exportOpId",
            "sessionToken", "generation", "targetHandle",
        )
        "office.reconcile" -> setOf(OP, EPOCH, "exportOpId", "format")
        "office.pushOriginal" -> setOf(
            OP, EPOCH, "taskID", "workspaceID", "nativeEpoch", "hostGeneration",
            "logicalPath",
        )
        else -> null
    }

    /** The staged-bytes rule per operation: required, optional or forbidden. */
    enum class Stage { NONE, REQUIRED, OPTIONAL }

    fun stageFor(operation: String, fields: Map<String, String>): Stage = when (operation) {
        "office.command" -> when (fields["action"]) {
            "applyText", "setCellContent" -> Stage.REQUIRED
            else -> Stage.NONE
        }
        "office.verify" -> Stage.REQUIRED
        else -> Stage.NONE
    }

    // ---- typed descriptor ----

    data class Ticket(
        val operation: String,
        /** All values are validated non-null strings; optionals are absent. */
        val fields: Map<String, String>,
    ) {
        fun field(key: String): String? = fields[key]
        fun required(key: String): String = fields.getValue(key)
        fun uuid(key: String): String? = fields[key]
        fun long(key: String): Long? = fields[key]?.toLongOrNull()
    }

    /** A typed pre-dispatch refusal: settle the ticket with exactly this
     * `{"code": ...}` failure envelope. Path-free tokens only. */
    class Refusal(val code: String, val detail: String? = null) : Exception(code)

    private fun value(key: String, raw: String): String {
        if (raw.length > 512 || raw.toByteArray(Charsets.UTF_8).size > 512 ||
            raw.any { it.code < 0x20 || it.code == 0x7f }
        ) {
            throw Refusal("internal", "descriptor value rejected: $key")
        }
        return raw
    }

    /** Strict parse of one claimed descriptor against the pump's bound epoch.
     * Throws [Refusal] with a shared-table token on ANY shape violation. */
    fun parseDescriptor(bytes: ByteArray, boundEpoch: Long): Ticket {
        if (bytes.isEmpty() || bytes.size > MAX_DESCRIPTOR_BYTES) {
            throw Refusal("internal", "descriptor size refused")
        }
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            throw Refusal("internal", "descriptor is not strict UTF-8")
        }
        val element = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (_: Exception) {
            throw Refusal("internal", "descriptor is not a JSON object")
        }
        val fields = LinkedHashMap<String, String>()
        for ((key, jsonValue) in element) {
            val primitive = jsonValue as? JsonPrimitive
            if (primitive == null || !primitive.isString) {
                throw Refusal("internal", "descriptor field is not a string: $key")
            }
            fields[key] = value(key, primitive.content)
        }
        val operation = fields[OP] ?: throw Refusal("internal", "descriptor missing operation")
        if (operation !in OPERATIONS) throw Refusal("internal", "unknown operation")
        val allowed = allowedKeys(operation)!!
        if (fields.keys.any { it !in allowed }) {
            throw Refusal("internal", "descriptor key outside the closed allowlist")
        }
        if (fields[EPOCH] != boundEpoch.toString()) throw Refusal("generationFenced")
        validate(operation, fields)
        return Ticket(operation, fields)
    }

    private fun validUuid(raw: String?): Boolean = raw != null &&
        runCatching { UUID.fromString(raw).toString().equals(raw, true) }.getOrDefault(false)

    private fun validate(operation: String, f: Map<String, String>) {
        when (operation) {
            "office.lookup" -> {
                if (!validUuid(f["taskID"])) throw Refusal("internal", "taskID")
                val present = f["workspacePresent"]
                if (present != "exact" && present != "absent") throw Refusal("internal", "workspacePresent")
                if (present == "exact") {
                    if (!validUuid(f["workspaceID"])) throw Refusal("internal", "workspaceID")
                } else if (f.containsKey("workspaceID")) {
                    throw Refusal("internal", "workspaceID must be absent")
                }
                if (f["nativeEpoch"] != f[EPOCH]) throw Refusal("generationFenced")
            }
            "office.open" -> {
                if (!validUuid(f["taskID"]) || !validUuid(f["workspaceID"])) {
                    throw Refusal("internal", "identity")
                }
                if (f["nativeEpoch"] != f[EPOCH]) throw Refusal("generationFenced")
                val path = f["logicalPath"] ?: throw Refusal("internal", "logicalPath")
                validateLogicalPath(path)
                val requestID = f["requestID"]
                if (requestID == null || requestID.length !in 1..64) {
                    throw Refusal("internal", "requestID")
                }
                f["hostGeneration"]?.toLongOrNull()?.let {
                    if (it < 0) throw Refusal("internal", "hostGeneration")
                }
            }
            "office.command" -> {
                if (f["sessionToken"].isNullOrBlank() || f["sessionToken"]!!.length > 128 ||
                    f["sessionToken"]!!.any { it.code < 0x20 || it == '/' || it == '\\' }
                ) throw Refusal("internal", "sessionToken")
                val generation = f["generation"]?.toLongOrNull()
                    ?: throw Refusal("internal", "generation")
                if (generation < 1) throw Refusal("internal", "generation")
                if (f["opId"]?.let { OP_ID.matches(it) } != true) throw Refusal("internal", "opId")
                if (f["action"] !in COMMAND_ACTIONS) throw Refusal("internal", "action")
                f["targetHandle"]?.let {
                    if (!HEX32.matches(it.lowercase(Locale.ROOT))) throw Refusal("internal", "targetHandle")
                }
                f["cellAddress"]?.let {
                    if (!CELL_ADDRESS.matches(it)) throw Refusal("internal", "cellAddress")
                }
                f["partId"]?.let {
                    if (it.length > 12 || it.any { c -> c !in '0'..'9' }) throw Refusal("internal", "partId")
                }
                f["contentKind"]?.let {
                    if (it !in CONTENT_KINDS) throw Refusal("internal", "contentKind")
                }
                if (f["taskID"] != null && !validUuid(f["taskID"])) throw Refusal("internal", "taskID")
                when (f["action"]) {
                    "applyText" -> if (f["contentKind"] != null || f["cellAddress"] != null ||
                        f["targetHandle"] == null
                    ) {
                        throw Refusal("internal", "applyText needs its captured target only")
                    }
                    "setCellContent" -> {
                        if (f["cellAddress"] == null || f["contentKind"] == null ||
                            f["targetHandle"] == null
                        ) throw Refusal("internal", "setCellContent fields incomplete")
                    }
                    "selectSlide" -> if (f["partId"] == null) throw Refusal("internal", "selectSlide needs partId")
                    "captureTarget", "queryDocumentContext", "queryTextSelection",
                    "queryCellCursor", "queryPresentationInfo", "selectAllText",
                    -> if (f["targetHandle"] != null || f["contentKind"] != null) {
                        throw Refusal("internal", "action carries apply-only fields")
                    }
                }
            }
            "office.save" -> {
                if (f["sessionToken"].isNullOrBlank() || f["sessionToken"]!!.length > 128 ||
                    f["sessionToken"]!!.any { it.code < 0x20 || it == '/' || it == '\\' }
                ) throw Refusal("internal", "sessionToken")
                val generation = f["generation"]?.toLongOrNull()
                    ?: throw Refusal("internal", "generation")
                if (generation < 1) throw Refusal("internal", "generation")
                if (f["opId"]?.let { OP_ID.matches(it) } != true) throw Refusal("internal", "opId")
                when (f["saveOperation"]) {
                    "flush" -> if (f["format"] != null || f["suggestedName"] != null) {
                        throw Refusal("internal", "flush carries export-only fields")
                    }
                    "export" -> {
                        if (f["format"] !in EXPORT_FORMATS) throw Refusal("internal", "format")
                        val name = f["suggestedName"]
                        if (name != null && (name.length > 120 || name.contains('/') || name.contains('\\'))) {
                            throw Refusal("internal", "suggestedName")
                        }
                    }
                    else -> throw Refusal("internal", "saveOperation")
                }
            }
            "office.verify" -> {
                val path = f["path"] ?: throw Refusal("internal", "path")
                if (path.isBlank() || path.contains('\u0000') || !path.startsWith("/")) {
                    throw Refusal("internal", "path")
                }
                if (f["sha256"]?.let { !SHA256_HEX.matches(it.lowercase(Locale.ROOT)) } != false) {
                    throw Refusal("internal", "sha256")
                }
                if (f["format"] !in EXPORT_FORMATS) throw Refusal("internal", "format")
                if (f["expectCommand"] != "applyText" && f["expectCommand"] != "setCellContent") {
                    throw Refusal("internal", "expectCommand")
                }
                if (f["verificationMode"] !in VERIFICATION_MODES) {
                    throw Refusal("semanticNotInspected", "verificationMode required")
                }
                f["contentKind"]?.let {
                    if (it !in CONTENT_KINDS) throw Refusal("internal", "contentKind")
                }
                f["cellAddress"]?.let {
                    if (!CELL_ADDRESS.matches(it)) throw Refusal("internal", "cellAddress")
                }
                f["expectPartIndex"]?.let {
                    val index = it.toLongOrNull()
                    if (index == null || index !in 0..1_048_576 ||
                        it.length > 12 || it.any { c -> c !in '0'..'9' }
                    ) throw Refusal("internal", "expectPartIndex")
                }
                f["preEditSha256"]?.let {
                    if (!SHA256_HEX.matches(it.lowercase(Locale.ROOT))) throw Refusal("internal", "preEditSha256")
                }
                if (f["taskID"] != null && !validUuid(f["taskID"])) throw Refusal("internal", "taskID")
                if (f["effectOpId"] != null && f["effectOpId"]!!.let { !OP_ID.matches(it) }) {
                    throw Refusal("internal", "effectOpId")
                }
                if (f["exportOpId"] != null && f["exportOpId"]!!.let { !OP_ID.matches(it) }) {
                    throw Refusal("internal", "exportOpId")
                }
                f["targetHandle"]?.let {
                    if (!HEX32.matches(it.lowercase(Locale.ROOT))) throw Refusal("internal", "targetHandle")
                }
                when (f["verificationMode"]) {
                    "liveEffect" -> {
                        if (f["sessionToken"].isNullOrBlank() || f["targetHandle"] == null ||
                            f["effectOpId"] == null ||
                            f["generation"]?.toLongOrNull().let { it == null || it < 1 }
                        ) throw Refusal("internal", "liveEffect identity fields incomplete")
                        if (f["sessionToken"]!!.length > 128 ||
                            f["sessionToken"]!!.any { it.code < 0x20 || it == '/' || it == '\\' }
                        ) throw Refusal("internal", "sessionToken")
                    }
                    "completedJob", "reconcile" -> {
                        // The proof rides the recomputed ORIGINAL stage opIds +
                        // the artifact digest; a live session is deliberately
                        // NOT required for a valid historical proof.
                        if (f["effectOpId"] == null || f["exportOpId"] == null) {
                            throw Refusal("internal", "historical proof opIds required")
                        }
                    }
                }
                if (f["expectCommand"] == "setCellContent" && (f["cellAddress"] == null ||
                        f["contentKind"] == null)
                ) throw Refusal("internal", "setCellContent expectation fields incomplete")
                if (f["expectCommand"] == "applyText" && (f["cellAddress"] != null ||
                        f["contentKind"] != null)
                ) throw Refusal("internal", "applyText carries cell-only fields")
                if (f["format"] != "docx" && f["expectPartIndex"] == null &&
                    f["expectCommand"] == "setCellContent"
                ) throw Refusal("structureInvalid", "captured logical part index required")
            }
            "office.reconcile" -> {
                val exportOpId = f["exportOpId"] ?: throw Refusal("internal", "exportOpId")
                if (!OP_ID.matches(exportOpId)) throw Refusal("internal", "exportOpId")
                if (f["format"] !in EXPORT_FORMATS) throw Refusal("internal", "format")
            }
            "office.pushOriginal" -> {
                if (!validUuid(f["taskID"]) || !validUuid(f["workspaceID"])) {
                    throw Refusal("internal", "identity")
                }
                if (f["nativeEpoch"] != f[EPOCH]) throw Refusal("generationFenced")
                validateLogicalPath(f["logicalPath"] ?: throw Refusal("internal", "logicalPath"))
                f["hostGeneration"]?.toLongOrNull()?.let {
                    if (it < 0) throw Refusal("internal", "hostGeneration")
                }
            }
        }
    }

    /** Local mirror of the journal path grammar (the stager revalidates). */
    private fun validateLogicalPath(path: String) {
        if (path.isBlank() || path.length > 4096 || path.startsWith("/") ||
            path.startsWith("~") || path.contains('\\') ||
            path.any { it.code < 32 }
        ) throw Refusal("internal", "logicalPath")
        if (path.split('/').any { it.isEmpty() || it == "." || it == ".." }) {
            throw Refusal("internal", "logicalPath")
        }
        val extension = path.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension !in EXPORT_FORMATS) throw Refusal("unsupportedFamily", "not an OOXML family")
    }

    // ---- staged bytes ----

    fun decodeStaged(bytes: ByteArray, ticket: Ticket): String {
        val stage = stageFor(ticket.operation, ticket.fields)
        if (bytes.size > MAX_STAGED_BYTES) throw Refusal("requestTooLarge", "staged bytes over budget")
        if (stage == Stage.NONE && bytes.isNotEmpty()) {
            throw Refusal("internal", "unexpected staged bytes")
        }
        if (stage == Stage.REQUIRED && bytes.isEmpty()) {
            throw Refusal("internal", "missing staged bytes")
        }
        val limit = if (ticket.operation == "office.command" || ticket.operation == "office.verify") {
            MAX_APPLY_TEXT_BYTES
        } else {
            MAX_STAGED_BYTES
        }
        if (bytes.size > limit) throw Refusal("requestTooLarge", "staged content over the engine cap")
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            throw Refusal("internal", "staged bytes are not strict UTF-8")
        }
    }

    // ---- replies ----

    /** A terminal settlement for one claimed ticket. */
    sealed class Settlement {
        class Success(val body: JsonObject) : Settlement()
        class Failure(val code: String, val detail: String? = null) : Settlement()
    }

    fun successReply(body: JsonObjectBuilder.() -> Unit): Settlement {
        val object0 = buildJsonObject {
            put("ok", 1)
            body()
        }
        val encoded = object0.toString().toByteArray(Charsets.UTF_8)
        if (encoded.size > MAX_REPLY_BYTES) {
            // Never truncate content: an over-budget success is a typed
            // refusal (the ANSWER_TOO_LARGE discipline, host side).
            return Settlement.Failure("answerTooLarge", "the reply exceeds the bounded transport")
        }
        return Settlement.Success(object0)
    }

    fun failureReply(code: String, detail: String? = null): Settlement {
        val boundedCode = code.take(64)
        val boundedDetail = detail?.take(MAX_DETAIL_CHARS)
        var body = buildJsonObject {
            put("code", boundedCode)
            if (boundedDetail != null) put("detail", boundedDetail)
        }
        if (body.toString().toByteArray(Charsets.UTF_8).size > MAX_FAILURE_REPLY_BYTES) {
            body = buildJsonObject { put("code", boundedCode) }
        }
        return Settlement.Failure(boundedCode, boundedDetail)
    }

    fun failureBytes(code: String, detail: String?): ByteArray {
        val settlement = failureReply(code, detail) as Settlement.Failure
        fun envelope(detail: String?): ByteArray = buildJsonObject {
            put("code", settlement.code)
            detail?.let { put("detail", it) }
        }.toString().toByteArray(Charsets.UTF_8)
        var bytes = envelope(settlement.detail)
        if (bytes.size > MAX_FAILURE_REPLY_BYTES) {
            // Keep BOTH keys honestly: shrink the detail (same bounded-take
            // discipline as MAX_DETAIL_CHARS) until the envelope fits. The
            // code-only shape stays the LAST resort when even an
            // empty-detail envelope cannot fit the budget.
            var keep = settlement.detail?.length ?: 0
            while (keep > 0 && bytes.size > MAX_FAILURE_REPLY_BYTES) {
                keep = (keep * 3) / 4
                bytes = envelope(settlement.detail!!.take(keep))
            }
            if (bytes.size > MAX_FAILURE_REPLY_BYTES) {
                bytes = envelope(null)
            }
        }
        return bytes
    }

    // ---- camelCase engine/save failure tokens (shared OfficeAIHostReply
    // ---- table; ENUM.name like FLUSH_ALREADY_IN_FLIGHT -> flushAlreadyInFlight)

    fun camelToken(enumName: String): String {
        val lower = enumName.lowercase(Locale.ROOT)
        val builder = StringBuilder(lower.length)
        var upperNext = false
        for (ch in lower) {
            if (ch == '_') { upperNext = true; continue }
            builder.append(if (upperNext) ch.uppercaseChar() else ch)
            upperNext = false
        }
        return builder.toString()
    }

    // ---- Amendment/2 literal codec ----

    /**
     * Amendment/2 literal codec — Main's exact ruling (2026-10-27 review):
     * a locale-free numeric/boolean heuristic is INCOMPLETE for an EXACT
     * STRING intent (date/time shapes like `2026-10-27`, `1/2`, `12:30`,
     * locale decimal/currency shapes etc. can still be reinterpreted), so
     * the settled native apostrophe codec applies to EVERY non-empty
     * literal: one leading apostrophe before the P-A native LITERAL, with
     * the value's case and bytes otherwise preserved exactly (`true` stays
     * lowercase, `00123` keeps its leading zeros). The codec apostrophe is a
     * text-alignment marker, NOT part of the wanted value: every verifier
     * expectation and every reply/detail carries the RAW original exact
     * string. A NUMBER intent stays the canonical numeric text pasted RAW
     * (no apostrophe) so the persisted cell must be numeric; a FORMULA
     * intent really starts with `=` and rides the native FORMULA surface.
     * No guessing regex list is expanded here; the pinned producer's actual
     * apostrophe-paste behavior is Main's device batch proof (this lane is
     * source-only and claims no native verification).
     */
    fun encodeNativeLiteral(raw: String): String =
        if (raw.isEmpty()) raw else "'$raw"

    /** The codec predicate under Main's rule: every non-empty literal uses
     * the apostrophe encoding (regression documentation + test hook). */
    fun literalUsesCodec(raw: String): Boolean = raw.isNotEmpty()
}

/** Read-only helper for building success replies with an optional field set. */
internal fun kotlinx.serialization.json.JsonObjectBuilder.putOptional(
    key: String, value: String?,
) {
    if (value != null) put(key, value)
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.putOptional(
    key: String, value: Number?,
) {
    if (value != null) put(key, value)
}

internal fun kotlinx.serialization.json.JsonObjectBuilder.putOptional(
    key: String, value: Boolean?,
) {
    if (value != null) put(key, value)
}
