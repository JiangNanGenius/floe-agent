// SPDX-License-Identifier: MPL-2.0
//
// LABELLED SYNTHETIC FIXTURE HOST for the Skills/MCP administration UI.
//
// This controller is an androidTest-only stand-in for the future Swift host:
// it projects typed snapshots, records effects the UI dispatches, and can
// echo scripted outcomes back (save errors, review staging, upgrade effect
// tokens, form outcomes). It performs NO real install, NO real network, NO
// Keystore, NO permission grant, NO business storage: every effect returns a
// recorded boolean and every projection value says "Synthetic". Screenshots
// produced through this fixture are UI evidence, never backend or product
// capability proof.

package com.floe.android.feature.integrations

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf

/** Base projections the fixture starts a test from. */
enum class IntegrationsFixtureScenario {
    HUB_DISCOVER,
    HUB_INSTALLED,
    HUB_EMPTY_ERROR,
    CONNECTORS,
    MCP_LIST,
}

class IntegrationsFixtureController : IntegrationUiCallbacks {

    private val initial: IntegrationsDestinationState = IntegrationsDestinationState(
        skills = emptyHub(),
        connectors = emptyConnectors(),
        mcp = emptyMcp(),
    )
    val state: MutableState<IntegrationsDestinationState> = mutableStateOf(initial)

    val holder: IntegrationsFlowHolder = IntegrationsFlowHolder(this)

    var currentScenario: IntegrationsFixtureScenario = IntegrationsFixtureScenario.HUB_DISCOVER
        private set

    /* ------------------------------ effect records ------------------------------ */

    var loadCount = 0; private set
    var closeAllCount = 0; private set
    val refreshCatalogCalls = mutableListOf<Boolean>()
    val officialInstalls = mutableListOf<String>()
    val skillToggles = mutableListOf<Triple<String, String, Boolean>>()
    val skillDeletes = mutableListOf<String>()
    val cancelledScopes = mutableListOf<SkillRunScopeUi>()
    val scriptedUpdates = mutableListOf<Boolean>()
    val confirmedReviews = mutableListOf<Long>()
    val cancelledReviews = mutableListOf<Long>()
    val createdForms = mutableListOf<Pair<String, SkillCreatorDraftUi>>()
    val finderInstalls = mutableListOf<Triple<String, String, String?>>()
    var folderStagingRequests = 0; private set
    val stagedImports = mutableListOf<Pair<String, String>>()
    val upgradeChecks = mutableListOf<String>()
    val upgradeApplies = mutableListOf<Long>()
    val upgradeRollbacks = mutableListOf<Long>()
    val upgradeCancels = mutableListOf<String>()
    val connectorOpens = mutableListOf<String>()
    val mcpEditorSessions = mutableListOf<Pair<McpEditorIdentity, Boolean>>()
    val mcpSaveRequests = mutableListOf<McpSaveRequest>()
    val mcpServerToggles = mutableListOf<Pair<String, Boolean>>()
    val mcpDeletes = mutableListOf<String>()
    val mcpToolToggles = mutableListOf<Triple<String, String, Boolean>>()
    val mcpRefreshes = mutableListOf<String>()
    val mcpRefreshCancels = mutableListOf<Pair<String, Long>>()

    var officialInstallAccepted = true
    var skillDeleteAccepted = true
    var cancelRunAccepted = true
    var confirmReviewAccepted = true
    var stagingAccepted = true
    var createAccepted = true
    var finderAccepted = true
    var importAccepted = true
    var upgradeCheckAccepted = true
    var upgradeApplyAccepted = true
    var upgradeRollbackAccepted = true
    var connectorOpenAccepted = true
    var saveAccepted = true
    var mcpDeleteAccepted = true
    var refreshAccepted = true
    var refreshCancelAccepted = true

    /* --------------------------- scripted host inputs --------------------------- */

    /** Seed source for [seedMcpEditor]; tests may replace the provider. */
    var mcpSeedProvider: (String?) -> McpEditorSeedUi? = { syntheticNewSeed(it) }

    /** Seed source for [seedUpgrade]; default: honest "no data". */
    var upgradeSeedProvider: (String) -> SkillUpgradeUi? = { null }

