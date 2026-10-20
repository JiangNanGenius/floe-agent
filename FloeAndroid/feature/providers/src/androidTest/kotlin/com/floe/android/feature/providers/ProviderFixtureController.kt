// SPDX-License-Identifier: MPL-2.0
//
// TEST-ONLY synthetic state for the provider presentation fixture. Every
// profile, endpoint, catalog entry and model below is invented and labelled;
// there is no provider backend, network request, credential store, database or
// production navigation here. The Activity that hosts this controller lives in
// the instrumentation APK and is not exported.

package com.floe.android.feature.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

internal enum class ProviderFixtureScenario {
    EMPTY_LIST,
    POPULATED_LIST,
    LIST_LOADING,
    EDITOR_TOP,
    EDITOR_BOTTOM,
    EDITOR_WAITING_HOST,
    SUPPLIER_ANCHORED,
    PURPOSE_WIDE,
    PURPOSE_WIDE_HOST,
    PURPOSE_WIDE_HOST_COLLAPSED,
    PURPOSE_WIDE_HOST_LARGE_FONT,
    PURPOSE_COMPACT,
    EDITOR_COMPACT,
    EDITOR_LOCKED_PROTOCOL,
    MODEL_MANAGER,
    MODEL_EDITOR,
    SAVE_RETRY,
    SECURE_FIELD,
}

/**
 * One host seam implementation for the fixture: it answers only in-memory
 * synthetic data and records call counts. No call reaches the network, the
 * Keystore, a database or a real provider.
 */
internal class ProviderFixtureHost : ProviderUiCallbacks {
    var saveCalls: Int = 0
        private set
    var testCalls: Int = 0
        private set
    var discoveryCalls: Int = 0
        private set
    var catalogRefreshCalls: Int = 0
        private set
    var requestNewProviderCalls: Int = 0
        private set
    var editorOpenedCalls: Int = 0
        private set

    /**
     * Optional controller hook used by the same-frame retry regression: when
     * armed with [nextSameFrameFailure], [saveProvider] runs the hook
     * synchronously before returning true, so the host's begin and failure
     * projections are both written inside the click dispatch.
     */
    var onSameFrameSaveFailure: ((String) -> Unit)? = null
    var nextSameFrameFailure: String? = null

    fun reset() {
        saveCalls = 0
        testCalls = 0
        discoveryCalls = 0
        catalogRefreshCalls = 0
        requestNewProviderCalls = 0
        editorOpenedCalls = 0
        nextSameFrameFailure = null
    }

