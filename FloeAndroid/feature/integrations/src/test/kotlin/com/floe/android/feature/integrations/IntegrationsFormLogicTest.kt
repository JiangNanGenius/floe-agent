// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation-logic tests (no Compose, no device, no host):
//  - MCP display preflight mirrors the Swift rules only for early field
//    highlighting (the host remains authoritative);
//  - credential intent computation mirrors MCPSettingsCenter.upsert;
//  - endpoint origin comparison mirrors the credential-account binding;
//  - the no-fake-availability rules: offer/connection/count claims are never
//    derived from local toggles (SKL-DISCOVER-USABLE; SKL-SOURCE-NO-GRANT).
//
// These tests are SOURCE ONLY in this stage: no Gradle/JVM run was performed
// by the source lane, so they are evidence of intended behavior, not a test
// result claim.

package com.floe.android.feature.integrations

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationsFormLogicTest {

    /* ------------------------- MCP display preflight ------------------------- */

    @Test
    fun `blank name is reported before anything else`() {
        val draft = McpDraftSnapshot(displayName = "", endpointText = "https://host/mcp")
        assertEquals(McpPreflightFinding.NAME_REQUIRED, McpFormPreflight.looksInvalid(draft))
    }

    @Test
    fun `endpoint must parse as http or https`() {
        assertEquals(
            McpPreflightFinding.ENDPOINT_REQUIRED,
            McpFormPreflight.looksInvalid(McpDraftSnapshot(displayName = "n", endpointText = "")),
        )
        assertEquals(
            McpPreflightFinding.ENDPOINT_UNPARSEABLE,
            McpFormPreflight.looksInvalid(McpDraftSnapshot(displayName = "n", endpointText = "not a url")),
        )
        assertEquals(
            McpPreflightFinding.ENDPOINT_UNPARSEABLE,
            McpFormPreflight.looksInvalid(McpDraftSnapshot(displayName = "n", endpointText = "ftp://host/x")),
        )
    }

    @Test
    fun `plain http requires the explicit insecure opt-in`() {
        val base = McpDraftSnapshot(displayName = "n", endpointText = "http://192.168.1.5:8080/mcp")
        assertEquals(McpPreflightFinding.INSECURE_HTTP_NOT_ALLOWED, McpFormPreflight.looksInvalid(base))
        assertNull(McpFormPreflight.looksInvalid(base.copy(allowInsecureHttp = true)))
    }

    @Test
    fun `credentials embedded in the url are flagged`() {
        val draft = McpDraftSnapshot(
            displayName = "n",
            endpointText = "https://user:pass@host/mcp",
        )
        assertEquals(McpPreflightFinding.ENDPOINT_EMBEDS_CREDENTIAL, McpFormPreflight.looksInvalid(draft))
    }

    @Test
    fun `custom header names follow the Swift token and reserved rules`() {
        val draft = McpDraftSnapshot(
            displayName = "n",
            endpointText = "https://host/mcp",
            authentication = McpAuthenticationUi.CUSTOM_HEADER,
            credentialHeaderName = "X-Api-Key",
        )
        assertNull(McpFormPreflight.looksInvalid(draft))
        for (reserved in listOf("host", "Content-Type", "mcp-session-id")) {
            assertEquals(
                McpPreflightFinding.HEADER_NAME_INVALID,
                McpFormPreflight.looksInvalid(draft.copy(credentialHeaderName = reserved)),
            )
        }
        assertEquals(
            McpPreflightFinding.HEADER_NAME_INVALID,
            McpFormPreflight.looksInvalid(draft.copy(credentialHeaderName = "Bad Header")),
        )
        assertEquals(
            McpPreflightFinding.HEADER_NAME_INVALID,
            McpFormPreflight.looksInvalid(draft.copy(credentialHeaderName = "mcp-param-x")),
        )
    }

    @Test
    fun `timeout is clamped to the Swift init range`() {
        assertEquals(5, McpFormPreflight.clampTimeoutSeconds(1))
        assertEquals(30, McpFormPreflight.clampTimeoutSeconds(30))
        assertEquals(120, McpFormPreflight.clampTimeoutSeconds(300))
    }

    /* ----------------------------- origin token ----------------------------- */

    @Test
    fun `origin token ignores path and query but not host scheme or port`() {
        val a = McpEndpointOrigin.parse("https://Example.com./mcp?x=1")
        val b = McpEndpointOrigin.parse("https://example.com/other")
        assertNotNull(a)
        assertEquals(a!!.accountToken, b!!.accountToken)
        assertTrue(
            McpDraftLogic.endpointChangedOrigin(
                "https://host-a/mcp",
                "https://host-b/mcp",
            ),
        )
        assertFalse(
            McpDraftLogic.endpointChangedOrigin(
                "https://host/mcp",
                "https://host/mcp/v2",
            ),
        )
        assertNull(McpEndpointOrigin.parse(""))
        assertNull(McpEndpointOrigin.parse("garbage"))
    }

    /* --------------------------- credential intent --------------------------- */

    private fun seed(
        stored: Boolean,
        serverId: String? = "server-1",
        endpoint: String = "https://host/mcp",
    ) = McpEditorSeedUi(
        serverId = serverId,
        displayName = "Server",
        endpointText = endpoint,
        enabled = true,
        allowInCanvas = false,
        allowInsecureHttp = false,
        authentication = McpAuthenticationUi.BEARER_TOKEN,
        credentialHeaderName = "Authorization",
        credentialStored = stored,
        timeoutSeconds = 30,
        transport = McpTransportUi.StreamableHttp,
        tools = emptyList(),
        networkActionsAvailable = true,
        networkActionsUnavailableReason = null,
    )

    @Test
    fun `auth none clears the stored credential`() {
        val intent = McpCredentialIntent.compute(
            draft = McpDraftSnapshot(authentication = McpAuthenticationUi.NONE),
            typedSecret = "ignored",
            seed = seed(stored = true),
            seedOriginToken = "https://host:443",
            currentOriginToken = "https://host:443",
        )
        assertEquals(CredentialDraftIntent.CLEAR, intent)
    }

    @Test
    fun `typed secret is a set even when a credential is stored`() {
        val intent = McpCredentialIntent.compute(
            draft = McpDraftSnapshot(authentication = McpAuthenticationUi.BEARER_TOKEN),
            typedSecret = "secret",
            seed = seed(stored = true),
            seedOriginToken = "https://host:443",
            currentOriginToken = "https://host:443",
        )
        assertEquals(CredentialDraftIntent.SET, intent)
    }

    @Test
    fun `empty draft keeps an existing secret only on the same origin`() {
        val keep = McpCredentialIntent.compute(
            draft = McpDraftSnapshot(authentication = McpAuthenticationUi.BEARER_TOKEN),
            typedSecret = null,
            seed = seed(stored = true),
            seedOriginToken = "https://host:443",
            currentOriginToken = "https://host:443",
        )
        assertEquals(CredentialDraftIntent.KEEP_EXISTING, keep)

        val changed = McpCredentialIntent.compute(
            draft = McpDraftSnapshot(authentication = McpAuthenticationUi.BEARER_TOKEN),
            typedSecret = null,
            seed = seed(stored = true),
            seedOriginToken = "https://old-host:443",
            currentOriginToken = "https://new-host:443",
        )
        assertEquals(CredentialDraftIntent.MISSING, changed)
    }

    @Test
    fun `nothing stored and nothing typed is missing, never a fake keep`() {
        val intent = McpCredentialIntent.compute(
            draft = McpDraftSnapshot(authentication = McpAuthenticationUi.CUSTOM_HEADER),
            typedSecret = "",
            seed = seed(stored = false),
            seedOriginToken = "https://host:443",
            currentOriginToken = "https://host:443",
        )
        assertEquals(CredentialDraftIntent.MISSING, intent)
    }

    /* ------------------------------ draft toggles ----------------------------- */

    @Test
    fun `tool toggles are projected from disabledRemoteToolNames`() {
        val tool = McpToolRowUi(
            remoteName = "search",
            displayName = "Search",
            toolDescription = "d",
            enabled = true,
            readOnlyHint = true,
            destructiveHint = false,
        )
        val disabled = McpDraftLogic.toggleTool(McpDraftSnapshot(), "search", enabled = false)
        assertFalse(McpDraftLogic.toolEnabled(disabled, tool))
        assertTrue(McpDraftLogic.toolEnabled(McpDraftLogic.toggleTool(disabled, "search", true), tool))
        assertEquals(setOf("search"), disabled.disabledRemoteToolNames)
    }

    /* -------------------------- no-fake-availability -------------------------- */

    @Test
    fun `catalog actions map states one-to-one`() {
        assertTrue(SkillsDisplayLogic.catalogAction(CatalogCardStateUi.NotInstalled) == CatalogCardAction.Install)
        assertTrue(SkillsDisplayLogic.catalogAction(CatalogCardStateUi.InstalledNeedsEnable) == CatalogCardAction.Enable)
        assertEquals(
            CatalogCardAction.OpenUpgrade("2.0.0"),
            SkillsDisplayLogic.catalogAction(CatalogCardStateUi.UpdateTo("2.0.0")),
        )
        assertEquals(
            CatalogCardAction.Explain("host reason"),
            SkillsDisplayLogic.catalogAction(CatalogCardStateUi.Unavailable("host reason")),
        )
        assertEquals(
            CatalogCardAction.Busy,
            SkillsDisplayLogic.catalogAction(CatalogCardStateUi.InstallStaging(SkillInstallStageUi.STAGING_SOURCE)),
        )
    }

    @Test
    fun `enabled plus configured never equals offered without the host verdict`() {
        val row = installedRow(
            enabled = true,
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.NOT_OFFERED_DISABLED,
        )
        // The local enable toggle is TRUE, yet the presentation must not
        // claim the skill is offered: SKL-DISCOVER-USABLE lives in the host.
        assertTrue(SkillsDisplayLogic.offerSummary(row) is OfferSummary.NotOffered)
    }

    @Test
    fun `offer summary carries the host remediation`() {
        val row = installedRow(
            enabled = true,
            availability = SkillAvailabilityUi.NeedsConfiguration("add the missing capability"),
            offerState = SkillOfferStateUi.NOT_OFFERED_NEEDS_SETUP,
        )
        val summary = SkillsDisplayLogic.offerSummary(row) as OfferSummary.NotOffered
        assertEquals("add the missing capability", summary.remediation)
    }

    @Test
    fun `model override exclusion is its own honest state`() {
        val row = installedRow(
            enabled = true,
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.NOT_OFFERED_MODEL_OVERRIDE,
        ).copy(modelOverrideNote = "text only model")
        val summary = SkillsDisplayLogic.offerSummary(row) as OfferSummary.NotOfferedModelOverride
        assertEquals("text only model", summary.note)
    }

    @Test
    fun `connection badges never invent a tool count`() {
        assertNull(McpDisplayLogic.toolCountFor(McpConnectionStateUi.Connecting(2)))
        assertNull(McpDisplayLogic.toolCountFor(McpConnectionStateUi.Inactive))
        assertNull(McpDisplayLogic.toolCountFor(McpConnectionStateUi.Failed("x")))
        assertEquals(4, McpDisplayLogic.toolCountFor(McpConnectionStateUi.Ready(4)))
        assertEquals(
            McpConnectionBadge.ReadingTools,
            McpDisplayLogic.connectionBadge(McpConnectionStateUi.Connecting(2), cancelling = false),
        )
        assertEquals(
            McpConnectionBadge.Cancelling,
            McpDisplayLogic.connectionBadge(McpConnectionStateUi.Connecting(2), cancelling = true),
        )
    }

    @Test
    fun `bundled guides cannot be deleted or toggled`() {
        val guide = installedRow(
            enabled = true,
            availability = SkillAvailabilityUi.Blocked("read-only guide"),
            offerState = SkillOfferStateUi.NOT_OFFERED_DISABLED,
        ).copy(isBundledReadOnlyGuide = true)
        assertFalse(SkillsDisplayLogic.canDelete(guide))
        assertFalse(SkillsDisplayLogic.canToggleEnabled(guide))
    }

    @Test
    fun `stop is offered only for a real projected run`() {
        val idle = installedRow(
            enabled = true,
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.OFFERED,
        )
        assertFalse(SkillsDisplayLogic.canRequestStop(idle))
        val running = idle.copy(
            runActivity = SkillRunActivityUi.Running(
                // A genuine run-only projection carries no env/job role.
                SkillRunScopeUi.RunOnly(taskId = "t", runId = "r", generation = 1),
            ),
        )
        assertTrue(SkillsDisplayLogic.canRequestStop(running))
    }

    @Test
    fun `creator and finder gates mirror the original disabled conditions`() {
        assertFalse(
            SkillsDisplayLogic.creatorInstallEnabled(
                SkillCreatorDraftUi("", "d", "i"),
                hostWorking = false,
            ),
        )
        assertTrue(
            SkillsDisplayLogic.creatorInstallEnabled(
                SkillCreatorDraftUi("n", "d", "i"),
                hostWorking = false,
            ),
        )
        assertFalse(
            SkillsDisplayLogic.creatorInstallEnabled(
                SkillCreatorDraftUi("n", "d", "i"),
                hostWorking = true,
            ),
        )
        assertFalse(SkillsDisplayLogic.finderInstallEnabled("https://x", null, hostWorking = false))
        assertTrue(SkillsDisplayLogic.finderInstallEnabled("https://x", "m", hostWorking = false))
        assertFalse(SkillsDisplayLogic.finderInstallEnabled("", "m", hostWorking = false))
    }

    @Test
    fun `search filter is local and case-insensitive over name and summary`() {
        val rows = listOf(
            installedRow(
                enabled = true,
                availability = SkillAvailabilityUi.Usable,
                offerState = SkillOfferStateUi.OFFERED,
            ).copy(skillId = "a", name = "Office Helper", summary = "Documents"),
            installedRow(
                enabled = true,
                availability = SkillAvailabilityUi.Usable,
                offerState = SkillOfferStateUi.OFFERED,
            ).copy(skillId = "b", name = "PDF Tools", summary = "Read documents"),
        )
        val docMatch = SkillsDisplayLogic.filterRows(rows, "documents", { it.name }, { it.summary })
        assertEquals(listOf("a", "b"), docMatch.map { it.skillId })
        val nameOnly = SkillsDisplayLogic.filterRows(rows, "office", { it.name }, { it.summary })
        assertEquals(listOf("a"), nameOnly.map { it.skillId })
        assertTrue(SkillsDisplayLogic.filterRows(rows, "  ", { it.name }, { it.summary }).size == 2)
    }

    private fun installedRow(
        enabled: Boolean,
        availability: SkillAvailabilityUi,
        offerState: SkillOfferStateUi,
    ) = SkillInstalledRowUi(
        skillId = "skill",
        name = "Skill",
        version = "1.0.0",
        summary = null,
        enabled = enabled,
        revision = "digest",
        availability = availability,
        offerState = offerState,
        sourceKind = SkillSourceKindUi.GITHUB,
    )
}
