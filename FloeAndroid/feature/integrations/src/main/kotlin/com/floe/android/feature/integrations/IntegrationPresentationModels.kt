// SPDX-License-Identifier: MPL-2.0
//
// Immutable presentation DTOs for the Skills/MCP administration flow
// (work package P2.6; G02 operations SKL-DISCOVER-USABLE, SKL-INSTALL-VERSION,
// SKL-SOURCE-NO-GRANT, MCP-REMOTE-TOOLS, SKL-CANCEL).
//
// Mapping authority (frozen original sources in this checkout):
//  - SkillsHubUiState        ⇄ FloeApp/Skills/SkillsView.swift (segmented
//                            Discover/Installed, official cards, import
//                            actions, scripted auto-update toggle, errors,
//                            working overlay, searchable, refreshable)
//  - SkillCatalogCardUi      ⇄ DomainSkillLibrary.exposed definitions +
//                            SkillsCenter.availableVersion/installed state
//  - SkillInstalledRowUi     ⇄ FloePersistence PersistedSkill (id, name,
//                            version, status, rewrittenDigest, sourceURL,
//                            compatibilityReportJSON) as the hub renders it
//  - SkillAvailabilityUi /   ⇄ FloeSkills SkillCompatibility problems and
//    SkillOfferStateUi          FloeTools ToolRunnerRegistry.allDescriptors
//                            ("registered AND isAvailable" + enabled +
//                            configured + actually usable); the HOST decides,
//                            the module only renders the decision.
//  - SkillPermissionRowUi    ⇄ FloePersistence PersistedSkillPermission
//                            (capability/decision/scope/grantedAt/expiresAt)
//  - SkillRunScopeUi         ⇄ the execution scope BridgeV3 taskExecution
//                            actually projects (SKL-CANCEL): task+run are
//                            required, environment/job roles appear ONLY
//                            when the host projected a real one (typed
//                            RunOnly vs JobOwned). Every id is host-issued —
//                            the module never invents, defaults or
//                            sentinel-fills one, and echoes the projected
//                            scope back unchanged.
//  - SkillInstallReviewUi    ⇄ SkillsCenter.PendingInstallation +
//                            SkillInstallReviewSheet (source, requested
//                            capabilities, tools, audited scripts, pinned
//                            pure-Python deps)
//  - SkillUpgradeUi          ⇄ SkillUpgradeCandidate +
//                            SkillGitHubUpgradeSheet (installed/available
//                            versions, commit, localized release notes, new
//                            capabilities/tools, per-file before/after,
//                            rollback, permission-expansion warning)
//  - ConnectorsUiState       ⇄ SkillsView ConnectorsView (external services
//                            section + tool sources section + footer)
//  - McpServerRowUi /        ⇄ SkillsView MCPServersView + MCPSettingsCenter
//    McpConnectionStateUi     (ConnectionState inactive/connecting/ready(n)/
//                            failed(message); per-server refresh generation)
//  - McpEditorSeedUi /       ⇄ MCPServerEditor + FloeTools
//    McpDraftSnapshot         MCPServerConfiguration (displayName, endpoint,
//                            enabled, allowInCanvas, allowInsecureHTTP,
//                            authentication none/bearerToken/customHeader,
//                            credentialHeaderName, timeoutSeconds clamped
//                            5…120, disabledRemoteToolNames) and
//                            MCPDiscoveredTool (remoteName, displayName,
//                            toolDescription, readOnlyHint, destructiveHint)
//
// These types carry NO business logic, NO persistence and NO network. They
// are an immutable UI projection supplied by the host (shared Swift runtime
// services behind the accepted bridge) and consumed by the composables in
// this module. Anything the host cannot honestly report arrives as an
// explicit UNAVAILABLE state with the host's remediation text — never as a
// fabricated success, fake progress, invented tool count or silent default.

package com.floe.android.feature.integrations

/* ------------------------------- skills hub ------------------------------- */

/** Where a managed skill came from (⇄ sourceURL scheme / hub membership). */
enum class SkillSourceKindUi(val swiftDisplay: String) {
    OFFICIAL_HUB("official"),
    BUNDLED("bundled"),
    GITHUB("github"),
    FINDER("finder"),
    FOLDER("folder"),
    CREATOR("creator"),
}

