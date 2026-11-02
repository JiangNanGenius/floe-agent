// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.integrations

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Authored NOTRUN display/preflight regression for the saved stdio draft. */
class McpStdioDraftTest {
    private fun stdioDraft(
        command: String = "node",
        directory: String = "apps/mcp",
    ) = McpDraftSnapshot(
        displayName = "Local tool",
        transportKind = McpTransportKindUi.STDIO,
        stdioCommand = command,
        stdioArgumentsText = "server.js",
        stdioWorkingDirectory = directory,
    )

    @Test
    fun commandIsRequiredButEndpointIsNot() {
        assertEquals(
            McpPreflightFinding.COMMAND_REQUIRED,
            McpFormPreflight.looksInvalid(stdioDraft(command = "  ")),
        )
        assertNull(McpFormPreflight.looksInvalid(stdioDraft()))
    }

    @Test
    fun workingDirectoryMustStayRelativeToTheProject() {
        assertEquals(
            McpPreflightFinding.WORKING_DIRECTORY_INVALID,
            McpFormPreflight.looksInvalid(stdioDraft(directory = "/tmp")),
        )
        assertEquals(
            McpPreflightFinding.WORKING_DIRECTORY_INVALID,
            McpFormPreflight.looksInvalid(stdioDraft(directory = "../outside")),
        )
    }

    @Test
    fun stdioNeverCarriesATransportCredentialIntent() {
        val draft = stdioDraft().copy(
            authentication = McpAuthenticationUi.BEARER_TOKEN,
        )
        assertEquals(
            CredentialDraftIntent.CLEAR,
            McpCredentialIntent.compute(
                draft = draft,
                typedSecret = "typed",
                seed = McpEditorSeedUi(
                    serverId = null,
                    displayName = "Local tool",
                    endpointText = "",
                    enabled = true,
                    allowInCanvas = false,
                    allowInsecureHttp = false,
                    authentication = McpAuthenticationUi.NONE,
                    credentialHeaderName = "Authorization",
                    credentialStored = false,
                    timeoutSeconds = 30,
                    transport = McpTransportUi.Stdio(
                        McpStdioBindingUi(McpStdioBindingStateUi.UNBOUND),
                    ),
                    transportKind = McpTransportKindUi.STDIO,
                    stdioCommand = "node",
                    tools = emptyList(),
                    networkActionsAvailable = true,
                    networkActionsUnavailableReason = null,
                ),
                seedOriginToken = null,
                currentOriginToken = null,
            ),
        )
    }
}
