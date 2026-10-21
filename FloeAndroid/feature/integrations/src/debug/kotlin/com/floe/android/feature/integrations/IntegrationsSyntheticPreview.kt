// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY synthetic preview for the Skills/MCP presentation flow.
//
// This is NOT a working backend and is NOT reachable from release navigation:
// it renders labelled sample rows (never real skill installs, never real MCP
// servers, never credentials) so a component preview can inspect the
// composition before the shared Swift bridge is wired. Every value here is
// synthetic, including availability states. The notice bar is mandatory and
// localized; a later binder must keep the label if it reuses this preview.
// The real entry stays [FloeSkillsSettingsDestination].

package com.floe.android.feature.integrations

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeText

/** Labelled synthetic previews (debug only). */
@Composable
fun IntegrationsUiSyntheticPreview(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface),
    ) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.10f))
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            SkillsHubPage(
                skills = syntheticHub(),
                holder = remember { IntegrationsFlowHolder(NoopHost) },
            )
        }
    }
}

/** Synthetic hub projection: names say "Synthetic", nothing is live. */
private fun syntheticHub(): SkillsHubUiState = SkillsHubUiState(
    isLoading = false,
    isWorking = false,
    catalogCards = listOf(
        SkillCatalogCardUi(
            skillId = "synthetic-office",
            name = "Synthetic Office Plugin",
            version = "1.4.0",
            summary = "Sample card showing the installed-ready state.",
            state = CatalogCardStateUi.InstalledReady,
        ),
        SkillCatalogCardUi(
            skillId = "synthetic-pdf",
            name = "Synthetic PDF Plugin",
            version = "2.1.0",
            summary = "Sample card showing the update affordance.",
            state = CatalogCardStateUi.UpdateTo("2.2.0"),
        ),
        SkillCatalogCardUi(
            skillId = "synthetic-network",
            name = "Synthetic Network Plugin",
            version = "1.0.3",
            summary = "Sample card showing the install affordance.",
            state = CatalogCardStateUi.NotInstalled,
        ),
    ),
    catalogChecking = false,
    catalogError = null,
    installed = listOf(
        SkillInstalledRowUi(
            skillId = "synthetic-skill-a",
            name = "Synthetic Installed Skill",
            version = "1.0.0",
            summary = "Enabled and usable; offered to the agent.",
            enabled = true,
            revision = "synthetic-digest-a",
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.OFFERED,
            updateAvailableVersion = null,
            sourceKind = SkillSourceKindUi.GITHUB,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-b",
            name = "Synthetic Needs Setup",
            version = "0.9.2",
            summary = "Enabled but missing setup; the remediation is synthetic.",
            enabled = true,
            revision = "synthetic-digest-b",
            availability = SkillAvailabilityUi.NeedsConfiguration(
                remediation = "Synthetic: add the missing capability in its settings.",
            ),
            offerState = SkillOfferStateUi.NOT_OFFERED_NEEDS_SETUP,
            sourceKind = SkillSourceKindUi.FOLDER,
            updateAvailableVersion = "0.9.3",
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-c",
            name = "Synthetic Running Skill",
            version = "2.0.0",
            summary = "Shows the owned-run stop affordance (synthetic scope).",
            enabled = true,
            revision = "synthetic-digest-c",
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.OFFERED,
            runActivity = SkillRunActivityUi.Running(
                // Run-only synthetic scope: exactly what a G02 host can
                // project — no invented environment or job identities.
                SkillRunScopeUi.RunOnly(
                    taskId = "synthetic-task",
                    runId = "synthetic-run",
                    generation = 1,
                ),
            ),
            sourceKind = SkillSourceKindUi.CREATOR,
        ),
    ),
    rewriteModels = listOf(RewriteModelUi("synthetic-model", "Synthetic Rewrite Model")),
    defaultRewriteModelId = "synthetic-model",
    autoScriptedUpdates = false,
    errorMessage = null,
)