    private var lastSeed: McpEditorSeedUi? = null
    private var editorIdentity: McpEditorIdentity? = null
    private var editorSaveInFlight = false
    private var editorSaveError: String? = null
    private var editorSaveOutcome: McpSaveOutcomeUi? = null
    private var editorSaveFailureSequence: Long = 0L
    private var editorCredentialStored = false

    /** Armed by [armSameFrameSaveFailure]: the next accepted save publishes
     * begin AND the identical failure synchronously inside [saveMcpServer],
     * before the holder can mark its duplicate-save latch or Compose can
     * compose an intermediate frame. */
    private var nextSameFrameSaveFailure: String? = null

    private fun publish(transform: (IntegrationsDestinationState) -> IntegrationsDestinationState) {
        state.value = transform(state.value)
    }

    fun applyScenario(scenario: IntegrationsFixtureScenario) {
        currentScenario = scenario
        val next = when (scenario) {
            IntegrationsFixtureScenario.HUB_DISCOVER -> initial.copy(
                skills = discoverHub(),
                connectors = syntheticConnectors(),
                mcp = syntheticMcpList(),
            )
            IntegrationsFixtureScenario.HUB_INSTALLED -> initial.copy(
                skills = installedHub(),
                connectors = syntheticConnectors(),
                mcp = syntheticMcpList(),
            )
            IntegrationsFixtureScenario.HUB_EMPTY_ERROR -> initial.copy(
                skills = errorHub(),
                connectors = syntheticConnectors(),
                mcp = emptyMcp(isLoading = false),
            )
            IntegrationsFixtureScenario.CONNECTORS -> initial.copy(
                skills = discoverHub(),
                connectors = syntheticConnectors(),
                mcp = syntheticMcpList(),
            )
            IntegrationsFixtureScenario.MCP_LIST -> initial.copy(
                skills = discoverHub(),
                connectors = syntheticConnectors(),
                mcp = syntheticMcpList(),
            )
        }
        state.value = next
        // The host replaces stale editor projections when a new base screen
        // becomes authoritative (mirrors a fresh settings session).
        editorIdentity = null
        editorSaveInFlight = false
        editorSaveError = null
        editorSaveOutcome = null
        editorSaveFailureSequence = 0L
        editorCredentialStored = false
        nextSameFrameSaveFailure = null
    }

    /* --------------------------------- hub paths --------------------------------- */

    override fun load() {
        loadCount += 1
    }

    override fun closeAll() {
        closeAllCount += 1
    }

    override fun refreshCatalog(force: Boolean): Boolean {
        refreshCatalogCalls += force
        return true
    }

    override fun installOfficialSkill(skillId: String): Boolean {
        officialInstalls += skillId
        if (!officialInstallAccepted) return false
        // The host really started staging: project the real stage, never a
        // fabricated percentage.
        publish { s ->
            s.copy(
                skills = s.skills.withCardState(skillId, CatalogCardStateUi.InstallStaging(SkillInstallStageUi.STAGING_SOURCE)),
            )
        }
        return true
    }

    /** Scripted progression of the staging stage for the named card. */
    fun emitCatalogStage(skillId: String, stage: SkillInstallStageUi) {
        publish { s -> s.copy(skills = s.skills.withCardState(skillId, CatalogCardStateUi.InstallStaging(stage))) }
    }

    fun emitCatalogReady(skillId: String) {
        publish { s -> s.copy(skills = s.skills.withCardState(skillId, CatalogCardStateUi.InstalledReady)) }
    }

    override fun setSkillEnabled(skillId: String, expectedRevision: String, enabled: Boolean): Boolean {
        skillToggles += Triple(skillId, expectedRevision, enabled)
        // The projection flips the row: one value, one host effect.
        publish { s -> s.copy(skills = s.skills.withInstalledEnabled(skillId, enabled)) }
        return true
    }

    override fun deleteSkill(skillId: String, expectedRevision: String): Boolean {
        skillDeletes += skillId
        if (!skillDeleteAccepted) return false
        publish { s -> s.copy(skills = s.skills.copy(installed = s.skills.installed.filterNot { it.skillId == skillId })) }
        return true
    }

