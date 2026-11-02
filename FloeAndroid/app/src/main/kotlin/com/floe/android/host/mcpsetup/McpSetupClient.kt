// SPDX-License-Identifier: MPL-2.0
//
// C02 host client for the reserved `floe.mcpsetup/23` channel.
//
// The App-side controller owns the user's explicit wizard operation and
// polls bounded native phases; the Swift domain owns the real project/
// environment validation, template byte verification, exec.shell jobs,
// service lane, MCP verification and MCP-domain save. No credential value,
// absolute path, raw job output or remote tool schema crosses this client.
// The template is public reviewed source bytes; chunks are bounded and the
// native side re-verifies the whole-file digest.
package com.floe.android.host.mcpsetup

import com.floe.android.bridge.SwiftCore
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal const val C02_MCP_SETUP_VERSION = 23
internal const val C02_MCP_SETUP_SCHEMA = "floe.mcpsetup/23"
internal const val C02_MCP_SETUP_TEMPLATE_SHA =
    "d484b1511e55777e57a06d6f6189e20d71dbeffdec808f56b3f54a66867e2651"
internal const val C02_MCP_SETUP_CONTRACT_SHA =
    "425829d625212d4d843cfb3b11ccd0d126cd498c3f261dfb182d2bf1e33f229c"
internal const val C02_MCP_SETUP_TEMPLATE_CHUNK = 44_000
internal const val C02_MCP_SETUP_MAX_DETAILS_BYTES = 8_192
internal const val C02_MCP_SETUP_PORT_MIN = 1_024
internal const val C02_MCP_SETUP_PORT_MAX = 65_535

internal fun interface McpSetupTransport {
    fun exchange(request: String): String
}

internal object SwiftMcpSetupTransport : McpSetupTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

class McpSetupException(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

data class McpSetupDraftDto(
    val displayName: String = "",
    val projectId: String? = null,
    val environmentId: String? = null,
    val portText: String = "8080",
    val details: String = "",
    val allowInCanvas: Boolean = false,
    val timeoutSeconds: Int = 30,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("mode", "linuxService")
        put("displayName", displayName)
        put("endpointText", "")
        put("authentication", "none")
        put("credentialHeaderName", "")
        put("allowInsecureHTTP", true)
        put("allowInCanvas", allowInCanvas)
        put("timeoutSeconds", timeoutSeconds)
        projectId?.let { put("projectID", it) }
        environmentId?.let { put("environmentID", it) }
        put("portText", portText)
        put("details", details)
    }
}

data class McpSetupProjectDto(val id: String, val name: String, val revision: String)

data class McpSetupEnvironmentDto(
    val id: String,
    val label: String,
    val backend: String,
    val containerId: String,
    val baseRevision: String,
    val layerFormat: Int,
)

data class McpSetupCapabilitiesDto(
    val epoch: Long,
    val templateBundled: Boolean,
    val serviceLaneAvailable: Boolean,
    val generationAvailable: Boolean,
    val stdioLaneAvailable: Boolean,
    val clientCompatibilityVersion: String,
    val clientPlatform: String,
)

data class McpSetupStepDto(
    val name: String,
    val state: String,
    val callId: String,
    val jobId: String?,
    val exitCode: Int?,
    val outputDigest: String?,
    val outputBytes: Int?,
    val errorCode: String?,
)

data class McpSetupReceiptDto(
    val endpoint: String,
    val smokeDigest: String,
    val verifiedTools: List<String>,
    val serverId: String?,
    val newRevision: String?,
)

data class McpSetupRecordDto(
    val id: String,
    val revision: Long,
    val phase: String,
    val busy: Boolean,
    val displayName: String,
    val projectId: String,
    val projectName: String,
    val environmentId: String,
    val environmentLabel: String,
    val containerId: String,
    val baseRevision: String,
    val allowInCanvas: Boolean,
    val port: Int,
    val workspaceRelativePath: String?,
    val serviceEndpoint: String?,
    val errorCode: String?,
    val errorMessage: String?,
    val steps: List<McpSetupStepDto>,
    val receipt: McpSetupReceiptDto?,
) {
    val isTerminal: Boolean
        get() = phase == "added" || phase == "stopped" || phase == "failed" || phase == "interrupted"
}

data class McpSetupPreflightDto(
    val valid: Boolean,
    val findings: List<String>,
    val port: Int?,
)

data class McpSetupOptionsDto(
    val projects: List<McpSetupProjectDto>,
    val environments: List<McpSetupEnvironmentDto>,
)

interface McpSetupService {
    fun capabilities(): McpSetupCapabilitiesDto
    fun projects(): List<McpSetupProjectDto>
    fun environments(projectId: String): List<McpSetupEnvironmentDto>
    fun validate(draft: McpSetupDraftDto): McpSetupPreflightDto
    fun create(draft: McpSetupDraftDto): McpSetupRecordDto
    fun stageTemplate(recordId: String, archive: ByteArray)
    fun prepare(record: McpSetupRecordDto): McpSetupRecordDto
    fun buildStart(record: McpSetupRecordDto): McpSetupRecordDto
    fun buildPoll(record: McpSetupRecordDto): McpSetupRecordDto
    fun buildCancel(record: McpSetupRecordDto): McpSetupRecordDto
    fun serviceStart(record: McpSetupRecordDto): McpSetupRecordDto
    fun verify(record: McpSetupRecordDto): McpSetupRecordDto
    fun commit(record: McpSetupRecordDto): McpSetupRecordDto
    fun stop(record: McpSetupRecordDto, discard: Boolean): McpSetupRecordDto?
    fun records(): List<McpSetupRecordDto>
}

