// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.providers.ConnectionProbeUi
import com.floe.android.feature.providers.ConnectionTestUi
import com.floe.android.feature.providers.ModelCapabilityUi
import com.floe.android.feature.providers.ModelDraftRowUi
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
    private val routeAuthority: HostRouteAuthority = NativeHostRouteAuthority,
) : ProviderUiCallbacks {

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

    /** providerID|draftModelId → the stable ModelProfile UUID used on save. */
    private val modelProfileIDs = ConcurrentHashMap<String, String>()

    /** presetID → REAL ProviderKind raw from the catalog page only. */
    private val catalogKinds = ConcurrentHashMap<String, String>()

    /** Editor identity → the native-issued `rt:v1:` host route handle. */
    private val editorRouteTokens = ConcurrentHashMap<String, String>()

    /** Test seam for the trusted host ingress; production is the frozen seam. */
    internal var secureIngress: HostSecureIngressSubmitter = NativeHostSecureIngressSubmitter

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
        countObservation?.cancel()
        countObservation = null
    }

    /** Last real `config.providers.list` page, kept for count re-projection. */
    private var lastProviderPageValue: JsonElement? = null
    private var lastModelCounts: Map<String, Int> = emptyMap()
    private var countObservation: kotlinx.coroutines.Job? = null

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
                ),
            )
        }
    }

    private fun admitted(): Boolean = host.readiness.value.providerConfigurationAdmitted

    private fun client() = host.commandClient

    private fun networkAvailable(): Boolean = admitted()

    // --------------------------------------------------------- projections

    internal fun refreshProviders() {
        if (!admitted()) return
        host.trackOperation(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID("plist"),
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        ) { outcome -> handleProvidersPage(outcome) }
    }

    private fun loadFailureCopy(): String =
        runCatching {
            host.appContext.getString(com.floe.android.R.string.providers_load_failed)
        }.getOrElse { "Couldn't load your providers. Try again." }

    private fun handleProvidersPage(outcome: HostOperationOutcome) {
        when (outcome) {
            is HostOperationOutcome.Completed -> {
                lastProviderPageValue = outcome.value
                val counts = host.conversations.modelCountsByProvider()
                lastModelCounts = counts
                if (counts.isEmpty()) {
                    // The models page may not have landed yet; the collector
                    // republishes the real counts as soon as it does.
                    host.conversations.refreshModels()
                }
                val rows = outcome.value?.let { ProviderWire.decodeProviderRows(it, counts) }
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
                            errorMessage = if (rows == null) loadFailureCopy() else null,
                        ),
                    )
                }
                // The provider side of the model join just changed: republish
                // the composer projection AFTER the destination carries the
                // new rows (no second catalog read).
                host.conversations.republishModelProjection()
            }
            is HostOperationOutcome.Rejected -> {
                // Detailed typed code stays in diagnostics; the ordinary UI
                // shows natural bilingual copy only.
                // Diagnostic only; wrapped so a host-unit environment without
                // the Android Log service can never cancel the host scope.
                runCatching {
                    android.util.Log.w("FloeProviders", "list_rejected:${outcome.code}")
                }
                updateDestination { it.copy(list = it.list.copy(isLoading = false,
                    errorMessage = loadFailureCopy())) }
            }
            is HostOperationOutcome.Failed -> {
                runCatching {
                    android.util.Log.w("FloeProviders", "list_failed:${outcome.code}")
                }
                updateDestination { it.copy(list = it.list.copy(isLoading = false,
                    errorMessage = loadFailureCopy())) }
            }
            HostOperationOutcome.Cancelled,
            HostOperationOutcome.Superseded -> Unit
        }
    }

    internal fun refreshCatalog() {
        if (!admitted()) return
        updateDestination {
            it.copy(catalog = catalogWithCustom(it.catalog).copy(refreshInFlight = true))
        }
        // REAL contract (RuntimeFacadeConfig.catalogSearch + RB2 router):
        // payload is CLOSED to {"query","filter"} and the completed page is
        // the ConfigPageComposer list, delivered as the {"rows":[...]} OBJECT
        // by the G02 binder boundary. The old {"operation":"catalog.refresh"}
        // payload was refused as invalidEnvelope/catalogQueryMissing, which is
        // why the chooser always showed an empty catalog.
        submitCatalogPage(filter = "all") { entries ->
            if (entries == null) {
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
                return@submitCatalogPage
            }
            // Marks come from the SERVER-SIDE configured filter page — the App
            // never guesses which saved rows map to presets.
            submitCatalogPage(filter = "configured") { configuredEntries ->
                val configured = configuredEntries
                    ?.mapNotNull { it.catalogEntryId }?.toSet() ?: emptySet()
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

    /** ONE real catalog page through the canonical command (closed payload). */
    private fun submitCatalogPage(
        filter: String,
        onPage: (List<OfficialSupplierUi>?) -> Unit,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "config.catalog.search",
                scope = HostScope.ApplicationConfiguration("catalog"),
                stateful = false,
                correlationID = client().correlationID("cat"),
                payload = ProviderWire.catalogRequestPayload(filter),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val value = outcome.value
                    if (value != null) {
                        catalogKinds.putAll(ProviderWire.catalogKinds(value))
                    }
                    // A typed domain refusal body (errorCode) is NOT a page.
                    onPage(value?.let { ProviderWire.decodeCatalogRows(it) })
                }
                else -> onPage(null)
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
        // The frozen `config.provider.save` vocabulary is exactly set/keep/
        // clear with a COMPLETE closed candidate (the previous `enabled.set`
        // intent was never part of it and was refused `providerSaveIntentUnknown`).
        // A bare row summary cannot form that candidate faithfully: the real
        // candidate also carries serviceRoleIsConversation / managedCapabilities
        // / the exact persisted model set, which only the provider editor's
        // loaded draft holds. Until a native metadata-only enable command (or a
        // full-candidate read) exists, this list toggle must not fabricate a
        // partial candidate: it refuses locally and the refreshed list row
        // keeps showing the real persisted state. Open the provider editor to
        // change enablement through its real Keep save.
        return false
    }

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
     * summary + `config.models.list` rows). Nothing is invented: the identity,
     * protocol, endpoint, enablement, custom-endpoint flags and the complete
     * saved model set (including disabled rows, with their canonical UUIDs)
     * come from the persisted values.
     *
     * Known frozen-read gap: `ConfigProviderSummary` does not expose
     * `nonSecretHeaders` (or `presetID`), so a custom header set cannot be
     * reconstructed. The draft carries no header text; a Keep save from this
     * editor therefore cannot preserve headers that were never readable in
     * this build. The exact missing metadata is reported in the handoff for a
     * bounded native read-projection addition; no destructive blank rewrite is
     * performed by this projection itself.
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
        val extras = ProviderWire.extrasFor(providerID)
        val protocol = WireProtocolUi.entries.firstOrNull {
            it.swiftRaw == extras?.wireProtocol
        } ?: WireProtocolUi.OPENAI_CHAT_COMPLETIONS
        val savedModels = host.conversations.modelRowsForProvider(providerID)
        val draftModels = savedModels.map { model ->
            ModelDraftRowUi(
                // The staging key is the SAVED identity so the save path can
                // keep the canonical ModelProfile UUID (see [modelUUIDFor]).
                draftModelId = model.id,
                savedModelId = model.id,
                remoteModelID = model.remoteModelId,
                displayName = model.displayName,
                enabled = model.isEnabled,
                hiddenFromPrimaryPicker = model.isHiddenFromPrimaryPicker,
                capabilities = ProviderWire.capabilitiesOf(model.capabilitiesRaw),
                reasoningEffort = ReasoningEffortUi.entries.firstOrNull {
                    it.swiftRaw == model.reasoningEffort
                } ?: ReasoningEffortUi.AUTOMATIC,
                contextTokens = model.contextTokens,
                maxOutputTokens = model.maxOutputTokens,
                source = com.floe.android.feature.providers.ModelSourceUi.SAVED,
                selectedForSave = true,
            )
        }
        val defaultModelID = host.conversations.defaultAgentModelIdFor(providerID)
            ?.takeIf { id -> draftModels.any { it.savedModelId == id } }
        val snapshot = ProviderDraftSnapshot(
            role = role,
            enabled = row.enabled,
            displayName = row.displayName,
            // presetID is not part of the frozen summary; an existing row
            // keeps "no preset" rather than claiming a catalog entry.
            supplier = null,
            protocol = protocol,
            baseUrl = row.endpointSummary,
            nonSecretHeaders = "",
            allowsPlainHttp = extras?.allowsPlainHTTP ?: false,
            toolNameCompatibility = extras?.toolNameCompatibility ?: false,
            models = draftModels,
            defaultModelDraftId = defaultModelID,
            offerDecisions = emptyMap(),
        )
        val catalog = destinationState.value.catalog
        return ProviderEditorSeedUi(
            snapshot = snapshot,
            credentialState = row.credentialState,
            availableProtocols = WireProtocolUi.entries.toList(),
            discoverySupported = role == ProviderServiceRoleUi.CONVERSATION,
            offers = ProviderWire.offersForRole(row, role),
            officialMediaModels = ProviderWire.officialMediaModels(catalog, role),
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
        // Epoch fencing is holder-owned; the host resets attempt metadata.
        saveFailureSequencer.reset(identity.editorId, identity.epoch)
        if (identity.editorId.startsWith("new")) {
            // ONE stable provider identity for every save attempt of this
            // editor (the native candidate requires a real UUID).
            newProviderIDs.putIfAbsent(identity.editorId, UUID.randomUUID().toString())
        }
        // Publish the editor projection so the form leaves the
        // "Loading configuration…" placeholder. Values come from the REAL
        // seed (saved rows + catalog offers); mutations keep transforming
        // this projection through publishEditor().
        val seed = seedEditorFor(identity.role, existingProviderID(identity))
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
        // addressed to this identity are fenced by the identity epoch check.
        inFlightTests.remove(identity.editorId)
        inFlightDiscoveries.remove(identity.editorId)
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
        val existingRevision = existingProviderID(identity)
            ?.let { ProviderHostControllerRevisions.revision(it) }
        // One-shot credential ingress; the RAM draft is consumed here and
        // never retained, logged or placed in any error or public JSON.
        var ingressToken: String? = null
        if (credentialDraft != null) {
            ingressToken = submitBoundProviderIntent(identity, providerID, candidate,
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
                        "candidate" to candidate,
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
                        "candidate" to candidate,
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
                    providerID?.let { id ->
                        flowHolder.currentEditorIdentity()?.takeIf { current ->
                            current.isCurrentFor(identity)
                        }
                    }
                }
                is HostOperationOutcome.Rejected ->
                    onSaveFailed(identity, SaveFailurePhaseUi.PREFLIGHT, outcome.code)
                is HostOperationOutcome.Failed ->
                    onSaveFailed(identity, SaveFailurePhaseUi.LOCAL_COMMIT, outcome.code)
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
        publishEditor(identity) {
            it.copy(
                saveInFlight = false,
                saveError = message,
                saveOutcome = SaveOutcomeUi.Failed(phase, message),
                saveFailureSequence = sequence,
            )
        }
        flowHolder.applyHostSaveOutcome(identity, SaveOutcomeUi.Failed(phase, message))
        flowHolder.noteSaveAttemptFinished(identity)
    }

    override fun testConnection(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        if (!admitted()) return false
        // The frozen public probe contract is `config.provider.probe` with a
        // closed `{providerID}`: the ACTUAL persisted profile + its stored
        // typed credential. There is no unsaved-draft probe API, so a new or
        // dirty draft must never be tested against an old saved profile/key
        // (that would imply the draft was verified). The host reports the
        // honest save-before-test limitation instead.
        val providerID = probeTargetProviderID(identity, probe)
        if (providerID == null) {
            publishEditor(identity) {
                it.copy(testState = ConnectionTestUi.Failed(
                    host.appContext.getString(com.floe.android.R.string.providers_probe_requires_save)))
            }
            return true
        }
        inFlightTests[identity.editorId] = providerID
        publishEditor(identity) { it.copy(testState = ConnectionTestUi.Testing) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.provider.probe",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID("pprobe"),
                payload = JsonObject(mapOf("providerID" to JsonPrimitive(providerID))),
            ),
        ) { outcome ->
            inFlightTests.remove(identity.editorId)
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val count = outcome.value?.let { ProviderWire.discoveredCount(it) } ?: 0
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Succeeded(count))
                    }
                }
                is HostOperationOutcome.Rejected ->
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Failed(outcome.code))
                    }
                is HostOperationOutcome.Failed ->
                    publishEditor(identity) {
                        it.copy(testState = ConnectionTestUi.Failed(outcome.code))
                    }
                HostOperationOutcome.Cancelled -> publishEditor(identity) {
                    it.copy(testState = ConnectionTestUi.Idle)
                }
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    override fun cancelConnectionTest(identity: ProviderEditorIdentity) {
        inFlightTests.remove(identity.editorId)
        publishEditor(identity) { it.copy(testState = ConnectionTestUi.Idle) }
    }

    override fun discoverModels(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        if (!admitted()) return false
        val providerID = probeTargetProviderID(identity, probe)
        if (providerID == null) {
            publishEditor(identity) {
                it.copy(testState = ConnectionTestUi.Failed(
                    host.appContext.getString(com.floe.android.R.string.providers_probe_requires_save)))
            }
            return true
        }
        inFlightDiscoveries[identity.editorId] = providerID
        host.trackOperation(
            HostCommandRequest(
                command = "config.provider.probe",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID("pdisc"),
                payload = JsonObject(mapOf("providerID" to JsonPrimitive(providerID))),
            ),
        ) { outcome ->
            inFlightDiscoveries.remove(identity.editorId)
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val models = outcome.value?.let { ProviderWire.decodeDiscoveredModels(it) }
                        ?: emptyList()
                    flowHolder.mergeHostCandidateModels(identity, models)
                }
                is HostOperationOutcome.Rejected, is HostOperationOutcome.Failed -> Unit
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    override fun cancelModelDiscovery(identity: ProviderEditorIdentity) {
        inFlightDiscoveries.remove(identity.editorId)
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

    /** ConfigProviderSummary members the App needs but the list row UI omits. */
    data class ProviderExtras(
        val kind: String,
        val wireProtocol: String,
        val allowsPlainHTTP: Boolean,
        val toolNameCompatibility: Boolean,
        val displayName: String,
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
     */
    fun decodeModelRows(value: JsonElement): List<ModelRow>? {
        val rows = (value as? JsonObject)?.get("rows") as? JsonArray ?: return null
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
            )
        }
    }

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
            val displayName = obj.string("displayName") ?: id
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
                    displayName = displayName,
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

    /** Closed catalog payload: the native router allows exactly these keys. */
    fun catalogRequestPayload(filter: String): JsonObject = JsonObject(
        mapOf(
            "query" to JsonPrimitive(""),
            "filter" to JsonPrimitive(filter),
        ),
    )

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
        val capabilities = effectiveCapabilities(model)
        return JsonObject(
            mapOf(
                "id" to JsonPrimitive(modelUUID(model.draftModelId)),
                "providerID" to JsonPrimitive(providerID),
                "remoteModelID" to JsonPrimitive(model.remoteModelID),
                "displayName" to JsonPrimitive(model.displayName.ifBlank { model.remoteModelID }),
                "limits" to JsonObject(
                    mapOf(
                        "contextTokens" to JsonPrimitive(model.contextTokens),
                        "maxOutputTokens" to JsonPrimitive(model.maxOutputTokens),
                    ),
                ),
                "capabilities" to JsonPrimitive(capabilityBits(capabilities)),
                "reasoningEffort" to JsonPrimitive(model.reasoningEffort.swiftRaw),
                "isEnabled" to JsonPrimitive(model.enabled),
                "isHiddenFromPrimaryPicker" to JsonPrimitive(model.hiddenFromPrimaryPicker),
            ),
        )
    }

    /** A chat model with no explicit user bits starts text+tool capable (the
     *  ORIGINAL defaultTextModel contract), never zero capabilities. */
    private fun effectiveCapabilities(model: ModelDraftRowUi): Set<ModelCapabilityUi> =
        model.capabilities.ifEmpty {
            setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS, ModelCapabilityUi.APPROVAL)
        }

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

    fun decodeDiscoveredModels(value: JsonElement): List<ModelDraftRowUi> {
        val array = (value as? JsonObject)?.get("discoveredModels") as? JsonArray
            ?: return emptyList()
        return array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val remote = obj.string("remoteModelID") ?: obj.string("id") ?: return@mapNotNull null
            val capabilities = (obj["capabilities"] as? JsonArray)
                ?.mapNotNull { bit ->
                    ModelCapabilityUi.entries.firstOrNull { it.swiftBit.toInt() == bit.intValue() }
                }?.toSet()
                ?: setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS)
            ModelDraftRowUi(
                draftModelId = "discovered-$remote",
                savedModelId = null,
                remoteModelID = remote,
                displayName = obj.string("displayName") ?: remote,
                enabled = obj.bool("enabled") ?: true,
                capabilities = capabilities,
                contextTokens = obj.long("contextTokens")?.toInt() ?: 0,
                maxOutputTokens = obj.long("maxOutputTokens")?.toInt() ?: 0,
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

/** Process-wide revision memory for provider rows (identity-only). */
internal object ProviderHostControllerRevisions {
    private val revisions = ConcurrentHashMap<String, HostRevision>()
    fun remember(providerID: String, revision: HostRevision) {
        revisions[providerID] = revision
    }

    fun revision(providerID: String): HostRevision? = revisions[providerID]

}
