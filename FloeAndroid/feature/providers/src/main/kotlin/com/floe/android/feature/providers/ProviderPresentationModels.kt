// SPDX-License-Identifier: MPL-2.0
//
// Immutable presentation DTOs for the provider/model configuration flow.
//
// Mapping authority (frozen iPad sources, Floe 1.7.34 (275) receipt base):
//  - ProviderServiceRoleUi      ⇄ FloeApp/Providers/ProviderServiceRole.swift enum
//  - WireProtocolUi             ⇄ FloeCore/ModelProtocol.swift raw values
//  - ModelCapabilityUi          ⇄ FloeCore/ModelCapabilities OptionSet raw bits
//  - ReasoningEffortUi          ⇄ FloeCore/ModelReasoningEffort raw values
//  - ConnectionTestUi           ⇄ ProviderEditorViewModel.ConnectionTestState
//  - SaveFailurePhaseUi         ⇄ ProviderSaveFailurePhase (preflight /
//                               credentialOrSync / localCommit)
//  - ProviderCredentialStateUi  ⇄ FloeSyncCore SyncStatus restricted to what
//                               Android can honestly express: .waitingForSecret
//                               ⇄ AWAITING_CONFIGURATION; the CloudKit lifecycle
//                               (.syncing/.paused/.error) is Apple-only and has
//                               no Android analogue here.
//  - CatalogFilterUi            ⇄ ProviderCatalogFilter (all/configured/
//                               available/local)
//  - ModelDraftRowUi.savedModelId ⇄ ModelProfile.id.uuidString (saved identity);
//                               remoteModelID ⇄ wire identifier; displayName ⇄
//                               user-facing label — three DISTINCT fields, never
//                               conflated (contract).
//
// These types carry NO business logic, NO persistence and NO wire calls. They
// are an immutable UI projection supplied by the host (shared Swift services
// behind the accepted bridge) and consumed by the composables in this module.

package com.floe.android.feature.providers

/** Product role chosen before configuring a provider (⇄ ProviderServiceRole). */
enum class ProviderServiceRoleUi(val swiftRaw: String) {
    CONVERSATION("conversation"),
    IMAGE("image"),
    VIDEO("video"),
}

/** Wire protocol spoken by an endpoint (⇄ ModelProtocol rawValue). */
enum class WireProtocolUi(val swiftRaw: String) {
    OPENAI_RESPONSES("openai-responses"),
    OPENAI_CHAT_COMPLETIONS("openai-chat-completions"),
    ANTHROPIC_MESSAGES("anthropic-messages"),
}

/** Official-catalog filter tab (⇄ ProviderCatalogFilter). */
enum class CatalogFilterUi(val swiftRaw: String) {
    ALL("all"),
    CONFIGURED("configured"),
    AVAILABLE("available"),
    LOCAL("local"),
}

/** Capability bits (⇄ ModelCapabilities rawValue; bit values preserved). */
enum class ModelCapabilityUi(val swiftBit: Int) {
    TEXT(1 shl 0),
    VISION(1 shl 1),
    TOOLS(1 shl 2),
    IMAGE_GENERATION(1 shl 3),
    IMAGE_EDITING(1 shl 4),
    APPROVAL(1 shl 5),
    VIDEO_GENERATION(1 shl 6),
}

/** Reasoning intent (⇄ ModelReasoningEffort). AUTOMATIC sends nothing. */
enum class ReasoningEffortUi(val swiftRaw: String) {
    AUTOMATIC("automatic"),
    LOW("low"),
    MEDIUM("medium"),
    HIGH("high"),
    MAXIMUM("maximum"),
}

/** Where the staged model row came from (⇄ discovery/manual distinction). */
enum class ModelSourceUi {
    /** Already saved on the host (ModelProfile committed previously). */
    SAVED,
    /** Returned by a real /models discovery round trip in this session. */
    DISCOVERED,
    /** Typed manually into the model manager in this session. */
    MANUAL,
    /** Staged from an official media preset descriptor. */
    OFFICIAL_MEDIA,
}

