// SPDX-License-Identifier: MPL-2.0
//
// The single narrow seam between the Skills/MCP presentation flow (this
// module) and the host that owns EVERY real effect (shared Swift runtime
// services behind the accepted bridge): catalog refresh, staged installs,
// enable/delete with revision binding, upgrade check/apply/rollback,
// creator/finder/folder installs, connector destination routing, MCP
// save/connect/disconnect/refresh/tool toggles and run cancellation.
//
// The module NEVER performs I/O, never persists, never touches the network
// and never renders success on its own. Async results arrive back
// exclusively as new immutable [IntegrationsDestinationState] projections
// addressed to the matching identity/token (editor epoch, form id, review
// id, effect token, run scope generation); stale ones are ignored.
//
// Boolean-returning effects follow the provider-flow contract: true means
// the host REALLY STARTED the operation and will report its outcome via
// projections; false means nothing started and the UI must not claim
// progress.
//
// Swift destinations for the binding stage (see binding-map.json):
//  - refreshCatalog          → SkillsCenter.refreshOfficialCatalog(force:)
//  - installOfficialSkill    → SkillsCenter.installOfficialSkill(id:)
//  - setSkillEnabled /       → SkillsCenter.setEnabled / remove →
//    deleteSkill               SkillManageTool.Arguments{action,id,
//                              expectedDigest} (revision-bound)
//  - cancelSkillRun          → the execution layer's owned job stop
//                              (ToolRunnerRegistry / jobs lifecycle)
//  - checkUpgrade /          → SkillsCenter.checkGitHubUpgrade /
//    applyUpgrade /            applyReviewedUpgrade / rollbackLatestUpgrade
//    cancelUpgrade /           / cancelUpgrade
//    rollbackUpgrade
//  - createSkill /           → SkillsCenter.create(name:description:
//    installFromFinder         instructions:) / installFromFinder(urlText:
//    / requestFolderStaging    rewriteModelID:) / the .fileImporter step
//    / importStagedPackage     (folder) → installTraditionalPackage
//  - confirmPendingInstallation → SkillsCenter.confirmPendingInstallation
//    / cancelPendingInstallation
//  - setAutoScriptedUpdates  → ContentUpdateCenter.scriptedAutoInstallDefaultsKey
//  - openConnectorDestination → app-shell routes for Mail/GitHub settings
//  - seedMcpEditor / saveMcpServer → MCPSettingsCenter.upsert(server:credential:)
//    → MCPServerConfiguration.validate() + keychain account bound to
//      id + scheme/host/port
//  - setMcpServerEnabled / setMcpToolEnabled / deleteMcpServer →
//    MCPSettingsCenter.setEnabled / setToolEnabled / remove
//  - refreshMcpServer / cancelMcpRefresh → MCPSettingsCenter.refresh(serverID:)
//    with refreshGenerationByServerID fencing

package com.floe.android.feature.integrations

/**
 * Everything the UI may ask the host to DO. Nothing here is allowed to
 * bypass the host's existing policy/approval layer: showing a capability
 * row, confirming an install review or flipping an enable toggle grants no
 * tool permission — the shared Swift policy remains the only authority.
 */
interface IntegrationUiCallbacks {

    /* ----------------------------- hub lifecycle ----------------------------- */

    /** Initial hub load (⇄ .task { center.load(); refreshOfficialCatalog() }
     * plus MCP activate). Host publishes the resulting projection. */
    fun load()

    /** Leaving the surface: drop local sessions and notify the host so it
     * can tear down staged review state (⇄ onDisappear cancelUpgrade rules;
     * in-flight host work keeps running and its late results stay fenced). */
    fun closeAll()

    /** Pull-to-refresh / explicit refresh. True = check started. */
    fun refreshCatalog(force: Boolean): Boolean

    /* -------------------------------- skills -------------------------------- */

    /** Official hub install (⇄ installOfficialSkill). True = started. */
    fun installOfficialSkill(skillId: String): Boolean

    /** Enable/disable, revision-bound (⇄ expectedDigest). True = accepted;
     * a changed skill surfaces the host's conflict error via projection. */
    fun setSkillEnabled(skillId: String, expectedRevision: String, enabled: Boolean): Boolean

    /** Destructive, revision-bound; the UI only calls this after the
     * explicit confirm dialog (⇄ remove(skill) with recoverable backup). */
    fun deleteSkill(skillId: String, expectedRevision: String): Boolean

    /** SKL-CANCEL: stop one real owned run. The scope must be EXACTLY what
     * the host projected — task+run required, environment/job roles only as
     * the real typed roles the host actually carries (RunOnly vs JobOwned);
     * the module never invents or rewrites any part. True = stop dispatched. */
    fun cancelSkillRun(scope: SkillRunScopeUi): Boolean

    /** ⇄ the shared scripted-auto-install toggle (one value with Settings →
     * Content updates; no second copy). */
    fun setAutoScriptedUpdates(enabled: Boolean)

    /* --------------------------- install review ---------------------------- */

    /** Explicit Install on the review sheet. True = the host accepted THIS
     * review token and begins its staged commit. Dismissing the sheet before
     * this call only drops the review (nothing has run yet). */
    fun confirmPendingInstallation(reviewId: Long): Boolean

    /** Drop the staged review; the staged copy is discarded by the host.
     * Does not cancel an install that was already confirmed (that is owned
     * by the host service and survives view reconstruction). */
    fun cancelPendingInstallation(reviewId: Long)

    /* --------------------------- transient forms --------------------------- */

