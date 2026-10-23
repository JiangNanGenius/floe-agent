// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.SupplierChoice
import com.floe.android.feature.providers.ConnectionProbeUi
import com.floe.android.feature.providers.ConnectionTestUi
import com.floe.android.feature.providers.ModelCapabilityUi
import com.floe.android.feature.providers.ModelDraftRowUi
import com.floe.android.feature.providers.ModelSavedMetadataUi
import com.floe.android.feature.providers.OfficialMediaModelUi
import com.floe.android.feature.providers.OfficialSupplierUi
import com.floe.android.feature.providers.OfferConnectionUi
import com.floe.android.feature.providers.ProviderCredentialStateUi
import com.floe.android.feature.providers.ProviderDestinationState
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderEditorIdentity
import com.floe.android.feature.providers.ProviderEditorSeedUi
import com.floe.android.feature.providers.ProviderEditorUiState
import com.floe.android.feature.providers.ProviderFlowHolder
import com.floe.android.feature.providers.ProviderListRowUi
import com.floe.android.feature.providers.ProviderListUiState
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.ProviderUiCallbacks
import com.floe.android.feature.providers.ReasoningEffortUi
import com.floe.android.feature.providers.SaveFailurePhaseUi
import com.floe.android.feature.providers.SaveOutcomeUi
import com.floe.android.feature.providers.SeparateOfferSeedUi
import com.floe.android.feature.providers.ServiceOfferUi
import com.floe.android.feature.providers.SupplierCatalogUiState
import com.floe.android.feature.providers.SupplierPresetUi
import com.floe.android.feature.providers.WireProtocolUi
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * App-host binding for the providers feature component.
 *
 * Implements [ProviderUiCallbacks] exactly and owns the immutable
 * [ProviderDestinationState] projection the settings destination renders.
 * Every callback maps to a canonical native operation through
 * [RuntimeHostCommandClient]; async outcomes are projected only to the
 * matching [ProviderEditorIdentity]/list epoch. Credentials travel through
 * the one-shot gateway save-intent (`int:v1:`) — never JSON, never logs;
 * RAM drafts are consumed once and dropped.
 *
 * Admission: provider configuration is usable once the owned store is ready
 * and the configuration domain handler exists — never gated on a synthetic
 * "AI ready" flag (first-provider rule).
 *
 * Save failures advance a per-identity+epoch monotonic
 * [ProviderEditorUiState.saveFailureSequence] — including two identical
 * failures in the same composition frame; polls, recompositions and
 * connection/discovery failures never advance it.
 */