internal class McpSetupClient(
    private val transport: McpSetupTransport = SwiftMcpSetupTransport,
) : McpSetupService {
    private val json = Json { ignoreUnknownKeys = true; isLenient = false }

    override fun capabilities(): McpSetupCapabilitiesDto {
        val response = exchange("handshake")
        return McpSetupCapabilitiesDto(
            epoch = response.long("epoch") ?: 0L,
            templateBundled = response.bool("templateBundled") ?: false,
            serviceLaneAvailable = response.bool("serviceLaneAvailable") ?: false,
            generationAvailable = response.bool("generationAvailable") ?: false,
            stdioLaneAvailable = response.bool("stdioLaneAvailable") ?: false,
            clientCompatibilityVersion = response.string("clientCompatibilityVersion") ?: "",
            clientPlatform = response.string("clientPlatform") ?: "",
        )
    }

    override fun projects(): List<McpSetupProjectDto> =
        exchange("mcp.setup.projects").requireArray("projects").map { element ->
            val row = element.jsonObject
            McpSetupProjectDto(
                id = row.string("id") ?: throw malformed("The project identity is missing."),
                name = row.string("name") ?: "",
                revision = row.string("revision") ?: "",
            )
        }

    override fun environments(projectId: String): List<McpSetupEnvironmentDto> {
        requireUuid(projectId, "projectID")
        return exchange("mcp.setup.environments") { put("projectID", projectId) }
            .requireArray("environments").map { element ->
                val row = element.jsonObject
                McpSetupEnvironmentDto(
                    id = row.string("id") ?: throw malformed("The environment identity is missing."),
                    label = row.string("label") ?: "",
                    backend = row.string("backend") ?: "",
                    containerId = row.string("containerID") ?: "",
                    baseRevision = row.string("baseRevision") ?: "",
                    layerFormat = row.int("layerFormat") ?: 0,
                )
            }
    }

    override fun validate(draft: McpSetupDraftDto): McpSetupPreflightDto {
        val response = exchange("mcp.setup.validate") {
            put("draft", draft.toJson())
        }
        val preflight = response["preflight"] as? JsonObject
            ?: throw malformed("The MCP setup preflight is missing.")
        return McpSetupPreflightDto(
            valid = preflight.bool("valid") ?: false,
            findings = preflight.requireArray("findings").mapNotNull { it.jsonPrimitive.contentOrNull },
            port = preflight.int("port"),
        )
    }

    override fun create(draft: McpSetupDraftDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.records.create") { put("draft", draft.toJson()) })

    override fun stageTemplate(recordId: String, archive: ByteArray) {
        requireUuid(recordId, "recordID")
        require(archive.isNotEmpty() && sha256(archive) == C02_MCP_SETUP_TEMPLATE_SHA) {
            "The bundled MCP template does not match its reviewed digest."
        }
        var offset = 0
        while (offset < archive.size) {
            val end = minOf(offset + C02_MCP_SETUP_TEMPLATE_CHUNK, archive.size)
            val chunk = archive.copyOfRange(offset, end)
            val complete = exchange("mcp.setup.template.chunk") {
                put("recordID", recordId)
                put("offset", offset)
                put("data", java.util.Base64.getEncoder().encodeToString(chunk))
                put("final", end == archive.size)
            }.bool("complete") ?: false
            offset = end
            if (end == archive.size && !complete) {
                throw malformed("The MCP template upload did not complete.")
            }
        }
    }

    override fun prepare(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.prepare") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun buildStart(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.build.start") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun buildPoll(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.build.poll") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun buildCancel(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.build.cancel") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun serviceStart(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.service.start") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun verify(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.verify") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun commit(record: McpSetupRecordDto): McpSetupRecordDto =
        parseRecord(exchange("mcp.setup.commit") {
            put("recordID", record.id)
            put("revision", record.revision)
        })

    override fun stop(record: McpSetupRecordDto, discard: Boolean): McpSetupRecordDto? {
        val response = exchange(if (discard) "mcp.setup.discard" else "mcp.setup.stop") {
            put("recordID", record.id)
            put("revision", record.revision)
        }
        val element = response["record"]
        if (element == null || element is kotlinx.serialization.json.JsonNull) return null
        return parseRecord(response)
    }

    override fun records(): List<McpSetupRecordDto> =
        exchange("mcp.setup.records.list").requireArray("records").map { parseRecordRow(it.jsonObject) }

    private fun parseRecord(response: JsonObject): McpSetupRecordDto =
        parseRecordRow(response["record"]?.jsonObject
            ?: throw malformed("The MCP setup record is missing."))

    private fun parseRecordRow(row: JsonObject): McpSetupRecordDto {
        val steps = row["steps"]?.jsonArray?.map { element ->
            val step = element.jsonObject
            McpSetupStepDto(
                name = step.string("name") ?: "",
                state = step.string("state") ?: "pending",
                callId = step.string("callID") ?: "",
                jobId = step.string("jobID"),
                exitCode = step.int("exitCode"),
                outputDigest = step.string("outputDigest"),
                outputBytes = step.int("outputBytes"),
                errorCode = step.string("errorCode"),
            )
        } ?: emptyList()
        val receipt = row["receipt"]?.jsonObject?.let { value ->
            McpSetupReceiptDto(
                endpoint = value.string("endpoint") ?: "",
                smokeDigest = value.string("smokeDigest") ?: "",
                verifiedTools = value["verifiedTools"]?.jsonArray
                    ?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
                serverId = value.string("serverID"),
                newRevision = value.string("newRevision"),
            )
        }
        return McpSetupRecordDto(
            id = row.string("id") ?: throw malformed("The record identity is missing."),
            revision = row.long("revision") ?: 0L,
            phase = row.string("phase") ?: "preparing",
            busy = row.bool("busy") ?: false,
            displayName = row.string("displayName") ?: "",
            projectId = row.string("projectID") ?: "",
            projectName = row.string("projectName") ?: "",
            environmentId = row.string("environmentID") ?: "",
            environmentLabel = row.string("environmentLabel") ?: "",
            containerId = row.string("containerID") ?: "",
            baseRevision = row.string("baseRevision") ?: "",
            allowInCanvas = row.bool("allowInCanvas") ?: false,
            port = row.int("port") ?: 0,
            workspaceRelativePath = row.string("workspaceRelativePath"),
            serviceEndpoint = row.string("serviceEndpoint"),
            errorCode = row.string("errorCode"),
            errorMessage = row.string("errorMessage"),
            steps = steps,
            receipt = receipt,
        )
    }

    private fun exchange(
        operation: String,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject {
        val request = buildJsonObject {
            put("version", C02_MCP_SETUP_VERSION)
            put("schema", C02_MCP_SETUP_SCHEMA)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            payload()
        }
        val raw = transport.exchange(request.toString())
        val response = runCatching { json.parseToJsonElement(raw).jsonObject }
            .getOrElse { throw malformed("The MCP setup reply was unreadable.") }
        if (response.bool("ok") != true) {
            throw McpSetupException(
                code = response.string("code") ?: "mcpSetupFailure",
                message = response.string("message") ?: "The MCP setup operation failed.",
                retryable = response.bool("retryable") ?: false,
            )
        }
        return response
    }

    private fun malformed(message: String) = McpSetupException("decode_failed", message, retryable = false)

    private fun requireUuid(value: String, field: String) {
        if (runCatching { UUID.fromString(value) }.isFailure) {
            throw McpSetupException("invalidRequest:$field", "The request identity is invalid.")
        }
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.requireArray(key: String): List<kotlinx.serialization.json.JsonElement> =
        (this[key] as? JsonArray) ?: throw malformed("The MCP setup reply has no $key list.")

    companion object {
        fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
    }
}

/**
 * Loads and verifies the App-bundled reviewed template before any byte is
 * sent to the native side. Missing or altered bytes are an honest null; the
 * wizard must not fabricate a template.
 */
object McpSetupTemplateAsset {
    private const val DIRECTORY = "mcp-template"
    private const val ARCHIVE = "floe-mcp-node-http-1.0.3-source.zip"
    private const val CONTRACT = "contract.json"

    fun load(open: (String) -> ByteArray): ByteArray? {
        val archive = runCatching { open("$DIRECTORY/$ARCHIVE") }.getOrNull() ?: return null
        val contract = runCatching { open("$DIRECTORY/$CONTRACT") }.getOrNull() ?: return null
        if (archive.size > 131_072 || contract.size > 8_192) return null
        if (McpSetupClient.sha256(archive) != C02_MCP_SETUP_TEMPLATE_SHA) return null
        if (McpSetupClient.sha256(contract) != C02_MCP_SETUP_CONTRACT_SHA) return null
        return archive
    }
}

/** Pure local preflight; the native domain re-validates before any effect. */
object McpSetupRules {
    fun findings(draft: McpSetupDraftDto): List<String> {
        val findings = ArrayList<String>()
        if (draft.displayName.trim().isEmpty() || draft.displayName.toByteArray(Charsets.UTF_8).size > 256) {
            findings += "nameRequired"
        }
        if (draft.projectId.isNullOrBlank()) findings += "projectRequired"
        if (draft.environmentId.isNullOrBlank()) findings += "environmentRequired"
        val port = draft.portText.trim().toIntOrNull()
        if (port == null || port !in C02_MCP_SETUP_PORT_MIN..C02_MCP_SETUP_PORT_MAX) {
            findings += "portInvalid"
        }
        if (draft.details.toByteArray(Charsets.UTF_8).size > C02_MCP_SETUP_MAX_DETAILS_BYTES) {
            findings += "detailsTooLong"
        }
        return findings
    }
}