/**
 * ⇄ SkillCompatibility problems + configuration state, resolved by the host
 * into one of these presentation shapes with LOCALIZED remediation copy.
 * NEEDS_CONFIGURATION / ENVIRONMENT_UNAVAILABLE are honest "not usable yet"
 * statements: an environment that is temporarily absent (the G03 Linux
 * environment) is reported as pending, never as removed from the product.
 */
sealed interface SkillAvailabilityUi {
    /** Enabled, configured, and the runtime can actually execute it now. */
    data object Usable : SkillAvailabilityUi

    /** Enabled but missing setup (a credential, a host, a package). */
    data class NeedsConfiguration(val remediation: String) : SkillAvailabilityUi

    /** A required runtime environment is temporarily unavailable. */
    data class EnvironmentUnavailable(val remediation: String) : SkillAvailabilityUi

    /** Disabled by the user (⇄ status != "enabled"). */
    data object Disabled : SkillAvailabilityUi

    /** Read-only or policy-blocked (⇄ hidden system guides: "update only
     * with the app"). [reason] is host-localized. */
    data class Blocked(val reason: String) : SkillAvailabilityUi
}

/**
 * The existing identity a skill-run cancellation must carry (SKL-CANCEL:
 * "real owned run stop / no orphans"). This mirrors the BridgeV3
 * taskExecution scope: the genuine task+run pair is required, while the
 * environment and job roles are OPTIONAL and only ever present when the
 * host actually projected real host-issued values. The module echoes the
 * typed scope back unchanged and never constructs one: a genuine run-only
 * row displays and cancels without any env/job identity, and a missing job
 * role is structurally absent — not an empty string the backend could
 * mistake for a resolvable command (the backend decides required roles and
 * refuses unresolved job commands).
 */
sealed interface SkillRunScopeUi {
    val taskId: String
    val runId: String
    /** A real host-projected environment role, or null when none exists. */
    val environmentId: String?
    /** The generation the run started under (host-minted, non-negative). */
    val generation: Long

    /** ⇄ a run the host owns without a resolvable job role: exactly
     * task+run (+ an optional real environment) + generation. */
    data class RunOnly(
        override val taskId: String,
        override val runId: String,
        override val environmentId: String? = null,
        override val generation: Long,
    ) : SkillRunScopeUi {
        init {
            require(taskId.isNotBlank() && runId.isNotBlank()) {
                "task/run ownership must be real host-issued identities"
            }
            require(generation >= 0) { "generation must be non-negative" }
        }
    }

    /** ⇄ a run the execution layer owns under a REAL projected job. The
     * jobId is host-issued; the environmentId remains optional/real. */
    data class JobOwned(
        override val taskId: String,
        override val runId: String,
        override val environmentId: String? = null,
        val jobId: String,
        override val generation: Long,
    ) : SkillRunScopeUi {
        init {
            require(taskId.isNotBlank() && runId.isNotBlank()) {
                "task/run ownership must be real host-issued identities"
            }
            require(jobId.isNotBlank()) { "jobId must be a real host-issued identity" }
            require(generation >= 0) { "generation must be non-negative" }
        }
    }
}

/** ⇄ an owned live run of this skill, projected only when one really exists. */
sealed interface SkillRunActivityUi {
    data object None : SkillRunActivityUi
    data class Running(val scope: SkillRunScopeUi) : SkillRunActivityUi
    /** Host already acknowledged the stop and is tearing the run down. */
    data class Cancelling(val scope: SkillRunScopeUi) : SkillRunActivityUi
}

/**
 * One persisted permission row (⇄ PersistedSkillPermission). RENDERING a
 * row grants nothing: source-signature trust and the enable toggle are never
 * permission grants — approvals come from the host's existing policy layer
 * only. Values are host-supplied display strings; scopeJSON is never parsed
 * here.
 */
data class SkillPermissionRowUi(
    val capability: String,
    val decision: String,
    val scopeSummary: String?,
    val grantedAtDisplay: String?,
    val expiresAtDisplay: String?,
)

/**
 * ⇄ ToolCatalog / CapabilityExecutionRouter / ToolRunnerRegistry discovery:
 * a skill's tools enter the agent's offered set only when enabled AND
 * configured AND actually usable, and a saved model capability override can
 * still exclude them. The host computes this whole verdict; the module never
 * derives OFFERED from [SkillInstalledRowUi.enabled] alone (no-fake-
 * availability rule, SKL-DISCOVER-USABLE). Physically absent channel modules
 * (root/ADB/phone on Play) are simply never projected at all.
 */