class ProviderHostController internal constructor(
    private val host: RuntimeHost,
    routeAuthority: HostRouteAuthority = NativeHostRouteAuthority,
) : ProviderUiCallbacks {

    /** Trusted-host route authority (JVM fixtures inject a scripted double). */
    internal var routeAuthority: HostRouteAuthority = routeAuthority

    /**
     * Trusted-host DRAFT probe seam (production = JNI). JVM fixtures bind a
     * scripted double; no fake service is added to production.
     */
    internal var draftProbe: HostDraftProbe = NativeHostDraftProbe

    /** Active draft-probe handle per editor identity (RAM only). */
    private val draftProbeHandles = ConcurrentHashMap<String, String>()
    /** Monotonic attempt id per editor identity (fences late polls). */
    private val draftProbeAttempts = ConcurrentHashMap<String, Long>()
    /** Stable identity for a draft probe of a not-yet-saved editor. */
    private val draftProbeIDs = ConcurrentHashMap<String, String>()
    private val draftProbeSequencer = AtomicLong(0)
    private val permissionActionSequencer = AtomicLong(0)
    private val permissionActions = ConcurrentHashMap<String, Long>()

    /** Caller-retained across configuration changes; RAM only. */
    val flowHolder = ProviderFlowHolder(this)

    private val destinationState = MutableStateFlow(
        ProviderDestinationState(
            list = ProviderListUiState(isLoading = true, conversationProviders = emptyList()),
            catalog = SupplierCatalogUiState(
                builtInPresets = emptyList(),
                officialProviders = emptyList(),
                configuredPresetIds = emptySet(),
                footer = null,
                refreshAvailable = false,
                refreshInFlight = false,
                networkActionsAvailable = false,
            ),
            editor = null,
        ),
    )
    val destination: StateFlow<ProviderDestinationState> = destinationState

    /** Per identity+epoch save-failure sequence (finalized contract). */
    private val saveFailureSequencer = SaveFailureSequencer()

    private val inFlightTests = ConcurrentHashMap<String, String>()
    private val inFlightDiscoveries = ConcurrentHashMap<String, String>()

    /** New-provider editor → the ONE provider UUID minted for its save. */
    private val newProviderIDs = ConcurrentHashMap<String, String>()

    /** editorId → the provider CAS revision OBSERVED when this editor was
     * seeded. A frozen draft must present the token it actually saw, never
     * a later live-cache value: concurrent editors/list refreshes still
     * refuse with the original staleRevision CAS. Bound in [editorOpened]
     * from the seed's own row, released in [editorClosed]/[stop]. */
    private val editorBaselines = ConcurrentHashMap<String, HostRevision>()

    /** providerID|draftModelId → the stable ModelProfile UUID used on save. */
    private val modelProfileIDs = ConcurrentHashMap<String, String>()

    /** presetID → REAL ProviderKind raw from the catalog page only. */
    private val catalogKinds = ConcurrentHashMap<String, String>()

    /** Editor identity → the native-issued `rt:v1:` host route handle. */
    private val editorRouteTokens = ConcurrentHashMap<String, String>()

    /** Test seam for the trusted host ingress; production is the frozen seam. */
    internal var secureIngress: HostSecureIngressSubmitter = NativeHostSecureIngressSubmitter

    /**
     * Trusted-host large-profile MODEL-SET staging (JVM fixtures replace
     * the inner [HostModelSetStager] seam). Production routes through the
     * JNI seam only; nothing here is a public command.
     */
    internal var modelSets = ProviderModelSetStagingController()

    internal fun start() {
        if (!admitted()) return
        // The custom-endpoint preset is a REAL, secret-free host option:
        // first-provider configuration must never depend on the optional
        // provider catalog being injected.
        updateDestination { it.copy(catalog = catalogWithCustom(it.catalog)) }
        refreshProviders()
        refreshCatalog()
        // Row model counts come from the ACTUAL `config.models.list` page the
        // conversation host already reads (one reader, no second catalog).
        if (countObservation == null) {
            countObservation = host.scope.launch(host.ioDispatcher) {
                host.conversations.modelProjectionFlow.collect {
                    republishModelCounts()
                }
            }
        }
    }

    internal fun stop() {
        inFlightTests.clear()
        inFlightDiscoveries.clear()
        // The native route/epoch fence retires any owned draft-probe work on
        // Root retirement; the App-side handles/attempts are cleared here so
        // a later start never resurrects stale polls.
        draftProbeAttempts.clear()
        permissionActions.clear()
        draftProbeHandles.clear()
        draftProbeIDs.clear()
        editorBaselines.clear()
        // Un-consumed model-set stages are App-side records only; the
        // native epoch/route fences retire the real slots.
        modelSets.discardAll()
        listActionFailure = null
        countObservation?.cancel()
        countObservation = null
    }

    /** Last real `config.providers.list` page, kept for count re-projection. */
    private var lastProviderPageValue: JsonElement? = null
    private var lastModelCounts: Map<String, Int> = emptyMap()
    private var countObservation: kotlinx.coroutines.Job? = null
    /** Last failed list action; read/count reconciliation must not erase it. */
    @Volatile private var listActionFailure: String? = null
    /** Fences provider/catalog page continuation chains (latest wins). */
    private val providerPageGeneration = java.util.concurrent.atomic.AtomicLong(0)
    private val catalogPageGeneration = java.util.concurrent.atomic.AtomicLong(0)

    private fun republishModelCounts() {
        val counts = host.conversations.modelCountsByProvider()
        if (counts == lastModelCounts) return
        lastModelCounts = counts
        val value = lastProviderPageValue ?: return
        val rows = ProviderWire.decodeProviderRows(value, counts) ?: return
        updateDestination { state ->
            state.copy(
                list = ProviderListUiState(
                    isLoading = false,
                    conversationProviders = rows.conversationProviders,
                    imageProviders = rows.imageProviders,
                    videoProviders = rows.videoProviders,
                    errorMessage = listActionFailure,
                ),
            )
        }
    }

    private fun admitted(): Boolean = host.readiness.value.providerConfigurationAdmitted

    private fun client() = host.commandClient

    private fun networkAvailable(): Boolean = admitted()

    // --------------------------------------------------------- projections

    /**
     * Bounded continuation read (Main decision
     * MAIN_CONFIG_READ_PAGING_DECISION_20261021): the provider page follows
     * the ACTUAL `ConfigPageComposer` nextCursor carried by the authorized
     * payload continuation field — strict progress (decimal index must
     * increase), page/row bounds, refresh generation fencing (a newer
     * refresh owns the surface; a late page never mixes into it), and error
     * ownership (a partial snapshot is NEVER published: the last real list
     * stays and an honest load failure is shown; malformed/foreign
     * continuations refuse rather than coerce to page 1).
     */
    internal fun refreshProviders(retainActionFailure: Boolean = false) {
        if (!admitted()) return
        if (!retainActionFailure) listActionFailure = null
        fetchProviderPage(providerPageGeneration.incrementAndGet(),
                          cursor = null, pages = 0, accumulated = ArrayList())
    }

    private fun fetchProviderPage(
        generation: Long,
        cursor: String?,
        pages: Int,
        accumulated: ArrayList<JsonElement>,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID("plist"),
                payload = ProviderWire.providerListPayload(cursor),
            ),
        ) { outcome ->
            if (providerPageGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val value = outcome.value
                    val rows = value?.let { ProviderWire.pageRows(it) }
                    if (rows == null) {
                        publishProviderListFailure("list_page_unreadable")
                        return@trackOperation
                    }
                    accumulated.addAll(rows)
                    val meta = ProviderWire.pageMeta(value)
                    if (meta?.hasMore == true) {
                        val next = meta.nextCursor
                        if (!pageProgressed(cursor, next) ||
                            pages + 1 >= MAX_PAGE_CHAIN ||
                            accumulated.size >= MAX_PAGE_CHAIN_ROWS) {
                            publishProviderListFailure("list_page_continuation")
                            return@trackOperation
                        }
                        fetchProviderPage(generation, next, pages + 1, accumulated)
                        return@trackOperation
                    }
                    publishProviderPage(
                        JsonObject(mapOf("rows" to JsonArray(accumulated.toList()))))
                }
                is HostOperationOutcome.Rejected -> {
                    // Detailed typed code stays in diagnostics; the ordinary
                    // UI shows natural bilingual copy only.
                    runCatching {
                        android.util.Log.w("FloeProviders", "list_rejected:${outcome.code}")
                    }
                    publishProviderListFailure(outcome.code)
                }
                is HostOperationOutcome.Failed -> {
                    runCatching {
                        android.util.Log.w("FloeProviders", "list_failed:${outcome.code}")
                    }
                    publishProviderListFailure(outcome.code)
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
    }

    /** Composer cursor rule: an absent first continuation starts at 0+. */
    private fun pageProgressed(previous: String?, next: String?): Boolean {
        val nextValue = next?.toLongOrNull() ?: return false
        if (nextValue < 0) return false
        if (previous == null) return true
        val previousValue = previous.toLongOrNull() ?: return false
        return nextValue > previousValue
    }

    private fun loadFailureCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_load_failed)
        }.getOrElse { "Couldn't load your providers. Try again." }

    private fun publishProviderPage(value: JsonElement) {
        lastProviderPageValue = value
        val counts = host.conversations.modelCountsByProvider()
        lastModelCounts = counts
        val rows = ProviderWire.decodeProviderRows(value, counts)
        updateDestination { state ->
            state.copy(
                list = ProviderListUiState(
                    isLoading = false,
                    conversationProviders = rows?.conversationProviders
                        ?: state.list.conversationProviders,
                    imageProviders = rows?.imageProviders
                        ?: state.list.imageProviders,
                    videoProviders = rows?.videoProviders
                        ?: state.list.videoProviders,
                    errorMessage = if (rows == null) loadFailureCopy() else listActionFailure,
                ),
            )
        }
        if (counts.isEmpty()) {
            // The models page may not have landed yet. Request it AFTER the
            // destination carries these rows: the sweep (and its editing
            // admission) is bound to the CURRENT provider set, so starting
            // it against the previous empty list would cache an empty sweep
            // for the wrong target set.
            host.conversations.refreshModels()
        }
        // The provider side of the model join just changed: republish the
        // composer projection AFTER the destination carries the new rows
        // (no second catalog read).
        host.conversations.republishModelProjection()
    }

    private fun publishProviderListFailure(code: String) {
        runCatching {
            android.util.Log.w("FloeProviders", "list_incomplete:$code")
        }
        updateDestination { it.copy(list = it.list.copy(isLoading = false,
            errorMessage = loadFailureCopy())) }
    }

    internal fun refreshCatalog() {
        if (!admitted()) return
        val generation = catalogPageGeneration.incrementAndGet()
        updateDestination {
            it.copy(catalog = catalogWithCustom(it.catalog).copy(refreshInFlight = true))
        }
        // REAL contract (RuntimeFacadeConfig.catalogSearch + RB2 router):
        // the payload is CLOSED to {"query","filter"(,"cursor")} and the
        // completed page is the ConfigPageComposer document delivered as the
        // {"rows":[…],nextCursor,hasMore} OBJECT by the domain-to-carrier
        // binder. Both `all` and `configured` follow the ACTUAL returned
        // continuation with the same bounded, progress-checked, generation-
        // fenced loop; a mid-chain refusal never publishes a partial mix.
        fetchCatalogPages(generation, filter = "all", cursor = null, pages = 0,
                          accumulated = ArrayList()) { rows ->
            if (rows == null) {
                if (catalogPageGeneration.get() != generation) return@fetchCatalogPages
                // Typed refusal (e.g. needsConfiguration/catalogNotInjected):
                // keep the honest empty catalog + custom preset; never fake
                // entries and never leave the UI in an endless refresh state.
                updateDestination {
                    it.copy(
                        catalog = catalogWithCustom(it.catalog).copy(
                            refreshInFlight = false,
                            refreshAvailable = true,
                            networkActionsAvailable = networkAvailable(),
                        ),
                    )
                }
                return@fetchCatalogPages
            }
            // Marks come from the SERVER-SIDE configured filter page — the
            // App never guesses which saved rows map to presets.
            fetchCatalogPages(generation, filter = "configured", cursor = null,
                              pages = 0, accumulated = ArrayList()) { configuredRows ->
                if (catalogPageGeneration.get() != generation) return@fetchCatalogPages
                val configured = configuredRows
                    ?.mapNotNull { ProviderWire.catalogEntryOf(it)?.catalogEntryId }
                    ?.toSet() ?: emptySet()
                val entries = rows.mapNotNull { ProviderWire.catalogEntryOf(it) }
                val merged = entries.map {
                    if (it.catalogEntryId in configured) it.copy(isConfigured = true) else it
                }
                updateDestination { state ->
                    state.copy(
                        catalog = catalogWithCustom(state.catalog).copy(
                            officialProviders = merged,
                            configuredPresetIds = configured,
                            refreshInFlight = false,
                            refreshAvailable = true,
                            networkActionsAvailable = networkAvailable(),
                        ),
                    )
                }
            }
        }
    }

    /** ONE bounded continuation chain for one closed catalog filter. */
    private fun fetchCatalogPages(
        generation: Long,
        filter: String,
        cursor: String?,
        pages: Int,
        accumulated: ArrayList<JsonElement>,
        onDone: (List<JsonElement>?) -> Unit,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "config.catalog.search",
                scope = HostScope.ApplicationConfiguration("catalog"),
                stateful = false,
                correlationID = client().correlationID("cat"),
                payload = ProviderWire.catalogRequestPayload(filter, cursor),
            ),
        ) { outcome ->
            if (catalogPageGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val value = outcome.value
                    if (value != null) catalogKinds.putAll(ProviderWire.catalogKinds(value))
                    val rows = value?.let { ProviderWire.pageRows(it) }
                    // A typed domain refusal body (errorCode) is NOT a page.
                    if (rows == null) {
                        onDone(null)
                        return@trackOperation
                    }
                    accumulated.addAll(rows)
                    val meta = ProviderWire.pageMeta(value)
                    if (meta?.hasMore == true) {
                        val next = meta.nextCursor
                        if (!pageProgressed(cursor, next) ||
                            pages + 1 >= MAX_PAGE_CHAIN ||
                            accumulated.size >= MAX_PAGE_CHAIN_ROWS) {
                            onDone(null)
                            return@trackOperation
                        }
                        fetchCatalogPages(generation, filter, next, pages + 1,
                                          accumulated, onDone)
                        return@trackOperation
                    }
                    onDone(accumulated.toList())
                }
                else -> onDone(null)
            }
        }
    }

    /** The host-owned custom endpoint preset (always available, never fake
     *  catalog data — it is the documented compatible-endpoint path). */
    private fun customPreset(): SupplierPresetUi = SupplierPresetUi(
        presetId = CUSTOM_PRESET_ID,
        displayName = host.appContext.getString(com.floe.android.R.string.providers_custom_endpoint),
        defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
        supportedProtocols = WireProtocolUi.entries.toList(),
        defaultEndpointHost = null,
        defaultEndpointAbsoluteString = "",
        defaultEndpointSchemeIsHttp = false,
        routeFamily = "",
        authStyle = "",
        isCustom = true,
    )

    private fun catalogWithCustom(catalog: SupplierCatalogUiState): SupplierCatalogUiState =
        catalog.copy(
            builtInPresets = listOf(customPreset()) +
                catalog.builtInPresets.filterNot { it.isCustom || it.presetId == CUSTOM_PRESET_ID },
        )

    private fun updateDestination(transform: (ProviderDestinationState) -> ProviderDestinationState) {
        destinationState.value = transform(destinationState.value)
    }

    // ------------------------------------------------------ ProviderUiCallbacks

    override fun openExistingProvider(providerId: String) {
        // Holder-driven; the host revalidates the row exists on seed.
        refreshProviders()
    }

    override fun requestNewProvider(role: ProviderServiceRoleUi) {
        // Holder-driven (role chooser); nothing to admit yet.
    }

    override fun setProviderEnabled(providerId: String, enabled: Boolean): Boolean {
        if (!admitted()) return false
        val row = findProviderRow(providerId) ?: return false
        // Already at the requested persisted state: nothing to write.
        if (row.enabled == enabled) return true
        // COMPACT existing-row KEEP metadata variant of the same
        // `config.provider.save` command (Main decision
        // MAIN_PROVIDER_COMPACT_METADATA_DECISION_20261021). The toggle
        // flips ONLY the persisted provider row's enabled flag under the
        // SAME per-provider save ownership + durable writer CAS: every
        // model row (incl. disabled/hidden ones), capability override,
        // preference, preset sidecar and credential reference provably
        // stays byte-identical, because NOTHING model- or secret-side is
        // serialized or touched. No full-candidate reconstruction, so a
        // valid 512-model profile toggles without ANY byte-bound refusal
        // — the old ">16 KiB => can't" limitation is gone, not hidden.
        // The ACTUAL committed advanced revision is returned natively;
        // a pending physical reconciliation is rejected, never bypassed,
        // and the refreshed list (never an optimistic flip) is the only
        // success surface.
        val revision = ProviderHostControllerRevisions.revision(providerId) ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "config.provider.save",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = client().correlationID("ptoggle"),
                revision = revision,
                payload = JsonObject(
                    mapOf(
                        "secretIntent" to JsonPrimitive("keep"),
                        "metadata" to JsonObject(
                            mapOf(
                                "id" to JsonPrimitive(providerId),
                                "isEnabled" to JsonPrimitive(enabled),
                            ),
                        ),
                    ),
                ),
            ),
        ) { outcome ->
            // The refreshed list is the ONLY success surface: a completed
            // metadata keep publishes the real persisted row; a typed
            // refusal keeps the switch on the persisted value (never a
            // fabricated success).
            when (outcome) {
                is HostOperationOutcome.Completed -> refreshProviders()
                is HostOperationOutcome.Rejected,
                is HostOperationOutcome.Failed -> {
                    // The row must NOT silently look successful: the switch
                    // keeps the persisted truth after the refresh, and the
                    // list carries an actionable bilingual message now.
                    val message = runCatching {
                        host.appContext.getString(com.floe.android.R.string.providers_toggle_failed)
                    }.getOrElse { "Couldn't update this provider. It stayed unchanged — try again." }
                    listActionFailure = message
                    updateDestination { it.copy(list = it.list.copy(errorMessage = message)) }
                    refreshProviders(retainActionFailure = true)
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    // (The list toggle's full-profile reconstruction helper path is gone:
    //  the compact metadata keep needs no role lookup, and the editor's
    //  initial role comes from the holder-supplied identity as before.)

    override fun deleteProvider(providerId: String): Boolean {
        if (!admitted()) return false
        val revision = ProviderHostControllerRevisions.revision(providerId) ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "config.provider.delete",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = client().correlationID("pdel"),
                revision = revision,
            ),
        ) { refreshProviders() }
        return true
    }

    /**
     * Opens either a blank new-provider draft or a REAL reconstruction of an
     * existing provider from the frozen read surfaces (`config.providers.list`
     * summary — now carrying the bounded additive secret-free `presetID` /
     * `nonSecretHeaders` projection Main authorized — plus the actual
     * `config.models.list` rows). Nothing is invented: the identity, protocol,
     * endpoint, enablement, custom-endpoint flags, catalog preset, permitted
     * non-secret headers and the complete saved model set (including disabled
     * rows, with their canonical UUIDs) come from the persisted values, so a
     * Keep save from this editor preserves them instead of clearing them.
     */
    override fun seedEditorFor(
        role: ProviderServiceRoleUi,
        existingProviderId: String?,
    ): ProviderEditorSeedUi? {
        if (!admitted()) return null
        val providerID = existingProviderId?.takeIf { it.isNotBlank() }
        if (providerID == null) {
            val catalog = destinationState.value.catalog
            return ProviderEditorSeedUi(
                snapshot = ProviderDraftSnapshot(role = role),
                credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
                availableProtocols = WireProtocolUi.entries.toList(),
                discoverySupported = role == ProviderServiceRoleUi.CONVERSATION,
                offers = emptyList(),
                officialMediaModels = ProviderWire.officialMediaModels(catalog, role),
            )
        }
        val row = findProviderRow(providerID) ?: return null
        // A saved profile is only edited from a COMPLETE real model read.
        // Seeding from a partial/empty cache would let a Keep save persist an
        // erased model set; refuse honestly and let the user retry once the
        // model projection lands.
        if (!host.conversations.modelsProjectionReadyForEditing()) {
            // The tap must explain why nothing opened; the message clears on
            // the next real list/count publication.
            updateDestination { state ->
                state.copy(list = state.list.copy(errorMessage = runCatching {
                    host.appContext.getString(
                        com.floe.android.R.string.providers_open_waiting_models)
                }.getOrElse {
                    "Models are still loading. Try again in a moment."
                }))
            }
            return null
        }
        val snapshot = snapshotForExistingProvider(row, role) ?: return null
        val catalog = destinationState.value.catalog
        return ProviderEditorSeedUi(
            snapshot = snapshot,
            credentialState = row.credentialState,
            availableProtocols = WireProtocolUi.entries.toList(),
            discoverySupported = role == ProviderServiceRoleUi.CONVERSATION,
            offers = ProviderWire.offersForRole(row, role),
            officialMediaModels = ProviderWire.officialMediaModels(catalog, role),
            providerRevisionVersion = row.revisionVersion,
        )
    }

    /**
     * The ONE secret-free reconstruction of a persisted provider, built from
     * the EXACT row object the caller captured (a background page publish
     * between row read and reconstruction must not mix two pages into one
     * draft). Every field comes from the actual persisted projection:
     * `config.providers.list` (identity/kind/protocol/endpoint/name/region/
     * enablement/plain-http/tool-name flags/presetID/non-secret headers) and
     * `config.models.list` (complete saved rows incl. disabled/hidden ones
     * with their canonical UUIDs); the default model comes from the real
     * `config.preferences.get` document. No field is guessed from the first
     * model or a role string.
     */
    private fun snapshotForExistingProvider(
        row: ProviderListRowUi,
        role: ProviderServiceRoleUi,
    ): ProviderDraftSnapshot? {
        val providerID = row.providerId
        val extras = ProviderWire.extrasFor(providerID)
        val protocol = WireProtocolUi.entries.firstOrNull {
            it.swiftRaw == extras?.wireProtocol
        } ?: WireProtocolUi.OPENAI_CHAT_COMPLETIONS
        val savedModels = host.conversations.modelRowsForProvider(providerID)
        val draftModels = savedModels.map(ProviderWire::savedModelDraft)
        val defaultModelID = host.conversations.defaultAgentModelIdFor(providerID)
            ?.takeIf { id -> draftModels.any { it.savedModelId == id } }
        val supplier = extras?.presetID?.let { presetID ->
            ProviderWire.supplierChoiceFor(
                presetID = presetID,
                displayName = destinationState.value.catalog.officialProviders
                    .firstOrNull { it.catalogEntryId == presetID }?.name ?: presetID,
                endpoint = row.endpointSummary,
            )
        }
        return ProviderDraftSnapshot(
            role = role,
            enabled = row.enabled,
            // A persisted NULL display name stays blank in the draft so the
            // ORIGINAL "blank means preset/kind fallback" rule is preserved
            // (never re-persist the UUID row fallback as a user name).
            displayName = extras?.displayName ?: "",
            supplier = supplier,
            protocol = protocol,
            baseUrl = row.endpointSummary,
            nonSecretHeaders = extras?.nonSecretHeaders ?: "",
            allowsPlainHttp = extras?.allowsPlainHTTP ?: false,
            toolNameCompatibility = extras?.toolNameCompatibility ?: false,
            models = draftModels,
            defaultModelDraftId = defaultModelID,
            offerDecisions = emptyMap(),
        )
    }

    private fun findProviderRow(providerID: String): ProviderListRowUi? =
        destinationState.value.list.conversationProviders
            .firstOrNull { it.providerId.equals(providerID, ignoreCase = true) }
            ?: destinationState.value.list.imageProviders
                .firstOrNull { it.providerId.equals(providerID, ignoreCase = true) }
            ?: destinationState.value.list.videoProviders
                .firstOrNull { it.providerId.equals(providerID, ignoreCase = true) }

    override fun seedSeparateOfferEditor(
        seed: SeparateOfferSeedUi,
        role: ProviderServiceRoleUi,
    ): ProviderEditorSeedUi? = seedEditorFor(role, null)?.let {
        it.copy(
            snapshot = it.snapshot.copy(
                supplier = com.floe.android.feature.providers.SupplierChoice(
                    presetId = seed.presetId,
                    displayName = seed.presetId,
                    catalogEntryId = seed.catalogEntryId,
                    absoluteEndpointDefault = seed.endpointAbsoluteString ?: "",
                    routeFamily = "",
                    authStyle = "",
                    supportsPlainHttpChoice = seed.endpointAbsoluteString
                        ?.startsWith("http://") == true,
                    suggestsToolNameCompatibility = false,
                ),
            ),
        )
    }

    override fun editorOpened(identity: ProviderEditorIdentity) {
        editorOpened(identity, null)
    }

    override fun editorOpened(identity: ProviderEditorIdentity, seededFrom: ProviderEditorSeedUi?) {
        // Epoch fencing is holder-owned; the host resets attempt metadata.
        saveFailureSequencer.reset(identity.editorId, identity.epoch)
        if (identity.editorId.startsWith("new")) {
            // ONE stable provider identity for every save attempt of this
            // editor (the native candidate requires a real UUID).
            newProviderIDs.putIfAbsent(identity.editorId, UUID.randomUUID().toString())
        }
        // Use the holder's FIRST seed (the exact object already placed into
        // drafts.open) whenever one is supplied; only seed-less direct callers
        // recompute here. This keeps the draft fields and the CAS baseline on
        // the same row read even if a list refresh lands between seed and open.
        val seed = seededFrom ?: seedEditorFor(identity.role, existingProviderID(identity))
        // Bind this editor's FROZEN CAS baseline from that seed's own row:
        // the moving VERSION comes from the exact seeded row object, the
        // stable RESOURCE identity from the remembered token (same provider
        // identity either way). A later list refresh can never rebind a
        // newer version onto this draft, and Save never adopts a live-cache
        // token; the native durable CAS still arbitrates.
        existingProviderID(identity)?.let { providerID ->
            val version = seed?.providerRevisionVersion
            val remembered = ProviderHostControllerRevisions.revision(providerID)
            if (version != null) {
                editorBaselines[identity.editorId] = HostRevision(
                    remembered?.resourceID ?: "provider.${providerID.uppercase()}",
                    version,
                )
            } else if (seededFrom == null && remembered != null) {
                // Seed-less direct open (no holder-provided seed): freeze the
                // currently remembered token ONCE here. It is still presented
                // frozen at Save and CAS-arbitrated natively; production
                // editor opens always arrive with the holder's seed.
                editorBaselines[identity.editorId] = remembered
            } else {
                editorBaselines.remove(identity.editorId)
            }
        }
        // Publish the editor projection so the form leaves the
        // "Loading configuration…" placeholder. Values come from the REAL
        // seed (saved rows + catalog offers); mutations keep transforming
        // this projection through publishEditor().
        publishEditor(identity) { seeded ->
            seeded.copy(
                isEditingExisting = existingProviderID(identity) != null,
                role = identity.role,
                credentialState = seed?.credentialState ?: seeded.credentialState,
                availableProtocols = seed?.availableProtocols ?: seeded.availableProtocols,
                discoverySupported = seed?.discoverySupported ?: seeded.discoverySupported,
                offers = seed?.offers ?: seeded.offers,
                networkActionsAvailable = networkAvailable(),
                networkActionsUnavailableReason = if (networkAvailable()) null else "unavailable",
            )
        }
        // Bind ONE native host route for this live editor sheet. The token is
        // minted by the accepted Root epoch; a missing handle simply leaves
        // the save path fail-closed with the honest ingress refusal.
        beginEditorRoute(identity)
    }

    override fun editorClosed(identity: ProviderEditorIdentity, discarded: Boolean) {
        // Draft disposal is holder-owned (RAM only). In-flight host probes
        // addressed to this identity are fenced by the identity epoch check;
        // trusted DRAFT probe work is cancelled for real and its native slot
        // retired with the route. A large-profile stage follows the SAME
        // rule: only the UN-CONSUMED record is cancelled (exact owner); an
        // accepted save already owns its typed values natively until its
        // real terminal, and the native route/epoch fence sweeps regardless.
        inFlightTests.remove(identity.editorId)
        inFlightDiscoveries.remove(identity.editorId)
        draftProbeAttempts.remove(identity.editorId)
        permissionActions.remove(identity.editorId)
        draftProbeHandles.remove(identity.editorId)?.let { handle ->
            editorRoute(identity)?.let { route -> draftProbe.cancel(handle, route) }
        }
        draftProbeIDs.remove(identity.editorId)
        // Frozen baseline lives only as long as this editor incarnation.
        editorBaselines.remove(identity.editorId)
        modelSets.discardFor(identity.editorId)
        endEditorRoute(identity.editorId)
    }

    override fun saveProvider(
        identity: ProviderEditorIdentity,
        draft: ProviderDraftSnapshot,
        credentialDraft: String?,
    ): Boolean {
        if (!admitted()) return false
        publishEditor(identity) { it.copy(saveInFlight = true, saveError = null) }
        val providerID = providerIDForSave(identity) ?: return false
        // The candidate (stable provider + model UUIDs, createIntent) is
        // frozen BEFORE the secret submit: the one-shot lease must carry the
        // EXACT candidate/baseRevision the public command will commit.
        val candidate = ProviderWire.candidateJson(
            providerID = providerID,
            // Existing rows keep their PERSISTED ProviderKind; only a new
            // draft derives its kind from the chosen catalog preset.
            kind = ProviderWire.extrasFor(providerID)?.kind
                // Null-safe lookup: a new draft may have no chosen preset at
                // all. ConcurrentHashMap.get(null) threw (Main
                // MAIN_FORMAL_FIRST_SAVE_CRASH_20261020). Semantics are the
                // exact trivial equivalent: persisted-kind precedence first,
                // catalog preset lookup ONLY when presetId exists, then the
                // true custom fallback.
                ?: draft.supplier?.presetId?.let { catalogKinds[it] }
                ?: CUSTOM_PROVIDER_KIND,
            createIntent = existingProviderID(identity) == null,
            draft = draft,
            modelUUID = { draftModelID -> modelUUIDFor(providerID, draft, draftModelID) },
        )
        val isExistingProvider = existingProviderID(identity) != null
        // The intent branch is chosen from the provider IDENTITY plus this
        // editor's frozen baseline revision, never from a raw revision-memory
        // hit/miss. A miss on an existing row used to fall into the
        // new-provider create/clear branch and could drop the persisted
        // credential reference.
        val existingRevision =
            if (isExistingProvider) editorBaselines[identity.editorId] else null
        if (providerSaveIntentBranch(
                isExistingProvider, existingRevision, credentialDraft,
            ) == ProviderSaveIntentBranch.REFUSE_MISSING_BASELINE
        ) {
            // Fail closed BEFORE any ingress consumption or dispatch: an
            // existing provider whose CAS token this editor never observed
            // must not degrade into create/clear and must not blindly adopt
            // a newer live-cache revision. The draft (including any typed
            // credential) stays untouched; a re-open after a real list read
            // re-seeds the baseline.
            runCatching {
                android.util.Log.w("FloeProviders", "save_refused:saveBaselineUnavailable")
            }
            onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, reopenSettingsCopy())
            return true
        }
        // Large profile (Main direction B): an inline candidate over the
        // frozen 16,384-byte bound stages the FULL selected-model body
        // through the trusted host — ordered, idempotent chunks within the
        // PROVEN per-model payload class — and the candidate then carries
        // ONLY the sealed immutable reference (mutually exclusive with
        // selectedModels; the native Set/Keep/Clear chain resolves it back
        // into the same typed atomic request). Never a truncation, never
        // a budget raise, never a second business store. Staging failure
        // fails the save preflight honestly: no partial save, no
        // optimistic success, no secret touched.
        var effectiveCandidate = candidate
        if (candidate.toString().encodeToByteArray().size > CANDIDATE_MAXIMUM_BYTES) {
            val route = editorRoute(identity)
            if (route == null) {
                runCatching { android.util.Log.w("FloeProviders", "model_set_route_unavailable") }
                onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, stagingUnavailableCopy())
                return true
            }
            val rows = (candidate["selectedModels"] as? JsonArray)
                ?.mapNotNull { it as? JsonObject } ?: emptyList()
            if (rows.isEmpty()) {
                // Oversize WITHOUT models: staging cannot help (it only
                // carries model rows); the scalar payload itself exceeds
                // the frozen candidate class. Honest typed preflight,
                // never a silent field drop.
                runCatching {
                    android.util.Log.w("FloeProviders", "candidate_scalars_too_large")
                }
                onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, detailsTooLargeCopy())
                return true
            }
            val staged = modelSets.stage(
                editorID = identity.editorId,
                providerID = providerID,
                baseResourceID = existingRevision?.resourceID ?: "provider.$providerID",
                baseVersion = existingRevision?.version ?: "0",
                createIntent = existingRevision == null,
                routeToken = route,
                rows = rows,
            )
            val frozenRef = (staged as? StagedModelSet.Frozen)?.ref
            if (frozenRef == null) {
                val code = (staged as? StagedModelSet.Refused)?.code ?: "model_set_unavailable"
                runCatching { android.util.Log.w("FloeProviders", "model_set_refused:$code") }
                // The closed code stays in diagnostics; the ordinary UI
                // shows the natural bilingual copy (product copy rule).
                onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, stagingUnavailableCopy())
                return true
            }
            effectiveCandidate = ProviderWire.stagedCandidateJson(candidate, frozenRef)
            if (effectiveCandidate.toString().encodeToByteArray().size > CANDIDATE_MAXIMUM_BYTES) {
                // Scalar-only overflow (name/headers) beyond the staged set:
                // an honest typed preflight refusal, never a dropped field.
                runCatching {
                    android.util.Log.w("FloeProviders", "model_set_candidate_unsupported")
                }
                onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, detailsTooLargeCopy())
                return true
            }
        }
        // One-shot credential ingress; the RAM draft is consumed here and
        // never retained, logged or placed in any error or public JSON.
        var ingressToken: String? = null
        if (credentialDraft != null) {
            ingressToken = submitBoundProviderIntent(identity, providerID, effectiveCandidate,
                existingRevision, credentialDraft)
            if (ingressToken == null) {
                onSaveFailed(identity, SaveFailurePhaseUi.CREDENTIAL_COMMIT,
                    "credential_unavailable")
                return true // the attempt was published; outcome below is final
            }
        }
        val request = when {
            ingressToken != null -> HostCommandRequest(
                command = "config.provider.save",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = client().correlationID("psave"),
                revision = existingRevision,
                createIntent = existingRevision == null,
                // Set carries the opaque one-shot handle ONLY; the frozen
                // candidate lives in the lease (native providerSaveSetInputs
                // refuses a candidate here).
                payload = JsonObject(
                    mapOf(
                        "secretIntent" to JsonPrimitive("set"),
                        "ingressToken" to JsonPrimitive(ingressToken),
                    ),
                ),
            )
            existingRevision != null -> HostCommandRequest(
                command = "config.provider.save",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = client().correlationID("psave"),
                revision = existingRevision,
                payload = JsonObject(
                    mapOf(
                        "secretIntent" to JsonPrimitive("keep"),
                        "candidate" to effectiveCandidate,
                    ),
                ),
            )
            else -> HostCommandRequest(
                command = "config.provider.save",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = client().correlationID("psave"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "secretIntent" to JsonPrimitive("clear"),
                        "candidate" to effectiveCandidate,
                    ),
                ),
            )
        }
        host.trackOperation(request) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val providerID = outcome.detailProviderID()
                        ?: existingRevision?.resourceID?.removePrefix("provider.")
                    onSaveSucceeded(identity)
                    refreshProviders()
                    // The committed provider/model rows are the new truth:
                    // re-read the REAL models page so the list counts, the
                    // composer picker and a reopened editor see the saved
                    // set (a same-id edit does not change the provider
                    // signature, so no other collector triggers this).
                    host.conversations.refreshModels()
                    providerID?.let { id ->
                        flowHolder.currentEditorIdentity()?.takeIf { current ->
                            current.isCurrentFor(identity)
                        }
                    }
                }
                is HostOperationOutcome.Rejected ->
                    onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, outcome.code)
                is HostOperationOutcome.Failed -> {
                    // Closed parse/binding identifiers only; no draft or credential data.
                    val diagnosticReasons = setOf(
                        "revisionShape", "revisionPresentUnreadable", "revisionResourceMismatch",
                        "candidateParse", "candidateModelsMissing", "candidateModelFormMixed",
                        "saveIntentRouteMismatch", "saveIntentSubjectMismatch", "saveIntentDivergence",
                        "saveIntentCreateConflict", "saveIntentSchema", "createConflict",
                        "createIntentBaseRevisionDivergence", "createIntentRevisionNonZero",
                        "candidate.id", "candidate.kind", "candidate.wireProtocol", "candidate.baseURL",
                        "candidate.displayName", "candidate.presetID", "candidate.headerValue",
                        "candidate.nonSecretHeaders", "candidate.syncEnabled", "candidate.serviceRole",
                        "candidate.selectedModels", "candidate.modelSetRef", "candidate.defaultModelID",
                    )
                    if (outcome.reason in diagnosticReasons || outcome.reason.startsWith("providerValidation[")) runCatching {
                        android.util.Log.w("FloeProviders", "save_refused:${outcome.reason}")
                    }
                    onSaveFailed(identity, SaveFailurePhaseUi.LOCAL_COMMIT, outcome.code)
                }
                HostOperationOutcome.Cancelled ->
                    onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, "cancelled")
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    private fun onSaveSucceeded(identity: ProviderEditorIdentity) {
        publishEditor(identity) {
            it.copy(
                saveInFlight = false,
                saveError = null,
                saveOutcome = SaveOutcomeUi.Succeeded,
                saveFailureSequence = saveFailureSequencer.current(identity.editorId, identity.epoch),
            )
        }
        flowHolder.applyHostSaveOutcome(identity, SaveOutcomeUi.Succeeded)
        flowHolder.finalizeSavedEditor(identity)
    }

    private fun onSaveFailed(identity: ProviderEditorIdentity, phase: SaveFailurePhaseUi, message: String) {
        val sequence = saveFailureSequencer.next(identity.editorId, identity.epoch)
        val displayMessage = if (message == "staleRevision") reopenSettingsCopy() else message
        publishEditor(identity) {
            it.copy(
                saveInFlight = false,
                saveError = displayMessage,
                saveOutcome = SaveOutcomeUi.Failed(phase, displayMessage),
                saveFailureSequence = sequence,
            )
        }
        flowHolder.applyHostSaveOutcome(identity, SaveOutcomeUi.Failed(phase, displayMessage))
        flowHolder.noteSaveAttemptFinished(identity)
    }

    /** Existing composer entry points use the SAME permission owner. The
     * provider row/endpoint and the caller's launch identity must still be
     * current when a system-dialog result arrives. */
    internal fun withLocalNetworkForProvider(
        providerID: String,
        isCurrent: () -> Boolean,
        onDenied: (String) -> Unit,
        dispatch: () -> Unit,
    ): Boolean {
        val row = findProviderRow(providerID) ?: return false
        val endpoint = row.endpointSummary
        val generation = client().generation()
        val rootEpoch = host.nativeRootEpoch()
        return host.integrations.localNetwork.runExplicitAction(
            ownerID = providerID,
            endpoint = endpoint,
            isCurrent = {
                isCurrent() && client().generation() == generation &&
                    host.nativeRootEpoch() == rootEpoch &&
                    findProviderRow(providerID)?.endpointSummary == endpoint
            },
            onDenied = onDenied,
            dispatch = dispatch,
        )
    }

    internal fun localNetworkDeniedCopy(code: String): String = try {
        host.appContext.getString(
            if (code == LocalNetworkAccessBroker.CODE_RECOVERY)
                com.floe.android.R.string.providers_local_network_settings
            else com.floe.android.R.string.providers_local_network_denied,
        )
    } catch (_: RuntimeException) { "Local network access is needed. Allow it in Settings and try again." }

    private fun withProbeNetworkPermission(
        identity: ProviderEditorIdentity,
        probe: ConnectionProbeUi,
        discovery: Boolean,
    ): Boolean {
        val broker = host.integrations.localNetwork
        if (!broker.isLocalLikely(probe.endpointAbsoluteString)) {
            return dispatchProviderProbe(identity, probe, discovery)
        }
        val action = permissionActionSequencer.incrementAndGet()
        permissionActions[identity.editorId] = action
        val route = editorRoute(identity)
        val generation = client().generation()
        val rootEpoch = host.nativeRootEpoch()
        return broker.runExplicitAction(
            ownerID = identity.editorId,
            endpoint = probe.endpointAbsoluteString,
            isCurrent = {
                permissionActions[identity.editorId] == action && admitted() &&
                    client().generation() == generation && host.nativeRootEpoch() == rootEpoch &&
                    editorRoute(identity) == route
            },
            onDenied = { code ->
                permissionActions.remove(identity.editorId, action)
                publishEditor(identity) {
                    it.copy(testState = ConnectionTestUi.Failed(localNetworkDeniedCopy(code)))
                }
            },
            dispatch = {
                permissionActions.remove(identity.editorId, action)
                dispatchProviderProbe(identity, probe, discovery)
            },
        )
    }

    private fun dispatchProviderProbe(
        identity: ProviderEditorIdentity,
        probe: ConnectionProbeUi,
        discovery: Boolean,
    ): Boolean {
        val savedTarget = probeTargetProviderID(identity, probe)
        return if (savedTarget != null) runSavedProbe(identity, savedTarget, discovery)
        else submitDraftProbe(identity, probe, discovery)
    }

    override fun testConnection(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        if (!admitted()) return false
        return withProbeNetworkPermission(identity, probe, discovery = false)
    }

    /** Saved-provider probe command path (unchanged frozen grammar). */
    private fun runSavedProbe(
        identity: ProviderEditorIdentity,
        providerID: String,
        discovery: Boolean,
    ): Boolean {
        inFlightTests[identity.editorId] = providerID
        if (!discovery) publishEditor(identity) { it.copy(testState = ConnectionTestUi.Testing) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.provider.probe",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID(if (discovery) "pdisc" else "pprobe"),
                payload = JsonObject(mapOf("providerID" to JsonPrimitive(providerID))),
            ),
        ) { outcome ->
            inFlightTests.remove(identity.editorId)
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    if (discovery) {
                        val models = outcome.value?.let { ProviderWire.decodeDiscoveredModels(it) }
                            ?: emptyList()
                        flowHolder.mergeHostCandidateModels(identity, models)
                    } else {
                        val count = outcome.value?.let { ProviderWire.discoveredCount(it) } ?: 0
                        publishEditor(identity) {
                            it.copy(testState = ConnectionTestUi.Succeeded(count))
                        }
                    }
                }
                is HostOperationOutcome.Rejected -> if (!discovery) {
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Failed(outcome.code))
                    }
                }
                is HostOperationOutcome.Failed -> if (!discovery) {
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Failed(outcome.code))
                    }
                }
                HostOperationOutcome.Cancelled -> if (!discovery) {
                    publishEditor(identity) { it.copy(testState = ConnectionTestUi.Idle) }
                }
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    /**
     * Trusted-host DRAFT probe/discovery (MAIN_CONFIG_DRAFT_PROBE_PARITY
     * _DECISION): the frozen RAM draft is mapped onto the EXACT closed save
     * candidate and dispatched through the ORIGINAL provider adapter under
     * this editor's OWN live route handle with the ephemeral key typed for
     * this attempt. Nothing is autosaved, no shadow provider exists, and the
     * result is published ONLY to the matching identity/epoch.
     */
    private fun submitDraftProbe(
        identity: ProviderEditorIdentity,
        probe: ConnectionProbeUi,
        discovery: Boolean,
    ): Boolean {
        val route = editorRoute(identity)
        if (route == null) {
            // No accepted runtime / live editor authority: an honest typed
            // refusal (nothing is dispatched, nothing is implied verified).
            if (!discovery) {
                publishEditor(identity) {
                    it.copy(testState = ConnectionTestUi.Failed(probeUnavailableCopy()))
                }
            }
            return true
        }
        val existing = existingProviderID(identity)
        val providerID = existing ?: draftProbeIDs.computeIfAbsent(identity.editorId) {
            UUID.randomUUID().toString()
        }
        val extras = ProviderWire.extrasFor(providerID)
        val candidate = ProviderWire.draftProbeCandidate(
            providerID = providerID,
            kind = extras?.kind ?: CUSTOM_PROVIDER_KIND,
            role = identity.role,
            displayName = extras?.displayName,
            presetID = extras?.presetID,
            probe = probe,
        )
        val handle = draftProbe.submit(candidate.toString(), probe.credentialDraft, route)
        if (handle == null) {
            if (!discovery) {
                publishEditor(identity) {
                    it.copy(testState = ConnectionTestUi.Failed(probeUnavailableCopy()))
                }
            }
            return true
        }
        val attempt = draftProbeSequencer.incrementAndGet()
        draftProbeAttempts[identity.editorId] = attempt
        draftProbeHandles[identity.editorId] = handle
        if (discovery) {
            inFlightDiscoveries[identity.editorId] = providerID
        } else {
            inFlightTests[identity.editorId] = providerID
            publishEditor(identity) { it.copy(testState = ConnectionTestUi.Testing) }
        }
        host.scope.launch(host.ioDispatcher) {
            val deadline = System.nanoTime() + DRAFT_PROBE_BUDGET_NANOS
            var settled = false
            while (System.nanoTime() < deadline) {
                if (draftProbeAttempts[identity.editorId] != attempt) {
                    // Superseded/cancelled/closed: the native cancel owns the
                    // real adapter cancellation; publish nothing.
                    draftProbe.cancel(handle, route)
                    return@launch
                }
                when (val envelope = draftProbe.poll(handle, route)) {
                    "P" -> kotlinx.coroutines.delay(DRAFT_PROBE_POLL_MILLIS)
                    else -> {
                        settled = true
                        draftProbeHandles.remove(identity.editorId)
                        inFlightTests.remove(identity.editorId)
                        inFlightDiscoveries.remove(identity.editorId)
                        val payload = if (envelope.startsWith("S")) {
                            runCatching {
                                Json.parseToJsonElement(envelope.substring(1)) as JsonObject
                            }.getOrNull()
                        } else {
                            null
                        }
                        if (discovery) {
                            if (payload != null) {
                                flowHolder.mergeHostCandidateModels(
                                    identity,
                                    ProviderWire.decodeDiscoveredModels(payload),
                                )
                            }
                        } else {
                            val status = payload?.let { ProviderWire.statusOf(it) }
                            val failure = payload?.let { ProviderWire.failureOf(it) }
                            publishEditor(identity) {
                                if (status == "connected") {
                                    it.copy(testState = ConnectionTestUi.Succeeded(
                                        payload?.let { value -> ProviderWire.discoveredCount(value) } ?: 0))
                                } else {
                                    it.copy(testState = ConnectionTestUi.Failed(
                                        failure ?: probeUnavailableCopy()))
                                }
                            }
                        }
                        return@launch
                    }
                }
            }
            if (!settled) {
                draftProbe.cancel(handle, route)
                draftProbeHandles.remove(identity.editorId)
                inFlightTests.remove(identity.editorId)
                inFlightDiscoveries.remove(identity.editorId)
                if (!discovery) {
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Failed(probeUnavailableCopy()))
                    }
                }
            }
        }
        return true
    }

    private fun probeUnavailableCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_probe_unavailable)
        }.getOrElse { "Couldn't start the connection test. Try again." }

    private fun reopenSettingsCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_save_reopen_required)
        }.getOrElse { "Reopen these settings and try again." }

    private fun stagingUnavailableCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_staging_unavailable)
        }.getOrElse { "Couldn't prepare this provider's model list for saving. Try again." }

    private fun detailsTooLargeCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_save_details_too_large)
        }.getOrElse { "This provider's name or headers are too large to save. Shorten them and try again." }

    override fun cancelConnectionTest(identity: ProviderEditorIdentity) {
        inFlightTests.remove(identity.editorId)
        draftProbeAttempts.remove(identity.editorId)
        permissionActions.remove(identity.editorId)
        draftProbeHandles.remove(identity.editorId)?.let { handle ->
            editorRoute(identity)?.let { route -> draftProbe.cancel(handle, route) }
        }
        publishEditor(identity) { it.copy(testState = ConnectionTestUi.Idle) }
    }

    override fun discoverModels(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        if (!admitted()) return false
        return withProbeNetworkPermission(identity, probe, discovery = true)
    }

    override fun cancelModelDiscovery(identity: ProviderEditorIdentity) {
        inFlightDiscoveries.remove(identity.editorId)
        draftProbeAttempts.remove(identity.editorId)
        permissionActions.remove(identity.editorId)
        draftProbeHandles.remove(identity.editorId)?.let { handle ->
            editorRoute(identity)?.let { route -> draftProbe.cancel(handle, route) }
        }
    }

    /**
     * The persisted provider a probe may legitimately target, or null when
     * the editor's draft is new/dirty (no unsaved-draft probe API exists).
     * A saved-profile probe is only honest while the user has not entered a
     * replacement key and the draft endpoint still equals the persisted one;
     * anything else would verify the OLD row while implying the draft.
     */
    private fun probeTargetProviderID(
        identity: ProviderEditorIdentity,
        probe: ConnectionProbeUi,
    ): String? {
        val existing = existingProviderID(identity) ?: return null
        if (probe.credentialDraft != null) return null
        val row = destinationState.value.list.let {
            it.conversationProviders + it.imageProviders + it.videoProviders
        }.firstOrNull { it.providerId == existing } ?: return null
        val draftEndpoint = probe.endpointAbsoluteString.trim().trimEnd('/')
        val savedEndpoint = row.endpointSummary.trim().trimEnd('/')
        if (draftEndpoint.isEmpty() || draftEndpoint != savedEndpoint) return null
        return existing
    }

    override fun supplierPresetChosen(preset: SupplierPresetUi) {
        // Holder-owned draft application; nothing host-side to persist.
    }

    override fun supplierCatalogEntryChosen(entry: OfficialSupplierUi) {
        // Holder-owned draft application; nothing host-side to persist.
    }

    override fun requestCatalogRefresh(): Boolean {
        if (!admitted()) return false
        refreshCatalog()
        return true
    }

    override fun serviceOfferRequiresDiscovery(
        identity: ProviderEditorIdentity,
        role: ProviderServiceRoleUi,
    ): Boolean = currentEditor(identity)?.offers
        ?.firstOrNull { it.role == role }?.requiresDiscovery
        ?: destinationState.value.editor?.offers
            ?.firstOrNull { it.role == role }?.requiresDiscovery
        ?: false

    override fun requestOfferDiscovery(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi): Boolean {
        val editor = currentEditor(identity) ?: return false
        val offer = editor.offers.firstOrNull { it.role == role } ?: return false
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "",
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = emptyMap(),
            credentialDraft = null,
            allowsPlainHttp = false,
            toolNameCompatibility = false,
        )
        return discoverModels(identity, probe)
    }

    override fun offerDecisionChanged(
        identity: ProviderEditorIdentity,
        role: ProviderServiceRoleUi,
        enabled: Boolean,
    ) {
        // Draft decision is holder-owned; the save candidate carries it.
    }

    override fun offerPromptConfirmed(identity: ProviderEditorIdentity, roles: Set<ProviderServiceRoleUi>) {
        // Local prompt resolution; separate-offer editors open via the holder.
    }

    override fun offerPromptDeclined(identity: ProviderEditorIdentity) {
        // Local prompt resolution.
    }

    // -------------------------------------------------------------- internals

    private fun currentEditor(identity: ProviderEditorIdentity): ProviderEditorUiState? =
        destinationState.value.editor?.takeIf { it.identity.isCurrentFor(identity) }

    private fun publishEditor(
        identity: ProviderEditorIdentity,
        transform: (ProviderEditorUiState) -> ProviderEditorUiState,
    ) {
        updateDestination { state ->
            val editor = state.editor
            if (editor == null || !editor.identity.isCurrentFor(identity)) {
                // Seed a minimal editor projection for this identity so the
                // outcome has a truthful landing spot; the destination only
                // renders it when the holder's current identity matches.
                val seeded = ProviderEditorUiState(
                    identity = identity,
                    isEditingExisting = existingProviderID(identity) != null,
                    role = identity.role,
                    credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
                    credentialRequirementMessage = null,
                    availableProtocols = WireProtocolUi.entries.toList(),
                    testState = ConnectionTestUi.Idle,
                    discoverySupported = identity.role == ProviderServiceRoleUi.CONVERSATION,
                    offers = emptyList(),
                    networkActionsAvailable = networkAvailable(),
                    networkActionsUnavailableReason = if (networkAvailable()) null else "unavailable",
                )
                state.copy(editor = transform(seeded))
            } else {
                state.copy(editor = transform(editor))
            }
        }
    }

    /** Existing saved provider id (UUID prefix of the identity), or null. */
    private fun existingProviderID(identity: ProviderEditorIdentity): String? {
        val match = EXISTING_EDITOR_ID.matchEntire(identity.editorId) ?: return null
        return runCatching { UUID.fromString(match.groupValues[1]) }.getOrNull()?.toString()
    }

    /** The REAL provider identity this editor saves into: an existing row's
     *  UUID or the one UUID minted for a new provider (never a role string). */
    private fun providerIDForSave(identity: ProviderEditorIdentity): String? =
        existingProviderID(identity) ?: newProviderIDs[identity.editorId]

    /** One stable ModelProfile UUID per provider+staged row. */
    private fun modelProfileUUID(providerID: String, draftModelID: String): String =
        modelProfileIDs.computeIfAbsent("$providerID|$draftModelID") {
            UUID.randomUUID().toString()
        }

    /**
     * A SAVED model row keeps its canonical ModelProfile UUID (never a freshly
     * minted one): rewriting identities would orphan the preferences default
     * and every historical run's model reference. Only a genuinely new
     * (manual/discovered) row receives a minted identity.
     */
    private fun modelUUIDFor(
        providerID: String,
        draft: ProviderDraftSnapshot,
        draftModelID: String,
    ): String {
        val saved = draft.models.firstOrNull { it.draftModelId == draftModelID }
            ?.savedModelId
        return saved ?: modelProfileUUID(providerID, draftModelID)
    }

    /**
     * Admit ONE live editor incarnation and bind its native host route. The
     * shared UI generation is allocated exactly once per editor creation;
     * the native Root epoch is captured NOW (the actual accepted bootstrap
     * generation) and asserted by the native admission.
     */
    private fun beginEditorRoute(identity: ProviderEditorIdentity) {
        val uiGeneration = HostUiAdmission.nextGeneration()
        val nativeEpoch = host.nativeRootEpoch()
        val token = if (nativeEpoch != null) {
            routeAuthority.open(
                HostEditorKind.PROVIDER, identity.editorId, uiGeneration, nativeEpoch)
        } else {
            null
        }
        if (token != null && isOpaqueHostRouteToken(token)) {
            editorRouteTokens[identity.editorId] = token
        } else {
            editorRouteTokens.remove(identity.editorId)
        }
    }

    /** Exact-ownership close; a stale handle can never clear a newer route. */
    private fun endEditorRoute(editorId: String) {
        editorRouteTokens.remove(editorId)?.let(routeAuthority::clear)
    }

    /**
     * This editor incarnation's own route handle. A missing handle is NOT
     * re-minted here: a late save from an old editor must fail closed rather
     * than mint a newer incarnation that could evict a newer editor.
     */
    private fun editorRoute(identity: ProviderEditorIdentity): String? =
        editorRouteTokens[identity.editorId]?.takeIf(::isOpaqueHostRouteToken)

    /**
     * Freeze the closed Set intent (subject + same candidate + baseRevision)
     * and hand it to the trusted native seam with this editor's route handle
     * and the bounded secret bytes. Returns the one-shot `int:v1:` handle or
     * null; the secret never enters any command, log or state.
     */
    private fun submitBoundProviderIntent(
        identity: ProviderEditorIdentity,
        providerID: String,
        candidate: JsonObject,
        existingRevision: HostRevision?,
        secret: String,
    ): String? {
        val route = editorRoute(identity) ?: return null
        val baseRevision = existingRevision?.let {
            JsonObject(
                mapOf(
                    "resourceID" to JsonPrimitive(it.resourceID),
                    "version" to JsonPrimitive(it.version),
                ),
            )
        } ?: JsonObject(
            mapOf(
                "resourceID" to JsonPrimitive("provider.$providerID"),
                // Expected-absent marker only for a real create intent.
                "version" to JsonPrimitive("0"),
            ),
        )
        val intentCore = JsonObject(
            mapOf(
                "subject" to JsonObject(
                    mapOf(
                        "kind" to JsonPrimitive("providerSave"),
                        "id" to JsonPrimitive(providerID),
                    ),
                ),
                "intent" to JsonPrimitive("set"),
                "baseRevision" to baseRevision,
                "candidate" to candidate,
            ),
        ).toString()
        val bytes = secret.toByteArray(Charsets.UTF_8)
        return try {
            val token = secureIngress.submit(intentCore, route, bytes)
            token?.takeIf(::isOpaqueIngressToken)
        } finally {
            bytes.fill(0)
        }
    }

    private fun HostOperationOutcome.Completed.detailProviderID(): String? = null

    /** Current list rows for composer wiring. */
    val configuredProviders: List<ProviderListRowUi>
        get() = destinationState.value.list.let {
            it.conversationProviders + it.imageProviders + it.videoProviders
        }

    private companion object {
        const val CUSTOM_PRESET_ID = "custom"
        const val CUSTOM_PROVIDER_KIND = "custom"
        /** Frozen native `ProviderSaveCandidate` byte bound (16 KiB). */
        const val CANDIDATE_MAXIMUM_BYTES = 16_384
        /** Continuation bounds for one read chain (composer page budget). */
        const val MAX_PAGE_CHAIN = 8
        const val MAX_PAGE_CHAIN_ROWS = 256
        /** Bounded draft-probe poll budget (adapter transport has its own
         *  timeouts; this only stops a UI poller from running forever). */
        const val DRAFT_PROBE_BUDGET_NANOS = 120_000_000_000L
        const val DRAFT_PROBE_POLL_MILLIS = 150L
        /**
         * The ACTUAL holder identity for an existing provider is
         * `"<providerUUID>-<role>-<openCounter>"` (ProviderFlowHolder). The
         * previous pattern required the string to END right after the UUID's
         * hyphen (`matchEntire`), so every real existing editor was
         * misclassified as new and reopened blank. A UUID prefix followed by
         * the role/counter suffix is the exact existing shape; `new-…` and
         * `separate-…` identities keep their own prefixes and never match.
         */
        val EXISTING_EDITOR_ID = Regex(
            "^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?:-[A-Za-z0-9_.-]*)?$")
    }
}