    override fun cancelSkillRun(scope: SkillRunScopeUi): Boolean {
        cancelledScopes += scope
        return cancelRunAccepted
    }

    /** Scripted terminal projection for a row the fixture ran earlier. */
    fun emitRunTerminal(skillId: String) {
        publish { s ->
            s.copy(
                skills = s.skills.withInstalled(skillId) { it.copy(runActivity = SkillRunActivityUi.None) },
            )
        }
    }

    fun emitRunRunning(skillId: String, scope: SkillRunScopeUi) {
        publish { s ->
            s.copy(
                skills = s.skills.withInstalled(skillId) { it.copy(runActivity = SkillRunActivityUi.Running(scope)) },
            )
        }
    }

    override fun setAutoScriptedUpdates(enabled: Boolean) {
        scriptedUpdates += enabled
        // The shared host preference is the value's only owner; echo it.
        publish { s -> s.copy(skills = s.skills.copy(autoScriptedUpdates = enabled)) }
    }

    /* ------------------------------ install review ------------------------------ */

    fun emitInstallReview(review: SkillInstallReviewUi?) {
        publish { it.copy(installReview = review) }
    }

    override fun confirmPendingInstallation(reviewId: Long): Boolean {
        confirmedReviews += reviewId
        if (!confirmReviewAccepted) return false
        // The commit runs host-side; the staged review projection clears.
        publish { it.copy(installReview = null) }
        return true
    }

    override fun cancelPendingInstallation(reviewId: Long) {
        cancelledReviews += reviewId
        publish { it.copy(installReview = null) }
    }

    /* ---------------------------------- forms ---------------------------------- */

    override fun createSkill(formId: String, draft: SkillCreatorDraftUi): Boolean {
        createdForms += formId to draft
        return createAccepted
    }

    override fun installFromFinder(formId: String, urlText: String, rewriteModelId: String?): Boolean {
        finderInstalls += Triple(formId, urlText, rewriteModelId)
        return finderAccepted
    }

    override fun requestFolderStaging(): Boolean {
        folderStagingRequests += 1
        return stagingAccepted
    }

    override fun importStagedPackage(formId: String, reference: StagedPackageRefUi): Boolean {
        stagedImports += formId to reference.handle
        return importAccepted
    }

    /** The shell finished SAF staging: hand the opaque reference to the flow. */
    fun deliverStagedPackage(reference: StagedPackageRefUi) {
        holder.onPackageStaged(reference)
    }

    /** Publish a host outcome for the LAST dispatched form (fenced by formId). */
    fun emitFormOutcomeFor(formId: String, succeeded: Boolean, message: String?) {
        publish { s ->
            s.copy(skills = s.skills.copy(formOutcome = SkillsFormOutcomeUi(formId, succeeded, message)))
        }
    }

    fun clearFormOutcome() {
        publish { s -> s.copy(skills = s.skills.copy(formOutcome = null)) }
    }

    /* ---------------------------------- upgrade ---------------------------------- */

    override fun seedUpgrade(skillId: String): SkillUpgradeUi? = upgradeSeedProvider(skillId)

    override fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean {
        upgradeChecks += skillId
        return upgradeCheckAccepted
    }

    override fun applyUpgrade(skillId: String, effectToken: Long): Boolean {
        upgradeApplies += effectToken
        if (!upgradeApplyAccepted) return false
        publish { s -> s.copy(upgrade = s.upgrade?.withToken(skillId) { it.copy(applyInFlight = true) }) }
        return true
    }

    override fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean {
        upgradeRollbacks += effectToken
        if (!upgradeRollbackAccepted) return false
        return true
    }

    override fun cancelUpgrade(skillId: String) {
        upgradeCancels += skillId
        publish { it.copy(upgrade = null) }
    }

    /** Replace the open upgrade sheet's projection (candidate discovered). */
    fun emitUpgradeProjection(upgrade: SkillUpgradeUi) {
        publish { s -> s.copy(upgrade = if (s.upgrade?.skillId == upgrade.skillId || s.upgrade == null) upgrade else s.upgrade) }
    }