enum class SkillOfferStateUi(val swiftRaw: String) {
    OFFERED("offered"),
    NOT_OFFERED_DISABLED("notOfferedDisabled"),
    NOT_OFFERED_NEEDS_SETUP("notOfferedNeedsSetup"),
    NOT_OFFERED_ENVIRONMENT("notOfferedEnvironment"),
    /** A saved per-model override keeps it out of this run's tool set. */
    NOT_OFFERED_MODEL_OVERRIDE("notOfferedModelOverride"),
}

/**
 * Service-owned staging of one install/upgrade write (⇄ SkillInstallStaging-
 * Service phases). Stage labels only — the host never sends a fake percentage
 * and the module never renders one. A failed stage leaves the PRIOR version
 * intact; the row keeps projecting the previous version (SKL-INSTALL-VERSION).
 */
enum class SkillInstallStageUi {
    STAGING_SOURCE,
    VALIDATING_PACKAGE,
    CHECKING_COMPATIBILITY,
    COMMITTING,
}

/** One installed (managed) skill row (⇄ visibleInstalled + PersistedSkill). */
data class SkillInstalledRowUi(
    /** ⇄ PersistedSkill.id — the stable lowercase skill identifier. */
    val skillId: String,
    val name: String,
    /** ⇄ PersistedSkill.version. */
    val version: String,
    /** ⇄ package metadata description (resolved by the host). */
    val summary: String?,
    /** ⇄ status == "enabled". */
    val enabled: Boolean,
    /**
     * ⇄ PersistedSkill.rewrittenDigest — the optimistic revision bound for
     * enable/delete/update ("expectedDigest"; a changed skill surfaces
     * ⇄ SkillStoreConflict.changedOrMissing instead of a silent overwrite).
     */
    val revision: String,
    val availability: SkillAvailabilityUi,
    val offerState: SkillOfferStateUi,
    /** Host-localized note when [SkillOfferStateUi.NOT_OFFERED_MODEL_OVERRIDE]. */
    val modelOverrideNote: String? = null,
    val permissions: List<SkillPermissionRowUi> = emptyList(),
    val runActivity: SkillRunActivityUi = SkillRunActivityUi.None,
    /** ⇄ SkillsCenter.availableVersion(for:): newer signed-catalog version. */
    val updateAvailableVersion: String? = null,
    val sourceKind: SkillSourceKindUi,
    /** ⇄ DomainSkillLibrary exposed == false handling surfaced for the user. */
    val isBundledReadOnlyGuide: Boolean = false,
    /** Non-null only while a host service is staging this skill's install. */
    val installStage: SkillInstallStageUi? = null,
)

/** One official-catalog card in the Discover segment (⇄ plugins.official). */
data class SkillCatalogCardUi(
    val skillId: String,
    val name: String,
    /** ⇄ definition.version, superseded by the signed catalog version when
     * installed (iOS shows the catalog package version for installed rows). */
    val version: String,
    /** ⇄ pluginSummary(definition): one-sentence purpose. */
    val summary: String,
    val state: CatalogCardStateUi,
)

/** ⇄ the card's conditional affordance block, one-to-one. */
sealed interface CatalogCardStateUi {
    /** Not installed → Install button. */
    data object NotInstalled : CatalogCardStateUi

    /** Install dispatched to the host service and staging (no fake progress). */
    data class InstallStaging(val stage: SkillInstallStageUi) : CatalogCardStateUi

    /** Installed and enabled → "Ready to use" (⇄ plugins.ready). */
    data object InstalledReady : CatalogCardStateUi

    /** Installed but disabled → Enable button. */
    data object InstalledNeedsEnable : CatalogCardStateUi

    /** Installed with a newer signed version → "Update to vX". */
    data class UpdateTo(val version: String) : CatalogCardStateUi

    /** The host cannot act on this card right now; [remediation] is its
     * localized explanation (never a silent dead button). */
    data class Unavailable(val remediation: String) : CatalogCardStateUi
}

/** ⇄ ModelProfile subset the Finder rewrite picker needs. */
data class RewriteModelUi(
    val modelId: String,
    val displayName: String,
)

