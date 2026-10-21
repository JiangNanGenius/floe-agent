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
import com.floe.android.feature.integrations.McpServerRevisionUi
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
import com.floe.android.R
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.update
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

    /**
     * The RB7 Skills folder-staging owner (S11). A SEPARATELY owned SAF
     * effect — it never shares the attachment picker's request lane. The
     * composition glue [SkillsFolderPickerEffect] presents the platform
     * OpenDocumentTree for each captured request and hands the tree URI
     * back; the controller copies the selected tree through the trusted
     * native staging channel into the domain-owned scratch directory, then
     * the domain's OWN `registerStagedFolder` validator issues the opaque
     * `stg:v1:` receipt. File arrival installs nothing: the staged
     * reference is offered to the module's import-confirm form, whose
     * `folder.import` command is the only install path (original review +
     * package-safety gates unchanged).
     */
    val folderStaging = SkillsFolderStagingController(
        host = host,
        onStaged = { reference -> flowHolder.onPackageStaged(reference) },
        onStageFailure = { code -> publishSkillsMessage(folderStageMessage(code)) },
        admitted = ::admitted,
    )

    /** Folder-staging typed reason → localized user copy (typed codes stay
     *  in diagnostics only; ordinary UI never prints a wire reason). */
    private fun folderStageMessage(reason: String): String {
        val resId = when (reason) {
        "folder_root_unreadable" -> R.string.integrations_folder_root_unreadable
        "folder_tree_unreadable" -> R.string.integrations_folder_tree_unreadable
        "folder_too_many_files" -> R.string.integrations_folder_too_many_files
        "folder_file_too_large" -> R.string.integrations_folder_file_too_large
        "folder_package_too_large" -> R.string.integrations_folder_package_too_large
        "folder_too_deep" -> R.string.integrations_folder_too_deep
        "folder_unsafe_name", "folder_path_too_long" -> R.string.integrations_folder_unsafe_name
        "folder_duplicate_path" -> R.string.integrations_folder_duplicate_path
        "folder_source_unreadable" -> R.string.integrations_folder_source_unreadable
        "folder_empty" -> R.string.integrations_folder_empty
        "folder_stale_generation" -> R.string.integrations_folder_stale_generation
        "stage_saturated" -> R.string.integrations_stage_saturated
        "storage_full", "folder_write_failed" -> R.string.integrations_storage_full
        "folder_digest_mismatch", "folder_receipt_refused", "stage_refused" ->
            R.string.integrations_folder_verify_failed
        else -> R.string.integrations_folder_unavailable
        }
        return actionString(resId)
    }

    /**
     * MAIN_ANDROID37_LAN_PERMISSION_DECISION_20261021: the Application-
     * owned (per-process; this controller lives on the host, which the
     * Application retains) ACCESS_LOCAL_NETWORK broker for the REQUIRED
     * Android 17 (API 37) local-network reach. It serves every
     * user-launched LOCAL connect hop (MCP now; provider/Home producers
     * can share the same broker through this public seam later) while
     * PUBLIC cloud stays completely ungated. The real current permission
     * state comes ONLY from the platform probe; the UI never sees a
     * "granted" flag the host did not read back.
     */
    internal val localNetwork = LocalNetworkAccessBroker(
        host = host,
        onGuidance = { guidance -> publishLocalGuidance(guidance) },
        onDeniedTyped = { code ->
            publishMcpMessage(actionString(
                if (code == LocalNetworkAccessBroker.CODE_RECOVERY)
                    R.string.integrations_local_network_settings
                else R.string.integrations_local_network_denied,
            ))
        },
    )

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

    /**
     * reviewId → wire review token + skill identity (tokens never enter UI).
     * [kind] drives the confirm/discard shape: an INSTALL review is a NEW
     * identity (explicit create intent, no fabricated version), an UPGRADE
     * review is an existing identity (digest CAS with the REAL echoed
     * revision). [revision] is that native-echoed digest (snapshot
     * `pendingReviews[].revision.version`, or the staged row's digest for a
     * directly returned projection); "" until a real digest is known — the
     * discard/confirm dispatch then re-reads the snapshot first instead of
     * ever sending a fabricated or empty CAS value.
     */
    internal enum class ReviewKind { INSTALL, UPGRADE }

    private class PendingReview(
        val reviewToken: String,
        val skillID: String,
        val revision: String,
        val kind: ReviewKind,
        val projection: SkillInstallReviewUi,
    )

    private val pendingReviews = ConcurrentHashMap<Long, PendingReview>()

    /** Staged UPGRADE reviews per skill id: the REAL `eff:v1:` review token
     *  minted by a completed `upgrade.check` (or the upgrade-shaped
     *  `official.install`) plus the module dispatch token whose sheet owns
     *  it. applyUpgrade uses this as its required `reviewToken`; nothing is
     *  ever invented — an unknown id refuses the dispatch. */
    internal class StagedUpgrade(
        val reviewToken: String,
        val skillID: String,
    )

    private val stagedUpgrades = ConcurrentHashMap<String, StagedUpgrade>()

    /** The skills settings document's REAL CAS digest (sha256 over the
     *  canonical `{"autoScriptedUpdates":<bool>}`) from the latest snapshot;
     *  null until one has actually landed. */
    @Volatile
    private var skillsSettingsRevision: String? = null

    /** Snapshot-paged `skills.list` follow bound (ConfigPageBudget pages are
     * index cursors; the guard keeps a pathological page loop bounded). */
    private val snapshotMaxPages = 32

    /** MCP editor id → the native-issued `rt:v1:` host route handle. */
    private val editorRouteTokens = ConcurrentHashMap<String, String>()

    /** New MCP editor → the ONE stable server UUID its save commits. */
    private val newServerIDs = ConcurrentHashMap<String, String>()

    /** JVM-fixture seam for the trusted route authority (the production
     *  default stays the frozen native seam; this never widens it). */
    internal var testRouteAuthority: HostRouteAuthority? = null
    private fun authority(): HostRouteAuthority = testRouteAuthority ?: routeAuthority

    /** Test seam for the trusted host ingress; production is the frozen seam. */
    internal var secureIngress: HostSecureIngressSubmitter = NativeHostSecureIngressSubmitter

    internal fun start() {
        if (admitted()) {
            refreshSkills()
            refreshMcpServers()
            refreshToolSources()
        }
    }

    internal fun stop() {
        pendingReviews.clear()
        stagedUpgrades.clear()
        skillsSettingsRevision = null
        folderStaging.invalidate()
        localNetwork.invalidate()
    }

    /** Typed, host-localized hub message channel (folder staging, paging). */
    private fun publishSkillsMessage(code: String) {
        updateDestination { it.copy(skills = it.skills.copy(errorMessage = code)) }
    }

    private fun publishMcpMessage(code: String) {
        updateDestination { it.copy(mcp = it.mcp.copy(errorMessage = code)) }
    }

    private fun publishLocalGuidance(
        guidance: com.floe.android.feature.integrations.LocalNetworkGuidanceUi?,
    ) {
        updateDestination {
            it.copy(mcp = it.mcp.copy(localNetworkGuidance = guidance))
        }
    }

    /** Localized string from the integrations runtime-action catalog. The
     *  JVM fixtures run without an Android context; callers treat the
     *  fallback key as an opaque diagnostic label, never as user copy. */
    private fun actionString(resId: Int, vararg args: Any): String = try {
        host.appContext.getString(resId, *args)
    } catch (_: RuntimeException) {
        "integrations_action_$resId"
    }

    private fun admitted(): Boolean = host.readiness.value.skillsMcpDomainAdmitted
    private fun client() = host.commandClient

    private fun updateDestination(
        transform: (IntegrationsDestinationState) -> IntegrationsDestinationState,
    ) {
        destinationState.update(transform)
    }

    // ---------------------------------------------------------- projections

    /**
     * Page chain identity. A NEW refresh supersedes any in-flight chain:
     * a late page from an older chain never mutates the projection (the
     * same stale-callback rule the editor epoch uses).
     */
    private val snapshotChain = java.util.concurrent.atomic.AtomicLong(0)
    private val mcpListChain = java.util.concurrent.atomic.AtomicLong(0)

    /** Tokens this host already confirmed/discarded; never re-mirrored from
     *  a snapshot into the review surface. */
    private val handledReviewTokens = ConcurrentHashMap.newKeySet<String>()

    internal fun refreshSkills() {
        if (!admitted()) return
        val chain = snapshotChain.incrementAndGet()
        requestSkillsPage(chain = chain, cursor = null, pagesRead = 0)
    }

    /** One snapshot page; `nextCursor` (decimal index; the frozen payload
     *  cursor role) continues the SAME chain under the page bound. Installed
     *  rows ACCUMULATE across pages; catalog, settings and pendingReviews
     *  repeat identically on every page, so the page's copies simply
     *  replace the accumulated fields. */
    private fun requestSkillsPage(chain: Long, cursor: String?, pagesRead: Int) {
        host.trackOperation(
            HostCommandRequest(
                command = "skills.list",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = false,
                correlationID = client().correlationID("slist"),
                payload = JsonObject(
                    buildMap {
                        put("operation", JsonPrimitive("snapshot"))
                        cursor?.let { put("cursor", JsonPrimitive(it)) }
                    },
                ),
            ),
        ) { outcome ->
            // A stale chain's callback must never touch a newer root/editor.
            if (snapshotChain.get() != chain) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { IntegrationsWire.decodeSkillsSnapshot(it) }
                    if (page == null) {
                        updateDestination {
                            it.copy(skills = it.skills.copy(
                                isLoading = false, errorMessage = "decode_failed"))
                        }
                    } else {
                        applySkillsPage(page, firstPage = cursor == null)
                        val next = page.nextCursor
                        if (page.hasMore && next != null && pagesRead + 1 < snapshotMaxPages) {
                            requestSkillsPage(chain, next, pagesRead + 1)
                        } else if (page.hasMore) {
                            // Bound reached: honest typed marker, never a
                            // silent "complete" claim.
                            publishSkillsMessage(
                                actionString(R.string.integrations_paging_truncated))
                        }
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

    /** RAM accumulator for the CURRENT snapshot chain (never persisted). */
    private var snapshotAccumulated: List<SkillInstalledRowUi> = emptyList()

    private fun applySkillsPage(
        page: IntegrationsWire.SkillsSnapshotPage,
        firstPage: Boolean,
    ) {
        if (firstPage) snapshotAccumulated = emptyList()
        val seen = HashSet<String>()
        val merged = (snapshotAccumulated + page.installed).filter { seen.add(it.skillId) }
        snapshotAccumulated = merged

        skillsSettingsRevision = page.settingsRevision ?: skillsSettingsRevision

        val catalogVersionById: Map<String, String> =
            page.catalogEntries.associate { it.id to it.version }
        val installedWithUpdates = merged.map { row ->
            val entry = catalogVersionById[row.skillId]
            val newer = entry != null && IntegrationsWire.isNewerVersion(entry, row.version)
            row.copy(updateAvailableVersion = if (newer) entry else null)
        }
        // Discover cards from the signed catalog projection, cross-referenced
        // against the accumulated installed rows (the original Discover
        // segment semantics; the old hardcoded emptyList is gone). Display
        // name/summary: the catalog packages rows carry id/version/
        // releaseNotes ONLY — the closed projection emits no display name,
        // so the id is the honest label and the localized release note is
        // the honest summary (never an invented description).
        val installedById = merged.associateBy { it.skillId }
        val cards = page.catalogEntries.map { entry ->
            val row = installedById[entry.id]
            val newer = row != null &&
                IntegrationsWire.isNewerVersion(entry.version, row.version)
            val state: com.floe.android.feature.integrations.CatalogCardStateUi = when {
                row == null -> com.floe.android.feature.integrations
                    .CatalogCardStateUi.NotInstalled
                newer -> com.floe.android.feature.integrations
                    .CatalogCardStateUi.UpdateTo(entry.version)
                !row.enabled -> com.floe.android.feature.integrations
                    .CatalogCardStateUi.InstalledNeedsEnable
                else -> com.floe.android.feature.integrations
                    .CatalogCardStateUi.InstalledReady
            }
            SkillCatalogCardUi(
                skillId = entry.id,
                name = entry.id,
                version = entry.version,
                summary = localizedReleaseNote(entry.releaseNotes) ?: "",
                state = state,
            )
        }

        // Reconcile the staged-review map: every live native review has a
        // snapshot row with the REAL echoed revision; reviews that vanished
        // (retired/expired/other generation) drop from the host map too.
        val liveTokens = HashSet<String>(page.pendingReviewRows.size)
        for (row in page.pendingReviewRows) {
            liveTokens.add(row.reviewToken)
            if (handledReviewTokens.contains(row.reviewToken)) continue
            val existing = pendingReviews.values.firstOrNull {
                it.reviewToken == row.reviewToken
            }
            if (existing == null) {
                val reviewId = reviewIdSource.incrementAndGet()
                val pending = PendingReview(
                    reviewToken = row.reviewToken,
                    skillID = row.skillID,
                    revision = row.revision,
                    kind = if (row.kind == "upgrade") ReviewKind.UPGRADE else ReviewKind.INSTALL,
                    projection = SkillInstallReviewUi(
                        reviewId = reviewId,
                        sourceDisplay = row.skillID,
                        skillName = row.skillID,
                        version = "",
                        requestedCapabilities = emptyList(),
                        tools = emptyList(),
                        scriptPaths = emptyList(),
                        pythonPackages = emptyList(),
                        commitInFlight = false,
                    ),
                )
                pendingReviews[reviewId] = pending
                // Mirror an un-attended staged review into the sheet when
                // nothing else is presented (⇄ the original single
                // pendingInstallation presentation semantics).
                val current = destinationState.value.installReview
                if (current == null) {
                    updateDestination { it.copy(installReview = pending.projection) }
                }
            } else if (row.revision.isNotEmpty() && existing.revision != row.revision) {
                // The snapshot echo is authoritative for the CAS revision.
                val slot = pendingReviews.entries.firstOrNull { it.value === existing }?.key
                if (slot != null) {
                    pendingReviews[slot] = PendingReview(
                        reviewToken = existing.reviewToken,
                        skillID = existing.skillID,
                        revision = row.revision,
                        kind = existing.kind,
                        projection = existing.projection,
                    )
                }
            }
        }
        pendingReviews.entries.toList().forEach { entry ->
            if (!liveTokens.contains(entry.value.reviewToken) &&
                destinationState.value.installReview?.reviewId != entry.key
            ) {
                pendingReviews.remove(entry.key)
            }
        }

        val catalogError = when {
            page.catalogLastFailure != null -> page.catalogLastFailure
            page.catalogState == "unavailable" -> null // not refreshed yet
            else -> null
        }
        updateDestination { state ->
            state.copy(
                skills = state.skills.copy(
                    isLoading = false,
                    installed = installedWithUpdates,
                    catalogCards = cards,
                    autoScriptedUpdates = page.autoScriptedUpdates,
                    rewriteModels = rewriteModelChoices(),
                    defaultRewriteModelId = null,
                    catalogError = catalogError ?: state.skills.catalogError,
                    errorMessage = state.skills.errorMessage.takeIf {
                        !firstPage && (
                            it == actionString(R.string.integrations_paging_truncated) ||
                                it == "row_decode_skipped"
                        )
                    },
                ),
            )
        }
    }

    private fun localizedReleaseNote(notes: Map<String, String>): String? {
        if (notes.isEmpty()) return null
        val locale = runCatching { java.util.Locale.getDefault().language }
            .getOrDefault("en")
        return notes.entries.firstOrNull { it.key.startsWith(locale) }?.value
            ?: notes.entries.firstOrNull()?.value
    }

    /** Rewrite-model choices from the ACTUAL configured-and-usable model
     *  projection (the existing run-domain `ModelProjection` the composer
     *  already owns — the same SKL-DISCOVER-USABLE rows, never an invented
     *  list). Empty until the real model page lands, exactly like every
     *  other projection in this controller. */
    private fun rewriteModelChoices(): List<com.floe.android.feature.integrations.RewriteModelUi> =
        host.conversations.modelProjectionFlow.value.models
            .filter { it.isUsable }
            .map { com.floe.android.feature.integrations.RewriteModelUi(it.modelId, it.displayName) }

    internal fun refreshMcpServers() {
        if (!admitted()) return
        val chain = mcpListChain.incrementAndGet()
        requestMcpListPage(chain, cursor = null)
    }

    private fun requestMcpListPage(chain: Long, cursor: String?) {
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.servers.list",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = false,
                correlationID = client().correlationID("mlist"),
                payload = JsonObject(
                    buildMap {
                        put("operation", JsonPrimitive("snapshot"))
                        cursor?.let { put("cursor", JsonPrimitive(it)) }
                    },
                ),
            ),
        ) { outcome ->
            if (mcpListChain.get() != chain) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { IntegrationsWire.decodeMcpServersPage(it) }
                    if (page == null) {
                        updateDestination {
                            it.copy(mcp = it.mcp.copy(isLoading = false,
                                errorMessage = "decode_failed"))
                        }
                        return@trackOperation
                    }
                    val carried: List<McpServerRowUi> =
                        if (cursor == null || cursor == "0") emptyList()
                        else destinationState.value.mcp.servers
                    val merged = carried + page.servers
                    updateDestination { state ->
                        state.copy(mcp = state.mcp.copy(
                            isLoading = false,
                            servers = merged,
                            errorMessage = if (page.decodeSkippedRows > 0)
                                "row_decode_skipped" else null,
                        ))
                    }
                    val next = page.nextCursor
                    if (page.hasMore && next != null &&
                        (cursor == null || (cursor.toIntOrNull() ?: -1) + 1 < snapshotMaxPages)
                    ) {
                        requestMcpListPage(chain, next)
                    } else if (page.hasMore) {
                        updateDestination {
                            it.copy(mcp = it.mcp.copy(
                                errorMessage = actionString(
                                    R.string.integrations_paging_truncated)))
                        }
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
        localNetwork.refreshCheck()
        refreshSkills()
        refreshMcpServers()
        refreshToolSources()
    }

    override fun closeAll() {
        // Holder-owned UI retirement; projections stay for the next open.
        // An un-presented picker request is dropped (nothing was launched);
        // in-flight staging continues host-owned exactly like installs.
        folderStaging.abandonUnlaunched()
    }

    /**
     * F-S12: bind the REAL `capability.tools.list` usable-tool projection to
     * the existing Connectors surface. Bounded page following (decimal
     * cursor), per-source tallies over `availability` + prerequisite kinds;
     * never a hard-empty list, never "all descriptors usable". stdio/SSH/
     * linux families stay honest NOT_IMPLEMENTED rows with the G03
     * remediation, exactly as the domain projects them.
     */
    private val toolSourcesChain = java.util.concurrent.atomic.AtomicLong(0)

    private class ToolSourceTally(
        var available: Int = 0,
        var blocked: Int = 0,
        val blockedReasons: MutableList<String> = mutableListOf(),
    )

    private fun refreshToolSources() {
        if (!admitted()) return
        val chain = toolSourcesChain.incrementAndGet()
        requestToolSourcesPage(
            chain = chain,
            cursor = null,
            nativeTally = ToolSourceTally(),
            mcpTallies = HashMap(),
            pagesRead = 0,
        )
    }

    private fun requestToolSourcesPage(
        chain: Long,
        cursor: String?,
        nativeTally: ToolSourceTally,
        mcpTallies: HashMap<String, ToolSourceTally>,
        pagesRead: Int,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "capability.tools.list",
                scope = HostScope.ApplicationConfiguration("capabilities"),
                stateful = false,
                correlationID = client().correlationID("caplist"),
                payload = JsonObject(
                    buildMap {
                        put("includeUnavailable", JsonPrimitive(true))
                        cursor?.let { put("cursor", JsonPrimitive(it)) }
                    },
                ),
            ),
        ) { outcome ->
            if (toolSourcesChain.get() != chain) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let {
                        IntegrationsWire.decodeToolSources(it)
                    } ?: return@trackOperation
                    for (item in page.items) {
                        val tally = when {
                            item.source == "mcp" -> mcpTallies.getOrPut(
                                item.mcpPrefix ?: "mcp",
                            ) { ToolSourceTally() }
                            else -> nativeTally
                        }
                        if (item.availability == "available") {
                            tally.available += 1
                        } else {
                            tally.blocked += 1
                            item.prerequisiteKinds.firstOrNull()?.let {
                                tally.blockedReasons.add(it)
                            }
                        }
                    }
                    val next = page.nextCursor
                    if (page.hasMore && next != null && pagesRead + 1 < snapshotMaxPages) {
                        requestToolSourcesPage(
                            chain, next, nativeTally, mcpTallies, pagesRead + 1)
                    } else {
                        publishToolSources(nativeTally, mcpTallies,
                            truncated = page.hasMore)
                    }
                }
                is HostOperationOutcome.Rejected, is HostOperationOutcome.Failed -> {
                    // Honest emptiness: no claim without a real projection.
                    updateDestination {
                        it.copy(connectors = it.connectors.copy(toolSources = emptyList()))
                    }
                }
                else -> Unit
            }
        }
    }

    private fun publishToolSources(
        nativeTally: ToolSourceTally,
        mcpTallies: Map<String, ToolSourceTally>,
        truncated: Boolean,
    ) {
        val servers = destinationState.value.mcp.servers
        val rows = mutableListOf<
            com.floe.android.feature.integrations.ConnectorDestinationRowUi>()
        val nativeTitle = buildString {
            append(actionString(R.string.integrations_source_native_tools))
            append(" · ")
            append(actionString(
                R.string.integrations_source_ready_count, nativeTally.available))
            if (nativeTally.blocked > 0) {
                append(" · ")
                append(actionString(
                    R.string.integrations_source_blocked_count, nativeTally.blocked))
            }
            if (truncated) {
                append(" · ")
                append(actionString(R.string.integrations_paging_truncated))
            }
        }
        rows.add(
            com.floe.android.feature.integrations.ConnectorDestinationRowUi(
                destinationId = "native-tools",
                title = nativeTitle,
                subtitle = null,
                availability = if (nativeTally.available > 0) {
                    com.floe.android.feature.integrations.ConnectorAvailabilityUi.Available
                } else {
                    com.floe.android.feature.integrations.ConnectorAvailabilityUi.Unavailable(
                        remediationFor(nativeTally.blockedReasons),
                    )
                },
            ),
        )
        for ((prefix, tally) in mcpTallies) {
            val server = servers.firstOrNull {
                mcpToolPrefix(it.serverId) == prefix
            }
            val label = server?.displayName ?: actionString(R.string.integrations_source_mcp)
            val title = "$label · " + actionString(
                R.string.integrations_source_ready_count, tally.available)
            rows.add(
                com.floe.android.feature.integrations.ConnectorDestinationRowUi(
                    destinationId = "mcp-tools." + (server?.serverId ?: prefix),
                    title = title,
                    subtitle = null,
                    availability = if (tally.available > 0) {
                        com.floe.android.feature.integrations.ConnectorAvailabilityUi.Available
                    } else {
                        com.floe.android.feature.integrations.ConnectorAvailabilityUi.Unavailable(
                            remediationFor(tally.blockedReasons),
                        )
                    },
                ),
            )
        }
        updateDestination {
            it.copy(connectors = it.connectors.copy(toolSources = rows))
        }
    }

    /** ⇄ MCPServerConfiguration.namespacePrefix (ORIGINAL rule, mirrored
     *  projection only): "mcp_" + first 10 lowercase uuid hex digits. */
    private fun mcpToolPrefix(serverId: String): String =
        "mcp_" + serverId.replace("-", "").lowercase().take(10)

    private fun remediationFor(reasons: List<String>): String {
        val kind = reasons.firstOrNull()
        return when {
            kind == null -> actionString(R.string.integrations_tools_unavailable)
            kind.contains("environment", true) || kind.contains("G03", true) ->
                actionString(R.string.integrations_tools_environment_pending)
            kind.contains("notImplemented", true) ->
                actionString(R.string.integrations_tools_environment_pending)
            kind.contains("credential", true) || kind.contains("configuration", true) ->
                actionString(R.string.integrations_tools_needs_configuration)
            else -> actionString(R.string.integrations_tools_unavailable)
        }
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

    /**
     * ⇄ SkillsCenter.installOfficialSkill semantics: the SAME affordance
     * installs (new identity: explicit create intent, no revision) or
     * stages an update (existing identity: `skill.<id>` digest CAS, NO
     * create intent — the domain refuses createConflict otherwise). The
     * choice is made from the REAL projected row, never a fabricated
     * version.
     */
    override fun installOfficialSkill(skillId: String): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
        val existing = row?.revision?.takeIf { it.isNotEmpty() }
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sinst"),
                createIntent = existing == null,
                revision = existing?.let { HostRevision("skill.$skillId", it) },
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("official.install"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { outcome -> handleInstallOutcome(outcome, requestedSkillId = skillId) }
        return true
    }

    private fun handleInstallOutcome(
        outcome: HostOperationOutcome,
        formId: String = "",
        /** The skill id the command targeted (official.install); null for
         *  finder/folder/creator where identity arrives with the review. */
        requestedSkillId: String? = null,
        /** True for `upgrade.check` results — the staged review is always
         *  an existing-identity UPGRADE there and feeds the sheet. */
        upgradeHop: Boolean = false,
    ) {
        when (outcome) {
            is HostOperationOutcome.Completed -> {
                val review = outcome.value?.let { IntegrationsWire.decodeReview(it) }
                if (review != null) {
                    // Kind truth: an existing installed row means the native
                    // staged an UPGRADE review (its confirm must ride the
                    // digest CAS, NOT create intent); no row = INSTALL.
                    val row = destinationState.value.skills.installed
                        .firstOrNull { it.skillId == review.skillID }
                    val kind = when {
                        upgradeHop -> ReviewKind.UPGRADE
                        row != null && requestedSkillId == review.skillID -> ReviewKind.UPGRADE
                        else -> ReviewKind.INSTALL
                    }
                    // The honest CAS echo: the staged review revision pairs
                    // with the CURRENT row digest. The snapshot echo (next
                    // page) replaces it authoritatively when present.
                    val revisionEcho = if (kind == ReviewKind.UPGRADE) row?.revision ?: "" else ""
                    val reviewId = reviewIdSource.incrementAndGet()
                    val projection = SkillInstallReviewUi(
                        reviewId = reviewId,
                        // F-S8 honesty: the closed SkillsReviewProjection
                        // carries NO display name/source strings; the skill
                        // id is the only truthful label (the old invented
                        // sourceDisplay/skillName decode keys are gone).
                        sourceDisplay = review.skillID,
                        skillName = review.skillID,
                        version = review.version,
                        requestedCapabilities = review.requestedCapabilities,
                        tools = review.tools,
                        scriptPaths = review.scriptPaths,
                        // The original SkillsReviewProjection carries NO
                        // python-package manifest fields; the sheet shows
                        // the honest "none projected" state instead of a
                        // fabricated requirement list.
                        pythonPackages = emptyList(),
                        commitInFlight = false,
                    )
                    pendingReviews[reviewId] = PendingReview(
                        reviewToken = review.reviewToken,
                        skillID = review.skillID,
                        revision = revisionEcho,
                        kind = kind,
                        projection = projection,
                    )
                    if (kind == ReviewKind.UPGRADE) {
                        stagedUpgrades[review.skillID] = StagedUpgrade(
                            reviewToken = review.reviewToken,
                            skillID = review.skillID,
                        )
                    }
                    if (upgradeHop) {
                        // F-S7: the check result FEEDS the open sheet with
                        // the real candidate (version/notes/files); the old
                        // result-discarded path is gone. The sheet only
                        // updates for its own skill id (late-hop fence).
                        updateDestination { state ->
                            val sheet = state.upgrade
                                ?.takeIf { it.skillId == review.skillID }
                            if (sheet == null) {
                                // No open sheet: the staged review is kept
                                // host-side; nothing else changes.
                                state
                            } else {
                                state.copy(
                                    upgrade = sheet.copy(
                                        candidateVersion = review.version,
                                        checkInFlight = false,
                                        applyInFlight = sheet.applyInFlight,
                                        isLatest = review.version.isNotEmpty() &&
                                            review.version == sheet.installedVersion,
                                        releaseNotes = review.releaseNotesLocalized,
                                        addedCapabilities = review.requestedCapabilities,
                                        addedTools = review.tools,
                                        changedFiles = review.scriptPaths.map {
                                            com.floe.android.feature.integrations
                                                .SkillFileDiffUi(it, null, null)
                                        },
                                        errorMessage = null,
                                    ),
                                )
                            }
                        }
                        refreshSkills()
                    } else {
                        updateDestination { it.copy(installReview = projection) }
                    }
                } else {
                    // committed=true reply (no token): the ORIGINAL funnel
                    // already installed through the staging service.
                    updateDestination {
                        it.copy(skills = it.skills.copy(
                            formOutcome = SkillsFormOutcomeUi(formId, true, null),
                        ))
                    }
                    refreshSkills()
                }
            }
            is HostOperationOutcome.Rejected -> {
                if (upgradeHop) {
                    updateDestination { state ->
                        val sheet = state.upgrade
                        if (sheet != null && sheet.skillId == requestedSkillId) {
                            state.copy(upgrade = sheet.copy(
                                checkInFlight = false, errorMessage = outcome.code))
                        } else state
                    }
                }
                updateDestination {
                    it.copy(skills = it.skills.copy(
                        formOutcome = SkillsFormOutcomeUi(formId, false, outcome.code),
                    ))
                }
            }
            is HostOperationOutcome.Failed -> {
                if (upgradeHop) {
                    updateDestination { state ->
                        val sheet = state.upgrade
                        if (sheet != null && sheet.skillId == requestedSkillId) {
                            state.copy(upgrade = sheet.copy(
                                checkInFlight = false, errorMessage = outcome.code))
                        } else state
                    }
                }
                updateDestination {
                    it.copy(skills = it.skills.copy(
                        formOutcome = SkillsFormOutcomeUi(formId, false, outcome.code),
                    ))
                }
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
        val digest = skillsSettingsRevision
        if (digest == null) {
            // The settings document's REAL digest has not landed yet: a
            // fabricated CAS ("settings", or any default) is forbidden, so
            // the honest behavior is a re-read; the toggle will dispatch on
            // the next user action once the snapshot carries the digest.
            refreshSkills()
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sauto"),
                revision = HostRevision("skills.settings", digest),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("settings.set"),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) {
            // The terminal re-reads the CURRENT document either way: a
            // typed staleRevision leaves the toggle at the real server
            // value, and the next user retry CASes against the fresh
            // digest (no optimistic flip is ever published here).
            refreshSkills()
        }
    }

    override fun confirmPendingInstallation(reviewId: Long): Boolean {
        val review = pendingReviews[reviewId] ?: return false
        if (!admitted()) return false
        // F-S4/S8: the review.kind decides the frozen shape, exactly as the
        // domain's reviewCommit gate demands: INSTALL = NEW identity (explicit
        // create intent, no revision); UPGRADE = existing identity with the
        // REAL skill.<id> digest CAS and NO create intent. A direct reply
        // without the snapshot echo cannot confirm an UPGRADE yet (its honest
        // digest is unknown): re-read the snapshot (whose pendingReviews rows
        // carry `revision.version` = the staged review's echoed CAS) and let
        // the user's next tap confirm with the real value. Never fabricate.
        when {
            review.kind == ReviewKind.UPGRADE && review.revision.isEmpty() -> {
                refreshSkills()
                return true
            }
            review.kind == ReviewKind.UPGRADE -> {
                confirmUpgradeReview(reviewId, review)
            }
            else -> confirmInstallReview(reviewId, review)
        }
        return true
    }

    private fun confirmInstallReview(reviewId: Long, review: PendingReview) {
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
            handledReviewTokens.add(review.reviewToken)
            pendingReviews.remove(reviewId)
            updateDestination { state ->
                if (state.installReview?.reviewId == reviewId) {
                    state.copy(installReview = null)
                } else state
            }
            if (outcome is HostOperationOutcome.Completed) refreshSkills()
        }
    }

    private fun confirmUpgradeReview(reviewId: Long, review: PendingReview) {
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("sreviewu"),
                revision = HostRevision("skill.${review.skillID}", review.revision),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("review.confirm"),
                        "reviewToken" to JsonPrimitive(review.reviewToken),
                    ),
                ),
            ),
        ) { outcome ->
            handledReviewTokens.add(review.reviewToken)
            pendingReviews.remove(reviewId)
            stagedUpgrades.remove(review.skillID)
            updateDestination { state ->
                if (state.installReview?.reviewId == reviewId) {
                    state.copy(installReview = null)
                } else state
            }
            if (outcome is HostOperationOutcome.Completed) refreshSkills()
        }
    }

    override fun cancelPendingInstallation(reviewId: Long) {
        val review = pendingReviews[reviewId] ?: return
        updateDestination { state ->
            if (state.installReview?.reviewId == reviewId) {
                state.copy(installReview = null)
            } else state
        }
        handledReviewTokens.add(review.reviewToken)
        pendingReviews.remove(reviewId)
        stagedUpgrades.remove(review.skillID)
        if (!admitted()) return
        // The native reviewDiscard is token-only, but the frozen matrix
        // demands a structural revision on every non-create skills.install
        // mutation and the envelope parser rejects an empty version. For an
        // UPGRADE-kind review the row digest is the honest echo (snapshot
        // pendingReviews or the staged row). For an INSTALL-kind review with
        // no digest echo yet (direct reply before the next snapshot page),
        // the honest structural value is the staged review's own echoed
        // revision, which only the snapshot carries: re-read first, and
        // dispatch the discard with the REAL pair — never "".
        if (review.revision.isEmpty()) {
            discardAfterSnapshot(review)
            return
        }
        dispatchReviewDiscard(review)
    }

    private fun discardAfterSnapshot(review: PendingReview) {
        // One-shot: dispatch the discard from the NEXT snapshot decode when
        // it echoes this still-live token's real revision. If the review is
        // gone by then, there is nothing to discard (retirement already
        // happened domain-side).
        host.trackOperation(
            HostCommandRequest(
                command = "skills.list",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = false,
                correlationID = client().correlationID("srdlist"),
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                val echo = outcome.value?.let { IntegrationsWire.decodeSkillsSnapshot(it) }
                    ?.pendingReviewRows
                    ?.firstOrNull { it.reviewToken == review.reviewToken }
                if (echo != null && echo.revision.isNotEmpty()) {
                    dispatchReviewDiscard(
                        PendingReview(
                            reviewToken = review.reviewToken,
                            skillID = review.skillID,
                            revision = echo.revision,
                            kind = if (echo.kind == "upgrade") ReviewKind.UPGRADE
                            else ReviewKind.INSTALL,
                            projection = review.projection,
                        ),
                    )
                }
            }
        }
    }

    private fun dispatchReviewDiscard(review: PendingReview) {
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
        // S11: true ONLY when the SAF OpenDocumentTree picker was really
        // presented (the owned Skills folder lane's request state flipped).
        // The staged tree is copied through the trusted native staging
        // channel into the domain-owned scratch directory; the domain's own
        // registerStagedFolder validator issues the opaque stg:v1 receipt,
        // which arrives at the module form via onPackageStaged. Arrival
        // installs nothing: folder.import remains the only install path.
        return folderStaging.presentPicker()
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
                    // F-S7: candidate from the ACTUAL catalog diff projected
                    // into the row (never hardcoded null); a staged check
                    // result then refines it with the review reply.
                    candidateVersion = row.updateAvailableVersion,
                    commit = null,
                    releaseNotes = null,
                    addedCapabilities = emptyList(),
                    addedTools = emptyList(),
                    changedFiles = emptyList(),
                    isLatest = row.updateAvailableVersion == null,
                    checkInFlight = false,
                    applyInFlight = false,
                    // F-S6: honest journal existence from the snapshot row
                    // (`rollbackAvailable`), never a hardcoded false once
                    // the real journal exists.
                    canRollback = row.rollbackAvailable,
                    errorMessage = null,
                    lastEffect = null,
                )
            }

    override fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean {
        if (!admitted()) return false
        // The frozen matrix demands a revision on every non-create
        // skills.install mutation (the LOCAL validator refuses the envelope
        // before it is ever built otherwise): the check rides the CURRENT
        // row's real digest. The domain uses its own row read for the
        // staged base; the envelope pair is the structural CAS the command
        // lane requires. No row, no honest pair — refuse instead of
        // fabricating one.
        val row = destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
        if (row == null || row.revision.isEmpty()) return false
        val seed = seedUpgrade(skillId) ?: return false
        updateDestination { state ->
            if (state.upgrade?.skillId == skillId) state else state.copy(upgrade = seed)
        }
        markCheckInFlight(skillId, true)
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supchk"),
                revision = HostRevision("skill.$skillId", row.revision),
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
            // F-S7: the Completed value is the SkillsReviewProjection — the
            // upgrade candidate — routed into the open sheet (with the real
            // staged eff:v1 token kept host-side for apply).
            handleInstallOutcome(
                outcome,
                requestedSkillId = skillId,
                upgradeHop = true,
            )
        }
        return true
    }

    /** Check-in-flight flips on the sheet that OWNS the dispatch (the
     *  same skill-id fence the apply/rollback paths use; a late terminal
     *  for another sheet incarnation cannot strand "Checking…"). */
    private fun markCheckInFlight(skillId: String, inFlight: Boolean) {
        updateDestination { state ->
            val sheet = state.upgrade?.takeIf { it.skillId == skillId }
                ?: return@updateDestination state
            state.copy(upgrade = sheet.copy(checkInFlight = inFlight))
        }
    }

    /**
     * F-S4. The closed native grammar is
     * `{operation, reviewToken(REQUIRED, eff:v1), effectToken(optional
     * STRING), cursor}` — the staged review token is the authority; the
     * optional effectToken is only a late-outcome echo fence. The host maps
     * the module's monotonic presentation Long onto that echo; the native
     * review token never enters the UI and the Long is never sent as one.
     * The revision pair is the CURRENT row's real `skill.<id>` digest (an
     * envelope CAS when present must match it exactly). The old
     * skillId + numeric token + "upgrade" revision shape could never pass
     * the closed payload check and is gone.
     */
    override fun applyUpgrade(skillId: String, effectToken: Long): Boolean {
        if (!admitted()) return false
        val staged = stagedUpgrades[skillId]
        val row = destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
        if (staged == null || row == null || row.revision.isEmpty()) {
            // No staged review / no real digest: refuse honestly at the
            // seam (the sheet shows the retry state) instead of minting a
            // token or revision.
            updateDestination { state ->
                val sheet = state.upgrade?.takeIf { it.skillId == skillId }
                if (sheet == null) state else state.copy(
                    upgrade = sheet.copy(errorMessage = "reviewRequired"),
                )
            }
            return false
        }
        markApplyInFlight(skillId, true)
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supapp"),
                revision = HostRevision("skill.$skillId", row.revision),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.apply"),
                        "reviewToken" to JsonPrimitive(staged.reviewToken),
                        "effectToken" to JsonPrimitive(effectToken.toString()),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    // The typed value (state "upgraded" + effectEcho) is
                    // consumed once for THIS dispatch token only; a late
                    // terminal cannot act on a newer sheet.
                    stagedUpgrades.remove(skillId)
                    markApplyInFlight(skillId, false)
                    updateDestination { state ->
                        state.upgrade
                            ?.takeIf { it.skillId == skillId }
                            ?.let {
                                state.copy(upgrade = it.copy(
                                    applyInFlight = false,
                                    lastEffect = UpgradeEffectUi(
                                        effectToken, UpgradeOutcomeUi.APPLIED),
                                ))
                            } ?: state
                    }
                    refreshSkills()
                }
                is HostOperationOutcome.Rejected -> {
                    markApplyInFlight(skillId, false)
                    // A consumed/expired/retired staged review must not stay
                    // mapped: the sheet then requires a fresh check.
                    if (outcome.code == "notFound") stagedUpgrades.remove(skillId)
                    updateDestination { state ->
                        state.upgrade?.takeIf { it.skillId == skillId }?.let {
                            state.copy(upgrade = it.copy(
                                applyInFlight = false,
                                errorMessage = outcome.code,
                                lastEffect = UpgradeEffectUi(
                                    effectToken, UpgradeOutcomeUi.FAILED),
                            ))
                        } ?: state
                    }
                }
                is HostOperationOutcome.Failed -> {
                    markApplyInFlight(skillId, false)
                    updateDestination { state ->
                        state.upgrade?.takeIf { it.skillId == skillId }?.let {
                            state.copy(upgrade = it.copy(
                                applyInFlight = false,
                                errorMessage = outcome.code,
                                lastEffect = UpgradeEffectUi(
                                    effectToken, UpgradeOutcomeUi.FAILED),
                            ))
                        } ?: state
                    }
                }
                else -> Unit
            }
        }
        return true
    }

    private fun markApplyInFlight(skillId: String, inFlight: Boolean) {
        updateDestination { state ->
            val sheet = state.upgrade?.takeIf { it.skillId == skillId }
                ?: return@updateDestination state
            state.copy(upgrade = sheet.copy(applyInFlight = inFlight))
        }
    }

    override fun cancelUpgrade(skillId: String) {
        stagedUpgrades.remove(skillId)
        // Drop any host-side pending UPGRADE review mirror for this skill;
        // the staged tree itself is torn down domain-side by discard.
        pendingReviews.entries.toList()
            .filter { it.value.skillID == skillId && it.value.kind == ReviewKind.UPGRADE }
            .forEach { entry ->
                handledReviewTokens.add(entry.value.reviewToken)
                pendingReviews.remove(entry.key)
            }
        if (!admitted()) return
        // upgrade.discard is token-less but the frozen matrix still
        // demands a structural revision on non-create skills.install:
        // echo the CURRENT row's real digest. Without an honest pair the
        // local validator would refuse the envelope anyway, so the
        // dispatch is skipped (the staged-upgrade map above is already
        // dropped; the next snapshot page prunes any still-live review and
        // the domain's generation-scoped retirement bounds the rest).
        val discardRevision = destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
            ?.revision
            ?.takeIf { it.isNotEmpty() }
            ?.let { HostRevision("skill.$skillId", it) }
            ?: return
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("supcan"),
                revision = discardRevision,
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.discard"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { }
    }

    /**
     * F-S6. The closed rollback grammar is `{operation, skillId, cursor}`
     * (no token on the wire) and the envelope revision, when present, must
     * be the CURRENT `skill.<id>` digest — the fabricated "rollback" version
     * always failed CAS and is gone. The module's dispatch Long is kept only
     * as the presentation fence in [UpgradeEffectUi].
     */
    override fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.skills.installed
            .firstOrNull { it.skillId == skillId }
        if (row == null || row.revision.isEmpty()) {
            updateDestination { state ->
                val sheet = state.upgrade?.takeIf { it.skillId == skillId }
                    ?: return@updateDestination state
                state.copy(upgrade = sheet.copy(errorMessage = "rowMissing"))
            }
            return false
        }
        host.trackOperation(
            HostCommandRequest(
                command = "skills.install",
                scope = HostScope.ApplicationConfiguration("skills"),
                stateful = true,
                correlationID = client().correlationID("suprb"),
                revision = HostRevision("skill.$skillId", row.revision),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("upgrade.rollback"),
                        "skillId" to JsonPrimitive(skillId),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    updateDestination { state ->
                        state.upgrade?.takeIf { it.skillId == skillId }?.let {
                            state.copy(upgrade = it.copy(
                                lastEffect = UpgradeEffectUi(
                                    effectToken, UpgradeOutcomeUi.ROLLED_BACK),
                            ))
                        } ?: state
                    }
                    refreshSkills()
                }
                is HostOperationOutcome.Rejected -> {
                    updateDestination { state ->
                        state.upgrade?.takeIf { it.skillId == skillId }?.let {
                            state.copy(upgrade = it.copy(
                                errorMessage = outcome.code,
                                lastEffect = UpgradeEffectUi(
                                    effectToken, UpgradeOutcomeUi.FAILED),
                            ))
                        } ?: state
                    }
                    refreshSkills()
                }
                is HostOperationOutcome.Failed -> {
                    updateDestination { state ->
                        state.upgrade?.takeIf { it.skillId == skillId }?.let {
                            state.copy(upgrade = it.copy(
                                errorMessage = outcome.code,
                                lastEffect = UpgradeEffectUi(
                                    effectToken, UpgradeOutcomeUi.FAILED),
                            ))
                        } ?: state
                    }
                    refreshSkills()
                }
                else -> Unit
            }
        }
        return true
    }

    override fun openConnectorDestination(destinationId: String): Boolean {
        // Connector destinations are presentation routes inside the
        // integrations surface; the holder owns the pane stack.
        return admitted()
    }

    /**
     * The single explicit local-network action (Android 17 / API 37): the
     * user taps the guidance the HOST projected from a REAL probe read —
     * REQUEST opens the platform dialog (chained only to the captured
     * blocked hop, never an automatic replay), RECOVERY opens this app's
     * system settings page. Nothing is dispatched when the dialog result
     * is denied, and the current state is always RE-READ from the platform
     * after any return (a revocation in settings is discovered honestly on
     * the next action/check, never assumed from a cached flag).
     */
    override fun localNetworkGuidanceAction(): Boolean {
        if (!admitted()) return false
        return localNetwork.performGuidanceAction(
            blockedDispatch = { serverId ->
                destinationState.value.mcp.servers
                    .firstOrNull { it.serverId == serverId }
                    ?.let { dispatchMcpConnect(it) }
            },
        )
    }

    // ------------------------------------------------------------------- MCP

    override fun seedMcpEditor(serverId: String?): McpEditorSeedUi? {
        if (!admitted()) return null
        localNetwork.refreshCheck()
        val row = serverId?.let { id ->
            destinationState.value.mcp.servers.firstOrNull { it.serverId == id }
        }
        // S9 "all original saved config fields": every editable field seeds
        // from the REAL decoded row (header name, timeout, insecure-HTTP
        // flag), never from an invented default that a later save would
        // silently write over the saved configuration.
        return McpEditorSeedUi(
            serverId = serverId,
            displayName = row?.displayName ?: "",
            endpointText = row?.endpointDisplay ?: "",
            enabled = row?.enabled ?: true,
            allowInCanvas = row?.allowInCanvas ?: false,
            allowInsecureHttp = row?.allowInsecureHttp ?: false,
            authentication = row?.authentication ?: McpAuthenticationUi.NONE,
            credentialHeaderName = row?.credentialHeaderName
                ?.takeIf { it.isNotEmpty() } ?: "Authorization",
            credentialStored = row?.credentialStored ?: false,
            timeoutSeconds = row?.timeoutSeconds ?: 30,
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
            authority().open(HostEditorKind.MCP, identity.editorId,
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
        editorRouteTokens.remove(identity.editorId)?.let(authority()::clear)
    }

    override fun saveMcpServer(request: McpSaveRequest): Boolean {
        if (!admitted()) return false
        publishEditor(request.identity) { it.copy(saveInFlight = true, saveError = null) }
        val serverID = serverIDForSave(request)
        // F-S3: the create hop is the CANDIDATE's own closed `createIntent`
        // key that the Core create gate reads — in BOTH the direct keep/clear
        // candidate and the frozen Set-lease intent candidate. The envelope
        // create flag alone never reached the save domain path.
        val create = request.baseRevision == null
        val candidate = IntegrationsWire.mcpCandidateJson(request, serverID, create)
        // F-S1/S2: the envelope CAS pair is the REAL row identity (resourceID
        // `mcp.<uuid>` + opaque digest). A new identity carries NO envelope
        // revision (createIntent is the frozen creation path).
        val revision = request.baseRevision?.let {
            HostRevision(it.resourceID, it.version)
        }
        val payload: JsonObject
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
            }
            CredentialDraftIntent.KEEP_EXISTING -> {
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("save"),
                        "secretIntent" to JsonPrimitive("keep"),
                        "candidate" to candidate,
                    ),
                )
            }
            CredentialDraftIntent.CLEAR -> {
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("save"),
                        "secretIntent" to JsonPrimitive("clear"),
                        "candidate" to candidate,
                    ),
                )
            }
            CredentialDraftIntent.MISSING -> {
                onMcpSaveFailed(request.identity, "credential_required")
                return true
            }
        }
        // The LAN-permission broker is consulted for the CONNECT hop only:
        // a metadata save of a localLikely server on API>=37 without the
        // permission still SAVES (typed "committed" comes back honestly) —
        // the permission guidance is reported separately below from the
        // connect sub-result, never conflated with the save outcome or with
        // an authentication failure.
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
                is HostOperationOutcome.Completed ->
                    onMcpSaveTerminal(request, serverID, outcome.value)
                is HostOperationOutcome.Rejected -> onMcpSaveFailed(request.identity, outcome.code)
                is HostOperationOutcome.Failed -> onMcpSaveFailed(request.identity, outcome.code)
                HostOperationOutcome.Cancelled -> onMcpSaveFailed(request.identity, "cancelled")
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    /**
     * Save terminal → structured outcome. F-S1/S2 + the finalized same-frame
     * failure contract stay intact: the SUCCESS revision is the COMMIT
     * reply's real digest; the deferred-settlement reply reports honestly
     * with a null new revision (never a coerced old/zero value); the
     * connect sub-result failure only feeds the separate local-network/
     * connection guidance surface, never the save outcome.
     */
    private fun onMcpSaveTerminal(
        request: McpSaveRequest,
        serverID: String,
        value: JsonElement?,
    ) {
        val reply = value as? JsonObject
        val committed = reply?.string("state") == "committed"
        val pendingSettlement =
            (reply?.get("pendingPhysicalSettlement") as? JsonPrimitive)?.booleanOrNull == true
        if (!committed) {
            // A completed-but-unrecognised page is a decode failure, not a
            // success; the existing failure sequencing stays authoritative.
            onMcpSaveFailed(request.identity, "decode_failed")
            return
        }
        val newRevision = (reply["revision"] as? JsonObject)?.string("version")
        publishEditor(request.identity) {
            it.copy(
                saveInFlight = false,
                saveError = null,
                saveOutcome = McpSaveOutcomeUi.Succeeded(
                    newServerId = reply.string("serverID") ?: serverID,
                    newRevision = if (pendingSettlement) null else newRevision,
                ),
                saveFailureSequence = mcpSaveFailureSequencer.current(
                    request.identity.editorId, request.identity.epoch),
            )
        }
        // Connect hop honesty (reported SEPARATELY from the metadata save):
        val connect = reply["connect"] as? JsonObject
        if (connect != null && connect.containsKey("errorCode")) {
            val reason = connect.string("reason") ?: "connect_failed"
            if (localNetwork.isLocalLikely(request.draft.endpointText) &&
                localNetwork.permissionBlockingHint(reason)
            ) {
                localNetwork.noteBlockedConnect(serverID, request.draft.endpointText)
            }
        }
        flowHolder.finalizeSavedEditor(request.identity)
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
                revision = HostRevision(row.revision.resourceID, row.revision.version),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("remove"),
                        "serverId" to JsonPrimitive(serverId),
                    ),
                ),
            ),
        ) { outcome ->
            // S10: typed settled outcomes, never a silent dismissal.
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val state = (outcome.value as? JsonObject)?.string("state")
                    if (state != null && state != "removed") {
                        updateDestination {
                            it.copy(mcp = it.mcp.copy(errorMessage = "remove_$state"))
                        }
                    }
                }
                is HostOperationOutcome.Rejected -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                is HostOperationOutcome.Failed -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                else -> Unit
            }
            refreshMcpServers()
        }
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
                revision = HostRevision(row.revision.resourceID, row.revision.version),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("enabled.set"),
                        "serverId" to JsonPrimitive(serverId),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Rejected -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                is HostOperationOutcome.Failed -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                is HostOperationOutcome.Completed -> {
                    // Enabling dispatches the REAL refresh domain-side; the
                    // row's new Connecting generation only ever arrives via
                    // the list reply. A connect sub-failure inside an
                    // otherwise-successful toggle is guidance surface only,
                    // never a toggle failure.
                    val connect = (outcome.value as? JsonObject)?.get("connect") as? JsonObject
                    if (enabled && connect != null && connect.containsKey("errorCode") &&
                        localNetwork.isLocalLikely(row.endpointDisplay) &&
                        localNetwork.permissionBlockingHint(
                            connect.string("reason") ?: "connect_failed")
                    ) {
                        localNetwork.noteBlockedConnect(row.serverId, row.endpointDisplay)
                    }
                }
                else -> Unit
            }
            refreshMcpServers()
        }
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
                revision = HostRevision(row.revision.resourceID, row.revision.version),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("tool.enabled.set"),
                        "serverId" to JsonPrimitive(serverId),
                        "remoteName" to JsonPrimitive(remoteName),
                        "enabled" to JsonPrimitive(enabled),
                    ),
                ),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Rejected ||
                outcome is HostOperationOutcome.Failed
            ) {
                val code = when (outcome) {
                    is HostOperationOutcome.Rejected -> outcome.code
                    else -> (outcome as HostOperationOutcome.Failed).code
                }
                updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = code))
                }
            }
            refreshMcpServers()
        }
        return true
    }

    /**
     * Explicit connect/refresh hop. LAN-permission integration point: on
     * API>=37 a user-initiated refresh of a LOCAL endpoint that lacks the
     * ACCESS_LOCAL_NETWORK grant routes through the broker's system dialog
     * FIRST (this same explicit tap owns the chained dispatch — no automatic
     * replay later); public cloud endpoints never pass through it, and the
     * permission state never substitutes an auth check.
     */
    override fun refreshMcpServer(serverId: String): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        if (localNetwork.blocksConnectHop(row.endpointDisplay)) {
            val started = localNetwork.requestForAction(
                serverId = serverId,
                endpoint = row.endpointDisplay,
                dispatch = { dispatchMcpConnect(row) },
            )
            return started
        }
        dispatchMcpConnect(row)
        return true
    }

    private fun dispatchMcpConnect(row: McpServerRowUi) {
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.connect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcprfr"),
                revision = HostRevision(row.revision.resourceID, row.revision.version),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("connect"),
                        "serverId" to JsonPrimitive(row.serverId),
                    ),
                ),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Rejected ||
                outcome is HostOperationOutcome.Failed
            ) {
                val code = when (outcome) {
                    is HostOperationOutcome.Rejected -> outcome.code
                    else -> (outcome as HostOperationOutcome.Failed).code
                }
                // Honest LAN-refusal attribution stays DISTINCT from auth:
                // "unreachable" family + local endpoint + no grant means the
                // permission action, never "bad credentials".
                if (localNetwork.isLocalLikely(row.endpointDisplay) &&
                    localNetwork.permissionBlockingHint(code)
                ) {
                    localNetwork.noteBlockedConnect(row.serverId, row.endpointDisplay)
                }
                updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = code))
                }
            }
            refreshMcpServers()
        }
    }

    /**
     * F-S10. cancel.refresh rides the frozen mcp.disconnect rule (local
     * validator REQUIRES a revision unless createIntent) — the row's REAL
     * digest pair is the honest structural value (the domain itself fences
     * by exact generation, never by this pair). The typed settled outcome
     * (`cancelling` | `noop[generationNotLive|workerAlreadySettling]`) is
     * surfaced: a noop immediately re-reads so the row's newer terminal
     * clears the holder latch honestly; nothing is dismissed silently and
     * no fabricated receipt is ever shown.
     */
    override fun cancelMcpRefresh(serverId: String, generation: Long): Boolean {
        if (!admitted()) return false
        val row = destinationState.value.mcp.servers.firstOrNull { it.serverId == serverId }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "mcp.disconnect",
                scope = HostScope.ApplicationConfiguration("mcp"),
                stateful = true,
                correlationID = client().correlationID("mcprfc"),
                revision = HostRevision(row.revision.resourceID, row.revision.version),
                payload = JsonObject(
                    mapOf(
                        "operation" to JsonPrimitive("cancel.refresh"),
                        "serverId" to JsonPrimitive(serverId),
                        "generation" to JsonPrimitive(generation.toString()),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val state = (outcome.value as? JsonObject)?.string("state")
                    if (state == "noop") {
                        // Superseded generation: the newer terminal owns
                        // the row now — re-read promptly so the UI's
                        // "Cancelling…" latch reflects the real state.
                        refreshMcpServers()
                    }
                }
                is HostOperationOutcome.Rejected -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                is HostOperationOutcome.Failed -> updateDestination {
                    it.copy(mcp = it.mcp.copy(errorMessage = outcome.code))
                }
                else -> Unit
            }
        }
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
        // A UUID-shaped editor id ("<serverId>-<n>" opens keep the raw
        // server UUID ONLY via request.serverId; module editor ids like
        // "new-3" are NOT UUIDs — fromString throws, never returns null.
        val existing = runCatching { UUID.fromString(request.identity.editorId) }
            .getOrNull()?.toString()
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
        baseRevision: McpServerRevisionUi?,
    ): String? {
        val secret = request.credentialDraft ?: return null
        // This editor incarnation's own handle. Never re-minted here: a late
        // save from an old editor must fail closed instead of creating a
        // newer incarnation that could evict a newer editor's route.
        val route = editorRouteTokens[request.identity.editorId]
            ?.takeIf(::isOpaqueHostRouteToken) ?: return null
        // F-S1/S2/S3: the lease baseRevision pair is the REAL one. Editing
        // an existing row freezes its actual resource+digest (a changed row
        // at commit is a typed staleRevision, never a blind overwrite); a
        // NEW identity freezes the resource derived from the minted UUID
        // with the frozen "0" absent-row marker the domain itself defines.
        val revision = if (baseRevision != null) {
            JsonObject(
                mapOf(
                    "resourceID" to JsonPrimitive(baseRevision.resourceID),
                    "version" to JsonPrimitive(baseRevision.version),
                ),
            )
        } else {
            JsonObject(
                mapOf(
                    "resourceID" to JsonPrimitive("mcp." + serverID.uppercase()),
                    "version" to JsonPrimitive("0"),
                ),
            )
        }
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

/**
 * MAIN_ANDROID37_LAN_PERMISSION_DECISION_20261021 — the shared local-
 * network permission broker.
 *
 * Android 17 (API 37) makes ACCESS_LOCAL_NETWORK a real runtime
 * requirement for reaching devices on the local network, and FloeAndroid
 * is target/compile 37. This broker owns the ONLY honest read path for
 * that state and the ONLY presentation request:
 *
 *  * API < 37 → [PermissionState.NotRequired]: ordinary INTERNET behavior
 *    is byte-for-byte unchanged; nothing is ever asked and nothing is
 *    gated.
 *  * The CURRENT state comes ONLY from a real platform probe
 *    ([permissionProbe]) re-read at every decision — never from a cached
 *    "granted" flag, and a failed probe is [PermissionState.Unknown]
 *    (dispatch proceeds and a real native refusal then surfaces the
 *    guidance; a probe error is never treated as a grant or as a denial).
 *  * The dialog opens ONLY from an EXPLICIT user action on a LOCAL
 *    endpoint (a row's Refresh/connect/save-and-connect hop, or the
 *    guidance row the host projected after a real typed refusal). No
 *    startup request, no broad WiFi/location/all-files/phone-control
 *    association — the LAN permission is a network-privacy permission.
 *  * PUBLIC cloud never passes through this broker and never depends on
 *    it. A denied LAN permission is reported with its OWN typed code
 *    (`local_network_permission_denied`), structurally distinct from
 *    every credential/auth failure — auth/TLS/no-redirect/SSRF policy in
 *    the native client stays untouched.
 *  * The permission RESULT is fenced to the captured request incarnation
 *    (a late callback never reads a replacement request and never acts on
 *    a superseded hop), and the chained dispatch is the SAME user tap's
 *    captured connect hop — never an automatic replay of an unknown or
 *    older mutation.
 *  * Revocation/recovery: the current state is re-read on every action;
 *    when the platform says the request can no longer be shown, the
 *    guidance flips to RECOVERY and the explicit tap opens this app's
 *    system-settings page (real intent, host-owned).
 *
 * The broker is Application-owned in effect (it lives on the host's
 * integrations controller, retained by the Application) so future
 * provider/Home local producers can share THIS seam rather than mint a
 * second permission store; nothing here adds a business DB or a
 * model-callable command.
 */
internal class LocalNetworkAccessBroker(
    private val host: RuntimeHost,
    private val onGuidance: (
        com.floe.android.feature.integrations.LocalNetworkGuidanceUi?,
    ) -> Unit,
    private val onDeniedTyped: (String) -> Unit,
) {
    companion object {
        const val PERMISSION_NAME = "android.permission.ACCESS_LOCAL_NETWORK"
        /** Android 17 API level; local proof:
         *  android-37.0 platform, Manifest.permission.ACCESS_LOCAL_NETWORK
         *  present in the installed SDK's android.jar. */
        const val API_LEVEL_LOCAL_NETWORK = 37
        /** The host's own typed marker family for the LAN permission. It
         *  is NEVER one of the credential/auth codes. */
        const val CODE_DENIED = "local_network_permission_denied"
        const val CODE_RECOVERY = "local_network_needs_settings"
    }

    sealed interface PermissionState {
        data object NotRequired : PermissionState
        data object Granted : PermissionState
        data object Denied : PermissionState
        /** The user checked "don't ask again" / the dialog can no longer
         *  be shown: only the settings page can restore the grant. */
        data object DeniedForever : PermissionState
        /** Probe unavailable or failed — never silently a grant, never a
         *  denial: dispatches proceed and only a REAL native refusal
         *  surfaces guidance. */
        data object Unknown : PermissionState
    }

    /** One captured dialog launch. The composition effect echoes THIS
     *  exact object back; a newer request never lets an older result act,
     *  and none is ever read blindly. */
    data class PendingRequest(
        val incarnation: Long,
        val serverId: String?,
        val capturedEndpoint: String,
        val dispatch: () -> Unit,
        val denied: ((String) -> Unit)? = null,
    )

    /** Test seam: the REAL platform read. `Context.checkSelfPermission` is
     *  the current authoritative state (a settings revocation shows up on
     *  the very next read). Any throw/absent context is [PermissionState.
     *  Unknown] — never a fabricated grant or denial. */
    internal var permissionProbe: () -> Int = {
        host.appContext.checkSelfPermission(PERMISSION_NAME)
    }
    internal var apiLevel: () -> Int = { android.os.Build.VERSION.SDK_INT }
    internal var settingsLauncher: () -> Boolean = {
        try {
            val intent = android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", host.appContext.packageName, null),
            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            host.appContext.startActivity(intent)
            true
        } catch (t: RuntimeException) {
            false
        }
    }

    @Volatile
    var state: PermissionState = PermissionState.Unknown
        internal set

    private val requestIncarnation = java.util.concurrent.atomic.AtomicLong(0)

    /** Opaque per-host-generation launch namespace for the composition
     *  permission-dialog lane (MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_
     *  20261021): the glue persists `namespace:incarnation` for the ONE
     *  platform dialog it launched and only dispatches a callback whose
     *  saved namespace still matches THIS generation, so a counter reset
     *  after process death can never bind a restored pre-death result to a
     *  new request. Carries no endpoint, credential or permission state. */
    internal val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

    private val permissionRequestFlow =
        kotlinx.coroutines.flow.MutableStateFlow<PendingRequest?>(null)
    val permissionRequest: kotlinx.coroutines.flow.StateFlow<PendingRequest?> =
        permissionRequestFlow

    /** The last blocked local hop the guidance refers to; a RECOVERY tap
     *  or a granted dialog chains ONLY this captured hop. */
    private var guidanceServerId: String? = null
    private var guidanceEndpoint: String? = null

    /** Current, cheap and platform-honest; never called on a composition
     *  fast path — only from user actions and the controller's refresh. */
    fun refreshCheck() {
        val level = runCatching { apiLevel() }.getOrDefault(0)
        if (level < API_LEVEL_LOCAL_NETWORK) {
            state = PermissionState.NotRequired
            clearGuidanceIfResolvable()
            return
        }
        val previouslyDeniedForever = state == PermissionState.DeniedForever
        state = runCatching { permissionProbe() }
            .getOrNull()?.let { granted ->
                if (granted == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    PermissionState.Granted
                } else {
                    // A present-but-denied state: whether a dialog can
                    // still be shown is decided by the platform result
                    // (rationale), not guessed here. Until a real result
                    // arrives the guidance offers REQUEST.
                    if (previouslyDeniedForever) PermissionState.DeniedForever
                    else PermissionState.Denied
                }
            } ?: PermissionState.Unknown
        if (state == PermissionState.Granted) {
            clearGuidanceIfResolvable()
        }
    }

    private fun clearGuidanceIfResolvable() {
        if (state == PermissionState.Granted ||
            state == PermissionState.NotRequired
        ) {
            guidanceServerId = null
            guidanceEndpoint = null
            onGuidance(null)
        }
    }

    /** Pure projection helper (also used by tests): is this endpoint
     *  plausibly a LOCAL network target? UX heuristic ONLY: it decides
     *  when the explicit permission action is offered BEFORE a hop, never
     *  whether a hop may run, and it never blocks public cloud. An
     *  unparseable endpoint is NOT local. */
    fun isLocalLikely(endpoint: String): Boolean {
        val hostName = runCatching { java.net.URI(endpoint.trim()).host }
            .getOrNull()?.lowercase()?.removePrefix("[")?.removeSuffix("]")
            ?.removeSuffix(".") ?: return false
        if (hostName.isEmpty()) return false
        if (hostName == "localhost" || hostName.endsWith(".localhost")) return true
        if (hostName.endsWith(".local") || hostName.endsWith(".internal")) return true
        // Single-label hostname (no dot): mDNS/NetBIOS-style local name.
        if (!hostName.contains('.') && !hostName.contains(':')) return true
        // IPv4 private/link-local literals.
        val ipv4 = Regex("""^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$""")
            .find(hostName)
        if (ipv4 != null) {
            val parts = ipv4.destructured.toList().mapNotNull { it.toIntOrNull() }
            if (parts.size == 4 && parts.all { it in 0..255 }) {
                val a = parts[0]; val b = parts[1]
                return a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) ||
                    a == 169 && b == 254 || a == 127
            }
            return false
        }
        // IPv6 literals (bracketed by URI.host stripping): ULA fc00::/7 and
        // link-local fe80::/10 and loopback ::1.
        if (hostName.contains(':')) {
            if (hostName == "::1") return true
            if (hostName.startsWith("fc") || hostName.startsWith("fd")) return true
            if (hostName.startsWith("fe80")) return true
            return false
        }
        return false
    }

    /** True when this hop is a LOCAL candidate that the API 37 runtime
     *  permission plausibly gates. Never called for public endpoints, and
     *  an Unknown probe state never blocks (see [requestForAction]). */
    fun blocksConnectHop(endpoint: String): Boolean {
        if (apiLevel() < API_LEVEL_LOCAL_NETWORK) return false
        if (!isLocalLikely(endpoint)) return false
        return when (state) {
            PermissionState.Granted, PermissionState.NotRequired -> false
            else -> true
        }
    }

    /**
     * The user's explicit connect hop met the local-permission surface.
     * Returns true when a dispatch was started (direct, or chained behind
     * the dialog the composition now shows for the CAPTURED request);
     * false means nothing ran (DeniedForever → the guidance row owns the
     * recovery), never a silent failure.
     */
    fun requestForAction(
        serverId: String,
        endpoint: String,
        dispatch: () -> Unit,
        onDenied: ((String) -> Unit)? = null,
    ): Boolean {
        // Read the CURRENT platform state at the action boundary.
        refreshCheck()
        return when (state) {
            PermissionState.Granted, PermissionState.NotRequired -> {
                dispatch(); true
            }
            // Unknown: a probe failure is not a denial — dispatch; a real
            // native refusal then surfaces the guidance honestly.
            PermissionState.Unknown -> {
                dispatch(); true
            }
            PermissionState.Denied -> {
                val captured = PendingRequest(
                    incarnation = requestIncarnation.incrementAndGet(),
                    serverId = serverId,
                    capturedEndpoint = endpoint,
                    dispatch = dispatch,
                    denied = onDenied,
                )
                permissionRequestFlow.value = captured
                true
            }
            PermissionState.DeniedForever -> {
                if (onDenied != null) {
                    onDenied(CODE_RECOVERY)
                    // This is an explicit new user action; returning from
                    // Settings never replays the old request automatically.
                    settingsLauncher()
                    return false
                }
                guidanceServerId = serverId
                guidanceEndpoint = endpoint
                onGuidance(
                    com.floe.android.feature.integrations.LocalNetworkGuidanceUi(
                        kind = com.floe.android.feature.integrations
                            .LocalNetworkGuidanceKindUi.RECOVERY,
                        serverLabel = endpoint,
                    ),
                )
                false
            }
        }
    }

    /** Shared by explicit provider tests and composer launches. The caller
     * owns its request identity; permission UI can never revive a cancelled
     * or navigated-away action. Public endpoints do not request permission. */
    fun runExplicitAction(
        ownerID: String,
        endpoint: String,
        isCurrent: () -> Boolean,
        onDenied: (String) -> Unit,
        dispatch: () -> Unit,
    ): Boolean {
        if (!isCurrent()) return false
        refreshCheck()
        if (!isLocalLikely(endpoint) || state == PermissionState.NotRequired ||
            state == PermissionState.Granted || state == PermissionState.Unknown
        ) {
            if (isCurrent()) dispatch()
            return true
        }
        return requestForAction(
            serverId = ownerID,
            endpoint = endpoint,
            dispatch = { if (isCurrent()) dispatch() },
            onDenied = { code -> if (isCurrent()) onDenied(code) },
        )
    }

    /** Typed failure attribution from a native refusal code/reason:
     *  UNREACHABILITY-family markers are LAN-plausible; credential/auth
     *  codes never are — mislabeling a permission gap as bad credentials
     *  (or vice versa) is exactly the confusion this decision forbids. */
    fun permissionBlockingHint(reason: String): Boolean {
        val r = reason.lowercase()
        if (r.contains("credential") || r.contains("auth") || r.contains("secret") ||
            r.contains("token") || r.contains("unauthorized") || r.contains("forbidden")
        ) {
            return false
        }
        return r.contains("unreachable") || r.contains("eperm") ||
            r.contains("operation not permitted") || r.contains("permission") ||
            r.contains("network is unreachable") || r.contains("denied")
    }

    /** A real typed refusal landed on a local hop: project the explicit
     *  guidance row (REQUEST while the dialog is still available,
     *  RECOVERY once it is not) bound to this captured endpoint. */
    fun noteBlockedConnect(serverId: String, endpoint: String) {
        guidanceServerId = serverId
        guidanceEndpoint = endpoint
        val kind = if (state == PermissionState.DeniedForever) {
            com.floe.android.feature.integrations.LocalNetworkGuidanceKindUi.RECOVERY
        } else {
            com.floe.android.feature.integrations.LocalNetworkGuidanceKindUi.REQUEST
        }
        onGuidance(
            com.floe.android.feature.integrations.LocalNetworkGuidanceUi(
                kind = kind,
                serverLabel = endpoint,
            ),
        )
    }

    /**
     * The guidance row's explicit tap. RECOVERY opens the settings page;
     * REQUEST re-reads the state and (still denied) opens the dialog
     * chained to the guidance's captured hop.
     */
    fun performGuidanceAction(blockedDispatch: (String) -> Unit): Boolean {
        refreshCheck()
        if (guidanceEndpoint == null && guidanceServerId == null) return false
        return when (state) {
            PermissionState.Granted, PermissionState.NotRequired -> {
                clearGuidanceIfResolvable()
                false
            }
            PermissionState.DeniedForever -> settingsLauncher()
            PermissionState.Unknown -> {
                // Guidance exists because a REAL refusal landed; retry the
                // captured hop directly — the platform answers honestly.
                guidanceServerId?.let(blockedDispatch)
                true
            }
            PermissionState.Denied -> {
                val server = guidanceServerId ?: return false
                val endpoint = guidanceEndpoint ?: ""
                val captured = PendingRequest(
                    incarnation = requestIncarnation.incrementAndGet(),
                    serverId = server,
                    capturedEndpoint = endpoint,
                    dispatch = { blockedDispatch(server) },
                )
                permissionRequestFlow.value = captured
                true
            }
        }
    }

    /** The composition effect echoes the platform result for the EXACT
     *  captured request; a replaced/absent request drops the late result
     *  without any state write. */
    fun onPermissionResult(captured: PendingRequest, granted: Boolean, rationale: Boolean) {
        if (permissionRequestFlow.value?.incarnation != captured.incarnation) return
        permissionRequestFlow.value = null
        // Authoritative: re-read the platform, never trust the boolean
        // alone as a "granted flag".
        refreshCheck()
        if (state == PermissionState.Granted) {
            clearGuidanceIfResolvable()
            // The SAME user tap owns the chained hop (captured at the
            // tap, never an automatic replay of an older mutation).
            captured.dispatch()
            return
        }
        if (!granted && !rationale) {
            state = PermissionState.DeniedForever
        }
        val code = if (state == PermissionState.DeniedForever) CODE_RECOVERY else CODE_DENIED
        (captured.denied ?: onDeniedTyped)(code)
        if (captured.denied == null) {
            noteBlockedConnect(captured.serverId ?: "", captured.capturedEndpoint)
        }
    }

    fun invalidate() {
        permissionRequestFlow.value = null
        guidanceServerId = null
        guidanceEndpoint = null
    }
}

