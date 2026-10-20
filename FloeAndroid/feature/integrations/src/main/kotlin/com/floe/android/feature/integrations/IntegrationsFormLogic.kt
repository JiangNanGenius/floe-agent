// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation logic for the Skills/MCP flow. NO Compose, NO I/O: the
// module's honesty rules (no-fake-availability, revision fencing, credential
// intent computation, MCP endpoint preflight as a DISPLAY comparison only)
// live here so they are unit-testable without a device.
//
// Swift authority mirrors (the original remains the decision-maker):
//  - endpoint/URL rules       ⇄ MCPServerConfiguration.validate()
//  - header-name rules        ⇄ MCPServerConfiguration.validate() token set
//  - timeout clamp            ⇄ MCPServerConfiguration.init min/max 5…120
//  - credential account bind  ⇄ MCPSettingsCenter.credentialAccount(_:) —
//    id + scheme + host + port: editing or cloud-syncing an endpoint
//    therefore requires a credential stored for the NEW destination instead
//    of silently sending the old secret to it.

package com.floe.android.feature.integrations

import java.net.URI

/* ---------------------------- MCP display preflight ---------------------------- */

/**
 * Presentation-side findings for the MCP editor. These mirror the original
 * Swift validation ONLY to highlight fields early (⇄ the provider flow's
 * "display comparison, Swift revalidates" rule): unparseable input yields
 * "unknown" findings, and the host's `MCPServerConfiguration.validate()`
 * remains the save-time authority. Nothing here grants or rejects a save.
 */
object McpFormPreflight {

    /** ⇄ the reserved/valid header-name logic in MCPServerConfiguration. */
    val RESERVED_HEADER_NAMES: Set<String> = setOf(
        "accept", "connection", "content-length", "content-type", "host",
        "mcp-method", "mcp-name", "mcp-protocol-version", "mcp-session-id",
        "transfer-encoding",
    )

    // RFC 7230 token chars + digits + letters. (The previous one-liner
    // concatenated CharRange.toString() — "0..9" — so real alphanumerics
    // like "X-Api-Key" were wrongly rejected; the JVM test caught it.)
    private val headerTokenChars: Set<Char> = buildSet {
        "!#$%&'*+-.^_`|~".forEach { add(it) }
        ('0'..'9').forEach { add(it) }
        ('A'..'Z').forEach { add(it) }
        ('a'..'z').forEach { add(it) }
    }

    /** Canonical origin token or null when the endpoint is unparseable
     * ("unknown" never triggers a secret clear — provider-flow rule). */
    fun endpointOrigin(endpointText: String): McpEndpointOrigin? = McpEndpointOrigin.parse(endpointText)

    /** True when the local draft would certainly fail host validation. */
    fun looksInvalid(draft: McpDraftSnapshot): McpPreflightFinding? {
        if (draft.displayName.isBlank()) return McpPreflightFinding.NAME_REQUIRED
        val endpoint = draft.endpointText.trim()
        if (endpoint.isEmpty()) return McpPreflightFinding.ENDPOINT_REQUIRED
        val origin = endpointOrigin(endpoint)
        if (origin == null) return McpPreflightFinding.ENDPOINT_UNPARSEABLE
        if (origin.embedsUserInfo) return McpPreflightFinding.ENDPOINT_EMBEDS_CREDENTIAL
        if (origin.scheme == "http" && !draft.allowInsecureHttp) {
            return McpPreflightFinding.INSECURE_HTTP_NOT_ALLOWED
        }
        if (draft.authentication == McpAuthenticationUi.CUSTOM_HEADER) {
            val name = draft.credentialHeaderName.trim()
            if (name.isEmpty() || !name.all { headerTokenChars.contains(it) } ||
                RESERVED_HEADER_NAMES.contains(name.lowercase()) ||
                name.lowercase().startsWith("mcp-param-")
            ) {
                return McpPreflightFinding.HEADER_NAME_INVALID
            }
        }
        return null
    }

    /** ⇄ timeoutSeconds clamp in the Swift init (display-side; the host
     * clamps again with authority). */
    fun clampTimeoutSeconds(value: Int): Int = value.coerceIn(5, 120)
}