    /** Creator sheet install (⇄ center.create). [formId] fences the outcome. */
    fun createSkill(formId: String, draft: SkillCreatorDraftUi): Boolean

    /** Finder install (⇄ installFromFinder(urlText:rewriteModelID:)). */
    fun installFromFinder(formId: String, urlText: String, rewriteModelId: String?): Boolean

    /** Show the folder PICKER (⇄ .fileImporter(isPresented:
     * $showingFolderImporter) — a shell capability on Android: SAF / file
     * picker). True means the host really presented the picker; the staged
     * opaque reference then arrives via the holder's onPackageStaged. This
     * is DISTINCT from the Finder URL sheet: the two import routes must
     * never collapse onto one another (SkillsView.swift:84 vs :85). */
    fun requestFolderStaging(): Boolean

    /** Folder import commit via the OPAQUE staged reference (no path
     * traversal, no binary in the bridge): ⇄ the fileImporter copy-to-temp
     * step behind installTraditionalPackage. */
    fun importStagedPackage(formId: String, reference: StagedPackageRefUi): Boolean

    /* ------------------------------ upgrade ------------------------------- */

    /** Seed when the upgrade sheet opens (⇄ onAppear: lastGitHubSource +
     * auto-check for official skills). Null = the host cannot seed; the UI
     * shows the honest unavailable state instead of inventing data. */
    fun seedUpgrade(skillId: String): SkillUpgradeUi?

    /** [source] null for official skills (hub source fixed); typed fields
     * for community sources (⇄ GitHubSkillSource validation is the host's). */
    fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean

    /** Apply the reviewed candidate. True = started; [effectToken] echoes in
     * SkillUpgradeUi.lastEffect so a late result cannot act on a new sheet. */
    fun applyUpgrade(skillId: String, effectToken: Long): Boolean

    /** Tear down staged upgrade review (⇄ center.cancelUpgrade: removes the
     * leased staging tree; the installed version is untouched). */
    fun cancelUpgrade(skillId: String)

    /** Restore previous content and grants (⇄ rollbackLatestUpgrade), only
     * after the explicit confirmation dialog. */
    fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean

    /* ------------------------------ connectors ------------------------------ */

    /** Mail/GitHub/etc. destinations stay host-owned: the module asks the
     * host to navigate; it never renders another module's UI. True = the
     * host handled the destination. */
    fun openConnectorDestination(destinationId: String): Boolean

    /* --------------------------------- MCP --------------------------------- */

    /** Pure projection read when the editor opens (saved config or new-
     * defaults seed). Null = unavailable right now; honest state instead of
     * invented defaults. */
    fun seedMcpEditor(serverId: String?): McpEditorSeedUi?

    fun mcpEditorOpened(identity: McpEditorIdentity)

    /** Editor dismissed. discarded=true = Cancel (draft + RAM secret thrown
     * away); a save already accepted by the host may still commit, but its
     * late result cannot touch this closed editor (epoch guard). */
    fun mcpEditorClosed(identity: McpEditorIdentity, discarded: Boolean)

    /** Save-and-connect (⇄ upsert + refresh when enabled). True = the host
     * accepted the request for this identity+epoch and will report
     * [McpEditorUiState.saveOutcome]/[McpEditorUiState.saveError].
     *
     * Failure-event contract: every NEW failed attempt must produce exactly
     * one final projection for this identity+epoch with
     * saveInFlight=false, saveError/saveOutcome as observed, and a STRICTLY
     * INCREASING [McpEditorUiState.saveFailureSequence] — even when the
     * message repeats the previous failure. A local validation failure can
     * be published synchronously inside this call, so begin+failure may
     * coalesce into one composition; the sequence is then the only attempt
     * boundary. Do not advance it for polls, text changes or connection/
     * discovery failures. */
    fun saveMcpServer(request: McpSaveRequest): Boolean

    /** Destructive; only after the explicit confirm dialog (⇄ remove: also
     * deletes the bound credential account — the host's authority). */
    fun deleteMcpServer(serverId: String): Boolean

    /** ⇄ setEnabled: enabling triggers a real refresh; disabling
     * invalidates the refresh generation and unregisters the tools. */
    fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean

    /** Per-tool enable inside the editor draft is LOCAL; this call is only
     * for the row-level live toggle the list may surface later. The draft
     * toggles ride on save (⇄ the iOS editor edits its @State copy). */
    fun setMcpToolEnabled(serverId: String, remoteName: String, enabled: Boolean): Boolean

    /** Connect / re-read tools (⇄ refresh(serverID:)). True = started under
     * a NEW host generation surfaced via [McpConnectionStateUi.Connecting]. */
    fun refreshMcpServer(serverId: String): Boolean

    /** Request cancellation of one in-flight refresh under its exact
     * generation (⇄ the generation fencing in refresh(): a superseded
     * client is torn down and never registers). True = the host accepted;
     * the terminal state still arrives via projection. */
    fun cancelMcpRefresh(serverId: String, generation: Long): Boolean

    /**
     * The ONE explicit local-network permission action
     * (MAIN_ANDROID37_LAN_PERMISSION_DECISION_20261021): tapped from the
     * host-projected [LocalNetworkGuidanceUi] row. The host re-reads the
     * REAL platform state, opens the system dialog for a still-offerable
     * request (chained only to the captured blocked hop) or this app's
     * settings page for recovery, and never conflates the permission with
     * an authentication failure. True = a real platform affordance (or
     * the captured retry hop) was started; false = nothing happened.
     */
    fun localNetworkGuidanceAction(): Boolean
}