/** ⇄ SkillsCenter rewrite/create outcome, addressed to one form session. */
data class SkillsFormOutcomeUi(
    /** The module-generated form id this outcome answers (fence key). */
    val formId: String,
    val succeeded: Boolean,
    /** Host-localized failure copy; null/blank on success. */
    val message: String?,
)

/**
 * Opaque staged-package reference for folder/attachment imports. Only the
 * handle + display metadata crosses the seam — never ZIP bytes, never
 * base64, never a filesystem path the UI should open. ⇄ the iOS fileImporter
 * copy-to-temp step, whose temp copy is likewise owned by the host service.
 */
data class StagedPackageRefUi(
    val handle: String,
    val displayName: String,
    val mimeType: String?,
    val sizeBytes: Long?,
) {
    /** Redacted representation: no content, only the opaque identity. */
    override fun toString(): String =
        "StagedPackageRefUi(handle=$handle, name=$displayName, mime=$mimeType, size=$sizeBytes)"
}

/** Staging-review projection for one pending installation (⇄ PendingInstallation). */
data class SkillInstallReviewUi(
    /** Host-issued MONOTONIC token per staged review; a confirmation for an
     * older/superseded token is stale and ignored (late-effect fence), and a
     * handled token is never re-opened by a later projection of the same
     * staged review. */
    val reviewId: Long,
    /** ⇄ pending.sourceURL.absoluteString — already credential-stripped by
     * the host (⇄ SkillInstallProvenance sanitizes user/password/query). */
    val sourceDisplay: String,
    val skillName: String,
    val version: String,
    /** ⇄ capabilityNames; empty renders "No additional capabilities". */
    val requestedCapabilities: List<String>,
    /** ⇄ toolNames. */
    val tools: List<String>,
    /** ⇄ containsScripts + scripts/ file list. */
    val scriptPaths: List<String>,
    /** ⇄ manifest.pythonPackages (spec + purpose). */
    val pythonPackages: List<PythonRequirementUi>,
    /** True while the host service commits the confirmed install. */
    val commitInFlight: Boolean,
) {
    val containsScripts: Boolean get() = scriptPaths.isNotEmpty()
}

/** ⇄ SkillManifest.pythonPackages entry. */
data class PythonRequirementUi(val spec: String, val purpose: String)

/** ⇄ GitHubSkillSource fields in the upgrade sheet's disclosure. */
data class GitHubSourceFieldsUi(
    val owner: String,
    val repository: String,
    val ref: String,
    val path: String,
)

/** ⇄ per-file before/after preview in the upgrade sheet (bounded text; a
 * binary resource renders as the host's "Binary resource: n bytes" line). */
data class SkillFileDiffUi(
    val path: String,
    val beforePreview: String?,
    val afterPreview: String?,
)

/**
 * Upgrade-review projection for the skill whose sheet is open. Mirrors
 * ⇄ SkillUpgradeCandidate + the sheet's conditional sections.
 */
data class SkillUpgradeUi(
    val skillId: String,
    val skillName: String,
    val installedVersion: String,
    val isOfficial: Boolean,
    /** ⇄ lastGitHubSource(skillID:) seed for non-official sources. */
    val savedSource: GitHubSourceFieldsUi?,
    /** Candidate package version once a real check staged it; null = none. */
    val candidateVersion: String?,
    val commit: String?,
    /** Host-localized release notes (⇄ releaseNotes[locale]). */
    val releaseNotes: String?,
    /** ⇄ addedCapabilities: an update that expands access needs review. */
    val addedCapabilities: List<String>,
    val addedTools: List<String>,
    val changedFiles: List<SkillFileDiffUi>,
    /** ⇄ changedFiles.isEmpty: already latest — Update now stays disabled. */
    val isLatest: Boolean,
    val checkInFlight: Boolean,
    val applyInFlight: Boolean,
    /** True when a completed rollback journal exists for this skill. */
    val canRollback: Boolean,
    /** ⇄ center.errorMessage scoped to this flow (host-localized). */
    val errorMessage: String?,
    /** Structured outcome for the last dispatched apply/rollback effect,
     * keyed by [effectToken]; consumed once (see holder). */
    val lastEffect: UpgradeEffectUi? = null,
)

data class UpgradeEffectUi(
    /** Echoes the module's dispatch token for the apply/rollback call. */
    val effectToken: Long,
    val outcome: UpgradeOutcomeUi,
)

enum class UpgradeOutcomeUi { APPLIED, ROLLED_BACK, FAILED }

