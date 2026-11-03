// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.mcpsetup

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class McpSetupClientTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun asset(path: String): ByteArray {
        val candidates = listOf(
            File("feature/integrations/src/main/assets/$path"),
            File("../feature/integrations/src/main/assets/$path"),
            File("src/main/assets/$path"),
        )
        return candidates.first { it.isFile }.readBytes()
    }

    private fun archive(): ByteArray =
        asset("mcp-template/floe-mcp-node-http-1.0.3-source.zip")

    @Test
    fun templateAssetVerifiesBundledBytesAndRejectsChanges() {
        val open: (String) -> ByteArray = { path -> asset(path) }
        assertNotNull(McpSetupTemplateAsset.load(open))
        val altered: (String) -> ByteArray = { path ->
            val bytes = asset(path)
            if (path.endsWith(".zip")) bytes.copyOf().also { it[0] = (it[0] + 1).toByte() } else bytes
        }
        assertNull(McpSetupTemplateAsset.load(altered))
    }

    @Test
    fun stageTemplateUsesBoundedChunksAndExactDigest() {
        val archive = archive()
        val requests = ArrayList<JsonObject>()
        val transport = McpSetupTransport { raw ->
            val request = json.parseToJsonElement(raw).jsonObject
            requests += request
            buildJsonObject {
                put("ok", true)
                put("schema", C02_MCP_SETUP_SCHEMA)
                put("operation", request["operation"]?.jsonPrimitive?.content)
                put("requestID", request["requestID"]?.jsonPrimitive?.content)
                put("complete", request["final"]?.jsonPrimitive?.content == "true")
            }.toString()
        }
        val client = McpSetupClient(transport)
        client.stageTemplate("11111111-1111-1111-1111-111111111111", archive)
        assertEquals(2, requests.size)
        assertEquals("mcp.setup.template.chunk", requests[0]["operation"]?.jsonPrimitive?.content)
        assertEquals("0", requests[0]["offset"]?.jsonPrimitive?.content)
        assertEquals("44000", requests[1]["offset"]?.jsonPrimitive?.content)
        val joined = requests.map {
            Base64.getDecoder().decode(it["data"]!!.jsonPrimitive.content)
        }.reduce { a, b -> a + b }
        assertTrue(joined.contentEquals(archive))
        assertFalse(requests.any { it.toString().contains("credential", ignoreCase = true) })
    }

    @Test
    fun recordProjectionParsesStepsAndReceiptWithoutSecrets() {
        val transport = McpSetupTransport {
            buildJsonObject {
                put("ok", true)
                put("schema", C02_MCP_SETUP_SCHEMA)
                put("operation", "mcp.setup.verify")
                put("requestID", "r1")
                put(
                    "record",
                    buildJsonObject {
                        put("id", "11111111-1111-1111-1111-111111111111")
                        put("revision", 4)
                        put("phase", "ready")
                        put("busy", false)
                        put("displayName", "Local tools")
                        put("projectID", "22222222-2222-2222-2222-222222222222")
                        put("projectName", "Project")
                        put("environmentID", "env-1")
                        put("environmentLabel", "Linux")
                        put("containerID", "container-1")
                        put("baseRevision", "base")
                        put("allowInCanvas", false)
                        put("port", 8080)
                        put(
                            "steps",
                            kotlinx.serialization.json.JsonArray(
                                listOf(
                                    buildJsonObject {
                                        put("name", "probe")
                                        put("state", "completed")
                                        put("callID", "mcp.setup.probe.x")
                                        put("exitCode", 0)
                                    },
                                ),
                            ),
                        )
                        put(
                            "receipt",
                            buildJsonObject {
                                put("endpoint", "http://127.0.0.1:8080/mcp")
                                put("smokeDigest", "a".repeat(64))
                                put(
                                    "verifiedTools",
                                    kotlinx.serialization.json.JsonArray(
                                        listOf(kotlinx.serialization.json.JsonPrimitive("service_status")),
                                    ),
                                )
                            },
                        )
                    },
                )
            }.toString()
        }
        val record = McpSetupClient(transport).verify(
            McpSetupRecordDto(
                id = "11111111-1111-1111-1111-111111111111",
                revision = 3,
                phase = "verifying",
                busy = true,
                displayName = "",
                projectId = "",
                projectName = "",
                environmentId = "",
                environmentLabel = "",
                containerId = "",
                baseRevision = "",
                allowInCanvas = false,
                port = 0,
                workspaceRelativePath = null,
                serviceEndpoint = null,
                errorCode = null,
                errorMessage = null,
                steps = emptyList(),
                receipt = null,
            ),
        )
        assertEquals("ready", record.phase)
        assertEquals(1, record.steps.size)
        assertEquals("service_status", record.receipt?.verifiedTools?.first())
        assertFalse(record.toString().contains("credential", ignoreCase = true))
    }

    @Test
    fun setupErrorsAreTypedAndBounded() {
        val transport = McpSetupTransport {
            buildJsonObject {
                put("ok", false)
                put("schema", C02_MCP_SETUP_SCHEMA)
                put("code", "serviceLaneUnavailable")
                put("message", "The Linux service runtime is not available.")
                put("retryable", true)
            }.toString()
        }
        val failure = runCatching { McpSetupClient(transport).capabilities() }.exceptionOrNull()
        assertTrue(failure is McpSetupException)
        failure as McpSetupException
        assertEquals("serviceLaneUnavailable", failure.code)
        assertTrue(failure.retryable)
    }

    @Test
    fun draftRulesMatchNativePreflightShape() {
        assertTrue(
            McpSetupRules.findings(
                McpSetupDraftDto(
                    displayName = "Tools",
                    projectId = "p",
                    environmentId = "e",
                    portText = "8080",
                ),
            ).isEmpty(),
        )
        val invalid = McpSetupRules.findings(
            McpSetupDraftDto(
                displayName = "",
                projectId = null,
                environmentId = null,
                portText = "80",
                details = "x".repeat(C02_MCP_SETUP_MAX_DETAILS_BYTES + 1),
            ),
        )
        assertTrue(invalid.contains("nameRequired"))
        assertTrue(invalid.contains("projectRequired"))
        assertTrue(invalid.contains("environmentRequired"))
        assertTrue(invalid.contains("portInvalid"))
        assertTrue(invalid.contains("detailsTooLong"))
    }
}
