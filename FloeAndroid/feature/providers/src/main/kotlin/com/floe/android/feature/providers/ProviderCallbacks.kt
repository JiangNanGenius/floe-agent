// SPDX-License-Identifier: MPL-2.0
//
// The single narrow seam between the presentation flow (this module) and the
// host that owns every real effect (shared Swift services behind the accepted
// bridge): save, test-connection, model discovery, catalog refresh, list
// mutations. The module NEVER performs I/O, never persists and never renders
// success on its own — outcomes arrive back exclusively as new immutable
// [ProviderEditorUiState] / [ProviderListUiState] projections addressed to
// the matching [ProviderEditorIdentity], and stale identities are ignored.

package com.floe.android.feature.providers

/**
 * Snapshot of the connection inputs one explicit network action probes.
 * [credentialDraft] is the RAM-typed secret passed for THIS action only; the
 * host must route it to the Keystore gateway on save and must not log it.
 *
 * Accepted steer `g02-source-secret-print-and-endpoint-epoch-fix`: the
 * generated data-class [toString] would have printed the credential, so it is
 * overridden here to mask every secret-shaped field explicitly. Nothing in
 * this module logs the probe, but a redacted representation removes the
 * accidental-leak path through debuggers, crash reports and call-site logging.
 * Header VALUES are not printed either (only the count), because a caller can
 * misclassify a secret as a header; classification remains Swift's authority.
 */
data class ConnectionProbeUi(
    val endpointAbsoluteString: String,
    val wireProtocol: WireProtocolUi,
    /** Parsed non-secret header lines (host re-parses with authority; this is
     * only the convenience projection of what the user typed). */
    val nonSecretHeaders: Map<String, String>,
    val credentialDraft: String?,
    val allowsPlainHttp: Boolean,
    val toolNameCompatibility: Boolean,
) {
    /** Explicit redaction: never includes the credential or header values. */
    override fun toString(): String =
        "ConnectionProbeUi(endpoint=$endpointAbsoluteString, wireProtocol=$wireProtocol, " +
            "nonSecretHeaderCount=${nonSecretHeaders.size}, " +
            "credential=${if (credentialDraft.isNullOrEmpty()) "absent" else "<present:redacted>"}, " +
            "allowsPlainHttp=$allowsPlainHttp, toolNameCompatibility=$toolNameCompatibility)"
}

/**
 * Everything the UI may ask the host to DO. Each effect reports availability
 * honestly: a Boolean return of true means the host really STARTED the
 * operation; false means it did not (the UI must not claim progress). Async
 * results arrive exclusively through state projections.
 *
 * Swift destinations for the binding stage:
 *  - [saveProvider]               → ProviderSaveRunner validate → store secret
 *                                   → commit metadata → verify readback
 *                                   (ConversationCenter / secret gateway).
 *  - [testConnection]/[discoverModels] → ProviderAdapterFactory round trips.
 *  - [requestCatalogRefresh]      → the `onRefreshCatalog` closure handed to
 *                                   ProvidersSettingsView on iOS.
 *  - [setProviderEnabled]/[deleteProvider] → ProviderListViewModel equivalents.
 */
interface ProviderUiCallbacks {

    /* ------------------------------ list ------------------------------ */

    /** Row tap / Edit: the host opens the editor for a saved provider (the
     * module seeds it through [seedEditorFor] and publishes its identity). */
    fun openExistingProvider(providerId: String)

    /** New provider for [role] chosen in the purpose chooser (host may update
     * availability or pre-seed defaults before the module opens the sheet). */
    fun requestNewProvider(role: ProviderServiceRoleUi)

    /** True when the host accepted the toggle (host publishes the new list). */
    fun setProviderEnabled(providerId: String, enabled: Boolean): Boolean

    /** Destructive; the UI only calls this after the explicit confirm dialog. */
    fun deleteProvider(providerId: String): Boolean

    /* --------------------------- editor session --------------------------- */

    /**
     * Pure projection read used when the editor opens: the host builds the
     * seed from the SAVED profile/models (existing) or from defaults for the
     * role (new). Null = the host cannot seed right now; the UI shows the
     * honest unavailable state instead of inventing data.
     */
    fun seedEditorFor(role: ProviderServiceRoleUi, existingProviderId: String?): ProviderEditorSeedUi?

    /** Seed for a distinct-connection offer's own editor (⇄ SeparateOfferRoute). */
    fun seedSeparateOfferEditor(seed: SeparateOfferSeedUi, role: ProviderServiceRoleUi): ProviderEditorSeedUi?

    fun editorOpened(identity: ProviderEditorIdentity)

    /**
     * Seed-aware open: the holder passes the EXACT seed object it just put
     * into the draft store. A host that tracks a frozen provider CAS
     * baseline binds it from THIS seed (the same row read that produced the
     * draft), never from a second read that a background list refresh could
     * advance in between. The default delegates to the identity-only
     * [editorOpened], so existing host doubles and baseline behavior stay
     * source-compatible.
     */
    fun editorOpened(identity: ProviderEditorIdentity, seededFrom: ProviderEditorSeedUi?) {
        editorOpened(identity)
    }

    /** Editor dismissed. discarded=true = Cancel (draft thrown away); a save
     * in flight may still commit in the host, but its late result cannot touch
     * this closed editor (epoch guard in [ProviderDraftStore]). */
    fun editorClosed(identity: ProviderEditorIdentity, discarded: Boolean)

    /**
     * Save dispatch. Returns true only when the host accepted the request and
     * will report the outcome for this identity+epoch (success projection or
     * [ProviderEditorUiState.saveError]); false means nothing was started.
     * The credential text is passed only to this call and never stored by the
     * module after dispatch.
     */
    fun saveProvider(identity: ProviderEditorIdentity, draft: ProviderDraftSnapshot, credentialDraft: String?): Boolean

    /** Explicit network action: real connectivity probe with model count. */
    fun testConnection(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean

    /** Cancel the in-flight probe (UI returns to Idle via the next projection). */
    fun cancelConnectionTest(identity: ProviderEditorIdentity)

    /** Explicit /models discovery round trip. */
    fun discoverModels(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean

    fun cancelModelDiscovery(identity: ProviderEditorIdentity)

    /* ---------------------------- supplier picker ---------------------------- */

    /** Built-in preset chosen in the unified selector (⇄ applyPreset). */
    fun supplierPresetChosen(preset: SupplierPresetUi)

    /** Verified catalog entry chosen (⇄ applyCatalogEntry). */
    fun supplierCatalogEntryChosen(entry: OfficialSupplierUi)

    /** Official-catalog refresh — explicit network action, never triggered by
     * opening the menu or typing a query. */
    fun requestCatalogRefresh(): Boolean

    /* ------------------------------ offers ------------------------------ */

    /** True when enabling this shared offer requires a real discovery probe
     * (⇄ offer.requiresDiscovery / enableServiceOfferWithDiscovery). */
    fun serviceOfferRequiresDiscovery(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi): Boolean

    /** Start the discovery a shared offer needs; true only when really started. */
    fun requestOfferDiscovery(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi): Boolean

    fun offerDecisionChanged(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi, enabled: Boolean)

    /** One-time multi-role prompt decision (⇄ confirmServiceOfferSelection). */
    fun offerPromptConfirmed(identity: ProviderEditorIdentity, roles: Set<ProviderServiceRoleUi>)

    /** Dismissed / Not now (⇄ declineServiceOfferPrompt: role not re-asked). */
    fun offerPromptDeclined(identity: ProviderEditorIdentity)
}
