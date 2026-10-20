// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.integrations.ConnectorsUiState
import com.floe.android.feature.integrations.CredentialDraftIntent
import com.floe.android.feature.integrations.GitHubSourceFieldsUi
import com.floe.android.feature.integrations.IntegrationUiCallbacks
import com.floe.android.feature.integrations.IntegrationsDestinationState
import com.floe.android.feature.integrations.IntegrationsFlowHolder
import com.floe.android.feature.integrations.McpAuthenticationUi
import com.floe.android.feature.integrations.McpConnectionStateUi
import com.floe.android.feature.integrations.McpEditorIdentity
import com.floe.android.feature.integrations.McpEditorSeedUi
import com.floe.android.feature.integrations.McpEditorUiState
import com.floe.android.feature.integrations.McpSaveOutcomeUi
import com.floe.android.feature.integrations.McpSaveRequest
import com.floe.android.feature.integrations.McpServerRowUi
import com.floe.android.feature.integrations.McpServersUiState
import com.floe.android.feature.integrations.McpToolRowUi
import com.floe.android.feature.integrations.McpTransportUi
import com.floe.android.feature.integrations.SkillAvailabilityUi
import com.floe.android.feature.integrations.SkillCatalogCardUi
import com.floe.android.feature.integrations.SkillCreatorDraftUi
import com.floe.android.feature.integrations.SkillInstalledRowUi
import com.floe.android.feature.integrations.SkillInstallReviewUi
import com.floe.android.feature.integrations.SkillInstallStageUi
import com.floe.android.feature.integrations.SkillOfferStateUi
import com.floe.android.feature.integrations.SkillPermissionRowUi
import com.floe.android.feature.integrations.SkillRunActivityUi
import com.floe.android.feature.integrations.SkillRunScopeUi
import com.floe.android.feature.integrations.SkillSourceKindUi
import com.floe.android.feature.integrations.SkillUpgradeUi
import com.floe.android.feature.integrations.SkillsFormOutcomeUi
import com.floe.android.feature.integrations.SkillsHubUiState
import com.floe.android.feature.integrations.StagedPackageRefUi
import com.floe.android.feature.integrations.UpgradeEffectUi
import com.floe.android.feature.integrations.UpgradeOutcomeUi
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * App-host binding for the integrations feature component (Skills/MCP +
 * backend tool discovery). Implements [IntegrationUiCallbacks] exactly and
 * owns the immutable [IntegrationsDestinationState] projection.
 *
 * Every supported operation maps to the canonical RB6 command vocabulary
 * (skills.list/install/uninstall, mcp.servers.list/connect/disconnect,
 * capability.tools.list) — HTTP/SSE/streamable/auth/namespace/cancel and
 * signed-native-skills management are preserved; local stdio/SSH transports
 * stay configured and render their honest PendingEnvironment remediation
 * (G03 execution environment) rather than being dropped or faked.
 *
 * MCP editor save failures advance [McpEditorUiState.saveFailureSequence]
 * per the finalized same-frame contract: +1 per NEW failed save attempt on
 * the current editor id+epoch, even when the message repeats; never for
 * polls, connection or discovery failures.
 */