/** Strict-tolerant wire decoders for the Skills/MCP owner pages. */
internal object IntegrationsWire {

    /** One live staged review echoed by `skills.list` snapshot rows:
     *  `reviewToken`, `skillID`, `kind` and the REAL echoed revision pair
     *  (`revision.version` = the honest CAS value the confirm/discard
     *  commands must carry — never a fabricated or coerced one). */
    class PendingReviewRow(
        val reviewToken: String,
        val skillID: String,
        val kind: String,
        val revision: String,
    )

    /** One signed-catalog package from `catalogProjection()`. */
    class CatalogEntry(
        val id: String,
        val version: String,
        val releaseNotes: Map<String, String>,
    )

    class SkillsSnapshotPage(
        val installed: List<SkillInstalledRowUi>,
        val catalogEntries: List<CatalogEntry>,
        val catalogState: String,
        val catalogLastFailure: String?,
        val pendingReviewRows: List<PendingReviewRow>,
        val autoScriptedUpdates: Boolean,
        val settingsRevision: String?,
        val hasMore: Boolean,
        val nextCursor: String?,
    )

    fun decodeSkillsSnapshot(value: JsonElement): SkillsSnapshotPage? {
        val root = value as? JsonObject ?: return null
        val installed = (root["skills"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            // The REAL revision pair: revision.version is the persisted
            // row's rewrittenDigest. A row without the digest cannot ride
            // CAS and is skipped honestly (never zero/default-filled).
            val revision = (obj["revision"] as? JsonObject)?.string("version")
                ?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            SkillInstalledRowUi(
                skillId = id,
                name = obj.string("name") ?: id,
                version = obj.string("version") ?: "",
                summary = obj.string("description"),
                enabled = obj.bool("enabled") ?: true,
                revision = revision,
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
                // F-S8: the row truth is the closed `official` flag the
                // snapshot emits; the old non-existent `source` string is
                // gone. Folder/creator/GitHub distinctions beyond hub
                // membership are not projected by the original row, so a
                // non-official row is reported through its own installed
                // identity only (CREATOR is the honest fallback class).
                sourceKind = if (obj.bool("official") == true) {
                    SkillSourceKindUi.OFFICIAL_HUB
                } else {
                    SkillSourceKindUi.CREATOR
                },
                isBundledReadOnlyGuide = obj.bool("bundledSeedSuppressed") == true,
                rollbackAvailable = obj.bool("rollbackAvailable") == true,
                installStage = null,
            )
        } ?: return null
        val catalog = root["catalog"] as? JsonObject
        val catalogState = catalog?.string("state") ?: "unavailable"
        val entries = (catalog?.get("packages") as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            CatalogEntry(
                id = id,
                version = obj.string("version") ?: "",
                releaseNotes = (obj["releaseNotes"] as? JsonObject)
                    ?.mapNotNull { (key, note) ->
                        val text = (note as? JsonPrimitive)?.contentOrNull
                        if (text == null) null else key to text
                    }?.toMap() ?: emptyMap(),
            )
        } ?: emptyList()
        val pending = (root["pendingReviews"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val token = obj.string("reviewToken") ?: return@mapNotNull null
            val skillID = obj.string("skillID") ?: return@mapNotNull null
            PendingReviewRow(
                reviewToken = token,
                skillID = skillID,
                kind = obj.string("kind") ?: "install",
                revision = (obj["revision"] as? JsonObject)?.string("version") ?: "",
            )
        } ?: emptyList()
        val settings = root["settings"] as? JsonObject
        val settingsRevision = (settings?.get("revision") as? JsonObject)
            ?.string("version")?.takeIf { it.isNotEmpty() }
        val nextCursor = (root["nextCursor"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.contentOrNull
        return SkillsSnapshotPage(
            installed = installed,
            catalogEntries = entries,
            catalogState = catalogState,
            catalogLastFailure = (catalog?.get("lastFailure") as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull,
            pendingReviewRows = pending,
            autoScriptedUpdates = settings?.bool("autoScriptedUpdates") ?: false,
            settingsRevision = settingsRevision,
            hasMore = root.bool("hasMore") ?: false,
            nextCursor = nextCursor,
        )
    }

    /** ⇄ SkillsReviewProjection.jsonObject(): the CLOSED real keys
     *  (`reviewToken` may be null on a committed reply, `skillID`,
     *  `version`, `committed`, `changedFiles`, `addedCapabilities`,
     *  `addedTools`, `releaseNotes`). The old invented
     *  `sourceDisplay`/`skillName`/`revision` keys are gone; a row-level
     *  display name for a staged review is the skill id (the projection
     *  genuinely carries no more), and the CAS revision comes from the
     *  snapshot `pendingReviews` echo, never decoded from a reply that
     *  has none. */
    class Review(
        val reviewToken: String,
        val skillID: String,
        val version: String,
        val requestedCapabilities: List<String>,
        val tools: List<String>,
        val scriptPaths: List<String>,
        val releaseNotesLocalized: String?,
    )

    fun decodeReview(value: JsonElement): Review? {
        val root = value as? JsonObject ?: return null
        if (root.bool("committed") == true) return null
        val token = root.string("reviewToken") ?: return null
        val skillID = root.string("skillID") ?: return null
        val notes = (root["releaseNotes"] as? JsonObject)
        val locale = runCatching { java.util.Locale.getDefault().language }
            .getOrDefault("en")
        val localized = notes?.entries?.firstOrNull { it.key == locale }?.value
            ?: notes?.entries?.firstOrNull()?.value
        return Review(
            reviewToken = token,
            skillID = skillID,
            version = root.string("version") ?: "",
            requestedCapabilities = (root["addedCapabilities"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            tools = (root["addedTools"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            scriptPaths = (root["changedFiles"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            releaseNotesLocalized = (localized as? JsonPrimitive)?.contentOrNull,
        )
    }

    class McpServersPage(
        val servers: List<McpServerRowUi>,
        val hasMore: Boolean,
        val nextCursor: String?,
        val decodeSkippedRows: Int,
    )

    /**
     * F-S1/F-S2. Decodes the ACTUAL `list()` rows: `id`, `credential.state`
     * and `revision.version` (the opaque config digest) drive everything
     * stateful; `connection.generation` arrives as a STRING (the domain's
     * canonical generation spelling), never coerced through `long()`. A row
     * missing the revision pair is skipped (it cannot carry CAS) and the
     * skip count is honestly reported.
     */
    fun decodeMcpServersPage(value: JsonElement): McpServersPage? {
        val root = value as? JsonObject ?: return null
        var skipped = 0
        val servers = (root["servers"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: run { skipped += 1; return@mapNotNull null }
            val id = obj.string("id") ?: run { skipped += 1; return@mapNotNull null }
            val revisionObj = obj["revision"] as? JsonObject
            val resourceID = revisionObj?.string("resourceID")
            val version = revisionObj?.string("version")
            if (resourceID.isNullOrEmpty() || version.isNullOrEmpty()) {
                skipped += 1
                return@mapNotNull null
            }
            val auth = when (obj.string("authentication")) {
                "bearerToken" -> McpAuthenticationUi.BEARER_TOKEN
                "customHeader" -> McpAuthenticationUi.CUSTOM_HEADER
                else -> McpAuthenticationUi.NONE
            }
            val connectionObj = obj["connection"] as? JsonObject
            val state = when (connectionObj?.string("state")) {
                "connecting" -> McpConnectionStateUi.Connecting(
                    connectionObj.string("generation")?.toLongOrNull() ?: 0L)
                "ready" -> McpConnectionStateUi.Ready(
                    connectionObj.long("toolCount")?.toInt() ?: 0)
                "failed" -> McpConnectionStateUi.Failed(
                    connectionObj.string("reason") ?: "failed")
                else -> McpConnectionStateUi.Inactive
            }
            val credential = obj["credential"] as? JsonObject
            val tools = (obj["tools"] as? JsonArray)?.mapNotNull { tool ->
                val toolObj = tool as? JsonObject ?: return@mapNotNull null
                McpToolRowUi(
                    remoteName = toolObj.string("remoteName") ?: return@mapNotNull null,
                    displayName = toolObj.string("displayName"),
                    toolDescription = toolObj.string("description") ?: "",
                    enabled = toolObj.bool("enabled") ?: true,
                    readOnlyHint = toolObj.bool("readOnlyHint") ?: false,
                    destructiveHint = toolObj.bool("destructiveHint") ?: false,
                )
            }
            McpServerRowUi(
                serverId = id,
                displayName = obj.string("displayName") ?: id,
                endpointDisplay = obj.string("endpoint") ?: "",
                enabled = obj.bool("enabled") ?: true,
                allowInCanvas = obj.bool("allowInCanvas") ?: false,
                allowInsecureHttp = obj.bool("allowInsecureHTTP") ?: false,
                authentication = auth,
                credentialHeaderName = obj.string("credentialHeaderName"),
                timeoutSeconds = obj.long("timeoutSeconds")?.toInt(),
                credentialStored = credential?.string("state") == "configured",
                credentialRequired = credential?.bool("required") ?: false,
                state = state,
                tools = tools,
                revision = McpServerRevisionUi(resourceID, version),
                disabledRemoteToolNames = (obj["disabledRemoteToolNames"] as? JsonArray)
                    ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            )
        } ?: return null
        val nextCursor = (root["nextCursor"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.contentOrNull
        return McpServersPage(
            servers = servers,
            hasMore = root.bool("hasMore") ?: false,
            nextCursor = nextCursor,
            decodeSkippedRows = skipped,
        )
    }

    /** ⇄ `capability.tools.list` page (S12). Only structural fields the
     *  domain emits are read; the usable verdict is the domain's
     *  `availability`, never re-derived client-side. */
    class ToolItem(
        val source: String,
        val availability: String,
        val prerequisiteKinds: List<String>,
        val mcpPrefix: String?,
    )

    class ToolSourcesPage(
        val items: List<ToolItem>,
        val hasMore: Boolean,
        val nextCursor: String?,
    )

    fun decodeToolSources(value: JsonElement): ToolSourcesPage? {
        val root = value as? JsonObject ?: return null
        val items = (root["tools"] as? JsonArray)?.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val name = obj.string("name") ?: return@mapNotNull null
            val prefix = if (obj.string("source") == "mcp" && name.startsWith("mcp_")) {
                val tail = name.indexOf('_', startIndex = 4)
                if (tail > 4) name.substring(0, tail) else null
            } else {
                null
            }
            ToolItem(
                source = obj.string("source") ?: "native",
                availability = obj.string("availability") ?: "unknown",
                prerequisiteKinds = (obj["prerequisites"] as? JsonArray)
                    ?.mapNotNull { (it as? JsonObject)?.string("kind") } ?: emptyList(),
                mcpPrefix = prefix,
            )
        } ?: return null
        val nextCursor = (root["nextCursor"] as? JsonPrimitive)
            ?.takeIf { it.isString }?.contentOrNull
        return ToolSourcesPage(
            items = items,
            hasMore = root.bool("hasMore") ?: false,
            nextCursor = nextCursor,
        )
    }

    /** Dot-separated numeric comparison mirroring the ORIGINAL
     *  SkillUpgradeCandidate version ordering (major.minor.patch; non-
     *  numeric tails are compared lexically and are NEVER "newer" than a
     *  numeric equal prefix). Projection helper ONLY: the native gates
     *  remain the install authority. */
    fun isNewerVersion(candidate: String, installed: String): Boolean {
        if (candidate == installed) return false
        val a = candidate.split('.')
        val b = installed.split('.')
        for (index in 0 until maxOf(a.size, b.size)) {
            val left = a.getOrNull(index) ?: "0"
            val right = b.getOrNull(index) ?: "0"
            val ln = left.takeWhile { it.isDigit() }.toIntOrNull() ?: -1
            val rn = right.takeWhile { it.isDigit() }.toIntOrNull() ?: -1
            if (ln != rn) return ln > rn
            if (left != right) return left > right
        }
        return false
    }

    fun creatorDraftJson(draft: SkillCreatorDraftUi): JsonObject = JsonObject(
        mapOf(
            "name" to JsonPrimitive(draft.name),
            "description" to JsonPrimitive(draft.description),
            "instructions" to JsonPrimitive(draft.instructions),
        ),
    )

    /**
     * F-S3 + F-S9. The closed candidate the CORE gate parses
     * (MCPSaveCandidate.allowedKeys): the create hop is the candidate's OWN
     * `createIntent` key (the envelope flag alone never reached the save
     * domain), and the row's per-tool enable set rides
     * `disabledRemoteToolNames` so an edit/save never resets the toggles.
     * Secret values are never part of the candidate (they travel only with
     * the frozen Set lease).
     */
    fun mcpCandidateJson(request: McpSaveRequest, serverID: String, create: Boolean): JsonObject {
        val draft = request.draft
        return JsonObject(
            buildMap {
                put("id", JsonPrimitive(serverID))
                put("displayName", JsonPrimitive(draft.displayName))
                put("endpoint", JsonPrimitive(draft.endpointText))
                put("enabled", JsonPrimitive(draft.enabled))
                put("allowInCanvas", JsonPrimitive(draft.allowInCanvas))
                put("allowInsecureHTTP", JsonPrimitive(draft.allowInsecureHttp))
                put(
                    "authentication",
                    JsonPrimitive(
                        when (draft.authentication) {
                            McpAuthenticationUi.NONE -> "none"
                            McpAuthenticationUi.BEARER_TOKEN -> "bearerToken"
                            McpAuthenticationUi.CUSTOM_HEADER -> "customHeader"
                        },
                    ),
                )
                put("credentialHeaderName", JsonPrimitive(draft.credentialHeaderName))
                put("timeoutSeconds", JsonPrimitive(draft.timeoutSeconds))
                put("createIntent", JsonPrimitive(create))
                put(
                    "disabledRemoteToolNames",
                    JsonArray(draft.disabledRemoteToolNames.sorted().map { JsonPrimitive(it) }),
                )
            },
        )
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull
}