enum class McpPreflightFinding {
    NAME_REQUIRED,
    ENDPOINT_REQUIRED,
    ENDPOINT_UNPARSEABLE,
    ENDPOINT_EMBEDS_CREDENTIAL,
    INSECURE_HTTP_NOT_ALLOWED,
    HEADER_NAME_INVALID,
}

/**
 * ⇄ MCPSettingsCenter.credentialAccount: scheme + lowercase trailing-dot-
 * stripped host + explicit-or-default port. [path] and query are excluded
 * (same-origin edits keep the bound secret; a real origin change does not).
 * [embedsUserInfo] flags user/password in the URL — the original rejects
 * those outright ("credentials belong in the keychain, not the URL").
 */
data class McpEndpointOrigin(
    val scheme: String,
    val host: String,
    val port: Int,
    val embedsUserInfo: Boolean,
) {
    /** Stable comparison token (display only; never a security decision). */
    val accountToken: String get() = "$scheme://$host:$port"

    companion object {
        fun parse(endpointText: String): McpEndpointOrigin? {
            val trimmed = endpointText.trim()
            if (trimmed.isEmpty()) return null
            val uri = try {
                URI(trimmed)
            } catch (_: Exception) {
                return null
            }
            val scheme = uri.scheme?.lowercase()?.takeIf { it == "https" || it == "http" } ?: return null
            val host = uri.host?.lowercase()?.trimEnd('.')?.takeIf { it.isNotEmpty() } ?: return null
            val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
            return McpEndpointOrigin(
                scheme = scheme,
                host = host,
                port = port,
                embedsUserInfo = !uri.userInfo.isNullOrEmpty(),
            )
        }
    }
}

/* --------------------------- credential intent rules --------------------------- */

/**
 * Computes the short-lived intent for the future Android Keystore gateway
 * from the RAM draft state. Mirrors ⇄ MCPSettingsCenter.upsert:
 *  - auth NONE → CLEAR (the bound account is deleted);
 *  - non-empty typed draft → SET (store for this identity+origin);
 *  - empty draft, auth required, still the SAME origin as when seeded and
 *    the host reported a stored credential → KEEP_EXISTING;
 *  - otherwise → MISSING: the host must answer authenticationRequired; the
 *    UI never pretends a secret exists and never re-sends one to a new
 *    endpoint.
 *
 * The draft origin comparison uses the display origin token only; the Swift
 * side remains authoritative for what "same origin" means at save time.
 */
object McpCredentialIntent {
    fun compute(
        draft: McpDraftSnapshot,
        typedSecret: String?,
        seed: McpEditorSeedUi,
        seedOriginToken: String?,
        currentOriginToken: String?,
    ): CredentialDraftIntent {
        if (draft.authentication == McpAuthenticationUi.NONE) return CredentialDraftIntent.CLEAR
        if (!typedSecret.isNullOrEmpty()) return CredentialDraftIntent.SET
        val sameOrigin = seedOriginToken != null &&
            currentOriginToken != null &&
            seedOriginToken == currentOriginToken
        return if (seed.credentialStored && sameOrigin) {
            CredentialDraftIntent.KEEP_EXISTING
        } else {
            CredentialDraftIntent.MISSING
        }
    }
}

/* ----------------------------- draft mutations ----------------------------- */

/** Pure helpers for the MCP editor draft (identity separated from wire
 * identity: the draft is the EDIT identity; [McpEditorSeedUi.serverId] is
 * the saved/wire identity; a save writes against baseRevision, never blind). */
object McpDraftLogic {

    fun toggleTool(draft: McpDraftSnapshot, remoteName: String, enabled: Boolean): McpDraftSnapshot =
        draft.copy(
            disabledRemoteToolNames = if (enabled) {
                draft.disabledRemoteToolNames - remoteName
            } else {
                draft.disabledRemoteToolNames + remoteName
            },
        )

    fun toolEnabled(draft: McpDraftSnapshot, tool: McpToolRowUi): Boolean =
        !draft.disabledRemoteToolNames.contains(tool.remoteName)