/** ⇄ SkillCreatorSheet fields (name / "When should Floe use it?" / instructions). */
data class SkillCreatorDraftUi(
    val name: String,
    val description: String,
    val instructions: String,
)

/* ------------------------------- connectors ------------------------------- */

/** ⇄ ConnectorsView row shapes; the destination routing itself is host-owned. */
data class ConnectorDestinationRowUi(
    /** Host-owned destination key (e.g. "mail", "github"). */
    val destinationId: String,
    val title: String,
    /** ⇄ "Connected · login" / "Not connected · Sign in…" caption. */
    val subtitle: String?,
    val availability: ConnectorAvailabilityUi,
)

sealed interface ConnectorAvailabilityUi {
    data object Available : ConnectorAvailabilityUi
    /** Present but not openable right now; [remediation] is the host's
     * localized instruction. Physically absent modules (GitHub updater /
     * ADB on Play) are never projected as rows at all — absence here is
     * the host's projection, the module adds nothing. */
    data class Unavailable(val remediation: String) : ConnectorAvailabilityUi
}

/** ⇄ ConnectorsView: services section + tool-sources section + footer. */
data class ConnectorsUiState(
    /** External account integrations (Mail, GitHub) — host-routed. */
    val services: List<ConnectorDestinationRowUi>,
    /** Extra tool-source destinations beyond the module's own MCP page. */
    val toolSources: List<ConnectorDestinationRowUi>,
)

/* ---------------------------------- MCP ----------------------------------- */

/** ⇄ MCPServerConfiguration.Authentication raw values. */
enum class McpAuthenticationUi(val swiftRaw: String) {
    NONE("none"),
    BEARER_TOKEN("bearerToken"),
    CUSTOM_HEADER("customHeader"),
}

/**
 * ⇄ MCPRemoteClient transport. The original ships standard Streamable HTTP;
 * the future Linux/stdio route (plan §MCP transports, G03 environment) stays
 * in the projection as a PENDING_ENVIRONMENT entry so G02 capability lists
 * report it as temporarily unavailable — not permanently removed.
 */
sealed interface McpTransportUi {
    data object StreamableHttp : McpTransportUi
    data class PendingEnvironment(val remediation: String) : McpTransportUi
}

/** ⇄ MCPSettingsCenter.ConnectionState (same four honest shapes). */
sealed interface McpConnectionStateUi {
    data object Inactive : McpConnectionStateUi

    /** "Reading tools…" — [generation] mirrors the host's per-server refresh
     * generation; a cancel request binds to exactly one generation. */
    data class Connecting(val generation: Long) : McpConnectionStateUi

    /** Confirmed registration of N tools from a real discovery round trip. */
    data class Ready(val toolCount: Int) : McpConnectionStateUi

    /** ⇄ .failed(message): host-localized, already secret-redacted. */
    data class Failed(val message: String) : McpConnectionStateUi
}

/** ⇄ MCPDiscoveredTool + the editor's per-tool enable state. */
data class McpToolRowUi(
    val remoteName: String,
    val displayName: String?,
    val toolDescription: String,
    /** ⇄ !disabledRemoteToolNames.contains(remoteName). */
    val enabled: Boolean,
    val readOnlyHint: Boolean,
    val destructiveHint: Boolean,
)

/** One saved MCP server row (⇄ MCPServersView row). */
data class McpServerRowUi(
    /** ⇄ MCPServerConfiguration.id.uuidString — saved identity, host-issued. */
    val serverId: String,
    val displayName: String,
    /** ⇄ endpoint.absoluteString — display only. */
    val endpointDisplay: String,
    val enabled: Boolean,
    val allowInCanvas: Boolean,
    val authentication: McpAuthenticationUi,
    /** ⇄ center.hasStoredCredential: a Boolean flag only; the raw secret is
     * never returned in any projection, ever. */
    val credentialStored: Boolean,
    val state: McpConnectionStateUi,
    /** Discovered tools for the live session; null until a real discovery
     * succeeded. Never a fabricated count. */
    val tools: List<McpToolRowUi>?,
    /** ⇄ MCPServerConfiguration Hashable equality per persist round: host-
     * issued config revision used to fence late events on edits. */
    val revision: Long,
)

/** ⇄ MCPServersView list state. */
data class McpServersUiState(
    val isLoading: Boolean,
    val servers: List<McpServerRowUi>,
    /** ⇄ center.errorMessage (host-localized, redacted). */
    val errorMessage: String?,
) {
    val isEmpty: Boolean get() = servers.isEmpty()
}