    /** Scripted apply/rollback completion for the token the UI dispatched. */
    fun emitUpgradeEffect(skillId: String, effectToken: Long, outcome: UpgradeOutcomeUi, error: String? = null) {
        publish { s ->
            s.copy(
                upgrade = s.upgrade?.withToken(skillId) {
                    it.copy(
                        applyInFlight = false,
                        errorMessage = error,
                        lastEffect = UpgradeEffectUi(effectToken, outcome),
                    )
                },
            )
        }
    }

    fun clearUpgradeProjection() {
        publish { it.copy(upgrade = null) }
    }

    private fun SkillUpgradeUi.withToken(skillId: String, transform: (SkillUpgradeUi) -> SkillUpgradeUi): SkillUpgradeUi? =
        if (this.skillId == skillId) transform(this) else this

    /* --------------------------------- connectors --------------------------------- */

    override fun openConnectorDestination(destinationId: String): Boolean {
        connectorOpens += destinationId
        return connectorOpenAccepted
    }

    /* ------------------------------------ MCP ------------------------------------ */

    override fun seedMcpEditor(serverId: String?): McpEditorSeedUi? {
        val seed = mcpSeedProvider(serverId) ?: return null
        lastSeed = seed
        return seed
    }

    override fun mcpEditorOpened(identity: McpEditorIdentity) {
        editorIdentity = identity
        editorSaveInFlight = false
        editorSaveError = null
        editorSaveOutcome = null
        editorSaveFailureSequence = 0L
        editorCredentialStored = lastSeed?.credentialStored == true
        publishEditor()
    }

    override fun mcpEditorClosed(identity: McpEditorIdentity, discarded: Boolean) {
        mcpEditorSessions += identity to discarded
        if (editorIdentity?.isCurrentFor(identity) == true) {
            editorIdentity = null
            publish { it.copy(editor = null) }
        }
    }

    private fun publishEditorFor(identity: McpEditorIdentity) {
        val seed = lastSeed ?: return
        publish {
            it.copy(
                editor = McpEditorUiState(
                    identity = identity,
                    seed = seed,
                    saveInFlight = editorSaveInFlight,
                    saveError = editorSaveError,
                    saveOutcome = editorSaveOutcome,
                    connectionState = seed.connectionStateForFixture(),
                    saveFailureSequence = editorSaveFailureSequence,
                    tools = seed.tools,
                    credentialStored = editorCredentialStored,
                    networkActionsAvailable = seed.networkActionsAvailable,
                    networkActionsUnavailableReason = seed.networkActionsUnavailableReason,
                ),
            )
        }
    }

    private fun publishEditor() {
        editorIdentity?.let { publishEditorFor(it) }
    }

    /** The identity of the editor session the module currently holds open. */
    fun currentEditorIdentity(): McpEditorIdentity? = editorIdentity

    /**
     * Scripted host save failure: one NEW failure event per call (even when
     * the text repeats), clears the in-flight flag and keeps the editor.
     */
    fun emitSaveError(message: String) {
        editorSaveInFlight = false
        editorSaveError = message
        editorSaveOutcome = McpSaveOutcomeUi.Failed(message)
        editorSaveFailureSequence += 1
        publishEditor()
    }

    /**
     * Publish a save-failure projection addressed to a SPECIFIC
     * identity+epoch and sequence. A current identity consumes the event; a
     * stale one is projected exactly as a real host would address the old
     * session, so the module must fence it. A repeated/older sequence for a
     * current identity simulates a projection poll/replay.
     */
    fun emitSaveFailureFor(
        identity: McpEditorIdentity,
        message: String,
        failureSequence: Long,
    ) {
        val current = editorIdentity
        if (current != null && current.isCurrentFor(identity)) {
            editorSaveInFlight = false
            editorSaveError = message
            editorSaveOutcome = McpSaveOutcomeUi.Failed(message)
            editorSaveFailureSequence = maxOf(editorSaveFailureSequence, failureSequence)
            publishEditorFor(identity)
        } else {
            lastSeed?.let { seed ->
                publish {
                    it.copy(
                        editor = McpEditorUiState(
                            identity = identity,
                            seed = seed,
                            saveInFlight = false,
                            saveError = message,
                            saveOutcome = McpSaveOutcomeUi.Failed(message),
                            connectionState = seed.connectionStateForFixture(),
                            tools = seed.tools,
                            credentialStored = editorCredentialStored,
                            networkActionsAvailable = seed.networkActionsAvailable,
                            networkActionsUnavailableReason = seed.networkActionsUnavailableReason,
                            saveFailureSequence = failureSequence,
                        ),
                    )
                }
            }
        }
    }