    /**
     * ⇄ iOS upsert: switching authentication to NONE clears the typed RAM
     * draft (the secret is deleted on save); any change of the endpoint
     * ORIGIN drops the typed draft so a stale secret is never silently
     * reused on a new destination (provider-flow contract).
     */
    fun onAuthenticationChanged(draft: McpDraftSnapshot, next: McpAuthenticationUi): McpDraftSnapshot =
        draft.copy(authentication = next)

    fun endpointChangedOrigin(
        previousText: String,
        nextText: String,
    ): Boolean {
        val before = McpEndpointOrigin.parse(previousText) ?: return false
        val after = McpEndpointOrigin.parse(nextText) ?: return false
        return before.accountToken != after.accountToken
    }
}

/* --------------------------- discover import routes --------------------------- */

/** The three Discover import rows, in the iOS order (SkillsView.swift:84-86). */
enum class DiscoverImportRowId { PLUGINS_IMPORT, IMPORT_FOLDER, CREATOR }

/** Distinct destinations of those rows. */
enum class SkillImportRoute { FINDER_URL, FOLDER_PICKER, CREATOR }

/**
 * Pinned mapping: "plugins.import" opens the Skill FINDER URL sheet
 * (SkillsView.swift:84, showingFinder = true); "skills.import_folder"
 * presents the FOLDER PICKER (:85, showingFolderImporter = true); the creator
 * row opens the creator (:86). The hub page renders rows from this mapping
 * and the holder executes the route, so the finder and the folder picker
 * cannot silently collapse onto one another (holder + mapping tests).
 */
object SkillsImportRouting {
    fun routeFor(row: DiscoverImportRowId): SkillImportRoute = when (row) {
        DiscoverImportRowId.PLUGINS_IMPORT -> SkillImportRoute.FINDER_URL
        DiscoverImportRowId.IMPORT_FOLDER -> SkillImportRoute.FOLDER_PICKER
        DiscoverImportRowId.CREATOR -> SkillImportRoute.CREATOR
    }

    /** Route that must NEVER be the folder picker (the original distinction). */
    fun finderRowRoute(): SkillImportRoute = routeFor(DiscoverImportRowId.PLUGINS_IMPORT)
    fun folderRowRoute(): SkillImportRoute = routeFor(DiscoverImportRowId.IMPORT_FOLDER)
}

/* ------------------------ no-fake-availability helpers ------------------------ */

/**
 * The hub's honest labels/actions. Every string is either a host-supplied
 * projection value or a fixed localization key — the module never derives a
 * stronger claim than the projection states.
 */
object SkillsDisplayLogic {

    /** ⇄ the Discover card's conditional block, one-to-one. */
    fun catalogAction(state: CatalogCardStateUi): CatalogCardAction = when (state) {
        CatalogCardStateUi.NotInstalled -> CatalogCardAction.Install
        is CatalogCardStateUi.InstallStaging -> CatalogCardAction.Busy
        CatalogCardStateUi.InstalledReady -> CatalogCardAction.None
        CatalogCardStateUi.InstalledNeedsEnable -> CatalogCardAction.Enable
        is CatalogCardStateUi.UpdateTo -> CatalogCardAction.OpenUpgrade(state.version)
        is CatalogCardStateUi.Unavailable -> CatalogCardAction.Explain(state.remediation)
    }

    /**
     * Offer line for an installed row. OFFERED requires the HOST's verdict;
     * a skill that is merely enabled/installed never reads as offered
     * (SKL-DISCOVER-USABLE). Absent modules were never projected, so no
     * channel-specific claim exists to fake here.
     */
    fun offerSummary(row: SkillInstalledRowUi): OfferSummary = when (row.offerState) {
        SkillOfferStateUi.OFFERED -> OfferSummary.Offered
        SkillOfferStateUi.NOT_OFFERED_DISABLED -> OfferSummary.NotOffered(null)
        SkillOfferStateUi.NOT_OFFERED_NEEDS_SETUP -> OfferSummary.NotOffered(
            (row.availability as? SkillAvailabilityUi.NeedsConfiguration)?.remediation
        )
        SkillOfferStateUi.NOT_OFFERED_ENVIRONMENT -> OfferSummary.NotOffered(
            (row.availability as? SkillAvailabilityUi.EnvironmentUnavailable)?.remediation
        )
        SkillOfferStateUi.NOT_OFFERED_MODEL_OVERRIDE -> OfferSummary.NotOfferedModelOverride(
            row.modelOverrideNote
        )
    }