    private val syntheticSeed = ProviderEditorSeedUi(
        snapshot = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            enabled = true,
            displayName = "Synthetic Gateway (fixture)",
            supplier = SupplierChoice(
                presetId = "openai",
                displayName = "OpenAI",
                catalogEntryId = null,
                absoluteEndpointDefault = "https://synthetic.invalid/v1",
                routeFamily = "openai",
                authStyle = "bearer",
                supportsPlainHttpChoice = false,
                suggestsToolNameCompatibility = false,
            ),
            protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            baseUrl = "https://synthetic.invalid/v1",
            nonSecretHeaders = "",
            allowsPlainHttp = false,
            toolNameCompatibility = false,
            models = listOf(
                fixtureModel(
                    draftId = "synthetic-draft-model-1",
                    wireId = "synthetic-chat-model-a",
                    name = "Synthetic Chat Model A",
                    selected = true,
                    capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS),
                ),
                fixtureModel(
                    draftId = "synthetic-draft-model-2",
                    wireId = "synthetic-chat-model-b",
                    name = "Synthetic Chat Model B",
                    selected = true,
                    capabilities = setOf(ModelCapabilityUi.TEXT, ModelCapabilityUi.VISION),
                ),
            ),
            defaultModelDraftId = "synthetic-draft-model-1",
        ),
        credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
        availableProtocols = WireProtocolUi.entries,
        discoverySupported = true,
        offers = listOf(
            ServiceOfferUi(
                role = ProviderServiceRoleUi.IMAGE,
                isEnabled = false,
                isUsable = true,
                connection = OfferConnectionUi.SHARED,
                modelCount = 1,
                requiresDiscovery = false,
                discoveryState = ConnectionTestUi.Idle,
                discoveryError = null,
                reason = null,
                note = null,
                canConfigureSeparately = false,
                separateOfferSeed = null,
            ),
        ),
        officialMediaModels = emptyList(),
    )

    override fun openExistingProvider(providerId: String) = Unit

    override fun requestNewProvider(role: ProviderServiceRoleUi) {
        requestNewProviderCalls += 1
    }

    override fun setProviderEnabled(providerId: String, enabled: Boolean): Boolean = true

    override fun deleteProvider(providerId: String): Boolean = true

    override fun seedEditorFor(
        role: ProviderServiceRoleUi,
        existingProviderId: String?,
    ): ProviderEditorSeedUi? = syntheticSeed.copy(snapshot = syntheticSeed.snapshot.copy(role = role))

    override fun seedSeparateOfferEditor(
        seed: SeparateOfferSeedUi,
        role: ProviderServiceRoleUi,
    ): ProviderEditorSeedUi? = seedEditorFor(role, null)

    override fun editorOpened(identity: ProviderEditorIdentity) {
        editorOpenedCalls += 1
    }

    override fun editorClosed(identity: ProviderEditorIdentity, discarded: Boolean) = Unit

    override fun saveProvider(
        identity: ProviderEditorIdentity,
        draft: ProviderDraftSnapshot,
        credentialDraft: String?,
    ): Boolean {
        saveCalls += 1
        nextSameFrameFailure?.let { message ->
            nextSameFrameFailure = null
            onSameFrameSaveFailure?.invoke(message)
        }
        return true
    }

    override fun testConnection(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        testCalls += 1
        return true
    }

    override fun cancelConnectionTest(identity: ProviderEditorIdentity) = Unit

    override fun discoverModels(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
        discoveryCalls += 1
        return true
    }

    override fun cancelModelDiscovery(identity: ProviderEditorIdentity) = Unit

    override fun supplierPresetChosen(preset: SupplierPresetUi) = Unit

    override fun supplierCatalogEntryChosen(entry: OfficialSupplierUi) = Unit

    override fun requestCatalogRefresh(): Boolean {
        catalogRefreshCalls += 1
        return true
    }

    override fun serviceOfferRequiresDiscovery(
        identity: ProviderEditorIdentity,
        role: ProviderServiceRoleUi,
    ): Boolean = false

    override fun requestOfferDiscovery(
        identity: ProviderEditorIdentity,
        role: ProviderServiceRoleUi,
    ): Boolean = true

    override fun offerDecisionChanged(
        identity: ProviderEditorIdentity,
        role: ProviderServiceRoleUi,
        enabled: Boolean,
    ) = Unit

    override fun offerPromptConfirmed(
        identity: ProviderEditorIdentity,
        roles: Set<ProviderServiceRoleUi>,
    ) = Unit

    override fun offerPromptDeclined(identity: ProviderEditorIdentity) = Unit
}

private fun fixtureModel(
    draftId: String,
    wireId: String,
    name: String,
    selected: Boolean,
    capabilities: Set<ModelCapabilityUi>,
) = ModelDraftRowUi(
    draftModelId = draftId,
    savedModelId = "synthetic-saved-$draftId",
    remoteModelID = wireId,
    displayName = name,
    enabled = true,
    hiddenFromPrimaryPicker = false,
    capabilities = capabilities,
    reasoningEffort = ReasoningEffortUi.AUTOMATIC,
    contextTokens = 128_000,
    maxOutputTokens = 8_192,
    source = ModelSourceUi.SAVED,
    selectedForSave = selected,
)