/** ⇄ MCPServerEditor defaults: a NEW server starts enabled, canvas off,
 * insecure-HTTP off, auth none, header name "Authorization", timeout 30. */
data class McpEditorSeedUi(
    /** Saved id when editing an existing server; null for a new one. */
    val serverId: String?,
    val displayName: String,
    val endpointText: String,
    val enabled: Boolean,
    val allowInCanvas: Boolean,
    val allowInsecureHttp: Boolean,
    val authentication: McpAuthenticationUi,
    val credentialHeaderName: String,
    val credentialStored: Boolean,
    val timeoutSeconds: Int,
    val transport: McpTransportUi,
    /** ⇄ center.toolsByServerID[serverId]: the live tool list. */
    val tools: List<McpToolRowUi>,
    /** Saved row revision when editing (null for a NEW server); the editor
     * save carries it as baseRevision so a changed saved config is an
     * explicit revision conflict the host rejects, never a blind overwrite. */
    val savedRevision: Long? = null,
    /** Honest availability of the host's network/save bridge. */
    val networkActionsAvailable: Boolean,
    val networkActionsUnavailableReason: String?,
)

/**
 * Editor identity: [editorId] is assigned per open ("new-<n>" /
 * "<serverId>-<n>"), [epoch] increases only when the host must hand a
 * DIFFERENT seed to the same id. A result addressed to a non-current
 * identity+epoch is stale and is ignored (late success can never close or
 * update a newer editor).
 */
data class McpEditorIdentity(
    val editorId: String,
    val epoch: Long,
    val serverId: String?,
) {
    init {
        require(epoch >= 0) { "epoch must be non-negative" }
    }

    fun sameEditor(other: McpEditorIdentity): Boolean = editorId == other.editorId
    fun isCurrentFor(other: McpEditorIdentity): Boolean =
        editorId == other.editorId && epoch == other.epoch
}

/** Non-secret editor snapshot (⇄ MCPServerConfiguration mutable fields). */
data class McpDraftSnapshot(
    val displayName: String = "",
    val endpointText: String = "",
    val enabled: Boolean = true,
    val allowInCanvas: Boolean = false,
    val allowInsecureHttp: Boolean = false,
    val authentication: McpAuthenticationUi = McpAuthenticationUi.NONE,
    val credentialHeaderName: String = "Authorization",
    /** ⇄ init clamps 5…120; display-side clamp mirrors it, host stays authority. */
    val timeoutSeconds: Int = 30,
    /** ⇄ disabledRemoteToolNames edited against the draft (iOS editor edits
     * its own @State server copy; persistence happens on save). */
    val disabledRemoteToolNames: Set<String> = emptySet(),
)

/**
 * Short-lived credential intent handed to the future Android Keystore
 * gateway (⇄ MCPSettingsCenter.upsert credential semantics):
 *  - KEEP_EXISTING: empty typed draft, auth required, secret still bound to
 *    the SAME origin — keep the stored secret;
 *  - SET: a RAM draft exists — store it for this identity+origin;
 *  - CLEAR: authentication switched to NONE — delete the bound secret;
 *  - MISSING: required but nothing to keep — the host rejects with
 *    authenticationRequired and the editor shows that error. NEVER a silent
 *    "keep what belongs to another endpoint".
 */
enum class CredentialDraftIntent { KEEP_EXISTING, SET, CLEAR, MISSING }

/** Save dispatch payload. [credentialDraft] is non-null only for [SET]. */
data class McpSaveRequest(
    val identity: McpEditorIdentity,
    val serverId: String?,
    val draft: McpDraftSnapshot,
    val credentialIntent: CredentialDraftIntent,
    val credentialDraft: String?,
    /** ⇄ revision observed at seed time; a save onto a changed saved config
     * is a revision conflict the host must reject explicitly. */
    val baseRevision: Long?,
) {
    /** Explicit redaction: never prints the credential draft. */
    override fun toString(): String =
        "McpSaveRequest(editor=${identity.editorId}, epoch=${identity.epoch}, " +
            "serverId=$serverId, name=${draft.displayName}, " +
            "endpoint=${draft.endpointText}, auth=${draft.authentication}, " +
            "credential=${if (credentialDraft.isNullOrEmpty()) "absent" else "<present:redacted>"}, " +
            "intent=$credentialIntent)"
}