/**
 * Credential availability the host can honestly report (⇄ SyncStatus subset).
 * AWAITING_CONFIGURATION mirrors `.waitingForSecret`: committed metadata whose
 * secret is absent — the provider is listed but cannot be used until the user
 * enters a key. Nothing on Android claims cross-device sync.
 */
enum class ProviderCredentialStateUi {
    CONFIGURED,
    AWAITING_CONFIGURATION,
}

/** ⇄ ProviderEditorViewModel.ConnectionTestState. */
sealed interface ConnectionTestUi {
    data object Idle : ConnectionTestUi
    data object Testing : ConnectionTestUi
    /** Confirmed success only — the host produced this from a real round trip. */
    data class Succeeded(val discoveredModelCount: Int) : ConnectionTestUi
    /** Secret-free, user-presentable failure reason supplied by the host. */
    data class Failed(val reason: String) : ConnectionTestUi
}

/** ⇄ ProviderSaveFailurePhase: how far the rejected save got before failing. */
enum class SaveFailurePhaseUi {
    /** Form validation rejected the input; nothing was written anywhere. */
    PREFLIGHT,
    /** The credential write ran and the subsequent commit failed. */
    CREDENTIAL_COMMIT,
    /** The local metadata commit/readback failed. */
    LOCAL_COMMIT,
}

/**
 * Host-computed save outcome for one editor identity+epoch. A pending or
 * failed save NEVER projects success; dismissal of the editor happens only
 * on [Succeeded] (or explicit user cancel).
 */
sealed interface SaveOutcomeUi {
    data object Succeeded : SaveOutcomeUi
    data class Failed(val phase: SaveFailurePhaseUi, val message: String) : SaveOutcomeUi
}

/**
 * Editor identity: [editorId] is assigned when the editor opens (one per
 * open instance, mirroring the iOS `ProviderEditorRoute.id`: "new-<role>" or
 * "<providerUuid>-<role>" with a monotonic suffix per open); [role] is the
 * service purpose for this editor (⇄ route.role); [epoch] increases whenever
 * the host must hand a DIFFERENT projection to the same id (re-seed after an
 * external change). A save/test/discovery result carrying an identity whose
 * epoch does not match the editor's current one is stale and must be ignored
 * (contract: late results cannot replace another editor).
 */
data class ProviderEditorIdentity(
    val editorId: String,
    val epoch: Long,
    val role: ProviderServiceRoleUi,
) {
    init {
        require(epoch >= 0) { "epoch must be non-negative" }
    }

    fun sameEditor(other: ProviderEditorIdentity): Boolean = editorId == other.editorId
    fun isCurrentFor(other: ProviderEditorIdentity): Boolean =
        editorId == other.editorId && epoch == other.epoch
}

/** ⇄ ProviderConfigurationField subset used by the form's highlight logic. */
enum class ProviderFieldUi {
    DISPLAY_NAME,
    SUPPLIER,
    PROTOCOL,
    BASE_URL,
    HEADERS,
    CREDENTIAL,
    COMPATIBILITY,
    MODELS,
}

/** One field-level finding from the host's Swift preflight authority. */
data class FieldIssueUi(val field: ProviderFieldUi, val message: String)

/* --------------------------------- list ---------------------------------- */

/** One saved provider row (⇄ ProviderRow in ProviderListView). */
data class ProviderListRowUi(
    /** ProviderProfile.id.uuidString — saved identity. */
    val providerId: String,
    /** displayName ?? preset name, resolved by the host projection. */
    val displayName: String,
    /** baseURL.absoluteString — display only, never re-parsed here as truth. */
    val endpointSummary: String,
    val modelCount: Int,
    val enabled: Boolean,
    val credentialState: ProviderCredentialStateUi,
)

/** ⇄ ProviderListViewModel projection (three role sections + loading). */
data class ProviderListUiState(
    val isLoading: Boolean,
    val conversationProviders: List<ProviderListRowUi>,
    val imageProviders: List<ProviderListRowUi> = emptyList(),
    val videoProviders: List<ProviderListRowUi> = emptyList(),
    /** ⇄ viewModel.errorMessage (e.g. delete failure alert text, host-localized). */
    val errorMessage: String? = null,
) {
    val isEmpty: Boolean
        get() = conversationProviders.isEmpty() &&
            imageProviders.isEmpty() &&
            videoProviders.isEmpty()
}