    /**
     * Arm the next accepted save to publish its in-flight begin AND its
     * identical failure synchronously inside [saveMcpServer]. Compose sees
     * only the coalesced final projection, exactly the same-frame retry the
     * monotonic failure sequence must make observable.
     */
    fun armSameFrameSaveFailure(message: String) {
        nextSameFrameSaveFailure = message
    }

    /** Scripted host success for a SPECIFIC identity (stale-epoch fencing). */
    fun emitSaveSucceededFor(identity: McpEditorIdentity, newServerId: String, newRevision: Long) {
        editorSaveInFlight = false
        editorSaveError = null
        editorSaveOutcome = McpSaveOutcomeUi.Succeeded(newServerId, newRevision)
        val current = editorIdentity
        if (current != null && current.isCurrentFor(identity)) {
            publishEditorFor(identity)
        } else {
            // Late result for an OLD identity: project it exactly as a real
            // host would (addressed to the stale id) and let the module fence.
            lastSeed?.let { seed ->
                publish {
                    it.copy(
                        editor = McpEditorUiState(
                            identity = identity,
                            seed = seed,
                            saveInFlight = false,
                            saveError = null,
                            saveOutcome = McpSaveOutcomeUi.Succeeded(newServerId, newRevision),
                            connectionState = seed.connectionStateForFixture(),
                            tools = seed.tools,
                            credentialStored = editorCredentialStored,
                            networkActionsAvailable = seed.networkActionsAvailable,
                            networkActionsUnavailableReason = seed.networkActionsUnavailableReason,
                        ),
                    )
                }
            }
        }
    }

    override fun saveMcpServer(request: McpSaveRequest): Boolean {
        mcpSaveRequests += request
        if (!saveAccepted) return false
        val sameFrameFailure = nextSameFrameSaveFailure
        if (sameFrameFailure != null) {
            nextSameFrameSaveFailure = null
            // Begin + identical failure are published synchronously inside
            // this dispatch; no composition frame (and no holder latch mark)
            // separates them, so only the failure event sequence can identify
            // the new attempt.
            editorSaveInFlight = true
            publishEditor()
            emitSaveError(sameFrameFailure)
        } else {
            editorSaveInFlight = true
            publishEditor()
        }
        return true
    }

    override fun deleteMcpServer(serverId: String): Boolean {
        mcpDeletes += serverId
        if (!mcpDeleteAccepted) return false
        publish { s -> s.copy(mcp = s.mcp.copy(servers = s.mcp.servers.filterNot { it.serverId == serverId })) }
        return true
    }

    override fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean {
        mcpServerToggles += serverId to enabled
        // ⇄ the host rule: enable triggers a refresh, disable unregisters.
        publish { s ->
            s.copy(
                mcp = s.mcp.withServer(serverId) {
                    it.copy(
                        enabled = enabled,
                        state = if (enabled) McpConnectionStateUi.Connecting(generation = 1) else McpConnectionStateUi.Inactive,
                        tools = if (enabled) it.tools else null,
                    )
                },
            )
        }
        return true
    }

    override fun setMcpToolEnabled(serverId: String, remoteName: String, enabled: Boolean): Boolean {
        mcpToolToggles += Triple(serverId, remoteName, enabled)
        publish { s ->
            s.copy(
                mcp = s.mcp.withServer(serverId) { row ->
                    row.copy(tools = row.tools?.map { if (it.remoteName == remoteName) it.copy(enabled = enabled) else it })
                },
            )
        }
        return true
    }

    override fun refreshMcpServer(serverId: String): Boolean {
        mcpRefreshes += serverId
        if (!refreshAccepted) return false
        val next = ((currentMcpGeneration(serverId) ?: 0L) + 1L)
        publish { s ->
            s.copy(mcp = s.mcp.withServer(serverId) { it.copy(state = McpConnectionStateUi.Connecting(next)) })
        }
        return true
    }