/** ⇄ upsert outcome: success (host committed + registered) or error string. */
sealed interface McpSaveOutcomeUi {
    data class Succeeded(val newServerId: String, val newRevision: Long) : McpSaveOutcomeUi
    data class Failed(val message: String) : McpSaveOutcomeUi
}

/** Full projection for the ACTIVE MCP editor identity. */
data class McpEditorUiState(
    val identity: McpEditorIdentity,
    val seed: McpEditorSeedUi,
    val saveInFlight: Boolean,
    /** Save-path error (⇄ validationMessage = error.localizedDescription). */
    val saveError: String?,
    /** Structured outcome for this identity+epoch; dismissal only on
     * [McpSaveOutcomeUi.Succeeded]. */
    val saveOutcome: McpSaveOutcomeUi? = null,
    /** Live connection state while the editor is open (row status mirror). */
    val connectionState: McpConnectionStateUi,
    /** ⇄ center.toolsByServerID[serverId]: the live tool list. */
    val tools: List<McpToolRowUi>?,
    /** ⇄ center.hasStoredCredential(serverID) re-read for this draft identity. */
    val credentialStored: Boolean,
    val networkActionsAvailable: Boolean,
    val networkActionsUnavailableReason: String?,
    /**
     * Monotonic host sequence for COMPLETED Save failures on this exact
     * identity+epoch. 0 (the default) is the legacy projection shape and
     * keeps the message/outcome-only consumption path.
     *
     * The host MUST advance this by one for every NEW failed save attempt it
     * accepts for this identity+epoch, even when [saveError] and
     * [saveOutcome] repeat the previous failure text/outcome. A retry can
     * fail synchronously inside the save dispatch, so its begin and failure
     * projections may coalesce into one composition frame; the sequence is
     * then the only reliable attempt boundary.
     *
     * The host MUST NOT advance it for a mere error-text change, a repeated
     * projection/poll/recomposition, a clock tick, or a connection/discovery
     * failure (those stay inline and are not save outcomes). It must never
     * decrease for one identity+epoch. Presentation metadata only: never a
     * backend identifier, never a credential/secret carrier.
     */
    val saveFailureSequence: Long = 0,
)

/* ---------------------------------- root ---------------------------------- */

/** ⇄ SkillsView hub state (center.load / catalog / installed / errors). */
data class SkillsHubUiState(
    val isLoading: Boolean,
    /** ⇄ center.isWorking — one overlay spinner over the hub while a host
     * skill service runs; dismissals during it are blocked by the holder. */
    val isWorking: Boolean,
    val catalogCards: List<SkillCatalogCardUi>,
    /** ⇄ center.isCheckingCatalog. */
    val catalogChecking: Boolean,
    /** ⇄ center.catalogError ("updates cannot be checked right now"). */
    val catalogError: String?,
    val installed: List<SkillInstalledRowUi>,
    /** ⇄ center.rewriteModels / defaultRewriteModelID for the Finder sheet. */
    val rewriteModels: List<RewriteModelUi>,
    val defaultRewriteModelId: String?,
    /** ⇄ the SHARED ContentUpdateCenter scripted-auto-install preference —
     * one value, managed identically under Settings → Content updates. */
    val autoScriptedUpdates: Boolean,
    /** ⇄ center.errorMessage (host-localized). */
    val errorMessage: String?,
    /** Outcome for the current transient form session (creator/finder/
     * folder import), keyed by the module's form id. */
    val formOutcome: SkillsFormOutcomeUi? = null,
) {
    val installedIds: Set<String> get() = installed.mapTo(HashSet()) { it.skillId }
}

/** Everything the destination renders for one moment in time. */
data class IntegrationsDestinationState(
    val skills: SkillsHubUiState,
    val connectors: ConnectorsUiState,
    val mcp: McpServersUiState,
    /** Host-staged installation awaiting explicit review (⇄ pendingInstallation). */
    val installReview: SkillInstallReviewUi? = null,
    /** Projection for the open upgrade sheet (ignored unless the skill id
     * matches the pane key). */
    val upgrade: SkillUpgradeUi? = null,
    /** Active MCP editor projection, or null; ignored unless its identity
     * matches the module's open editor session (epoch guard). */
    val editor: McpEditorUiState? = null,
)