internal class ProviderFixtureController {
    val host = ProviderFixtureHost()
    val holder = ProviderFlowHolder(host)
    val state = mutableStateOf(emptyDestinationState())
    var compact by mutableStateOf(false)
    var scenario: ProviderFixtureScenario by mutableStateOf(ProviderFixtureScenario.EMPTY_LIST)
        private set

    /** Host-harness category visibility; collapsed/folded host uses false. */
    val hostCategoryVisible: Boolean
        get() = scenario != ProviderFixtureScenario.PURPOSE_WIDE_HOST_COLLAPSED

    /** Host-harness large-font override (2x fontScale) for wrapping/scroll. */
    val hostLargeFont: Boolean
        get() = scenario == ProviderFixtureScenario.PURPOSE_WIDE_HOST_LARGE_FONT

    private var identity: ProviderEditorIdentity? = null
    private var availableProtocolsForRun: List<WireProtocolUi> = WireProtocolUi.entries
    private var saveFailureSequence: Long = 0L

    fun currentIdentity(): ProviderEditorIdentity? = identity

    fun currentDraftProtocol(): WireProtocolUi? =
        identity?.let { holder.drafts.slot(it.editorId)?.snapshot?.value?.protocol }

    fun applyScenario(next: ProviderFixtureScenario) {
        scenario = next
        compact = next == ProviderFixtureScenario.PURPOSE_COMPACT ||
            next == ProviderFixtureScenario.EDITOR_COMPACT
        availableProtocolsForRun = when (next) {
            ProviderFixtureScenario.EDITOR_LOCKED_PROTOCOL -> listOf(WireProtocolUi.ANTHROPIC_MESSAGES)
            else -> WireProtocolUi.entries
        }
        holder.closeAll()
        host.reset()
        identity = null
        saveFailureSequence = 0L
        state.value = emptyDestinationState()
        when (next) {
            ProviderFixtureScenario.EMPTY_LIST -> {
                state.value = state.value.copy(list = emptyListState())
            }
            ProviderFixtureScenario.POPULATED_LIST -> {
                state.value = state.value.copy(
                    list = populatedListState().copy(errorMessage = "Synthetic list error (fixture)."),
                )
            }
            ProviderFixtureScenario.LIST_LOADING -> {
                state.value = state.value.copy(
                    list = ProviderListUiState(
                        isLoading = true,
                        conversationProviders = emptyList(),
                    ),
                )
            }
            ProviderFixtureScenario.EDITOR_TOP,
            ProviderFixtureScenario.EDITOR_BOTTOM,
            ProviderFixtureScenario.EDITOR_WAITING_HOST,
            ProviderFixtureScenario.SUPPLIER_ANCHORED,
            ProviderFixtureScenario.PURPOSE_WIDE,
            ProviderFixtureScenario.PURPOSE_WIDE_HOST,
            ProviderFixtureScenario.PURPOSE_WIDE_HOST_COLLAPSED,
            ProviderFixtureScenario.PURPOSE_WIDE_HOST_LARGE_FONT,
            ProviderFixtureScenario.PURPOSE_COMPACT,
            ProviderFixtureScenario.EDITOR_COMPACT,
            ProviderFixtureScenario.EDITOR_LOCKED_PROTOCOL,
            ProviderFixtureScenario.MODEL_MANAGER,
            ProviderFixtureScenario.MODEL_EDITOR,
            ProviderFixtureScenario.SAVE_RETRY,
            ProviderFixtureScenario.SECURE_FIELD,
            -> openEditorForScenario(next)
        }
    }

    fun openSupplierChooser() {
        val current = identity ?: return
        holder.openSupplierChooser(current)
        state.value = state.value.copy(editor = editorProjection(current))
    }

    fun openModelManager() {
        val current = identity ?: return
        holder.openModelManager(current)
        state.value = state.value.copy(editor = editorProjection(current))
    }