    override fun cancelMcpRefresh(serverId: String, generation: Long): Boolean {
        mcpRefreshCancels += serverId to generation
        return refreshCancelAccepted
    }

    /** Scripted completion of a connecting generation. */
    fun emitMcpState(serverId: String, state: McpConnectionStateUi, tools: List<McpToolRowUi>? = null) {
        publish { s ->
            s.copy(mcp = s.mcp.withServer(serverId) { it.copy(state = state, tools = tools ?: it.tools) })
        }
    }

    private fun currentMcpGeneration(serverId: String): Long? =
        state.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?.state
            ?.let { it as? McpConnectionStateUi.Connecting }
            ?.generation

    private fun McpEditorSeedUi.connectionStateForFixture(): McpConnectionStateUi =
        if (serverId == null) McpConnectionStateUi.Inactive else McpConnectionStateUi.Inactive
}

/* ------------------------------ state helpers ------------------------------ */

private fun McpServersUiState.withServer(
    serverId: String,
    transform: (McpServerRowUi) -> McpServerRowUi,
): McpServersUiState = copy(servers = servers.map { if (it.serverId == serverId) transform(it) else it })

private fun SkillsHubUiState.withCardState(skillId: String, state: CatalogCardStateUi): SkillsHubUiState =
    copy(catalogCards = catalogCards.map { if (it.skillId == skillId) it.copy(state = state) else it })

private fun SkillsHubUiState.withInstalledEnabled(skillId: String, enabled: Boolean): SkillsHubUiState =
    copy(
        installed = installed.map {
            if (it.skillId == skillId) {
                it.copy(
                    enabled = enabled,
                    availability = if (!enabled) SkillAvailabilityUi.Disabled else it.availability,
                    offerState = if (!enabled) SkillOfferStateUi.NOT_OFFERED_DISABLED else it.offerState,
                )
            } else {
                it
            }
        },
    )

private fun SkillsHubUiState.withInstalled(
    skillId: String,
    transform: (SkillInstalledRowUi) -> SkillInstalledRowUi,
): SkillsHubUiState =
    copy(installed = installed.map { if (it.skillId == skillId) transform(it) else it })

/* ------------------------------ synthetic data ------------------------------ */

internal fun emptyHub(): SkillsHubUiState = SkillsHubUiState(
    isLoading = false,
    isWorking = false,
    catalogCards = emptyList(),
    catalogChecking = false,
    catalogError = null,
    installed = emptyList(),
    rewriteModels = listOf(RewriteModelUi("synthetic-model", "Synthetic Rewrite Model")),
    defaultRewriteModelId = "synthetic-model",
    autoScriptedUpdates = false,
    errorMessage = null,
)

internal fun emptyConnectors(): ConnectorsUiState = ConnectorsUiState(emptyList(), emptyList())

internal fun emptyMcp(isLoading: Boolean = false): McpServersUiState =
    McpServersUiState(isLoading = isLoading, servers = emptyList(), errorMessage = null)

internal fun syntheticTool(name: String, display: String, enabled: Boolean = true): McpToolRowUi =
    McpToolRowUi(
        remoteName = name,
        displayName = display,
        toolDescription = "Synthetic description; no server involved.",
        enabled = enabled,
        readOnlyHint = true,
        destructiveHint = false,
    )

internal fun discoverHub(): SkillsHubUiState = emptyHub().copy(
    catalogCards = listOf(
        SkillCatalogCardUi(
            skillId = "synthetic-office",
            name = "Synthetic Office Plugin",
            version = "1.4.0",
            summary = "Sample card showing the ready state.",
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
            sourceKind = SkillSourceKindUi.GITHUB,
        ),
    ),
)