private fun syntheticMcp(): McpServersUiState = McpServersUiState(
    isLoading = false,
    servers = listOf(
        McpServerRowUi(
            serverId = "synthetic-server-ready",
            displayName = "Synthetic Ready Server",
            endpointDisplay = "https://synthetic.invalid/mcp",
            enabled = true,
            allowInCanvas = false,
            authentication = McpAuthenticationUi.BEARER_TOKEN,
            credentialStored = true,
            state = McpConnectionStateUi.Ready(toolCount = 4),
            tools = listOf(
                McpToolRowUi(
                    remoteName = "synthetic_tool",
                    displayName = "Synthetic Tool",
                    toolDescription = "Synthetic description; no server involved.",
                    enabled = true,
                    readOnlyHint = true,
                    destructiveHint = false,
                ),
            ),
            revision = McpServerRevisionUi(
                "mcp.6F7B2A1C-3D4E-5F60-7182-93A4B5C6D7E8",
                "synthetic-digest",
            ),
        ),
        McpServerRowUi(
            serverId = "synthetic-server-failed",
            displayName = "Synthetic Failed Server",
            endpointDisplay = "https://synthetic.invalid/other",
            enabled = true,
            allowInCanvas = false,
            authentication = McpAuthenticationUi.NONE,
            credentialStored = false,
            state = McpConnectionStateUi.Failed("Synthetic failure for layout review"),
            tools = null,
            revision = McpServerRevisionUi(
                "mcp.6F7B2A1C-3D4E-5F60-7182-93A4B5C6D7E8",
                "synthetic-digest",
            ),
        ),
    ),
    errorMessage = null,
)

/** No-op host so the preview can render without any real effect. */
private object NoopHost : IntegrationUiCallbacks {
    override fun load() = Unit
    override fun closeAll() = Unit
    override fun refreshCatalog(force: Boolean): Boolean = false
    override fun installOfficialSkill(skillId: String): Boolean = false
    override fun setSkillEnabled(skillId: String, expectedRevision: String, enabled: Boolean): Boolean = false
    override fun deleteSkill(skillId: String, expectedRevision: String): Boolean = false
    override fun cancelSkillRun(scope: SkillRunScopeUi): Boolean = false
    override fun setAutoScriptedUpdates(enabled: Boolean) = Unit
    override fun confirmPendingInstallation(reviewId: Long): Boolean = false
    override fun cancelPendingInstallation(reviewId: Long) = Unit
    override fun createSkill(formId: String, draft: SkillCreatorDraftUi): Boolean = false
    override fun installFromFinder(formId: String, urlText: String, rewriteModelId: String?): Boolean = false
    override fun requestFolderStaging(): Boolean = false
    override fun importStagedPackage(formId: String, reference: StagedPackageRefUi): Boolean = false
    override fun seedUpgrade(skillId: String): SkillUpgradeUi? = null
    override fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean = false
    override fun applyUpgrade(skillId: String, effectToken: Long): Boolean = false
    override fun cancelUpgrade(skillId: String) = Unit
    override fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean = false
    override fun openConnectorDestination(destinationId: String): Boolean = false
    override fun seedMcpEditor(serverId: String?): McpEditorSeedUi? = null
    override fun mcpEditorOpened(identity: McpEditorIdentity) = Unit
    override fun mcpEditorClosed(identity: McpEditorIdentity, discarded: Boolean) = Unit
    override fun saveMcpServer(request: McpSaveRequest): Boolean = false
    override fun deleteMcpServer(serverId: String): Boolean = false
    override fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean = false
    override fun setMcpToolEnabled(serverId: String, remoteName: String, enabled: Boolean): Boolean = false
    override fun refreshMcpServer(serverId: String): Boolean = false
    override fun cancelMcpRefresh(serverId: String, generation: Long): Boolean = false

    override fun localNetworkGuidanceAction(): Boolean = false
}

/** Separate synthetic MCP-list preview (debug only). */
@Composable
fun IntegrationsMcpSyntheticPreview(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface),
    ) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.10f))
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        McpServersPage(
            mcp = syntheticMcp(),
            holder = remember { IntegrationsFlowHolder(NoopHost) },
            onBack = {},
            onAdd = {},
        )
    }
}