    fun openModelEditor() {
        val current = identity ?: return
        val draft = holder.drafts.slot(current.editorId)?.snapshot?.value ?: return
        val first = draft.models.firstOrNull() ?: return
        holder.openModelEditor(current, first.draftModelId)
        state.value = state.value.copy(editor = editorProjection(current))
    }

    fun publishSaveError(message: String) {
        val current = identity ?: return
        saveFailureSequence += 1
        state.value = state.value.copy(
            editor = editorProjection(current).copy(
                saveInFlight = false,
                saveError = message,
                saveFailureSequence = saveFailureSequence,
                saveOutcome = SaveOutcomeUi.Failed(SaveFailurePhaseUi.LOCAL_COMMIT, message),
            ),
        )
    }

    /** Host boundary for a retry: prior error cleared, attempt in flight. */
    fun beginSaveAttempt() {
        val current = identity ?: return
        state.value = state.value.copy(
            editor = editorProjection(current).copy(
                saveInFlight = true,
                saveError = null,
                saveOutcome = null,
            ),
        )
    }

    /**
     * Same-frame retry regression hook: the next accepted save publishes its
     * begin AND failure projections synchronously inside [ProviderFixtureHost.saveProvider].
     * The composition therefore sees only the final (same-message, not
     * in-flight) projection, exactly the coalescing case a real host can
     * produce when local validation rejects a save immediately.
     */
    fun armSameFrameSaveFailure(message: String) {
        host.onSameFrameSaveFailure = {
            beginSaveAttempt()
            publishSaveError(it)
        }
        host.nextSameFrameFailure = message
    }

    /** Connection-path failure: inline context, never the save alert. */
    fun publishConnectionFailure(reason: String) {
        val current = identity ?: return
        state.value = state.value.copy(
            editor = editorProjection(current).copy(
                testState = ConnectionTestUi.Failed(reason),
            ),
        )
    }

    /** Late save failure from an editor that is no longer current. */
    fun publishStaleSaveFailure(staleIdentity: ProviderEditorIdentity, message: String) {
        state.value = state.value.copy(
            editor = editorProjection(staleIdentity).copy(
                saveInFlight = false,
                saveError = message,
                saveOutcome = SaveOutcomeUi.Failed(SaveFailurePhaseUi.LOCAL_COMMIT, message),
            ),
        )
    }

    fun setSecureInput(value: String) {
        val current = identity ?: return
        holder.setSecureInput(current, value)
    }

    private fun openEditorForScenario(next: ProviderFixtureScenario) {
        holder.openRoleChooser()
        if (next == ProviderFixtureScenario.PURPOSE_COMPACT) return
        if (next == ProviderFixtureScenario.PURPOSE_WIDE ||
            next == ProviderFixtureScenario.PURPOSE_WIDE_HOST ||
            next == ProviderFixtureScenario.PURPOSE_WIDE_HOST_COLLAPSED ||
            next == ProviderFixtureScenario.PURPOSE_WIDE_HOST_LARGE_FONT
        ) {
            // Wide purpose menu is opened by the test through the real add
            // action, so this scenario only seeds the list behind it.
            holder.cancelRoleChooser()
            state.value = state.value.copy(
                list = populatedListState(),
                catalog = fixtureCatalog(),
            )
            return
        }
        holder.chooseRole(ProviderServiceRoleUi.CONVERSATION)
        val current = holder.currentEditorIdentity() ?: return
        identity = current
        state.value = state.value.copy(
            list = populatedListState(),
            catalog = fixtureCatalog(),
            editor = editorProjection(current),
        )
        when (next) {
            ProviderFixtureScenario.EDITOR_WAITING_HOST -> {
                state.value = state.value.copy(editor = null)
            }
            ProviderFixtureScenario.EDITOR_LOCKED_PROTOCOL -> {
                holder.setProtocol(current, WireProtocolUi.ANTHROPIC_MESSAGES)
                state.value = state.value.copy(editor = editorProjection(current))
            }
            ProviderFixtureScenario.SUPPLIER_ANCHORED -> holder.openSupplierChooser(current)
            ProviderFixtureScenario.MODEL_MANAGER -> holder.openModelManager(current)
            ProviderFixtureScenario.MODEL_EDITOR -> {
                holder.openModelManager(current)
                val draft = holder.drafts.slot(current.editorId)?.snapshot?.value
                val first = draft?.models?.firstOrNull()
                if (first != null) holder.openModelEditor(current, first.draftModelId)
            }
            else -> Unit
        }
    }