/**
 * Strict-tolerant wire decoders for the providers/models/catalogue owner
 * pages. Required fields decode exactly; unknown fields are ignored by the
 * pinned JSON library. Where the owner wire schema is still source-pending,
 * the decoder reads only the documented closed keys and the HANDOFF records
 * the typed adaptation delta — no alternate schema is invented here.
 */
internal object ProviderWire {

    data class ProviderRows(
        val conversationProviders: List<ProviderListRowUi>,
        val imageProviders: List<ProviderListRowUi>,
        val videoProviders: List<ProviderListRowUi>,
    )

    /**
     * One REAL `config.models.list` row: the ORIGINAL `ModelProfile` JSON plus
     * its `revision {resourceID:"model.<uuid>",version:<digest>}`. This is the
     * same row shape the conversation model projection consumes; the provider
     * row count is derived from these rows (ConfigProviderSummary has no
     * `modelCount` member — the previous decoder invented a default of 0).
     */
    data class ModelRow(
        val id: String,
        val providerId: String,
        val remoteModelId: String,
        val displayName: String,
        val isEnabled: Boolean,
        val isHiddenFromPrimaryPicker: Boolean,
        val capabilitiesRaw: Int?,
        val contextTokens: Int,
        val maxOutputTokens: Int,
        val reasoningEffort: String?,
        val savedMetadata: ModelSavedMetadataUi? = null,
        /** Exact immutable owned read (incl. opaque revision) for narrow
         * full-snapshot model edits such as the reasoning shortcut. */
        val originalProjection: JsonObject? = null,
    ) {
        /** Text-capable for the ordinary conversation composer. */
        val supportsText: Boolean
            get() {
                val bits = capabilitiesRaw ?: return true
                return (bits and TEXT_CAPABILITY_BIT) != 0
            }

        companion object {
            const val TEXT_CAPABILITY_BIT = 1
        }
    }

