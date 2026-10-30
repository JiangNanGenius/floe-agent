// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * G07.1/G07.2 network host lane — the Kotlin mirror of the Swift-owned wire
 * authority (`G07NetworkHostMailbox.swift` + `FloeAndroidNetwork`
 * `NetworkToolRequest.swift` / `NetworkObservationV1.swift`).
 *
 * This file performs ONLY closed-grammar parsing/bounding of what the
 * mailbox already handed the pump. It never decides authority, never invents
 * a measurement, never logs a target, and stores no permission state. The
 * request `host`/`url`/`subnetCidr` is parsed ONLY to hand the existing LAN
 * broker a bounded host/label hint when the service reports
 * `permissionRequired`.
 * Endpoint arguments are opaque untrusted data: normalizing a host here never
 * grants permission and never widens the request the service re-validates.
 */
internal object NetworkDiagnosticsWire {

    const val MAX_DESCRIPTOR_BYTES = 2048
    const val MAX_REQUEST_BYTES = 16 * 1024
    const val MAX_OBSERVATION_BYTES = 256 * 1024
    const val MAX_FAILURE_BYTES = 512
    const val MAX_DETAIL_CHARS = 200
    const val MAX_TARGET_HOST_CHARS = 253

    const val OPERATION = "operation"
    const val EPOCH = "epoch"
    const val METHOD = "method"
    const val OPERATION_ID = "operationID"
    const val TASK_ID = "taskID"
    const val RUN_ID = "runID"
    const val PAYLOAD_BYTES = "payloadBytes"
    const val BUDGET_MS = "budgetMs"

    const val EXECUTE_OPERATION = "network.execute"

    val METHODS = setOf(
        "network.status",
        "network.wifiScan",
        "network.dnsLookup",
        "network.ping",
        "network.tcpProbe",
        "network.http",
        "network.lanDiscover",
        "network.speedTest",
    )

    val STATUSES = setOf(
        "ok", "partial", "permissionRequired", "unavailable",
        "unsupported", "cancelled", "timeout", "error",
    )

    private val DESCRIPTOR_KEYS = setOf(
        OPERATION, EPOCH, METHOD, OPERATION_ID, TASK_ID, RUN_ID,
        PAYLOAD_BYTES, BUDGET_MS,
    )
    private val REQUEST_KEYS = setOf("version", "operationID", "method", "arguments")
    private val FAILURE_CODE = Regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$")

    data class Ticket(
        val epoch: Long,
        val method: String,
        val operationID: String,
        val taskID: String,
        val runID: String,
        val payloadBytes: Int,
        val budgetMs: Long,
    )

    data class RequestFacts(
        val method: String,
        /**
         * Host only (no scheme, path, query, userinfo or port). For
         * `network.lanDiscover` this is the subnet's network address; an
         * mDNS-only browse has no concrete endpoint and stays null. For
         * `network.speedTest` it is the requested direction's endpoint host
         * (local-looking endpoint preferred for downloadAndUpload).
         */
        val targetHost: String?,
    )

    /** Typed pre-dispatch refusal: settle exactly `{"code":token}`. */
    class Refusal(val code: String, val detail: String? = null) : Exception(code)

    /** Pure host-side strict UTF-8 decode. Never touches the JNI object, so
     * JVM pump regressions can inject a fake transport without loading the
     * native library. */
    internal fun strictText(bytes: ByteArray): String? = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull()

    private fun JsonObject.text(key: String): String {
        val primitive = this[key] as? JsonPrimitive ?: throw Refusal("descriptorInvalid")
        if (!primitive.isString) throw Refusal("descriptorInvalid")
        val value = primitive.content
        if (value.isEmpty() || value.length > 256 ||
            value.any { it.code < 0x20 || it.code == 0x7f }
        ) {
            throw Refusal("descriptorInvalid")
        }
        return value
    }

    private fun JsonObject.int(key: String): Int {
        val primitive = this[key] as? JsonPrimitive ?: throw Refusal("descriptorInvalid")
        if (primitive.isString) throw Refusal("descriptorInvalid")
        return primitive.intOrNull ?: throw Refusal("descriptorInvalid")
    }

    private fun uuid(value: String): UUID = try {
        UUID.fromString(value)
    } catch (_: IllegalArgumentException) {
        throw Refusal("descriptorInvalid")
    }