/* ------------------------------ supplier catalog -------------------------- */

/**
 * Built-in shipped preset (⇄ ProviderPreset). [defaultEndpointHost] and
 * [defaultEndpointSchemeIsHttp] mirror `defaultBaseURL` for display and the
 * plain-HTTP acknowledgement rule; the preset is host-provided data, never a
 * locally hard-coded provider database.
 */
data class SupplierPresetUi(
    /** ⇄ ProviderTemplateID rawValue; the manual/custom choice is flagged by
     * [isCustom] and keeps the SAME field. */
    val presetId: String,
    val displayName: String,
    val defaultProtocol: WireProtocolUi,
    val supportedProtocols: List<WireProtocolUi>,
    val defaultEndpointHost: String?,
    val defaultEndpointAbsoluteString: String,
    val defaultEndpointSchemeIsHttp: Boolean,
    /** Routing family token used to build the connection identity (⇄
     * ProviderKind.rawValue + auth style). */
    val routeFamily: String,
    val authStyle: String,
    val isCustom: Boolean = false,
)

enum class SupplierAvailabilityUi { SUPPORTED, UNSUPPORTED }

/** One verified official-catalog entry (⇄ ProviderCatalogEntry projection). */
data class OfficialSupplierUi(
    val catalogEntryId: String,
    val name: String,
    val aliases: List<String>,
    val defaultProtocol: WireProtocolUi,
    val kindPresetName: String,
    val endpointHost: String?,
    /** Prefill endpoint handed to the editor (⇄ entry.baseURL.absoluteString;
     * null when the catalog carries no usable default). */
    val endpointAbsoluteString: String?,
    /** Routing family + auth style for the connection-identity token (⇄
     * entry.kind / entry.authStyle). */
    val routeFamily: String,
    val authStyle: String,
    val modelCount: Int,
    /** Model-id keywords from directory metadata — for LOCAL search only.
     * Catalog model counts/ids are directory metadata, not current provider
     * API truth (reference manifest constraint). */
    val modelKeywords: List<String>,
    val availability: SupplierAvailabilityUi,
    /** Localized (host-resolved) reason for UNSUPPORTED entries. */
    val unsupportedReason: String?,
    /** Roles a shipped adapter can really serve (⇄ ProviderServiceOfferResolver). */
    val servedRoles: List<ProviderServiceRoleUi>,
    val isLocalEndpoint: Boolean,
    /** True when a saved provider already uses this catalog identity
     * (⇄ configuredPresetIDs.contains(entry.presetID)); host-projected. */
    val isConfigured: Boolean = false,
    val suggestsToolNameCompatibility: Boolean,
)

/** Footer metadata under the official section (⇄ catalog document source). */
data class CatalogFooterUi(
    val sourceProject: String,
    val offeredProviderCount: Int,
    val documentCount: Int,
    val shortDocumentSha256: String?,
    val fetchedAtDisplay: String?,
)

/** Immutable supplier-catalog projection consumed by the chooser. */
data class SupplierCatalogUiState(
    val builtInPresets: List<SupplierPresetUi>,
    val officialProviders: List<OfficialSupplierUi>,
    /** presetIDs of already-saved providers (⇄ configuredPresetIDs). */
    val configuredPresetIds: Set<String>,
    val footer: CatalogFooterUi?,
    val refreshAvailable: Boolean,
    val refreshInFlight: Boolean,
    /** False while the shared-core bridge cannot run any network action;
     * buttons report this honestly instead of faking availability. */
    val networkActionsAvailable: Boolean,
)

/* ------------------------------- service offers ---------------------------- */

/** ⇄ ProviderServiceOfferResolution.ConnectionMode. */
enum class OfferConnectionUi { SHARED, DISTINCT }