    /**
     * ConfigProviderSummary members the App needs but the list row UI omits.
     * `displayName` is the PERSISTED value (null = the original
     * blank-means-preset/kind fallback), `presetID` and `nonSecretHeaders`
     * come from the bounded additive secret-free read projection (Main
     * authorization 2026-10-20) so an existing provider can be reopened and
     * Keep-saved losslessly.
     */
    data class ProviderExtras(
        val kind: String,
        val wireProtocol: String,
        val allowsPlainHTTP: Boolean,
        val toolNameCompatibility: Boolean,
        val displayName: String?,
        val presetID: String? = null,
        val nonSecretHeaders: String = "",
    )

    /** Persisted preset → supplier selection (display only; an explicit
     *  preset choice still owns endpoint-default application). */
    fun supplierChoiceFor(
        presetID: String,
        displayName: String,
        endpoint: String,
    ): SupplierChoice = SupplierChoice(
        presetId = presetID,
        displayName = displayName,
        catalogEntryId = presetID,
        absoluteEndpointDefault = endpoint,
        routeFamily = "",
        authStyle = "",
        supportsPlainHttpChoice = endpoint.startsWith("http://"),
        suggestsToolNameCompatibility = false,
    )

    /** Capability bits → the editor's typed capability set. */
    fun capabilitiesOf(raw: Int?): Set<ModelCapabilityUi> {
        if (raw == null) return emptySet()
        return ModelCapabilityUi.entries.filter { (raw and it.swiftBit) != 0 }.toSet()
    }