    /** Strict parse of one claimed descriptor against the pump's bound epoch. */
    fun parseDescriptor(bytes: ByteArray, boundEpoch: Long): Ticket {
        if (bytes.isEmpty() || bytes.size > MAX_DESCRIPTOR_BYTES) {
            throw Refusal("descriptorInvalid")
        }
        val text = strictText(bytes) ?: throw Refusal("descriptorInvalid")
        val objectValue = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (_: Exception) {
            throw Refusal("descriptorInvalid")
        }
        if (objectValue.keys != DESCRIPTOR_KEYS) throw Refusal("descriptorInvalid")
        if (objectValue.text(OPERATION) != EXECUTE_OPERATION) {
            throw Refusal("descriptorInvalid")
        }
        if (objectValue.text(EPOCH) != boundEpoch.toString()) {
            // A foreign/stale generation is fenced, never retried.
            throw Refusal("descriptorInvalid")
        }
        val method = objectValue.text(METHOD)
        if (method !in METHODS) throw Refusal("descriptorInvalid")
        val operationID = uuid(objectValue.text(OPERATION_ID))
        val taskID = uuid(objectValue.text(TASK_ID))
        val runID = uuid(objectValue.text(RUN_ID))
        val payloadBytes = objectValue.int(PAYLOAD_BYTES)
        if (payloadBytes <= 0 || payloadBytes > MAX_REQUEST_BYTES) {
            throw Refusal("requestTooLarge")
        }
        val budgetMs = objectValue.int(BUDGET_MS).toLong()
        if (budgetMs <= 0 || budgetMs > 120_000) throw Refusal("descriptorInvalid")
        return Ticket(
            epoch = boundEpoch,
            method = method,
            operationID = operationID.toString(),
            taskID = taskID.toString(),
            runID = runID.toString(),
            payloadBytes = payloadBytes,
            budgetMs = budgetMs,
        )
    }

    /**
     * Validates the staged request v1 against the descriptor and extracts a
     * HOST-ONLY target hint for the existing permission broker. Paths,
     * queries, userinfo and ports never leave this function.
     */
    fun validateRequest(bytes: ByteArray, ticket: Ticket): RequestFacts {
        if (bytes.isEmpty() || bytes.size > MAX_REQUEST_BYTES) {
            throw Refusal("requestTooLarge")
        }
        if (bytes.size != ticket.payloadBytes) throw Refusal("requestInvalid")
        val text = strictText(bytes) ?: throw Refusal("requestInvalid")
        val root = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (_: Exception) {
            throw Refusal("requestInvalid")
        }
        if (root.keys != REQUEST_KEYS) throw Refusal("requestInvalid")
        val version = (root["version"] as? JsonPrimitive)?.intOrNull
            ?: throw Refusal("requestInvalid")
        if (version != 1) throw Refusal("requestInvalid")
        val operationID = root.text(OPERATION_ID)
        val requestUUID = try {
            UUID.fromString(operationID)
        } catch (_: IllegalArgumentException) {
            throw Refusal("requestInvalid")
        }
        if (requestUUID.toString() != ticket.operationID) {
            throw Refusal("requestInvalid")
        }
        if (root.text(METHOD) != ticket.method) throw Refusal("requestInvalid")
        val arguments = root["arguments"] as? JsonObject
            ?: throw Refusal("requestInvalid")
        return RequestFacts(ticket.method, targetHost(arguments))
    }