    private fun editorProjection(current: ProviderEditorIdentity) = ProviderEditorUiState(
        identity = current,
        isEditingExisting = true,
        role = current.role,
        credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
        credentialRequirementMessage = null,
        availableProtocols = availableProtocolsForRun,
        testState = ConnectionTestUi.Idle,
        discoverySupported = true,
        offers = listOf(
            ServiceOfferUi(
                role = ProviderServiceRoleUi.IMAGE,
                isEnabled = false,
                isUsable = true,
                connection = OfferConnectionUi.SHARED,
                modelCount = 1,
                requiresDiscovery = false,
                discoveryState = ConnectionTestUi.Idle,
                discoveryError = null,
                reason = null,
                note = null,
                canConfigureSeparately = false,
                separateOfferSeed = null,
            ),
        ),
        pendingOfferPrompt = null,
        saveInFlight = false,
        saveError = null,
        saveFailureSequence = saveFailureSequence,
        saveOutcome = null,
        formMessage = "Synthetic fixture state — no real provider request.",
        fieldIssues = emptyList(),
        hostCandidateModels = emptyList(),
        officialMediaModels = emptyList(),
        networkActionsAvailable = true,
        networkActionsUnavailableReason = null,
    )
}

internal fun emptyDestinationState() = ProviderDestinationState(
    list = emptyListState(),
    catalog = fixtureCatalog(),
    editor = null,
)

internal fun emptyListState() = ProviderListUiState(
    isLoading = false,
    conversationProviders = emptyList(),
    imageProviders = emptyList(),
    videoProviders = emptyList(),
    errorMessage = null,
)

internal fun populatedListState() = ProviderListUiState(
    isLoading = false,
    conversationProviders = listOf(
        ProviderListRowUi(
            providerId = "synthetic-provider-1",
            displayName = "Synthetic Chat Provider (fixture)",
            endpointSummary = "https://synthetic.invalid/v1",
            modelCount = 2,
            enabled = true,
            credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
        ),
    ),
    imageProviders = listOf(
        ProviderListRowUi(
            providerId = "synthetic-provider-2",
            displayName = "Synthetic Image Provider (fixture)",
            endpointSummary = "https://synthetic.invalid/images",
            modelCount = 1,
            enabled = false,
            credentialState = ProviderCredentialStateUi.CONFIGURED,
        ),
    ),
    videoProviders = listOf(
        ProviderListRowUi(
            providerId = "synthetic-provider-3",
            displayName = "Synthetic Video Provider (fixture)",
            endpointSummary = "https://synthetic.invalid/video",
            modelCount = 1,
            enabled = true,
            credentialState = ProviderCredentialStateUi.CONFIGURED,
        ),
    ),
)