internal fun installedHub(): SkillsHubUiState = emptyHub().copy(
    installed = listOf(
        SkillInstalledRowUi(
            skillId = "synthetic-skill-a",
            name = "Synthetic Installed Skill",
            version = "1.0.0",
            summary = "Enabled, usable, offered.",
            enabled = true,
            revision = "synthetic-digest-a",
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.OFFERED,
            permissions = listOf(
                SkillPermissionRowUi(
                    capability = "synthetic.capability",
                    decision = "Synthetic decision",
                    scopeSummary = "Synthetic scope",
                    grantedAtDisplay = null,
                    expiresAtDisplay = null,
                ),
            ),
            sourceKind = SkillSourceKindUi.GITHUB,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-b",
            name = "Synthetic Needs Setup",
            version = "0.9.2",
            summary = "Enabled but missing setup.",
            enabled = true,
            revision = "synthetic-digest-b",
            availability = SkillAvailabilityUi.NeedsConfiguration(
                remediation = "Synthetic: add the missing capability in its settings.",
            ),
            offerState = SkillOfferStateUi.NOT_OFFERED_NEEDS_SETUP,
            updateAvailableVersion = "0.9.3",
            sourceKind = SkillSourceKindUi.FOLDER,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-c",
            name = "Synthetic Environment Skill",
            version = "3.1.0",
            summary = "Runtime temporarily unavailable.",
            enabled = true,
            revision = "synthetic-digest-c",
            availability = SkillAvailabilityUi.EnvironmentUnavailable(
                remediation = "Synthetic: the Linux environment is starting.",
            ),
            offerState = SkillOfferStateUi.NOT_OFFERED_ENVIRONMENT,
            sourceKind = SkillSourceKindUi.CREATOR,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-d",
            name = "Synthetic Override Skill",
            version = "1.2.0",
            summary = "Kept out by a saved model override.",
            enabled = true,
            revision = "synthetic-digest-d",
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.NOT_OFFERED_MODEL_OVERRIDE,
            modelOverrideNote = "Synthetic note: not offered in this model's task.",
            sourceKind = SkillSourceKindUi.CREATOR,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-e",
            name = "Synthetic Running Skill",
            version = "2.0.0",
            summary = "Shows the owned-run stop affordance.",
            enabled = true,
            revision = "synthetic-digest-e",
            availability = SkillAvailabilityUi.Usable,
            offerState = SkillOfferStateUi.OFFERED,
            runActivity = SkillRunActivityUi.Running(
                SkillRunScopeUi.RunOnly(taskId = "synthetic-task", runId = "synthetic-run", generation = 1),
            ),
            sourceKind = SkillSourceKindUi.GITHUB,
        ),
        SkillInstalledRowUi(
            skillId = "synthetic-skill-f",
            name = "Synthetic Guide",
            version = "1.0.0",
            summary = "Read-only bundled guide.",
            enabled = false,
            revision = "synthetic-digest-f",
            availability = SkillAvailabilityUi.Blocked(reason = "Synthetic: update only with the app."),
            offerState = SkillOfferStateUi.NOT_OFFERED_DISABLED,
            isBundledReadOnlyGuide = true,
            sourceKind = SkillSourceKindUi.BUNDLED,
        ),
    ),
)

internal fun errorHub(): SkillsHubUiState = emptyHub().copy(
    catalogError = "Synthetic catalog error",
    catalogChecking = false,
    errorMessage = "Synthetic host error line",
)

internal fun syntheticConnectors(): ConnectorsUiState = ConnectorsUiState(
    services = listOf(
        ConnectorDestinationRowUi(
            destinationId = "synthetic-mail",
            title = "Synthetic Mail",
            subtitle = "Synthetic · connected",
            availability = ConnectorAvailabilityUi.Available,
        ),
        ConnectorDestinationRowUi(
            destinationId = "synthetic-account",
            title = "Synthetic Account",
            subtitle = null,
            availability = ConnectorAvailabilityUi.Unavailable(
                remediation = "Synthetic: sign in to connect.",
            ),
        ),
    ),
    toolSources = listOf(
        ConnectorDestinationRowUi(
            destinationId = "synthetic-tool-source",
            title = "Synthetic Tool Source",
            subtitle = "Synthetic caption",
            availability = ConnectorAvailabilityUi.Available,
        ),
    ),
)