class IntegrationsHostController internal constructor(
    private val host: RuntimeHost,
    private val routeAuthority: HostRouteAuthority = NativeHostRouteAuthority,
) : IntegrationUiCallbacks {

    val flowHolder = IntegrationsFlowHolder(this)

    private val destinationState = MutableStateFlow(
        IntegrationsDestinationState(
            skills = SkillsHubUiState(
                isLoading = true,
                isWorking = false,
                catalogCards = emptyList(),
                catalogChecking = false,
                catalogError = null,
                installed = emptyList(),
                rewriteModels = emptyList(),
                defaultRewriteModelId = null,
                autoScriptedUpdates = false,
                errorMessage = null,
                formOutcome = null,
            ),
            connectors = ConnectorsUiState(
                services = emptyList(),
                toolSources = emptyList(),
            ),
            mcp = McpServersUiState(isLoading = true, servers = emptyList(), errorMessage = null),
            installReview = null,
            upgrade = null,
            editor = null,
        ),
    )
    val destination: StateFlow<IntegrationsDestinationState> = destinationState

    /** Per editor id+epoch MCP save-failure sequence (finalized contract). */
    private val mcpSaveFailureSequencer = SaveFailureSequencer()

    /** Host-monotonic install review ids (presentation only). */
    private val reviewIdSource = AtomicLong(0)

    /** reviewId → wire review token + skill identity (tokens never enter UI). */
    private class PendingReview(
        val reviewToken: String,
        val skillID: String,
        val revision: String,
        val projection: SkillInstallReviewUi,
    )

    private val pendingReviews = ConcurrentHashMap<Long, PendingReview>()

    /** MCP editor id → the native-issued `rt:v1:` host route handle. */
    private val editorRouteTokens = ConcurrentHashMap<String, String>()

    /** New MCP editor → the ONE stable server UUID its save commits. */
    private val newServerIDs = ConcurrentHashMap<String, String>()

    /** Test seam for the trusted host ingress; production is the frozen seam. */
    internal var secureIngress: HostSecureIngressSubmitter = NativeHostSecureIngressSubmitter

    internal fun start() {
        if (admitted()) {
            refreshSkills()
            refreshMcpServers()
        }
    }

    internal fun stop() {
        pendingReviews.clear()
    }

    private fun admitted(): Boolean = host.readiness.value.skillsMcpDomainAdmitted
    private fun client() = host.commandClient

    private fun updateDestination(
        transform: (IntegrationsDestinationState) -> IntegrationsDestinationState,
    ) {
        destinationState.value = transform(destinationState.value)
    }

    // ---------------------------------------------------------- projections

    internal fun refreshSkills() {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "skills.list",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = false,
                correlationID = client().correlationID("slist"),
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { IntegrationsWire.decodeSkillsSnapshot(it) }
                    updateDestination { state ->
                        state.copy(
                            skills = state.skills.copy(
                                isLoading = false,
                                installed = page?.installed ?: state.skills.installed,
                                catalogCards = page?.catalog ?: state.skills.catalogCards,
                                autoScriptedUpdates = page?.autoScriptedUpdates
                                    ?: state.skills.autoScriptedUpdates,
                                rewriteModels = page?.rewriteModels ?: state.skills.rewriteModels,
                                defaultRewriteModelId = page?.defaultRewriteModelId,
                                errorMessage = if (page == null) "decode_failed" else null,
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> updateDestination {
                    it.copy(skills = it.skills.copy(isLoading = false, errorMessage = outcome.code))
                }
                is HostOperationOutcome.Failed -> updateDestination {
                    it.copy(skills = it.skills.copy(isLoading = false, errorMessage = outcome.code))
                }
                else -> Unit
            }
        }
    }

    internal fun refreshMcpServers() {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.servers.list",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = false,
                correlationID = client().correlationID("mlist"),
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { IntegrationsWire.decodeMcpServers(it) }
                    updateDestination { state ->
                        state.copy(
                            mcp = McpServersUiState(
                                isLoading = false,
                                servers = page ?: state.mcp.servers,
                                errorMessage = if (page == null) "decode_failed" else null,
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> updateDestination {
                    it.copy(mcp = it.mcp.copy(isLoading = false, errorMessage = outcome.code))
                }
                is HostOperationOutcome.Failed -> updateDestination {
                    it.copy(mcp = it.mcp.copy(isLoading = false, errorMessage = outcome.code))
                }
                else -> Unit
            }
        }
    }

    // ------------------------------------------------ IntegrationUiCallbacks

    override fun load() {
        refreshSkills()
        refreshMcpServers()
    }

    override fun closeAll() {
        // Holder-owned UI retirement; projections stay for the next open.
    }

    override fun refreshCatalog(force: Boolean): Boolean {
        if (!admitted()) return false
        updateDestination {
            it.copy(skills = it.skills.copy(catalogChecking = true, catalogError = null))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "skills.list",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = false,
                correlationID = client().correlationID("scat"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("catalog.refresh"),
                        "force" to JsonPrimitive(force),
                    ),
                ),
            ),
        ) { outcome ->
            updateDestination {
                it.copy(skills = it.skills.copy(catalogChecking = false))
            }
            if (outcome is HostOperationOutcome.Completed) refreshSkills()
        }
        return true
    }

    override fun installOfficialSkill(skillId: String): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sinst"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("official.install"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { outcome -> handleInstallOutcome(outcome) }
        return true
    }

    private fun handleInstallOutcome(outcome: HostOperationOutcome, formId: String = "") {
        when (outcome) {
            is HostOperationOutcome.Completed -> {
                val review = outcome.value?.let { IntegrationsWire.decodeReview(it) }
                if (review != null) {
                    val reviewId = reviewIdSource.incrementAndGet()
                    val projection = SkillInstallReviewUi(
                        reviewId = reviewId,
                        sourceDisplay = review.sourceDisplay,
                        skillName = review.skillName,
                        version = review.version,
                        requestedCapabilities = review.requestedCapabilities,
                        tools = review.tools,
                        scriptPaths = review.scriptPaths,
                        pythonPackages = review.pythonPackages,
                        commitInFlight = false,
                    )
                    pendingReviews[reviewId] = PendingReview(
                        reviewToken = review.reviewToken,
                        skillID = review.skillID,
                        revision = review.revision,
                        projection = projection,
                    )
                    updateDestination { it.copy(installReview = projection) }
                } else {
                    updateDestination {
                        it.copy(skills = it.skills.copy(
                            formOutcome = SkillsFormOutcomeUi(formId, true, null),
                        ))
                    }
                    refreshSkills()
                }
            }
            is HostOperationOutcome.Rejected -> updateDestination {
                it.copy(skills = it.skills.copy(
                    formOutcome = SkillsFormOutcomeUi(formId, false, outcome.code),
                ))
            }
            is HostOperationOutcome.Failed -> updateDestination {
                it.copy(skills = it.skills.copy(
                    formOutcome = SkillsFormOutcomeUi(formId, false, outcome.code),
                ))
            }
            else -> Unit
        }
    }

    override fun setSkillEnabled(
        skillId: String,
        expectedRevision: String,
        enabled: Boolean,
    ): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sen"),
                revision = HostRevision("skill.$skillId", expectedRevision),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("enabled.set"),
                        "skillId" to JsonPrimitive(skillId),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { refreshSkills() }
        return true
    }

    override fun deleteSkill(skillId: String, expectedRevision: String): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.uninstall",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sun"),
                revision = HostRevision("skill.$skillId", expectedRevision),
                payload = JsonObject(mapOf("operation" to JsonPrimitive("uninstall"))),
            ),
        ) { refreshSkills() }
        return true
    }

    override fun cancelSkillRun(scope: SkillRunScopeUi): Boolean {
        if (!host.readiness.value.runDomainAdmitted) return false
        // The scope is EXACTLY what the host projected (task+run required;
        // env/job only as actually carried). Maps to run.skillcancel.
        val payload = mutableMapOf<String, JsonElement>(
            "expectedState" to JsonPrimitive("any"),
        )
        (scope as? SkillRunScopeUi.JobOwned)?.let {
            payload["environmentID"] = JsonPrimitive(it.environmentId ?: return@let)
            payload["jobID"] = JsonPrimitive(it.jobId)
        }
        host.trackOperation(
            HostCommandRequest(
                command = "run.skillcancel",
                scope = HostScope.TaskExecution(scope.taskId, scope.runId,
                    (scope as? SkillRunScopeUi.JobOwned)?.environmentId),
                stateful = true,
                correlationID = client().correlationID("sskill"),
                payload = JsonObject(payload),
            ),
        ) { }
        return true
    }

    override fun setAutoScriptedUpdates(enabled: Boolean) {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sauto"),
                revision = HostRevision("skills.settings", "settings"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("settings.set"),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { refreshSkills() }
    }

    override fun confirmPendingInstallation(reviewId: Long): Boolean {
        val review = pendingReviews[reviewId] ?: return false
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sreview"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("review.confirm"),
                        "reviewToken" to JsonPrimitive(review.reviewToken),
                    ),
                ),
            ),
        ) { outcome ->
            pendingReviews.remove(reviewId)
            updateDestination { it.copy(installReview = null) }
            if (outcome is HostOperationOutcome.Completed) refreshSkills()
        }
        return true
    }

    override fun cancelPendingInstallation(reviewId: Long) {
        val review = pendingReviews.remove(reviewId) ?: return
        updateDestination { state ->
            if (state.installReview?.reviewId == reviewId) {
                state.copy(installReview = null)
            } else state
        }
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("srd"),
                revision = HostRevision("skill.${review.skillID}", review.revision),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("review.discard"),
                        "reviewToken" to JsonPrimitive(review.reviewToken),
                    ),
                ),
            ),
        ) { }
    }

    override fun createSkill(formId: String, draft: SkillCreatorDraftUi): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("screate"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("creator.create"),
                        "draft" to IntegrationsWire.creatorDraftJson(draft),
                    ),
                ),
            ),
        ) { handleInstallOutcome(it, formId) }
        return true
    }

    override fun installFromFinder(
        formId: String,
        urlText: String,
        rewriteModelId: String?,
    ): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sfinder"),
                createIntent = true,
                payload = JsonObject(
                    buildMap {
                        put("operation", JsonPrimitive("finder.import"))
                        put("url", JsonPrimitive(urlText))
                        rewriteModelId?.let { put("rewriteModelId", JsonPrimitive(it)) }
                    },
                ),
            ),
        ) { handleInstallOutcome(it, formId) }
        return true
    }

    override fun requestFolderStaging(): Boolean {
        // The host presents the SAF folder picker; the staged folder is
        // registered by the skills owner and imported with the stg:v1 token.
        if (!admitted()) return false
        return true
    }

    override fun importStagedPackage(formId: String, reference: StagedPackageRefUi): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sfolder"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("folder.import"),
                        "stagingToken" to JsonPrimitive(reference.handle),
                    ),
                ),
            ),
        ) { handleInstallOutcome(it, formId) }
        return true
    }

    override fun seedUpgrade(skillId: String): SkillUpgradeUi? =
        destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
            ?.let { row ->
                SkillUpgradeUi(
                    skillId = row.skillId,
                    skillName = row.name,
                    installedVersion = row.version,
                    isOfficial = row.sourceKind == SkillSourceKindUi.OFFICIAL_HUB,
                    savedSource = null,
                    candidateVersion = row.updateAvailableVersion,
                    commit = null,
                    releaseNotes = null,
                    addedCapabilities = emptyList(),
                    addedTools = emptyList(),
                    changedFiles = emptyList(),
                    isLatest = row.updateAvailableVersion == null,
                    checkInFlight = false,
                    applyInFlight = false,
                    canRollback = false,
                    errorMessage = null,
                    lastEffect = null,
                )
            }

    override fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supchk"),
                payload = JsonObject(
                    buildMap {
                        put("operation", JsonPrimitive("upgrade.check"))
                        put("skillId", JsonPrimitive(skillId))
                        source?.let {
                            put("source", JsonObject(
                                mapOf(
                                    "owner" to JsonPrimitive(it.owner),
                                    "repository" to JsonPrimitive(it.repository),
                                    "ref" to JsonPrimitive(it.ref),
                                    "path" to JsonPrimitive(it.path),
                                ),
                            ))
                        }
                    },
                ),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                // The review projection arrives as the upgrade candidate.
                refreshSkills()
            }
        }
        return true
    }

    override fun applyUpgrade(skillId: String, effectToken: Long): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supapp"),
                revision = HostRevision("skill.$skillId", "upgrade"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.apply"),
                        "skillId" to JsonPrimitive(skillId),
                        "effectToken" to JsonPrimitive(effectToken),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    updateDestination { state ->
                        state.upgrade?.let {
                            state.copy(upgrade = it.copy(
                                applyInFlight = false,
                                lastEffect = UpgradeEffectUi(effectToken, UpgradeOutcomeUi.APPLIED),
                            ))
                        } ?: state
                    }
                    refreshSkills()
                }
                is HostOperationOutcome.Rejected -> updateDestination { state ->
                    state.upgrade?.let {
                        state.copy(upgrade = it.copy(
                            applyInFlight = false,
                            lastEffect = UpgradeEffectUi(effectToken, UpgradeOutcomeUi.FAILED),
                        ))
                    } ?: state
                }
                else -> Unit
            }
        }
        return true
    }

    override fun cancelUpgrade(skillId: String) {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supcan"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.discard"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { }
    }

    override fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("suprb"),
                revision = HostRevision("skill.$skillId", "rollback"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.rollback"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { refreshSkills() }
        return true
    }

    override fun openConnectorDestination(destinationId: String): Boolean {
        // Connector destinations are presentation routes inside the
        // integrations surface; the holder owns the pane stack.
        return admitted()
    }

    // ------------------------------------------------------------------- MCP

    override fun seedMcpEditor(serverId: String?): McpEditorSeedUi? {
        if (!admitted()) return null
        val row = serverId?.let { id ->
            destinationState.value.mcp.servers.firstOrNull { it.serverId == id }
        }
        return McpEditorSeedUi(
            serverId = serverId,
            displayName = row?.displayName ?: "",
            endpointText = row?.endpointDisplay ?: "",
            enabled = row?.enabled ?: true,
            allowInCanvas = row?.allowInCanvas ?: false,
            allowInsecureHttp = row?.authentication == McpAuthenticationUi.NONE,
            authentication = row?.authentication ?: McpAuthenticationUi.NONE,
            credentialHeaderName = "Authorization",
            credentialStored = row?.credentialStored ?: false,
            timeoutSeconds = 30,
            transport = McpTransportUi.StreamableHttp,
            tools = row?.tools ?: emptyList(),
            savedRevision = row?.revision,
            networkActionsAvailable = admitted(),
            networkActionsUnavailableReason = if (admitted()) null else "unavailable",
        )
    }

    override fun mcpEditorOpened(identity: McpEditorIdentity) {
        mcpSaveFailureSequencer.reset(identity.editorId, identity.epoch)
        // ONE shared UI incarnation per editor creation; the native admission
        // asserts both the captured native Root epoch and the monotonic shared
        // UI generation (stale/foreign opens are refused there).
        val uiGeneration = HostUiAdmission.nextGeneration()
        val nativeEpoch = host.nativeRootEpoch()
        val token = if (nativeEpoch != null) {
            routeAuthority.open(HostEditorKind.MCP, identity.editorId,
                uiGeneration, nativeEpoch)
        } else {
            null
        }
        if (token != null && isOpaqueHostRouteToken(token)) {
            editorRouteTokens[identity.editorId] = token
        } else {
            editorRouteTokens.remove(identity.editorId)
        }
    }

    override fun mcpEditorClosed(identity: McpEditorIdentity, discarded: Boolean) {
        // Draft/secret disposal is slot-owned (RAM only); a save already
        // admitted may still commit, but its late result is fenced by the
        // identity epoch and cannot touch this closed editor.
        editorRouteTokens.remove(identity.editorId)?.let(routeAuthority::clear)
    }

    override fun saveMcpServer(request: McpSaveRequest): Boolean {
        if (!admitted()) return false
        publishEditor(request.identity) { it.copy(saveInFlight = true, saveError = null) }
        val serverID = serverIDForSave(request)
        val candidate = IntegrationsWire.mcpCandidateJson(request, serverID)
        val revision = request.baseRevision?.let { HostRevision("mcp.server", it.toString()) }
        val payload: JsonObject
        val create: Boolean
        when (request.credentialIntent) {
            CredentialDraftIntent.SET -> {
                val ingressToken = submitBoundMcpIntent(
                    request, serverID, candidate, request.baseRevision)
                if (ingressToken == null) {
                    onMcpSaveFailed(request.identity, "credential_unavailable")
                    return true
                }
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("save"),
                        "secretIntent" to JsonPrimitive("set"),
                        "ingressToken" to JsonPrimitive(ingressToken),
                    ),
                )
                create = revision == null
            }
            CredentialDraftIntent.KEEP_EXISTING -> {
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("save"),
                        "secretIntent" to JsonPrimitive("keep"),
                        "candidate" to candidate,
                    ),
                )
                create = revision == null
            }
            CredentialDraftIntent.CLEAR -> {
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("save"),
                        "secretIntent" to JsonPrimitive("clear"),
                        "candidate" to candidate,
                    ),
                )
                create = revision == null
            }
            CredentialDraftIntent.MISSING -> {
                onMcpSaveFailed(request.identity, "credential_required")
                return true
            }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.connect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcp-save"),
                revision = revision,
                createIntent = create,
                payload = payload,
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> onMcpSaveSucceeded(request.identity)
                is HostOperationOutcome.Rejected -> onMcpSaveFailed(request.identity, outcome.code)
                is HostOperationOutcome.Failed -> onMcpSaveFailed(request.identity, outcome.code)
                HostOperationOutcome.Cancelled -> onMcpSaveFailed(request.identity, "cancelled")
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    private fun onMcpSaveSucceeded(identity: McpEditorIdentity) {
        publishEditor(identity) {
            it.copy(
                saveInFlight = false,
                saveError = null,
                saveOutcome = McpSaveOutcomeUi.Succeeded(
                    newServerId = identity.serverId ?: identity.editorId,
                    newRevision = it.credentialStoredRevision() ?: 0L,
                ),
                saveFailureSequence = mcpSaveFailureSequencer.current(identity.editorId, identity.epoch),
            )
        }
        flowHolder.finalizeSavedEditor(identity)
        refreshMcpServers()
    }

    private fun onMcpSaveFailed(identity: McpEditorIdentity, message: String) {
        val sequence = mcpSaveFailureSequencer.next(identity.editorId, identity.epoch)
        publishEditor(identity) {
            it.copy(
                saveInFlight = false,
                saveError = message,
                saveOutcome = McpSaveOutcomeUi.Failed(message),
                saveFailureSequence = sequence,
            )
        }
        flowHolder.noteMcpSaveAttemptFinished(identity, sequence)
    }

    private fun McpEditorUiState.credentialStoredRevision(): Long? = seed.savedRevision

    override fun deleteMcpServer(serverId: String): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.disconnect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcpdel"),
                revision = HostRevision("mcp.server", row.revision.toString()),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("remove"),
                        "serverId" to JsonPrimitive(serverId),
                    ),
                ),
            ),
        ) { refreshMcpServers() }
        return true
    }

    override fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.connect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcpen"),
                revision = HostRevision("mcp.server", row.revision.toString()),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("enabled.set"),
                        "serverId" to JsonPrimitive(serverId),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { refreshMcpServers() }
        return true
    }

    override fun setMcpToolEnabled(
        serverId: String,
        remoteName: String,
        enabled: Boolean,
    ): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.connect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcptool"),
                revision = HostRevision("mcp.server", row.revision.toString()),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("tool.enabled.set"),
                        "serverId" to JsonPrimitive(serverId),
                        "remoteName" to JsonPrimitive(remoteName),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { refreshMcpServers() }
        return true
    }

    override fun refreshMcpServer(serverId: String): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.connect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcprfr"),
                revision = HostRevision("mcp.server", row.revision.toString()),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("connect"),
                        "serverId" to JsonPrimitive(serverId),
                    ),
                ),
            ),
        ) { refreshMcpServers() }
        return true
    }

    override fun cancelMcpRefresh(serverId: String, generation: Long): Boolean {
        if (!admitted()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.disconnect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcprfc"),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("cancel.refresh"),
                        "serverId" to JsonPrimitive(serverId),
                        "generation" to JsonPrimitive(generation.toString()),
                    ),
                ),
            ),
        ) { }
        return true
    }

    // -------------------------------------------------------------- internals

    private fun publishEditor(
        identity: McpEditorIdentity,
        transform: (McpEditorUiState) -> McpEditorUiState,
    ) {
        updateDestination { state ->
            val editor = state.editor
            if (editor == null || !editor.identity.isCurrentFor(identity)) {
                val seed = seedMcpEditor(identity.serverId) ?: return@updateDestination state
                val seeded = McpEditorUiState(
                    identity = identity,
                    seed = seed,
                    saveInFlight = false,
                    saveError = null,
                    saveOutcome = null,
                    connectionState = McpConnectionStateUi.Inactive,
                    tools = seed.tools,
                    credentialStored = seed.credentialStored,
                    networkActionsAvailable = admitted(),
                    networkActionsUnavailableReason = if (admitted()) null else "unavailable",
                )
                state.copy(editor = transform(seeded))
            } else {
                state.copy(editor = transform(editor))
            }
        }
    }

    /** The stable server identity this editor saves into (UUID-valid). */
    private fun serverIDForSave(request: McpSaveRequest): String {
        request.serverId?.let { return it }
        val existing = UUID.fromString(request.identity.editorId)?.toString()
        if (existing != null) return existing
        return newServerIDs.computeIfAbsent(request.identity.editorId) {
            UUID.randomUUID().toString()
        }
    }

    /**
     * Freeze the closed mcpSave intent (same candidate + baseRevision) and
     * submit it through the trusted native seam with the editor's own route
     * handle. The secret bytes never enter a command, log or state.
     */
    private fun submitBoundMcpIntent(
        request: McpSaveRequest,
        serverID: String,
        candidate: JsonObject,
        baseRevision: Long?,
    ): String? {
        val secret = request.credentialDraft ?: return null
        // This editor incarnation's own handle. Never re-minted here: a late
        // save from an old editor must fail closed instead of creating a
        // newer incarnation that could evict a newer editor's route.
        val route = editorRouteTokens[request.identity.editorId]
            ?.takeIf(::isOpaqueHostRouteToken) ?: return null
        val revision = baseRevision?.let {
            JsonObject(
                mapOf(
                    "resourceID" to JsonPrimitive("mcp.server"),
                    "version" to JsonPrimitive(it.toString()),
                ),
            )
        } ?: JsonObject(
            mapOf(
                "resourceID" to JsonPrimitive("mcp.server"),
                "version" to JsonPrimitive("0"),
            ),
        )
        val intentCore = JsonObject(
            mapOf(
                "subject" to JsonObject(
                    mapOf(
                        "kind" to JsonPrimitive("mcpSave"),
                        "id" to JsonPrimitive(serverID),
                    ),
                ),
                "intent" to JsonPrimitive("set"),
                "baseRevision" to revision,
                "candidate" to candidate,
            ),
        ).toString()
        val bytes = secret.toByteArray(Charsets.UTF_8)
        return try {
            secureIngress.submit(intentCore, route, bytes)?.takeIf(::isOpaqueIngressToken)
        } finally {
            bytes.fill(0)
        }
    }
}