/** One additional role the current supplier can serve (⇄ offer state). */
data class ServiceOfferUi(
    val role: ProviderServiceRoleUi,
    val isEnabled: Boolean,
    val isUsable: Boolean,
    val connection: OfferConnectionUi,
    val modelCount: Int,
    val requiresDiscovery: Boolean,
    val discoveryState: ConnectionTestUi,
    val discoveryError: String?,
    /** Non-secret reason shown for unusable/distinct offers (⇄ offer.reason). */
    val reason: String?,
    val note: String?,
    val canConfigureSeparately: Boolean,
    /** Endpoint+seed models for a distinct offer opened as its own editor. */
    val separateOfferSeed: SeparateOfferSeedUi?,
)

/** ⇄ SeparateOfferRoute: distinct-connection offer opened as its own editor. */
data class SeparateOfferSeedUi(
    val presetId: String,
    val catalogEntryId: String?,
    val endpointAbsoluteString: String?,
    val seedModelRemoteIds: List<String>,
)

/** ⇄ ProviderServiceOfferPrompt: transient one-time multi-role confirmation. */
data class OfferPromptUi(val primaryRole: ProviderServiceRoleUi, val offers: List<PromptOfferUi>)

data class PromptOfferUi(
    val role: ProviderServiceRoleUi,
    val requiresDiscovery: Boolean,
    val modelCount: Int,
)

/* --------------------------------- models --------------------------------- */

/**
 * One staged model row in the editor session. The three identity fields are
 * deliberately distinct typed values (contract):
 *  - [savedModelId]: host-saved ModelProfile.id.uuidString, null for rows not
 *    committed yet (manual/discovered staging);
 *  - [draftModelId]: stable staging key inside THIS editor session (never a
 *    wire id, never a saved id);
 *  - [remoteModelID]: the wire identifier.
 */
data class ModelDraftRowUi(
    val draftModelId: String,
    val savedModelId: String?,
    val remoteModelID: String,
    val displayName: String,
    val enabled: Boolean = true,
    val hiddenFromPrimaryPicker: Boolean = false,
    val capabilities: Set<ModelCapabilityUi> = emptySet(),
    val reasoningEffort: ReasoningEffortUi = ReasoningEffortUi.AUTOMATIC,
    /** ⇄ ModelLimits.contextTokens (0 means "not filled yet"). */
    val contextTokens: Int = 0,
    /** ⇄ ModelLimits.maxOutputTokens; 0 == provider default (not set). */
    val maxOutputTokens: Int = 0,
    val source: ModelSourceUi = ModelSourceUi.SAVED,
    /** Per-model vision verified by catalog metadata (⇄ catalogVerifiedImage
     * Input): a projection badge only, never a provider-wide claim. */
    val verifiedVision: Boolean = false,
    /** Staged for save (⇄ selectedModelIDs membership). */
    val selectedForSave: Boolean = false,
    /** Media descriptor facts (image/video roles), host-projected rows. */
    val mediaFacts: List<LabelledFactUi> = emptyList(),
)

/** Read-only "label: value" row (media capability summary). */
data class LabelledFactUi(val label: String, val value: String)

/** ⇄ MediaModelDescriptor entries offered in the model manager for media roles. */
data class OfficialMediaModelUi(
    val displayName: String,
    val remoteModelID: String,
    /** Full template row staged locally when tapped (host-authored defaults). */
    val template: ModelDraftRowUi,
)

/* --------------------------------- draft ---------------------------------- */

/** The supplier choice made in the unified selector (⇄ selectedPreset +
 * catalogPresetID + applyPreset/applyCatalogEntry results). */
data class SupplierChoice(
    val presetId: String,
    val displayName: String,
    val catalogEntryId: String?,
    val absoluteEndpointDefault: String,
    val routeFamily: String,
    val authStyle: String,
    val supportsPlainHttpChoice: Boolean,
    val suggestsToolNameCompatibility: Boolean,
)

/**
 * Editor session snapshot of every NON-SECRET field. The secure credential
 * text is deliberately absent: it lives only in [ProviderDraftSlot.secureInput]
 * (RAM) and is passed directly to the host action that needs it.
 */