internal fun syntheticMcpList(): McpServersUiState = McpServersUiState(
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
                syntheticTool("synthetic_tool", "Synthetic Tool"),
                syntheticTool("synthetic_tool_two", "Synthetic Tool Two", enabled = false),
            ),
            revision = 3,
        ),
        McpServerRowUi(
            serverId = "synthetic-server-connecting",
            displayName = "Synthetic Connecting Server",
            endpointDisplay = "https://synthetic.invalid/stream",
            enabled = true,
            allowInCanvas = false,
            authentication = McpAuthenticationUi.CUSTOM_HEADER,
            credentialStored = false,
            state = McpConnectionStateUi.Connecting(generation = 5),
            tools = null,
            revision = 1,
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
            revision = 1,
        ),
        McpServerRowUi(
            serverId = "synthetic-server-disabled",
            displayName = "Synthetic Disabled Server",
            endpointDisplay = "https://synthetic.invalid/off",
            enabled = false,
            allowInCanvas = false,
            authentication = McpAuthenticationUi.NONE,
            credentialStored = false,
            state = McpConnectionStateUi.Inactive,
            tools = null,
            revision = 2,
        ),
    ),
    errorMessage = null,
)

internal fun syntheticNewSeed(serverId: String?): McpEditorSeedUi = McpEditorSeedUi(
    serverId = serverId,
    displayName = if (serverId == null) "" else "Synthetic Ready Server",
    endpointText = if (serverId == null) "" else "https://synthetic.invalid/mcp",
    enabled = true,
    allowInCanvas = false,
    allowInsecureHttp = false,
    authentication = if (serverId == null) McpAuthenticationUi.NONE else McpAuthenticationUi.BEARER_TOKEN,
    credentialHeaderName = "Authorization",
    credentialStored = serverId != null,
    timeoutSeconds = 30,
    savedRevision = if (serverId == null) null else 3,
    transport = McpTransportUi.StreamableHttp,
    tools = if (serverId == null) emptyList() else listOf(
        syntheticTool("synthetic_tool", "Synthetic Tool"),
        syntheticTool("synthetic_tool_two", "Synthetic Tool Two", enabled = false),
    ),
    networkActionsAvailable = true,
    networkActionsUnavailableReason = null,
)

internal fun syntheticInstallReview(reviewId: Long = 11L, commitInFlight: Boolean = false): SkillInstallReviewUi =
    SkillInstallReviewUi(
        reviewId = reviewId,
        sourceDisplay = "https://synthetic.invalid/skill-source",
        skillName = "Synthetic Staged Skill",
        version = "1.0.0",
        requestedCapabilities = listOf("synthetic.network", "synthetic.files"),
        tools = listOf("synthetic_tool"),
        scriptPaths = listOf("scripts/run.py"),
        pythonPackages = listOf(PythonRequirementUi("synthetic-package==1.2.3", "Synthetic purpose")),
        commitInFlight = commitInFlight,
    )

internal fun syntheticUpgrade(
    skillId: String,
    candidate: String? = null,
    canRollback: Boolean = false,
    isLatest: Boolean = false,
): SkillUpgradeUi = SkillUpgradeUi(
    skillId = skillId,
    skillName = "Synthetic Installed Skill",
    installedVersion = "1.0.0",
    isOfficial = true,
    savedSource = null,
    candidateVersion = candidate,
    commit = if (candidate == null) null else "syntheticcommit123",
    releaseNotes = if (candidate == null) null else "Synthetic release notes for the review.",
    addedCapabilities = if (candidate == null) emptyList() else listOf("synthetic.extra"),
    addedTools = if (candidate == null) emptyList() else listOf("synthetic_extra_tool"),
    changedFiles = if (candidate == null) emptyList() else listOf(
        SkillFileDiffUi("SKILL.md", beforePreview = "synthetic before", afterPreview = "synthetic after"),
    ),
    isLatest = isLatest || candidate == null,
    checkInFlight = false,
    applyInFlight = false,
    canRollback = canRollback,
    errorMessage = null,
)

internal val syntheticStagedRef: StagedPackageRefUi = StagedPackageRefUi(
    handle = "synthetic-handle-7",
    displayName = "Synthetic Staged Package",
    mimeType = "application/octet-stream",
    sizeBytes = 4096,
)
