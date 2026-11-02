// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.integrations.CredentialDraftIntent
import com.floe.android.feature.integrations.McpAuthenticationUi
import com.floe.android.feature.integrations.McpDraftSnapshot
import com.floe.android.feature.integrations.McpEditorIdentity
import com.floe.android.feature.integrations.McpSaveRequest
import com.floe.android.feature.integrations.McpTransportKindUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN wire regression for the MCP saved-definition lifecycle.
 * Pure JSON/projection checks only: the native domain owns storage, binding
 * and admission.
 */
class IntegrationsHostControllerTest {
    private val identity = McpEditorIdentity(
        editorId = "new-1", epoch = 1, serverId = null)

    @Test
    fun rootlessStdioCandidateCarriesCommandWithoutInventingBindingIdentity() {
        val request = McpSaveRequest(
            identity = identity,
            serverId = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            draft = McpDraftSnapshot(
                displayName = "Local tool",
                transportKind = McpTransportKindUi.STDIO,
                stdioCommand = "node",
                stdioArgumentsText = "server.js\n--verbose",
                stdioWorkingDirectory = "apps/mcp",
            ),
            credentialIntent = CredentialDraftIntent.CLEAR,
            credentialDraft = null,
            baseRevision = null,
        )
        val candidate = IntegrationsWire.mcpCandidateJson(
            request, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", create = true)
        assertEquals("stdio", candidate["transport"]?.jsonPrimitive?.content)
        assertFalse(candidate.containsKey("endpoint"))
        assertFalse(candidate.containsKey("credentialHeaderName"))
        val stdio = checkNotNull(candidate["stdio"]?.jsonObject)
        assertEquals("node", stdio["command"]?.jsonPrimitive?.content)
        assertEquals(
            listOf("server.js", "--verbose"),
            checkNotNull(stdio["arguments"]?.jsonArray)
                .map { it.jsonPrimitive.content },
        )
        assertEquals("apps/mcp", stdio["workingDirectory"]?.jsonPrimitive?.content)
        for (forbidden in listOf(
            "projectID", "environmentID", "rootIdentity", "taskID", "revision",
        )) {
            assertFalse(forbidden, stdio.containsKey(forbidden))
        }
        assertEquals("none", candidate["authentication"]?.jsonPrimitive?.content)
    }

    @Test
    fun httpCandidateKeepsTheOriginalEndpointShape() {
        val request = McpSaveRequest(
            identity = identity,
            serverId = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            draft = McpDraftSnapshot(
                displayName = "Remote",
                endpointText = "https://example.com/mcp",
                authentication = McpAuthenticationUi.BEARER_TOKEN,
            ),
            credentialIntent = CredentialDraftIntent.KEEP_EXISTING,
            credentialDraft = null,
            baseRevision = null,
        )
        val candidate = IntegrationsWire.mcpCandidateJson(
            request, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", create = false)
        assertEquals(
            "https://example.com/mcp",
            candidate["endpoint"]?.jsonPrimitive?.content,
        )
        assertEquals("streamableHTTP", candidate["transport"]?.jsonPrimitive?.content)
        assertEquals(
            "bearerToken", candidate["authentication"]?.jsonPrimitive?.content)
        assertFalse(candidate.containsKey("stdio"))
    }

    @Test
    fun stdioListRowDecodesDefinitionAndUnboundState() {
        val value = Json.parseToJsonElement(
            """
            {"servers":[
              {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
               "displayName":"Local tool","endpoint":null,
               "transport":"stdio",
               "stdio":null,
               "stdioDefinition":{"command":"node","arguments":["server.js"],
                 "workingDirectory":"apps/mcp"},
               "stdioBindingState":"unbound",
               "enabled":false,"allowInCanvas":false,
               "allowInsecureHTTP":false,"authentication":"none",
               "credential":{"required":false,"state":"noneConfigured"},
               "revision":{"resourceID":"mcp.AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                 "version":"digest"},
               "connection":{"state":"inactive"},"toolCount":0,"tools":[],
               "disabledRemoteToolNames":[]}
            ],"hasMore":false,"nextCursor":null}
            """.trimIndent(),
        )
        val page = checkNotNull(IntegrationsWire.decodeMcpServersPage(value))
        val row = page.servers.single()
        assertEquals(McpTransportKindUi.STDIO, row.transportKind)
        assertEquals("node", row.stdioCommand)
        assertEquals(listOf("server.js"), row.stdioArguments)
        assertEquals("apps/mcp", row.stdioWorkingDirectory)
        assertEquals(false, row.stdioBound)
        assertEquals("stdio · node", row.endpointDisplay)
        assertFalse(row.enabled)
    }

    @Test
    fun legacyHttpListRowDefaultsToHttp() {
        val value = Json.parseToJsonElement(
            """
            {"servers":[
              {"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
               "displayName":"Remote","endpoint":"https://example.com/mcp",
               "enabled":true,"allowInCanvas":false,
               "allowInsecureHTTP":false,"authentication":"none",
               "credential":{"required":false,"state":"noneConfigured"},
               "revision":{"resourceID":"mcp.BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                 "version":"digest"},
               "connection":{"state":"inactive"},"toolCount":0,"tools":[]}
            ],"hasMore":false,"nextCursor":null}
            """.trimIndent(),
        )
        val page = checkNotNull(IntegrationsWire.decodeMcpServersPage(value))
        val row = page.servers.single()
        assertEquals(McpTransportKindUi.STREAMABLE_HTTP, row.transportKind)
        assertNull(row.stdioCommand)
        assertNull(row.stdioBound)
        assertEquals("https://example.com/mcp", row.endpointDisplay)
    }
}