    /** Enable toggle is available except for read-only bundled guides. */
    fun canToggleEnabled(row: SkillInstalledRowUi): Boolean = !row.isBundledReadOnlyGuide

    /** Delete affordance ⇄ the hub's exposed check: hidden system guides
     * are read-only ("System guides update only with the app"). */
    fun canDelete(row: SkillInstalledRowUi): Boolean = !row.isBundledReadOnlyGuide

    /** Stop affordance only for a real host-projected run (SKL-CANCEL). */
    fun canRequestStop(row: SkillInstalledRowUi): Boolean =
        row.runActivity is SkillRunActivityUi.Running

    /** Creator sheet gating ⇄ disabled(name.isEmpty || description.isEmpty
     * || instructions.isEmpty || center.isWorking). */
    fun creatorInstallEnabled(draft: SkillCreatorDraftUi, hostWorking: Boolean): Boolean =
        !hostWorking && draft.name.isNotEmpty() && draft.description.isNotEmpty() &&
            draft.instructions.isNotEmpty()

    /** Finder sheet gating ⇄ disabled(url.isEmpty || rewriteModelID == nil
     * || center.isWorking). */
    fun finderInstallEnabled(urlText: String, selectedModelId: String?, hostWorking: Boolean): Boolean =
        !hostWorking && urlText.isNotEmpty() && selectedModelId != null

    /** Filter ⇄ searchText.localizedStandardContains(name/description). */
    fun <T> filterRows(rows: List<T>, query: String, nameOf: (T) -> String, summaryOf: (T) -> String?): List<T> {
        if (query.isBlank()) return rows
        val needle = query.trim().lowercase()
        return rows.filter {
            nameOf(it).lowercase().contains(needle) ||
                summaryOf(it)?.lowercase()?.contains(needle) == true
        }
    }
}

/** What the Discover card can honestly offer right now. */
sealed interface CatalogCardAction {
    data object Install : CatalogCardAction
    data object Enable : CatalogCardAction
    data class OpenUpgrade(val version: String) : CatalogCardAction
    data object Busy : CatalogCardAction
    data object None : CatalogCardAction
    /** Button disabled WITH the host's reason — never a silent dead control. */
    data class Explain(val remediation: String) : CatalogCardAction
}

sealed interface OfferSummary {
    data object Offered : OfferSummary
    /** [remediation] comes from the host projection when it has one. */
    data class NotOffered(val remediation: String?) : OfferSummary
    data class NotOfferedModelOverride(val note: String?) : OfferSummary
}

/* -------------------------------- MCP display -------------------------------- */

/** ⇄ MCPServersView stateText/stateIcon/stateColor mapping, one-to-one. */
object McpDisplayLogic {

    fun connectionBadge(state: McpConnectionStateUi, cancelling: Boolean): McpConnectionBadge =
        when {
            cancelling && state is McpConnectionStateUi.Connecting ->
                McpConnectionBadge.Cancelling
            else -> when (state) {
                McpConnectionStateUi.Inactive -> McpConnectionBadge.NotConnected
                is McpConnectionStateUi.Connecting -> McpConnectionBadge.ReadingTools
                is McpConnectionStateUi.Ready -> McpConnectionBadge.Ready(state.toolCount)
                is McpConnectionStateUi.Failed -> McpConnectionBadge.Failed(state.message)
            }
        }

    /** The only honest tool count: straight from a Ready projection. */
    fun toolCountFor(state: McpConnectionStateUi): Int? =
        (state as? McpConnectionStateUi.Ready)?.toolCount
}

sealed interface McpConnectionBadge {
    data object NotConnected : McpConnectionBadge
    data object ReadingTools : McpConnectionBadge
    /** Count arrives ONLY from the host's ready(n) — never estimated. */
    data class Ready(val count: Int) : McpConnectionBadge
    data object Cancelling : McpConnectionBadge
    data class Failed(val message: String) : McpConnectionBadge
}