    private fun targetHost(arguments: JsonObject): String? {
        (arguments["host"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?.let { return safeHost(it) }
        // G07.1 network.http keeps its original url-host hint unchanged.
        arguments.urlHost("url")?.let { return it }
        // network.lanDiscover: the subnet scan's network address is the only
        // concrete hint. mDNS-only discovery has no endpoint, so it stays null
        // and the existing host permission surface owns the guidance.
        (arguments["subnetCidr"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?.substringBefore('/')
            ?.let { return safeHost(it) }
        val download = arguments.urlHost("downloadUrl")
        val upload = arguments.urlHost("uploadUrl")
        val direction = (arguments["direction"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content ?: "download"
        return when (direction) {
            "upload" -> upload
            "downloadAndUpload" ->
                // Prefer a local-looking endpoint so the existing broker gets
                // the useful hint when only one direction is local. The
                // service remains authoritative for the actual route.
                listOfNotNull(download, upload).firstOrNull { isLocalHint(it) }
                    ?: download ?: upload
            else -> download ?: upload
        }
    }

    private fun JsonObject.urlHost(key: String): String? {
        val url = (this[key] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content ?: return null
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return null
        return safeHost(host)
    }

    private fun isLocalHint(host: String): Boolean {
        if (host.endsWith(".local")) return true
        if (host == "::1" || host.startsWith("fe80:") ||
            host.startsWith("fc") || host.startsWith("fd")
        ) {
            return true
        }
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.mapNotNull { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false
        return when {
            octets[0] == 10 -> true
            octets[0] == 172 && octets[1] in 16..31 -> true
            octets[0] == 192 && octets[1] == 168 -> true
            octets[0] == 127 -> true
            else -> false
        }
    }

    private fun safeHost(value: String): String? {
        val host = value.trim()
            .removePrefix("[").removeSuffix("]")
            .trimEnd('.')
            .lowercase(Locale.ROOT)
        if (host.isEmpty() || host.length > MAX_TARGET_HOST_CHARS) return null
        if (host.any { it.code < 0x20 || it.code == 0x7f || it.isWhitespace() }) return null
        return host
    }

    /**
     * Validates the observation identity/envelope (not the measurements).
     * Returns the status token; throws `observationInvalid` for a cross-wired
     * or structurally broken reply. Swift re-validates the full typed model.
     */
    fun validateObservation(bytes: ByteArray, ticket: Ticket): String {
        if (bytes.isEmpty() || bytes.size > MAX_OBSERVATION_BYTES) {
            throw Refusal("observationInvalid")
        }
        val text = strictText(bytes) ?: throw Refusal("observationInvalid")
        val root = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (_: Exception) {
            throw Refusal("observationInvalid")
        }
        val version = (root["version"] as? JsonPrimitive)?.intOrNull
            ?: throw Refusal("observationInvalid")
        if (version != 1) throw Refusal("observationInvalid")
        val operationID = (root[OPERATION_ID] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?: throw Refusal("observationInvalid")
        val replyUUID = try {
            UUID.fromString(operationID)
        } catch (_: IllegalArgumentException) {
            throw Refusal("observationInvalid")
        }
        if (replyUUID.toString() != ticket.operationID) {
            throw Refusal("observationInvalid")
        }
        val method = (root[METHOD] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?: throw Refusal("observationInvalid")
        if (method != ticket.method) throw Refusal("observationInvalid")
        val source = (root["source"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?: throw Refusal("observationInvalid")
        if (source != "phone") throw Refusal("observationInvalid")
        val status = (root["status"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?: throw Refusal("observationInvalid")
        if (status !in STATUSES) throw Refusal("observationInvalid")
        return status
    }

    private fun permissionNames(root: JsonObject): List<String> {
        val array = root["missingPermissions"] as? JsonArray ?: return emptyList()
        return array.asSequence()
            .mapNotNull { (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content }
            .filter { value ->
                // The phone service is the trust boundary here; accept its
                // bounded permission token whether or not it uses the full
                // `android.permission.` prefix, but never control bytes.
                value.length <= 128 &&
                    value.none { it.code < 0x20 || it.code == 0x7f }
            }
            .take(16)
            .toList()
    }

    /** Non-null only for a valid permissionRequired observation. */
    fun permissionRequest(
        bytes: ByteArray,
        ticket: Ticket,
        facts: RequestFacts,
    ): NetworkPermissionRequest? {
        val text = strictText(bytes) ?: return null
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()
            ?: return null
        val status = (root["status"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content ?: return null
        if (status != "permissionRequired") return null
        val missing = permissionNames(root)
        if (missing.isEmpty()) return null
        val label = when {
            ticket.method != "network.lanDiscover" -> null
            facts.targetHost == null -> "Local network discovery (.local/mDNS)"
            else -> "LAN subnet ${facts.targetHost.orEmpty()}"
        }
        return NetworkPermissionRequest(
            operationID = ticket.operationID,
            method = ticket.method,
            missingPermissions = missing,
            targetHost = facts.targetHost,
            targetLabel = label,
        )
    }

    /** Bounded typed failure body; never truncates a success payload. */
    fun failureBytes(code: String, detail: String?): ByteArray {
        val safeCode = if (FAILURE_CODE.matches(code)) code else "internal"
        val safeDetail = detail?.filter { it.code >= 0x20 && it.code != 0x7f }
            ?.take(MAX_DETAIL_CHARS)
        val body = buildJsonObject {
            put("code", safeCode)
            if (!safeDetail.isNullOrEmpty()) put("detail", safeDetail)
        }
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        if (bytes.size <= MAX_FAILURE_BYTES) return bytes
        return buildJsonObject { put("code", "internal") }
            .toString().toByteArray(Charsets.UTF_8)
    }
}