data class ProviderDraftSnapshot(
    val role: ProviderServiceRoleUi,
    val enabled: Boolean = true,
    /** "" means "use the supplier default name" (iOS fallback semantics). */
    val displayName: String = "",
    val supplier: SupplierChoice? = null,
    val protocol: WireProtocolUi = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
    val baseUrl: String = "",
    /** "Header: value" per line (⇄ nonSecretHeadersText). */
    val nonSecretHeaders: String = "",
    val allowsPlainHttp: Boolean = false,
    val toolNameCompatibility: Boolean = false,
    val models: List<ModelDraftRowUi> = emptyList(),
    val defaultModelDraftId: String? = null,
    /** User decisions on shared-connection offers, keyed by role. */
    val offerDecisions: Map<ProviderServiceRoleUi, Boolean> = emptyMap(),
)

/** Host seed for opening an editor (⇄ ProviderEditorViewModel.load()). */
data class ProviderEditorSeedUi(
    val snapshot: ProviderDraftSnapshot,
    val credentialState: ProviderCredentialStateUi,
    val availableProtocols: List<WireProtocolUi>,
    val discoverySupported: Boolean,
    val offers: List<ServiceOfferUi>,
    val officialMediaModels: List<OfficialMediaModelUi>,
)

/* --------------------------------- editor --------------------------------- */

/** Full immutable projection for the ACTIVE editor identity. */
data class ProviderEditorUiState(
    val identity: ProviderEditorIdentity,
    /** ⇄ existing == nil: "Add Provider" vs "Edit Provider" title. */
    val isEditingExisting: Boolean,
    val role: ProviderServiceRoleUi,
    val credentialState: ProviderCredentialStateUi,
    /** ⇄ connectionCredentialRequirementMessage (host-localized). */
    val credentialRequirementMessage: String?,
    /** ⇄ availableProtocols; the picker locks when only one is offered. */
    val availableProtocols: List<WireProtocolUi>,
    val testState: ConnectionTestUi = ConnectionTestUi.Idle,
    /** ⇄ supportsDiscovery. */
    val discoverySupported: Boolean,
    val offers: List<ServiceOfferUi>,
    /** ⇄ pendingServiceOfferPrompt (transient one-time confirmation). */
    val pendingOfferPrompt: OfferPromptUi? = null,
    /** ⇄ isSaving — in-flight disables duplicate Save (contract). */
    val saveInFlight: Boolean = false,
    /** ⇄ saveErrorMessage — Save-path failures open an immediate alert over
     * the retained editor. Connection/discovery failures stay inline. */
    val saveError: String? = null,
    /**
     * Monotonic host sequence for Save-path failures on this identity+epoch.
     *
     * The host MUST advance this whenever it publishes a NEW save failure,
     * even when the message text is identical to the previous failure. The
     * retained editor uses the sequence (not only the text or a transient
     * in-flight flag) to recognise a real retry that completes within one
     * composition frame: without it, a synchronously-failing retry can
     * coalesce its begin/failure projection and look like an unchanged stale
     * failure. It is presentation metadata only, never a backend identifier,
     * and must not decrease for one identity+epoch.
     */
    val saveFailureSequence: Long = 0,
    /** Structured host outcome for this identity+epoch. Success is honoured
     * only here; a pending/failed attempt never closes the editor. */
    val saveOutcome: SaveOutcomeUi? = null,
    /** ⇄ errorMessage — inline bottom section. */
    val formMessage: String? = null,
    /** ⇄ fieldIssues from the Swift preflight authority. */
    val fieldIssues: List<FieldIssueUi> = emptyList(),
    /** Candidate models discovered/saved as projected by the host; merged
     * into the draft staging list by the session holder (⇄ candidateModels). */
    val hostCandidateModels: List<ModelDraftRowUi> = emptyList(),
    val officialMediaModels: List<OfficialMediaModelUi> = emptyList(),
    /** Honest availability of the shared-core network/save bridge. */
    val networkActionsAvailable: Boolean,
    val networkActionsUnavailableReason: String?,
)

/** Everything the destination renders for one moment in time. */
data class ProviderDestinationState(
    val list: ProviderListUiState,
    val catalog: SupplierCatalogUiState,
    /** Active editor projection, or null while no editor host state exists.
     * The module ignores it unless [ProviderEditorIdentity] matches its own
     * open editor session. */
    val editor: ProviderEditorUiState? = null,
)
