// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import org.json.JSONObject

/**
 * Strict Kotlin mirror of the Swift-owned artifact request v1. The bridge
 * frame is 64 KiB; this lane does not spend it on a 4 MiB report. Requests are
 * <= 8 KiB, replies <= 32 KiB and failures <= 512 B.
 */
internal object NetworkArtifactWire {
    const val MAX_DESCRIPTOR_BYTES = 2_048
    const val MAX_REQUEST_BYTES = 8 * 1024
    const val MAX_REPLY_BYTES = 32 * 1024
    const val MAX_FAILURE_BYTES = 512
    const val MAX_DETAIL_CHARS = 200
    const val MAX_FILTER_PROTOCOLS = 4
    const val MAX_FILTER_SERVICES = 2
    const val MAX_HOST_CHARS = 64
    const val MAX_BUDGET_MS = 30_000

    const val OPERATION = "networkArtifact.execute"
    val METHODS = setOf("network.pcapAnalyze", "network.coverageSummary")
    private val PROTOCOLS = setOf("tcp", "udp", "icmp", "icmpv6")
    private val SERVICES = setOf("dns", "http")

    private val DESCRIPTOR_KEYS = setOf(
        "operation", "epoch", "method", "operationID", "taskID", "runID",
        "payloadBytes", "budgetMs", "workspace",
    )
    private val REQUEST_KEYS = setOf("version", "operationID", "method", "arguments")
    private val FAILURE_CODE = Regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$")
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }

    data class Ticket(
        val epoch: Long,
        val method: String,
        val operationID: UUID,
        val taskID: UUID,
        val runID: UUID,
        val payloadBytes: Int,
        val budgetMs: Long,
        val workspaceFingerprint: String?,
    )

    sealed interface Request {
        val method: String
        val operationID: UUID

        data class Pcap(
            override val operationID: UUID,
            val analysisID: String,
            val filters: ArtifactFilter,
        ) : Request {
            override val method: String get() = "network.pcapAnalyze"
        }

        data class Coverage(
            override val operationID: UUID,
            val sessionID: String,
        ) : Request {
            override val method: String get() = "network.coverageSummary"
        }
    }

    data class ArtifactFilter(
        val protocols: Set<String> = emptySet(),
        val services: Set<String> = emptySet(),
        val address: String? = null,
        val port: Int? = null,
        val startEpochMillis: Long? = null,
        val endEpochMillis: Long? = null,
    )

    class Refusal(val code: String, val detail: String? = null) : Exception(code)

    fun strictText(bytes: ByteArray): String? = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull()

    fun parseDescriptor(bytes: ByteArray, boundEpoch: Long): Ticket {
        if (bytes.isEmpty() || bytes.size > MAX_DESCRIPTOR_BYTES) {
            throw Refusal("descriptorInvalid")
        }
        val text = strictText(bytes) ?: throw Refusal("descriptorInvalid")
        val root = runCatching { json.parseToJsonElement(text).jsonObject }
            .getOrElse { throw Refusal("descriptorInvalid") }
        if (root.keys != DESCRIPTOR_KEYS) throw Refusal("descriptorInvalid")
        if (root.text("operation") != OPERATION) throw Refusal("descriptorInvalid")
        if (root.text("epoch") != boundEpoch.toString()) throw Refusal("descriptorInvalid")
        val method = root.text("method").takeIf { it in METHODS } ?: throw Refusal("descriptorInvalid")
        val operationID = root.uuid("operationID")
        val taskID = root.uuid("taskID")
        val runID = root.uuid("runID")
        val payloadBytes = root.integer("payloadBytes")
        if (payloadBytes <= 0 || payloadBytes > MAX_REQUEST_BYTES) {
            throw Refusal("requestTooLarge")
        }
        val budgetMs = root.integer("budgetMs").toLong()
        if (budgetMs <= 0 || budgetMs > MAX_BUDGET_MS) throw Refusal("descriptorInvalid")
        val workspace = (root["workspace"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?.takeIf { it.isNotEmpty() }
            ?.also {
                if (!Regex("[0-9a-f]{64}").matches(it)) throw Refusal("descriptorInvalid")
            }
        return Ticket(boundEpoch, method, operationID, taskID, runID,
            payloadBytes, budgetMs, workspace)
    }

    /**
     * The Swift tool emits Foundation's uppercase canonical UUID string, while
     * App-private store directories use lowercase `UUID.toString()`. Normalize
     * exactly one artifact identity here, before any store lookup. This is
     * identity normalization only: the ticket/owner/epoch/share checks are
     * unchanged and an opaque UUID still grants nothing by itself.
     */
    private fun canonicalArtifactId(value: String): String? {
        if (value.length != 36) return null
        val id = runCatching { UUID.fromString(value) }.getOrNull() ?: return null
        if (!id.toString().equals(value, ignoreCase = true)) return null
        if (id.mostSignificantBits == 0L && id.leastSignificantBits == 0L) return null
        return id.toString()
    }

    fun validateRequest(bytes: ByteArray, ticket: Ticket): Request {
        if (bytes.isEmpty() || bytes.size > MAX_REQUEST_BYTES) throw Refusal("requestTooLarge")
        if (bytes.size != ticket.payloadBytes) throw Refusal("requestInvalid")
        val text = strictText(bytes) ?: throw Refusal("requestInvalid")
        val root = runCatching { json.parseToJsonElement(text).jsonObject }
            .getOrElse { throw Refusal("requestInvalid") }
        if (root.keys != REQUEST_KEYS) throw Refusal("requestInvalid")
        if ((root["version"] as? JsonPrimitive)?.intOrNull != 1) throw Refusal("requestInvalid")
        val operationID = root.uuid("operationID")
        if (operationID != ticket.operationID) throw Refusal("requestInvalid")
        if (root.text("method") != ticket.method) throw Refusal("requestInvalid")
        val arguments = root["arguments"] as? JsonObject ?: throw Refusal("requestInvalid")
        return when (ticket.method) {
            "network.pcapAnalyze" -> {
                if (arguments.keys.any { it !in setOf("analysisID", "filters") }) {
                    throw Refusal("requestInvalid")
                }
                val analysisID = canonicalArtifactId(arguments.text("analysisID"))
                    ?: throw Refusal("requestInvalid")
                val filters = (arguments["filters"] as? JsonObject)?.let(::filter)
                    ?: ArtifactFilter()
                Request.Pcap(operationID, analysisID, filters)
            }
            "network.coverageSummary" -> {
                if (arguments.keys != setOf("sessionID")) throw Refusal("requestInvalid")
                val sessionID = canonicalArtifactId(arguments.text("sessionID"))
                    ?: throw Refusal("requestInvalid")
                Request.Coverage(operationID, sessionID)
            }
            else -> throw Refusal("methodUnsupported")
        }
    }

    fun failure(code: String, detail: String? = null): ByteArray {
        if (!FAILURE_CODE.matches(code)) return """{"code":"internal"}""".toByteArray()
        val root = JSONObject().put("code", code)
        detail?.take(MAX_DETAIL_CHARS)?.let { root.put("detail", it) }
        val bytes = root.toString().toByteArray(Charsets.UTF_8)
        return if (bytes.size <= MAX_FAILURE_BYTES) bytes else """{"code":"internal"}""".toByteArray()
    }

    fun failureCode(bytes: ByteArray): String? = runCatching {
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        root.optString("code").takeIf { FAILURE_CODE.matches(it) }
    }.getOrNull()

    private fun filter(value: JsonObject): ArtifactFilter {
        val allowed = setOf(
            "protocols", "services", "address", "port", "startEpochMillis", "endEpochMillis",
        )
        if (value.keys.any { it !in allowed }) throw Refusal("requestInvalid")
        val protocols = (value["protocols"] as? JsonArray)?.map { primitive ->
            (primitive as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: throw Refusal("requestInvalid")
        }?.toSet() ?: emptySet()
        if (protocols.size > MAX_FILTER_PROTOCOLS || protocols.any { it !in PROTOCOLS }) {
            throw Refusal("requestInvalid")
        }
        val services = (value["services"] as? JsonArray)?.map { primitive ->
            (primitive as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: throw Refusal("requestInvalid")
        }?.toSet() ?: emptySet()
        if (services.size > MAX_FILTER_SERVICES || services.any { it !in SERVICES }) {
            throw Refusal("requestInvalid")
        }
        val address = (value["address"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.content
            ?.let {
                if (it.length !in 1..MAX_HOST_CHARS ||
                    it.any { character -> character.isWhitespace() || character in "/@?#" }
                ) throw Refusal("requestInvalid")
                it
            }
        val port = (value["port"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            ?.also { if (it !in 1..65_535) throw Refusal("requestInvalid") }
        val start = (value["startEpochMillis"] as? JsonPrimitive)
            ?.takeIf { !it.isString }?.longOrNull
            ?.also { if (it < 0) throw Refusal("requestInvalid") }
        val end = (value["endEpochMillis"] as? JsonPrimitive)
            ?.takeIf { !it.isString }?.longOrNull
            ?.also { if (it < 0) throw Refusal("requestInvalid") }
        if (start != null && end != null && start > end) throw Refusal("requestInvalid")
        return ArtifactFilter(protocols, services, address, port, start, end)
    }

    private fun JsonObject.text(key: String): String {
        val primitive = this[key] as? JsonPrimitive ?: throw Refusal("descriptorInvalid")
        if (!primitive.isString) throw Refusal("descriptorInvalid")
        val value = primitive.content
        if (value.isEmpty() || value.length > 256 ||
            value.any { it.code < 0x20 || it.code == 0x7f }
        ) throw Refusal("descriptorInvalid")
        return value
    }

    private fun JsonObject.integer(key: String): Int {
        val primitive = this[key] as? JsonPrimitive ?: throw Refusal("descriptorInvalid")
        if (primitive.isString) throw Refusal("descriptorInvalid")
        return primitive.intOrNull ?: throw Refusal("descriptorInvalid")
    }

    private fun JsonObject.uuid(key: String): UUID {
        val value = text(key)
        return runCatching { UUID.fromString(value) }.getOrElse {
            throw Refusal("descriptorInvalid")
        }
    }
}