internal fun fixtureCatalog() = SupplierCatalogUiState(
    builtInPresets = listOf(
        SupplierPresetUi(
            presetId = "openai",
            displayName = "OpenAI (fixture preset)",
            defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            supportedProtocols = WireProtocolUi.entries,
            defaultEndpointHost = "synthetic.invalid",
            defaultEndpointAbsoluteString = "https://synthetic.invalid/v1",
            defaultEndpointSchemeIsHttp = false,
            routeFamily = "openai",
            authStyle = "bearer",
        ),
        SupplierPresetUi(
            presetId = "anthropic",
            displayName = "Anthropic (fixture preset)",
            defaultProtocol = WireProtocolUi.ANTHROPIC_MESSAGES,
            supportedProtocols = listOf(WireProtocolUi.ANTHROPIC_MESSAGES),
            defaultEndpointHost = "synthetic.invalid",
            defaultEndpointAbsoluteString = "https://synthetic.invalid/anthropic",
            defaultEndpointSchemeIsHttp = false,
            routeFamily = "anthropic",
            authStyle = "x-api-key",
        ),
        SupplierPresetUi(
            presetId = "manual",
            displayName = "Manual / Custom Endpoint (fixture)",
            defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            supportedProtocols = WireProtocolUi.entries,
            defaultEndpointHost = null,
            defaultEndpointAbsoluteString = "",
            defaultEndpointSchemeIsHttp = false,
            routeFamily = "custom",
            authStyle = "bearer",
            isCustom = true,
        ),
    ),
    officialProviders = listOf(
        OfficialSupplierUi(
            catalogEntryId = "synthetic-official-alpha",
            name = "Synthetic Official Alpha",
            aliases = listOf("fixture-alpha"),
            defaultProtocol = WireProtocolUi.OPENAI_RESPONSES,
            kindPresetName = "Synthetic Kind",
            endpointHost = "alpha.synthetic.invalid",
            endpointAbsoluteString = "https://alpha.synthetic.invalid/v1",
            routeFamily = "synthetic-alpha",
            authStyle = "bearer",
            modelCount = 2,
            modelKeywords = listOf("synthetic-alpha-model"),
            availability = SupplierAvailabilityUi.SUPPORTED,
            unsupportedReason = null,
            servedRoles = listOf(ProviderServiceRoleUi.CONVERSATION, ProviderServiceRoleUi.IMAGE),
            isLocalEndpoint = false,
            isConfigured = false,
            suggestsToolNameCompatibility = true,
        ),
        OfficialSupplierUi(
            catalogEntryId = "synthetic-official-beta",
            name = "Synthetic Official Beta",
            aliases = listOf("fixture-beta"),
            defaultProtocol = WireProtocolUi.ANTHROPIC_MESSAGES,
            kindPresetName = "Synthetic Kind",
            endpointHost = "beta.synthetic.invalid",
            endpointAbsoluteString = null,
            routeFamily = "synthetic-beta",
            authStyle = "x-api-key",
            modelCount = 1,
            modelKeywords = listOf("synthetic-beta-model"),
            availability = SupplierAvailabilityUi.UNSUPPORTED,
            unsupportedReason = "Synthetic unsupported reason (fixture).",
            servedRoles = listOf(ProviderServiceRoleUi.VIDEO),
            isLocalEndpoint = false,
            isConfigured = true,
            suggestsToolNameCompatibility = false,
        ),
        OfficialSupplierUi(
            catalogEntryId = "synthetic-official-local",
            name = "Synthetic Local Gateway",
            aliases = listOf("fixture-local"),
            defaultProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            kindPresetName = "Synthetic Local",
            endpointHost = "127.0.0.1",
            endpointAbsoluteString = "http://127.0.0.1:8080/v1",
            routeFamily = "synthetic-local",
            authStyle = "none",
            modelCount = 1,
            modelKeywords = listOf("synthetic-local-model"),
            availability = SupplierAvailabilityUi.SUPPORTED,
            unsupportedReason = null,
            servedRoles = listOf(ProviderServiceRoleUi.CONVERSATION),
            isLocalEndpoint = true,
            isConfigured = false,
            suggestsToolNameCompatibility = false,
        ),
    ),
    configuredPresetIds = setOf("synthetic-official-beta"),
    footer = CatalogFooterUi(
        sourceProject = "Synthetic fixture catalog",
        offeredProviderCount = 6,
        documentCount = 6,
        shortDocumentSha256 = "0123456789abcdef",
        fetchedAtDisplay = "2026-10-18 00:00 (fixture)",
    ),
    refreshAvailable = true,
    refreshInFlight = false,
    networkActionsAvailable = true,
)
