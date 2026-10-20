// SPDX-License-Identifier: MPL-2.0
//
// Callback-surface guard tests (SKL-SOURCE-NO-GRANT / MCP-REMOTE-TOOLS):
// the module's host seam must never grow its own permission, approval or
// grant authority, and it must never expose a network/transport primitive
// that would bypass the host. Installing, enabling, connecting or toggling
// a tool therefore has no dedicated "grant" channel: approvals stay with the
// existing shared policy layer.
//
// SOURCE ONLY in this stage (no Gradle/JVM run was performed).

package com.floe.android.feature.integrations

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationsCallbackSurfaceTest {

    private val methodNames: List<String> =
        IntegrationUiCallbacks::class.java.methods.map { it.name }

    @Test
    fun `the seam exposes no permission or approval authority`() {
        val forbidden = listOf("grant", "approve", "permission", "authorize", "consent")
        val offending = methodNames.filter { name ->
            forbidden.any { token -> name.lowercase().contains(token) }
        }
        assertTrue("unexpected authority-like callbacks: $offending", offending.isEmpty())
    }

    @Test
    fun `the seam exposes no network client or raw transport primitive`() {
        val forbidden = listOf("http", "socket", "connectTransport", "sendJson", "executeTool")
        val offending = methodNames.filter { name ->
            forbidden.any { token -> name.lowercase().contains(token.lowercase()) }
        }
        assertTrue("unexpected transport-like callbacks: $offending", offending.isEmpty())
    }

    @Test
    fun `the seam exposes neither persistence nor installation-file access`() {
        val forbidden = listOf("database", "persist", "unzip", "extract", "readFile", "writeFile")
        val offending = methodNames.filter { name ->
            forbidden.any { token -> name.lowercase().contains(token) }
        }
        assertTrue("unexpected storage-like callbacks: $offending", offending.isEmpty())
    }

    @Test
    fun `the save payload keeps the secret out of its printable representation`() {
        val request = McpSaveRequest(
            identity = McpEditorIdentity("new-1", 1, null),
            serverId = null,
            draft = McpDraftSnapshot(displayName = "n", endpointText = "https://host/mcp"),
            credentialIntent = CredentialDraftIntent.SET,
            credentialDraft = "do-not-print-me",
            baseRevision = null,
        )
        assertFalse(request.toString().contains("do-not-print-me"))
        assertTrue(request.toString().contains("redacted"))
    }
}