/** Strict-tolerant wire decoders for the Skills/MCP owner pages. */
internal object IntegrationsWire {

    class SkillsSnapshot(
        val installed: List<SkillInstalledRowUi>,
        val catalog: List<SkillCatalogCardUi>,
        val autoScriptedUpdates: Boolean,
        val rewriteModels: List<com.floe.android.feature.integrations.RewriteModelUi>,
        val defaultRewriteModelId: String?,
    )

    fun decodeSkillsSnapshot(value: JsonElement): SkillsSnapshot? {
        val root = value as? JsonObject ?: return null
        val installed = (root["skills"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            SkillInstalledRowUi(
                skillId = id,
                name = obj.string("name") ?: id,
                version = obj.string("version") ?: "",
                summary = obj.string("description"),
                enabled = obj.bool("enabled") ?: true,
                revision = (obj["revision"] as? JsonObject)?.string("version") ?: "",
                availability = if (obj.bool("enabled") == false) {
                    SkillAvailabilityUi.Disabled
                } else {
                    SkillAvailabilityUi.Usable
                },
                offerState = if (obj.bool("enabled") == false) {
                    SkillOfferStateUi.NOT_OFFERED_DISABLED
                } else {
                    SkillOfferStateUi.OFFERED
                },
                permissions = emptyList(),
                runActivity = SkillRunActivityUi.None,
                updateAvailableVersion = null,
                sourceKind = when (obj.string("source")) {
                    "official" -> SkillSourceKindUi.OFFICIAL_HUB
                    "github" -> SkillSourceKindUi.GITHUB
                    "finder" -> SkillSourceKindUi.FINDER
                    "folder" -> SkillSourceKindUi.FOLDER
                    else -> SkillSourceKindUi.CREATOR
                },
                isBundledReadOnlyGuide = obj.bool("bundledSeedSuppressed") == true,
                installStage = null,
            )
        } ?: emptyList()
        val settings = root["settings"] as? JsonObject
        return SkillsSnapshot(
            installed = installed,
            catalog = emptyList(),
            autoScriptedUpdates = settings?.bool("autoScriptedUpdates") ?: false,
            rewriteModels = emptyList(),
            defaultRewriteModelId = settings?.string("defaultRewriteModelId"),
        )
    }

    class Review(
        val reviewToken: String,
        val skillID: String,
        val revision: String,
        val sourceDisplay: String,
        val skillName: String,
        val version: String,
        val requestedCapabilities: List<String>,
        val tools: List<String>,
        val scriptPaths: List<String>,
        val pythonPackages: List<com.floe.android.feature.integrations.PythonRequirementUi>,
    )

    fun decodeReview(value: JsonElement): Review? {
        val root = value as? JsonObject ?: return null
        val token = root.string("reviewToken") ?: return null
        val skillID = root.string("skillID") ?: return null
        return Review(
            reviewToken = token,
            skillID = skillID,
            revision = (root["revision"] as? JsonObject)?.string("version") ?: "",
            sourceDisplay = root.string("sourceDisplay") ?: skillID,
            skillName = root.string("skillName") ?: skillID,
            version = root.string("version") ?: "",
            requestedCapabilities = (root["addedCapabilities"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            tools = (root["addedTools"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            scriptPaths = (root["changedFiles"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            pythonPackages = emptyList(),
        )
    }

    fun decodeMcpServers(value: JsonElement): List<McpServerRowUi>? {
        val root = value as? JsonObject ?: return null
        return (root["servers"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("serverID") ?: return@mapNotNull null
            val auth = when (obj.string("authentication")) {
                "bearerToken" -> McpAuthenticationUi.BEARER_TOKEN
                "customHeader" -> McpAuthenticationUi.CUSTOM_HEADER
                else -> McpAuthenticationUi.NONE
            }
            val connectionObj = obj["connection"] as? JsonObject
            val state = when (connectionObj?.string("state")) {
                "connecting" -> McpConnectionStateUi.Connecting(
                    connectionObj.long("generation") ?: 0L)
                "ready" -> McpConnectionStateUi.Ready(
                    connectionObj.long("toolCount")?.toInt() ?: 0)
                "failed" -> McpConnectionStateUi.Failed(
                    connectionObj.string("reason") ?: "failed")
                else -> McpConnectionStateUi.Inactive
            }
            McpServerRowUi(
                serverId = id,
                displayName = obj.string("displayName") ?: id,
                endpointDisplay = obj.string("endpoint") ?: "",
                enabled = obj.bool("enabled") ?: true,
                allowInCanvas = obj.bool("allowInCanvas") ?: false,
                authentication = auth,
                credentialStored = obj.string("credentialState") == "configured",
                state = state,
                tools = (obj["tools"] as? JsonArray)?.mapNotNull { tool ->
                    val toolObj = tool as? JsonObject ?: return@mapNotNull null
                    McpToolRowUi(
                        remoteName = toolObj.string("remoteName") ?: return@mapNotNull null,
                        displayName = toolObj.string("displayName"),
                        toolDescription = toolObj.string("description") ?: "",
                        enabled = toolObj.bool("enabled") ?: true,
                        readOnlyHint = toolObj.bool("readOnlyHint") ?: false,
                        destructiveHint = toolObj.bool("destructiveHint") ?: false,
                    )
                },
                revision = obj.long("revision") ?: 0L,
            )
        }
    }

    fun creatorDraftJson(draft: SkillCreatorDraftUi): JsonObject = JsonObject(
        mapOf(
            "name" to JsonPrimitive(draft.name),
            "description" to JsonPrimitive(draft.description),
            "instructions" to JsonPrimitive(draft.instructions),
        ),
    )

    fun mcpCandidateJson(request: McpSaveRequest, serverID: String): JsonObject {
        val draft = request.draft
        return JsonObject(
            mapOf(
                "id" to JsonPrimitive(serverID),
                "displayName" to JsonPrimitive(draft.displayName),
                "endpoint" to JsonPrimitive(draft.endpointText),
                "enabled" to JsonPrimitive(draft.enabled),
                "allowInCanvas" to JsonPrimitive(draft.allowInCanvas),
                "allowInsecureHTTP" to JsonPrimitive(draft.allowInsecureHttp),
                "authentication" to JsonPrimitive(
                    when (draft.authentication) {
                        McpAuthenticationUi.NONE -> "none"
                        McpAuthenticationUi.BEARER_TOKEN -> "bearerToken"
                        McpAuthenticationUi.CUSTOM_HEADER -> "customHeader"
                    },
                ),
                "credentialHeaderName" to JsonPrimitive(draft.credentialHeaderName),
                "timeoutSeconds" to JsonPrimitive(draft.timeoutSeconds),
            ),
        )
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull
}