    /** App-scope registry of the real summary fields (never invented). */
    private val providerExtras = java.util.concurrent.ConcurrentHashMap<String, ProviderExtras>()

    fun extrasFor(providerId: String): ProviderExtras? =
        providerExtras[providerId.uppercase()]

    /**
     * Decodes one `config.models.list` page (`{"rows":[ModelProfile…]}`).
     * Unknown fields are ignored; a row without its real id/provider identity
     * is skipped (never fabricated).
     *
     * FULL-ROW READ FIDELITY (job-7d4d4e41017f4391): an unprocessed chunk
     * marker (the additive closed `modelRead` transport row streamed by
     * ModelPageReadController) is NEVER a model row and NEVER silently
     * skipped — a page that still carries one means the reader did not
     * complete the reconstruction, so the whole page fails to decode and
     * the consumer keeps its last real projection instead of losing a
     * saved model. Pages consumed here are ordinary complete ORIGINAL
     * pages (the reader replaces marker pages with reconstructed rows).
     */
    fun decodeModelRows(value: JsonElement): List<ModelRow>? {
        val rows = (value as? JsonObject)?.get("rows") as? JsonArray ?: return null
        if (rows.any { ModelPageReadController.isChunkRow(it) }) return null
        return rows.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = obj.string("id") ?: return@mapNotNull null
            val providerID = obj.string("providerID") ?: return@mapNotNull null
            val remote = obj.string("remoteModelID") ?: return@mapNotNull null
            val capabilities = (obj["capabilities"] as? JsonObject)
                ?.long("rawValue")?.toInt()
                ?: (obj["capabilities"] as? JsonPrimitive)?.longOrNull?.toInt()
                ?: (obj["capabilities"] as? JsonArray)
                    ?.mapNotNull { (it as? JsonPrimitive)?.longOrNull?.toInt() }
                    ?.fold(0) { bits, bit -> bits or bit }
            val limits = obj["limits"] as? JsonObject
            ModelRow(
                id = id,
                providerId = providerID,
                remoteModelId = remote,
                displayName = obj.string("displayName") ?: remote,
                isEnabled = obj.bool("isEnabled") ?: true,
                isHiddenFromPrimaryPicker = obj.bool("isHiddenFromPrimaryPicker") ?: false,
                capabilitiesRaw = capabilities,
                contextTokens = limits?.long("contextTokens")?.toInt() ?: 0,
                maxOutputTokens = limits?.long("maxOutputTokens")?.toInt() ?: 0,
                reasoningEffort = obj.string("reasoningEffort"),
                originalProjection = obj,
                savedMetadata = ModelSavedMetadataUi(
                    pricingJSON = obj["pricing"]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.toString(),
                    useSurfacesJSON = obj["useSurfaces"]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.toString(),
                    explicitCapabilitiesJSON = obj["explicitCapabilities"]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.toString(),
                    explicitCapabilitiesRaw = optionBits(obj["explicitCapabilities"]),
                    capabilitiesRaw = capabilities,
                    reasoningEffortRaw = obj.string("reasoningEffort"),
                ),
            )
        }
    }

    private fun optionBits(value: JsonElement?): Int? =
        (value as? JsonObject)?.long("rawValue")?.toInt()
            ?: (value as? JsonPrimitive)?.longOrNull?.toInt()
            ?: (value as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.longOrNull?.toInt() }
                ?.fold(0) { bits, bit -> bits or bit }

    /** One production seed path, retaining metadata with the row instead
     * of a mutable global model-ID registry or a later unrelated read. */
    internal fun savedModelDraft(model: ModelRow): ModelDraftRowUi = ModelDraftRowUi(
        draftModelId = model.id, savedModelId = model.id,
        remoteModelID = model.remoteModelId, displayName = model.displayName,
        enabled = model.isEnabled, hiddenFromPrimaryPicker = model.isHiddenFromPrimaryPicker,
        capabilities = capabilitiesOf(model.capabilitiesRaw),
        reasoningEffort = ReasoningEffortUi.entries.firstOrNull {
            it.swiftRaw == model.reasoningEffort
        } ?: ReasoningEffortUi.AUTOMATIC,
        contextTokens = model.contextTokens, maxOutputTokens = model.maxOutputTokens,
        source = com.floe.android.feature.providers.ModelSourceUi.SAVED,
        selectedForSave = true, savedMetadata = model.savedMetadata,
    )

    /**
     * Reads the persisted default agent model id from
     * `config.preferences.get` (`{"preferences":{"defaultAgentModelID":…}}`).
     */
    fun decodeDefaultAgentModel(value: JsonElement?): String? {
        val root = value as? JsonObject ?: return null
        val preferences = root["preferences"] as? JsonObject ?: return null
        return preferences.string("defaultAgentModelID")
    }

    /**
     * Decodes the ACTUAL `config.providers.list` effect value.
     *
     * Main decision 2026-10-20 (OBJECT-only carrier): the domain page is the
     * `ConfigPageComposer` document — `ConfigProviderSummary` objects
     * (`id, kind, wireProtocol, baseURL, displayName, region, isEnabled,
     * allowsPlainHTTP, toolNameCompatibility, createdAt, updatedAt,
     * syncRevision, secret{configured, opaqueReference, synchronizable}`) —
     * and the G02 domain-to-carrier binder composes that LIST into the
     * frozen effect carrier as the explicit OBJECT `{"rows":[...]}`. This
     * reader consumes EXACTLY that rows shape: the carrier never delivers a
     * top-level array (accepting one here could only mask a regression or an
     * unfixed carrier), so any other document is a decode failure (the
     * caller shows the load error); no empty-list substitute is invented.
     * There is no per-row `revision` object; the provider CAS revision is
     * the canonical `provider.<uuid>` / `<syncRevision>` mapping
     * (`ConfigRevision.provider`), derived here from the REAL persisted
     * value so a subsequent save/delete uses the actual revision.
     */
    fun decodeProviderRows(
        value: JsonElement,
        modelCounts: Map<String, Int> = emptyMap(),
    ): ProviderRows? {
        val rows = (value as? JsonObject)?.get("rows") as? JsonArray ?: return null
        val conversation = ArrayList<ProviderListRowUi>()
        val image = ArrayList<ProviderListRowUi>()
        val video = ArrayList<ProviderListRowUi>()
        for (element in rows) {
            val obj = element as? JsonObject ?: continue
            val id = obj.string("providerID") ?: obj.string("id") ?: continue
            val persistedName = obj.string("displayName")
            val displayName = persistedName ?: id
            val enabled = obj.bool("enabled") ?: obj.bool("isEnabled") ?: true
            // The real count comes ONLY from the `config.models.list` page for
            // this provider (ConfigProviderSummary has no modelCount member;
            // the previous default-0 was an invented value). An unloaded page
            // honestly reports 0 until the models read lands.
            val modelCount = modelCounts[id.uppercase()] ?: 0
            obj.string("kind")?.let { kind ->
                providerExtras[id.uppercase()] = ProviderExtras(
                    kind = kind,
                    wireProtocol = obj.string("wireProtocol") ?: "",
                    allowsPlainHTTP = obj.bool("allowsPlainHTTP") ?: false,
                    toolNameCompatibility = obj.bool("toolNameCompatibility") ?: false,
                    displayName = persistedName,
                    // Bounded additive secret-free projection (Main
                    // authorization 2026-10-20): persisted catalog preset and
                    // the ORIGINAL vetted non-secret header map. Unknown to
                    // older producers (absent = nil/empty).
                    presetID = obj.string("presetID"),
                    nonSecretHeaders = headerLines(obj["nonSecretHeaders"] as? JsonObject),
                )
            }
            val secret = obj["secret"] as? JsonObject
            val credential = if (obj.bool("credentialConfigured") == true ||
                secret?.bool("configured") == true
            ) {
                ProviderCredentialStateUi.CONFIGURED
            } else {
                ProviderCredentialStateUi.AWAITING_CONFIGURATION
            }
            val roles = (obj["serviceRoles"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?: listOf("conversation")
            val revision = (obj["revision"] as? JsonObject)?.let {
                val resourceID = it.string("resourceID")
                val version = it.string("version")
                if (resourceID != null && version != null) {
                    HostRevision(resourceID, version)
                } else null
            } ?: obj.long("syncRevision")?.let { syncRevision ->
                // Canonical persisted provider revision (ConfigRevision.provider):
                // resourceID "provider.<uuid>", version "<syncRevision>".
                HostRevision("provider.$id", syncRevision.toString())
            }
            revision?.let { ProviderHostControllerRevisions.remember(id, it) }
            val endpoint = obj.string("endpointSummary")
                ?: obj.string("baseURL") ?: ""
            val row = ProviderListRowUi(
                providerId = id,
                displayName = displayName,
                endpointSummary = endpoint,
                modelCount = modelCount,
                enabled = enabled,
                credentialState = credential,
                revisionVersion = revision?.version,
            )
            when {
                "conversation" in roles -> conversation.add(row)
                "image" in roles -> image.add(row)
                "video" in roles -> video.add(row)
                else -> conversation.add(row)
            }
        }
        return ProviderRows(conversation, image, video)
    }

    /**
     * Decodes ONE real `config.catalog.search` completed page.
     *
     * The native domain returns ConfigPageComposer rows of the ORIGINAL
     * `ProviderCatalogEntry` Codable shape (`presetID, name, aliases, kind,
     * defaultProtocol, baseURL, domains, models, availability,
     * unsupportedReason, upstreamID, authStyle, toolNameCompatibility,
     * serviceOffers, modelMetadata`) and the G02 binder delivers that LIST as
     * the frozen OBJECT `{"rows":[...]}`. Anything else (including the old
     * authored `officialProviders/presets` document and a bare array) is a
     * decode failure — never an empty-success substitute.
     */
    fun decodeCatalogRows(value: JsonElement): List<OfficialSupplierUi>? {
        val rows = (value as? JsonObject)?.get("rows") as? JsonArray ?: return null
        return rows.mapNotNull { element ->
            (element as? JsonObject)?.let { decodeCatalogEntry(it) }
        }
    }

    /** Closed catalog payload: the native router allows exactly these keys
     *  (plus the authorized OPTIONAL continuation for paging). */
    fun catalogRequestPayload(filter: String, cursor: String? = null): JsonObject =
        JsonObject(buildMap {
            put("query", JsonPrimitive(""))
            put("filter", JsonPrimitive(filter))
            if (cursor != null) put("cursor", JsonPrimitive(cursor))
        })

    /** Closed providers-list payload (original snapshot operation + the
     *  authorized OPTIONAL bounded continuation cursor). */
    fun providerListPayload(cursor: String? = null): JsonObject = JsonObject(buildMap {
        put("operation", JsonPrimitive("snapshot"))
        if (cursor != null) put("cursor", JsonPrimitive(cursor))
    })

    /** Legacy closed models-list payload (UNCHANGED behavior): first page
     *  carries NO payload; a continuation carries ONLY the composer cursor
     *  member. The additive full-row `modelRead` opt-in grammar is owned
     *  by ModelPageReadController (the only upgraded models reader), so
     *  this helper intentionally does not grow a second wire shape. */
    fun modelsListPayload(cursor: String?): JsonObject? = cursor?.let {
        JsonObject(mapOf("cursor" to JsonPrimitive(it)))
    }

    /** Rows member of one projected page document (absent = not a page). */
    fun pageRows(value: JsonElement): List<JsonElement>? =
        ((value as? JsonObject)?.get("rows") as? JsonArray)?.toList()
        // A bare ARRAY carrier (pre-projection bytes at the facade boundary)
        // is also a complete row list for in-process readers.
            ?: (value as? JsonArray)?.toList()

    /** One projected page's continuation metadata. Absent keys read as a
     *  single complete page (never an invented continuation). */
    data class PageMeta(val nextCursor: String?, val hasMore: Boolean)

    fun pageMeta(value: JsonElement?): PageMeta? {
        val obj = value as? JsonObject ?: return null
        val next = (obj["nextCursor"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val hasMore = (obj["hasMore"] as? JsonPrimitive)?.booleanOrNull ?: false
        return PageMeta(next, hasMore)
    }

    /** One catalog row -> the presentation entry (null when malformed). */
    fun catalogEntryOf(element: JsonElement): OfficialSupplierUi? =
        (element as? JsonObject)?.let { decodeCatalogEntry(it) }

    /** presetID -> REAL ProviderKind raw, straight from one catalog page. */
    fun catalogKinds(value: JsonElement): Map<String, String> {
        val rows = (value as? JsonObject)?.get("rows") as? JsonArray ?: return emptyMap()
        val kinds = LinkedHashMap<String, String>()
        for (element in rows) {
            val obj = element as? JsonObject ?: continue
            val presetID = obj.string("presetID") ?: continue
            val kind = obj.string("kind") ?: continue
            kinds[presetID] = kind
        }
        return kinds
    }

    private fun decodeCatalogEntry(obj: JsonObject): OfficialSupplierUi? {
        val presetID = obj.string("presetID") ?: return null
        val name = obj.string("name") ?: return null
        val protocol = WireProtocolUi.entries
            .firstOrNull { it.swiftRaw == obj.string("defaultProtocol") }
            ?: WireProtocolUi.OPENAI_CHAT_COMPLETIONS
        val baseURL = obj.string("baseURL")
        val endpointHost = runCatching { java.net.URI(baseURL ?: "") }.getOrNull()?.host
        val kind = obj.string("kind") ?: "custom"
        val offered = (obj["serviceOffers"] as? JsonArray).orEmpty().mapNotNull { element ->
            (element as? JsonObject)?.string("role")
        }
        val roles = LinkedHashSet<ProviderServiceRoleUi>()
        roles.add(ProviderServiceRoleUi.CONVERSATION)
        for (raw in offered) {
            ProviderServiceRoleUi.entries.firstOrNull { it.swiftRaw == raw }?.let(roles::add)
        }
        val models = (obj["models"] as? JsonArray).orEmpty()
            .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        return OfficialSupplierUi(
            catalogEntryId = presetID,
            name = name,
            aliases = (obj["aliases"] as? JsonArray).orEmpty()
                .mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
            defaultProtocol = protocol,
            kindPresetName = name,
            endpointHost = endpointHost,
            endpointAbsoluteString = baseURL,
            routeFamily = "",
            authStyle = obj.string("authStyle") ?: "",
            modelCount = models.size,
            modelKeywords = models,
            availability = if (obj.string("availability") == "unsupported") {
                com.floe.android.feature.providers.SupplierAvailabilityUi.UNSUPPORTED
            } else {
                com.floe.android.feature.providers.SupplierAvailabilityUi.SUPPORTED
            },
            unsupportedReason = obj.string("unsupportedReason"),
            servedRoles = roles.toList(),
            isLocalEndpoint = kind == "local",
            isConfigured = false,
            suggestsToolNameCompatibility = obj.bool("toolNameCompatibility") ?: false,
        )
    }

    private fun decodeOfficialSupplier(obj: JsonObject): OfficialSupplierUi? {
        val id = obj.string("catalogEntryId") ?: obj.string("id") ?: return null
        val name = obj.string("name") ?: return null
        val protocols = (obj["supportedProtocols"] as? JsonArray)
            ?.mapNotNull { proto ->
                val raw = (proto as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                WireProtocolUi.entries.firstOrNull { it.swiftRaw == raw }
            }
            ?: WireProtocolUi.entries.toList()
        val defaultProtocol = WireProtocolUi.entries
            .firstOrNull { it.swiftRaw == obj.string("defaultProtocol") }
            ?: protocols.firstOrNull()
            ?: WireProtocolUi.OPENAI_CHAT_COMPLETIONS
        return OfficialSupplierUi(
            catalogEntryId = id,
            name = name,
            aliases = (obj["aliases"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            defaultProtocol = defaultProtocol,
            kindPresetName = obj.string("kindPresetName") ?: name,
            endpointHost = obj.string("endpointHost"),
            endpointAbsoluteString = obj.string("endpointAbsoluteString"),
            routeFamily = obj.string("routeFamily") ?: "",
            authStyle = obj.string("authStyle") ?: "",
            modelCount = obj.long("modelCount")?.toInt() ?: 0,
            modelKeywords = (obj["modelKeywords"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            availability = if (obj.string("availability") == "unsupported") {
                com.floe.android.feature.providers.SupplierAvailabilityUi.UNSUPPORTED
            } else {
                com.floe.android.feature.providers.SupplierAvailabilityUi.SUPPORTED
            },
            unsupportedReason = obj.string("unsupportedReason"),
            servedRoles = (obj["servedRoles"] as? JsonArray)
                ?.mapNotNull { role ->
                    val raw = (role as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                    ProviderServiceRoleUi.entries.firstOrNull { it.swiftRaw == raw }
                } ?: listOf(ProviderServiceRoleUi.CONVERSATION),
            isLocalEndpoint = obj.bool("isLocalEndpoint") ?: false,
            isConfigured = obj.bool("isConfigured") ?: false,
            suggestsToolNameCompatibility = obj.bool("suggestsToolNameCompatibility") ?: false,
        )
    }

    private fun decodePreset(obj: JsonObject): SupplierPresetUi? {
        val id = obj.string("presetId") ?: return null
        val protocols = (obj["supportedProtocols"] as? JsonArray)
            ?.mapNotNull { proto ->
                val raw = (proto as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                WireProtocolUi.entries.firstOrNull { it.swiftRaw == raw }
            }
            ?: WireProtocolUi.entries.toList()
        return SupplierPresetUi(
            presetId = id,
            displayName = obj.string("displayName") ?: id,
            defaultProtocol = WireProtocolUi.entries
                .firstOrNull { it.swiftRaw == obj.string("defaultProtocol") }
                ?: protocols.firstOrNull() ?: WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            supportedProtocols = protocols,
            defaultEndpointHost = obj.string("defaultEndpointHost"),
            defaultEndpointAbsoluteString = obj.string("defaultEndpointAbsoluteString") ?: "",
            defaultEndpointSchemeIsHttp = obj.bool("defaultEndpointSchemeIsHttp") ?: false,
            routeFamily = obj.string("routeFamily") ?: "",
            authStyle = obj.string("authStyle") ?: "",
            isCustom = obj.bool("isCustom") ?: false,
        )
    }

    fun offersForRole(row: ProviderListRowUi, role: ProviderServiceRoleUi): List<ServiceOfferUi> =
        // The saved row carries its enabled roles; separate-offer wiring is
        // holder-driven. Media roles only appear when the provider serves
        // them (wire `serviceRoles`, decoded above).
        emptyList()

    fun officialMediaModels(
        catalog: SupplierCatalogUiState,
        role: ProviderServiceRoleUi,
    ): List<OfficialMediaModelUi> = if (role != ProviderServiceRoleUi.CONVERSATION) {
        catalog.officialProviders
            .filter { it.servedRoles.contains(role) }
            .flatMap { supplier ->
                supplier.modelKeywords.take(4).map { keyword ->
                    OfficialMediaModelUi(
                        displayName = keyword,
                        remoteModelID = keyword,
                        template = ModelDraftRowUi(
                            draftModelId = "official-${supplier.catalogEntryId}-$keyword",
                            savedModelId = null,
                            remoteModelID = keyword,
                            displayName = keyword,
                            enabled = true,
                            hiddenFromPrimaryPicker = false,
                            capabilities = when (role) {
                                ProviderServiceRoleUi.CONVERSATION ->
                                    setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS)
                                ProviderServiceRoleUi.IMAGE ->
                                    setOf(ModelCapabilityUi.IMAGE_GENERATION)
                                ProviderServiceRoleUi.VIDEO ->
                                    setOf(ModelCapabilityUi.VIDEO_GENERATION)
                            },
                            verifiedVision = role != ProviderServiceRoleUi.CONVERSATION,
                        ),
                    )
                }
            }
    } else {
        emptyList()
    }

    /**
     * The EXACT native `ProviderSaveCandidate` JSON (RuntimeFacadeConfigIngress
     * .ProviderSaveCandidate.allowedKeys). The previous payload used a role
     * string as `kind`, a STRING for `nonSecretHeaders`, an ARRAY for
     * `managedCapabilities`, partial model rows and a non-UUID id — every one
     * of which the closed native parser refuses. The candidate stays
     * secret-free (the credential travels only through the one-shot ingress
     * token in `secretIntent:"set"`).
     */
    /**
     * The EXACT native `ProviderSaveCandidate` JSON
     * (RuntimeFacadeConfigIngress.ProviderSaveCandidate.allowedKeys). The
     * previous payload used a role string as `kind`, a STRING for
     * `nonSecretHeaders`, an ARRAY for `managedCapabilities`, partial model
     * rows and a non-UUID id — every one of which the closed native parser
     * refuses. The candidate stays secret-free (the credential travels only
     * through the one-shot ingress token in `secretIntent:"set"`).
     *
     * [providerID]/[kind]/[createIntent] are the controller's REAL resolved
     * identity (existing row UUID or the one minted per new editor; the
     * catalog entry's ProviderKind, else the custom compatible-endpoint kind).
     */
    fun candidateJson(
        providerID: String,
        kind: String,
        createIntent: Boolean,
        draft: ProviderDraftSnapshot,
        modelUUID: (String) -> String,
    ): JsonObject {
        val selected = draft.models.filter { it.selectedForSave }
        val defaultDraftID = draft.defaultModelDraftId
            ?.takeIf { id -> selected.any { it.draftModelId == id } }
        val members = mutableMapOf<String, JsonElement>(
            "id" to JsonPrimitive(providerID),
            "kind" to JsonPrimitive(kind),
            "wireProtocol" to JsonPrimitive(draft.protocol.swiftRaw),
            "baseURL" to JsonPrimitive(draft.baseUrl),
            "displayName" to JsonPrimitive(draft.displayName),
            "isEnabled" to JsonPrimitive(draft.enabled),
            "allowsPlainHTTP" to JsonPrimitive(draft.allowsPlainHttp),
            "toolNameCompatibility" to JsonPrimitive(draft.toolNameCompatibility),
            // Local-sync is refused typed by the native contract; ordinary
            // Android saves are local-only truth.
            "syncEnabled" to JsonPrimitive(false),
            "serviceRoleIsConversation" to JsonPrimitive(
                draft.role == ProviderServiceRoleUi.CONVERSATION),
            "selectedModels" to JsonArray(
                selected.map { modelProfileJson(providerID, it, modelUUID) }),
            "managedCapabilities" to JsonPrimitive(managedCapabilityBits(selected)),
            "createIntent" to JsonPrimitive(createIntent),
        )
        draft.supplier?.let { members["presetID"] = JsonPrimitive(it.presetId) }
        members["nonSecretHeaders"] = nonSecretHeadersJson(draft.nonSecretHeaders)
        if (defaultDraftID != null) {
            members["defaultModelID"] = JsonPrimitive(modelUUID(defaultDraftID))
        }
        return JsonObject(members)
    }

    /** Closed persisted header OBJECT -> "Header: value" editor lines. */
    fun headerLines(headers: JsonObject?): String =
        headers.orEmpty().entries.joinToString("\n") { (name, value) ->
            val text = (value as? JsonPrimitive)?.contentOrNull ?: ""
            "$name: $text"
        }

    /**
     * The exact closed save candidate for a trusted-host DRAFT probe: the
     * SAME builder (`candidateJson`) and the SAME closed grammar a real save
     * uses, built from the live editor probe fields (endpoint, protocol,
     * permitted headers, plain-http/tool-name flags) plus the persisted
     * identity/preset/kind context. Nothing is persisted by the probe; the
     * candidate only carries the protocol/auth/model mapping native must
     * validate and dispatch.
     */
    fun draftProbeCandidate(
        providerID: String,
        kind: String,
        role: ProviderServiceRoleUi,
        displayName: String?,
        presetID: String?,
        probe: ConnectionProbeUi,
    ): JsonObject {
        val headers = probe.nonSecretHeaders.entries.joinToString("\n") {
            "${it.key}: ${it.value}"
        }
        val draft = ProviderDraftSnapshot(
            role = role,
            enabled = true,
            displayName = displayName ?: "",
            supplier = presetID?.let {
                supplierChoiceFor(
                    presetID = it,
                    displayName = it,
                    endpoint = probe.endpointAbsoluteString,
                )
            },
            protocol = probe.wireProtocol,
            baseUrl = probe.endpointAbsoluteString,
            nonSecretHeaders = headers,
            allowsPlainHttp = probe.allowsPlainHttp,
            toolNameCompatibility = probe.toolNameCompatibility,
            models = emptyList(),
            defaultModelDraftId = null,
        )
        return candidateJson(
            providerID = providerID,
            kind = kind,
            createIntent = false,
            draft = draft,
            modelUUID = { UUID.randomUUID().toString() },
        )
    }

    /**
     * The closed save-candidate form for a STAGED large profile: the
     * EXACT scalar fields of [candidateJson] (same builder output — same
     * managedCapabilities fold, same defaultModelID identity), with
     * `selectedModels` replaced by the frozen immutable staged-set
     * reference. Exactly one representation — the native parser refuses
     * both forms or neither, before any effect. Row-level codec
     * equivalence is guaranteed because the staged rows ARE the same
     * JSON objects a small profile would have inlined (the caller passes
     * the built candidate), and the reference itself is an opaque ASCII
     * identity + canonical digest produced by the trusted host seam.
     */
    fun stagedCandidateJson(candidate: JsonObject, modelSetRef: String): JsonObject =
        JsonObject(candidate.toMutableMap().apply {
            remove("selectedModels")
            put("modelSetRef", JsonPrimitive(modelSetRef))
        })

    /** "Header: value" lines -> the closed OBJECT the native parser accepts. */
    private fun nonSecretHeadersJson(raw: String): JsonObject {
        val headers = LinkedHashMap<String, JsonElement>()
        raw.lineSequence().forEach { line ->
            val trimmed = line.trim()
            if (trimmed.isEmpty()) return@forEach
            val separator = trimmed.indexOf(':')
            if (separator <= 0) return@forEach
            val name = trimmed.substring(0, separator).trim()
            val value = trimmed.substring(separator + 1).trim()
            if (name.isNotEmpty()) headers[name] = JsonPrimitive(value)
        }
        return JsonObject(headers)
    }

    /**
     * Full ORIGINAL `ModelProfile` JSON for the candidate (the native parser
     * decodes it through ConfigModelSnapshot). Capability bits, limits and
     * reasoning effort map onto their exact Swift raw values; nothing is
     * invented for a model the user did not stage.
     */
    private fun modelProfileJson(
        providerID: String,
        model: ModelDraftRowUi,
        modelUUID: (String) -> String,
    ): JsonObject {
        val saved = model.savedMetadata
        val representedBits = ModelCapabilityUi.entries.fold(0) { bits, item -> bits or item.swiftBit }
        // Keep persisted bits the pinned presentation does not expose.
        val capabilities = capabilityBits(effectiveCapabilities(model)) or
            ((saved?.capabilitiesRaw ?: 0) and representedBits.inv())
        val fields = mutableMapOf<String, JsonElement>(
            "id" to JsonPrimitive(modelUUID(model.draftModelId)),
            "providerID" to JsonPrimitive(providerID),
            "remoteModelID" to JsonPrimitive(model.remoteModelID),
            "displayName" to JsonPrimitive(model.displayName.ifBlank { model.remoteModelID }),
            "limits" to JsonObject(mapOf(
                "contextTokens" to JsonPrimitive(model.contextTokens),
                "maxOutputTokens" to JsonPrimitive(model.maxOutputTokens),
            )),
            "capabilities" to JsonPrimitive(capabilities),
            "isEnabled" to JsonPrimitive(model.enabled),
            "isHiddenFromPrimaryPicker" to JsonPrimitive(model.hiddenFromPrimaryPicker),
        )
        val oldReasoning = ReasoningEffortUi.entries.firstOrNull {
            it.swiftRaw == saved?.reasoningEffortRaw
        } ?: ReasoningEffortUi.AUTOMATIC
        if (saved == null || model.reasoningEffort != oldReasoning) {
            fields["reasoningEffort"] = JsonPrimitive(model.reasoningEffort.swiftRaw)
        } else {
            saved.reasoningEffortRaw?.let { fields["reasoningEffort"] = JsonPrimitive(it) }
        }
        // Values originate from JsonElement.toString() on the real saved
        // projection. Preserve exact decimal JSON and optional-zero intent.
        saved?.pricingJSON?.let { fields["pricing"] = Json.parseToJsonElement(it) }
        saved?.useSurfacesJSON?.let { fields["useSurfaces"] = Json.parseToJsonElement(it) }
        val editable = listOf(ModelCapabilityUi.VISION, ModelCapabilityUi.TOOLS,
            ModelCapabilityUi.IMAGE_GENERATION, ModelCapabilityUi.IMAGE_EDITING,
            ModelCapabilityUi.VIDEO_GENERATION).fold(0) { bits, item -> bits or item.swiftBit }
        val changed = saved?.capabilitiesRaw?.let { (it xor capabilities) and editable } ?: 0
        if (changed != 0) {
            fields["explicitCapabilities"] = JsonPrimitive((saved?.explicitCapabilitiesRaw ?: 0) or changed)
        } else {
            saved?.explicitCapabilitiesJSON?.let { fields["explicitCapabilities"] = Json.parseToJsonElement(it) }
        }
        return JsonObject(fields)
    }

    private fun effectiveCapabilities(model: ModelDraftRowUi): Set<ModelCapabilityUi> =
        if (model.capabilities.isEmpty() && model.savedModelId == null && model.savedMetadata == null) {
            setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL)
        } else model.capabilities

    private fun capabilityBits(capabilities: Set<ModelCapabilityUi>): Int =
        capabilities.fold(0) { bits, capability -> bits or capability.swiftBit }

    private fun managedCapabilityBits(models: List<ModelDraftRowUi>): Int =
        models.fold(0) { bits, model -> bits or capabilityBits(effectiveCapabilities(model)) }

    fun probePayload(probe: ConnectionProbeUi, token: String, discovery: Boolean = false): JsonObject {
        val members = mutableMapOf<String, JsonElement>(
            "operation" to JsonPrimitive(if (discovery) "discover" else "probe"),
            "endpoint" to JsonPrimitive(probe.endpointAbsoluteString),
            "wireProtocol" to JsonPrimitive(probe.wireProtocol.swiftRaw),
            "allowsPlainHTTP" to JsonPrimitive(probe.allowsPlainHttp),
            "toolNameCompatibility" to JsonPrimitive(probe.toolNameCompatibility),
            "nonSecretHeaders" to JsonPrimitive(
                probe.nonSecretHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" }),
        )
        if (token != "no-credential") {
            members["ingressToken"] = JsonPrimitive(token)
        }
        return JsonObject(members)
    }

    fun discoveredCount(value: JsonElement): Int =
        ((value as? JsonObject)?.get("discoveredModels") as? JsonArray)?.size ?: 0

    /** Terminal status of a settled draft-probe payload. */
    fun statusOf(payload: JsonObject): String? = payload.string("status")

    /** Redacted typed failure identifier (never a raw provider body or key). */
    fun failureOf(payload: JsonObject): String? =
        payload.string("errorCode") ?: payload.string("failureReason")

    fun decodeDiscoveredModels(value: JsonElement): List<ModelDraftRowUi> {
        val array = (value as? JsonObject)?.get("discoveredModels") as? JsonArray
            ?: return emptyList()
        return array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val remote = obj.string("remoteModelID") ?: obj.string("id") ?: return@mapNotNull null
            // Native discovery returns ModelProfile: nested limits and a
            // scalar OptionSet. Retain legacy flat/array discovery replies.
            val limits = obj["limits"] as? JsonObject
            val capabilities = when (val raw = obj["capabilities"]) {
                is JsonPrimitive -> raw.longOrNull?.let { bits ->
                    ModelCapabilityUi.entries.filter { bits and it.swiftBit.toLong() != 0L }.toSet()
                }
                is JsonArray -> raw.mapNotNull { bit ->
                    ModelCapabilityUi.entries.firstOrNull { it.swiftBit == bit.intValue() }
                }.toSet()
                else -> null
            } ?: setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS)
            ModelDraftRowUi(
                draftModelId = "discovered-$remote",
                savedModelId = null,
                remoteModelID = remote,
                displayName = obj.string("displayName") ?: remote,
                enabled = obj.bool("enabled") ?: true,
                capabilities = capabilities,
                contextTokens = (limits?.long("contextTokens") ?: obj.long("contextTokens"))
                    ?.toInt() ?: 128_000,
                maxOutputTokens = (limits?.long("maxOutputTokens") ?: obj.long("maxOutputTokens"))
                    ?.toInt() ?: 0,
                source = com.floe.android.feature.providers.ModelSourceUi.DISCOVERED,
                selectedForSave = true,
            )
        }
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonElement.intValue(): Int? = (this as? JsonPrimitive)?.longOrNull?.toInt()
}

/** Process-wide revision memory for provider rows (identity-only).
 *
 * The native `config.providers.list` projection carries Foundation's
 * UPPERCASE `uuidString` ids, while `existingProviderID` normalizes through
 * `java.util.UUID.toString()` (LOWERCASE). UUID identity is case-insensitive,
 * so the map keys canonicalize to the uppercase form: a case-sensitive miss
 * here made every existing-provider Save fall into the new-provider
 * create/clear branch (the branch is keyed on this lookup). No wire shape,
 * CAS rule or credential authority changed. */
internal object ProviderHostControllerRevisions {
    private val revisions = ConcurrentHashMap<String, HostRevision>()

    private fun key(providerID: String): String = providerID.uppercase()

    fun remember(providerID: String, revision: HostRevision) {
        revisions[key(providerID)] = revision
    }

    fun revision(providerID: String): HostRevision? = revisions[key(providerID)]

}

/** Closed save-intent decision: the branch is chosen from the provider
 * IDENTITY (is this editor editing a persisted row?) plus this editor's
 * frozen baseline revision — never from a live-cache adoption or a
 * missing-lookup fallback. An existing provider whose baseline is
 * unavailable REFUSES fail-closed; it must never degrade into the
 * create/clear branch, and only a genuinely new provider may create. */
internal enum class ProviderSaveIntentBranch {
    SET_EXISTING,
    SET_CREATE,
    KEEP_EXISTING,
    CREATE_WITHOUT_SECRET,
    REFUSE_MISSING_BASELINE,
}

internal fun providerSaveIntentBranch(
    isExistingProvider: Boolean,
    saveBaseline: HostRevision?,
    credentialDraft: String?,
): ProviderSaveIntentBranch = when {
    credentialDraft != null -> when {
        !isExistingProvider -> ProviderSaveIntentBranch.SET_CREATE
        saveBaseline != null -> ProviderSaveIntentBranch.SET_EXISTING
        else -> ProviderSaveIntentBranch.REFUSE_MISSING_BASELINE
    }
    isExistingProvider ->
        if (saveBaseline != null) ProviderSaveIntentBranch.KEEP_EXISTING
        else ProviderSaveIntentBranch.REFUSE_MISSING_BASELINE
    else -> ProviderSaveIntentBranch.CREATE_WITHOUT_SECRET
}
