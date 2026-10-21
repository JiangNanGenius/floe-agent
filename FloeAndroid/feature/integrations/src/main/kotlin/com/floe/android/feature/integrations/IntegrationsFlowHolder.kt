// SPDX-License-Identifier: MPL-2.0
//
// Root presentation holder for the Skills/MCP administration flow. It owns
// the navigation stack, the RAM-only MCP editor store, the transient skill
// form store, the skill-run cancel latches and the MCP refresh-cancel
// latches; every UI mutation flows through the host seam and produces an
// explicit result the caller can act on. No SavedStateHandle, no Bundle, no
// rememberSaveable, no database.
//
// Never fabricates outcomes: host projections are the only source of truth,
// and every stale effect is rejected by its fence:
//  - MCP editor identity + epoch — old results cannot close/update a newer
//    editor (rapid navigation/back/reopen contract);
//  - reviewId — a confirmation for a superseded staged install is ignored;
//  - formId — creator/finder/import outcomes address one form session;
//  - effectToken — upgrade apply/rollback outcomes address one dispatch;
//  - run scope identity — a stop is bound to the FULL projected typed scope
//    (task, run, real optional env/job, generation); a terminal projection
//    or a replaced scope clears it; equal job/generation fields on another
//    task/run never match the live latch;
//  - refresh generation — a cancel binds to one host Connecting(generation).
//
// Dismissing a dialog is never an implicit cancel of work the host already
// STARTED: installs/commits are owned by the host service and survive view
// reconstruction (SKL-INSTALL-VERSION, SKL-CANCEL).

package com.floe.android.feature.integrations

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf

/* ------------------------------ result types ------------------------------ */

/**
 * Outcome of one module action. Results NEVER carry secrets and are never
 * logged. `Stale` means a callback/outcome addressed to an identity the
 * store no longer accepts (late result cannot replace another session).
 */
sealed interface IntegrationsFlowResult {
    data object Accepted : IntegrationsFlowResult
    data object Stale : IntegrationsFlowResult
    data class Rejected(val reason: RejectedReason) : IntegrationsFlowResult
}

enum class RejectedReason {
    /** A save is already in flight for this editor identity+epoch. */
    SAVE_IN_FLIGHT,
    /** No open session exists for that identity/token. */
    NO_SESSION,
    /** The draft cannot support this action right now. */
    INPUT_INSUFFICIENT,
    /** The host refused to start the effect (nothing happened). */
    HOST_UNAVAILABLE,
    /** A destructive/stop intent needs its explicit confirmation first. */
    CONFIRMATION_REQUIRED,
    /** A stop was already accepted for this EXACT live projected scope. */
    CANCEL_IN_FLIGHT,
}

private fun rejected(reason: RejectedReason): IntegrationsFlowResult =
    IntegrationsFlowResult.Rejected(reason)

/* ------------------------------- session keys ------------------------------ */

/** One module-issued upgrade sheet session for a skill. */
data class UpgradeSession(
    val skillId: String,
    var effectToken: Long = 0L,
    /** ⇄ the sheet's .onAppear auto-check fires at most once per session. */
    var autoCheckDispatched: Boolean = false,
)

/* --------------------------------- holder --------------------------------- */

class IntegrationsFlowHolder(
    private val host: IntegrationUiCallbacks,
) {
    val navigation = IntegrationsNavStack()
    val mcpEditors = McpEditorStore()
    val skillForms = SkillFormStore()

    /** ⇄ SkillsView @State searchText (hub; local filtering only). */
    val hubSearchQuery: MutableState<String> = mutableStateOf("")

    /** ⇄ showingInstalled segment selection (false = Discover). */
    val showingInstalled: MutableState<Boolean> = mutableStateOf(false)

    /** Local latches: cancel REQUESTED for a projected run scope, keyed by
     * skill id. The value is the FULL typed projected scope (task, run,
     * real optional env/job, generation) — data-class equality over the
     * whole identity, so a stop for another task/run that merely shares the
     * job/generation fields neither blocks a new dispatch nor renders this
     * row as cancelling. Cleared when the row's run activity leaves that
     * exact scope (terminal projection or replaced scope).
     *
     * Snapshot-backed: the "Cancelling…" affordance must re-render the
     * moment the latch flips (accepted stop / terminal echo), not wait for
     * an unrelated projection. Reads during composition subscribe; the
     * fencing semantics are unchanged. */
    private val runCancelLatched = mutableStateMapOf<String, SkillRunScopeUi>()
    private val refreshCancelLatched = mutableStateMapOf<String, Long>()

    /** The module keeps its OWN pending-install sheet sync state so the same
     * reviewId is presented exactly once. Host tokens are monotonic: once a
     * review is confirmed/cancelled, later projections of it never re-open
     * the sheet (a commit projection must not resurrect the dialog). */
    private var presentedReviewId: Long? = null
    private var lastHandledReviewId: Long = -1L

    /** Upgrade sheets keyed by skillId (one open sheet per skill). */
    private val upgradeSessions = mutableMapOf<String, UpgradeSession>()

    /* ------------------------------ hub lifecycle ------------------------------ */

    /** Latched initial load: a recreated composition cannot re-dispatch it
     * (the holder is retained by the host). */
    private var loadDispatched = false

    fun loadOnce() {
        if (loadDispatched) return
        loadDispatched = true
        host.load()
    }

    fun load() = host.load()

    /* -------------------------------- skills -------------------------------- */

    fun refreshCatalog(force: Boolean): Boolean = host.refreshCatalog(force)

    fun installOfficialSkill(skillId: String): IntegrationsFlowResult =
        if (host.installOfficialSkill(skillId)) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)

    /**
     * Enable toggle. NOTE (SKL-SOURCE-NO-GRANT): flipping enable never grants
     * any capability — the host's policy layer alone decides what may run;
     * the row's offer state keeps coming from the projection.
     */
    fun setSkillEnabled(skillId: String, expectedRevision: String, enabled: Boolean): Boolean =
        host.setSkillEnabled(skillId, expectedRevision, enabled)

    /** Destructive delete, only with the confirm-dialog flag set. */
    fun deleteSkill(skillId: String, expectedRevision: String, confirmed: Boolean): IntegrationsFlowResult {
        if (!confirmed) return rejected(RejectedReason.CONFIRMATION_REQUIRED)
        return if (host.deleteSkill(skillId, expectedRevision)) {
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    /** SKL-CANCEL: request the host stop one REAL projected run. Returns
     * Rejected(NO_SESSION) when the row projects no running scope (a stop
     * is never dispatched on an idle row — nothing fakes a cancellation),
     * and Rejected(CANCEL_IN_FLIGHT) when an already-accepted stop covers
     * the EXACT live scope: the holder itself rejects the duplicate, the
     * disabled affordance alone is never the guard. A host refusal
     * (HOST_UNAVAILABLE) never latches, so a retry is possible; a replaced
     * scope overwrites the stale latch on the next accepted dispatch. */
    fun cancelSkillRun(row: SkillInstalledRowUi): IntegrationsFlowResult {
        val running = row.runActivity as? SkillRunActivityUi.Running
            ?: run {
                // Terminal projection: drop any stale latch for this row.
                runCancelLatched.remove(row.skillId)
                return rejected(RejectedReason.NO_SESSION)
            }
        if (runCancelLatched[row.skillId] == running.scope) {
            return rejected(RejectedReason.CANCEL_IN_FLIGHT)
        }
        val started = host.cancelSkillRun(running.scope)
        if (!started) return rejected(RejectedReason.HOST_UNAVAILABLE)
        runCancelLatched[row.skillId] = running.scope
        return IntegrationsFlowResult.Accepted
    }

    /** True while the host STILL projects the same running scope after an
     * accepted stop (renders "Cancelling…"). A host-projected
     * [SkillRunActivityUi.Cancelling] also reads as cancelling. A terminal
     * (None) or REPLACED-scope projection clears the latch, so a stop for an
     * old generation can never hang the row in "cancelling" forever.
     * Matching is over the FULL typed scope identity (task, run, real
     * optional env/job, generation): equal job/generation fields on another
     * task/run do not count as this row's live latch. */
    fun isRunCancelling(row: SkillInstalledRowUi): Boolean {
        when (val activity = row.runActivity) {
            is SkillRunActivityUi.Cancelling -> return true
            is SkillRunActivityUi.Running -> {
                val latched = runCancelLatched[row.skillId]
                    ?: return false
                val matches = latched == activity.scope
                if (!matches) runCancelLatched.remove(row.skillId)
                return matches
            }
            SkillRunActivityUi.None -> {
                runCancelLatched.remove(row.skillId)
                return false
            }
        }
    }

    fun setAutoScriptedUpdates(enabled: Boolean) = host.setAutoScriptedUpdates(enabled)

    /* ---------------------------- transient forms ---------------------------- */

    /** Skill Creator sheet (⇄ skills.creator / toolbar plus → showingCreator). */
    fun openCreator(): SkillFormSlot {
        val slot = skillForms.open(IntegrationsPane.SKILL_CREATOR)
        navigation.push(IntegrationsPane.SKILL_CREATOR, slot.formId)
        return slot
    }

    /**
     * Skill Finder URL sheet. ⇄ SkillsView.swift:84 — the "plugins.import"
     * row AND the toolbar magnifier both open the FINDER (showingFinder),
     * NOT the folder picker. Kept distinct from [openFolderImport] and
     * covered by a dedicated holder test so the two effects cannot silently
     * collapse onto one another.
     */
    fun openFinder(): SkillFormSlot {
        val slot = skillForms.open(IntegrationsPane.SKILL_FINDER)
        navigation.push(IntegrationsPane.SKILL_FINDER, slot.formId)
        return slot
    }

    /**
     * ⇄ SkillsView.swift:85 — the "skills.import_folder" row presents the
     * FOLDER PICKER (showingFolderImporter). The picker itself is a shell
     * capability (SAF), so this only asks the host to present it; nothing
     * opens inside the module until a staged reference actually arrives.
     */
    fun openFolderImport(): IntegrationsFlowResult =
        if (host.requestFolderStaging()) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)

    /**
     * Executes ONE Discover import route. Called by the hub page after the
     * pure [SkillsImportRouting] mapping, so the finder (URL sheet) and the
     * folder picker remain separate host effects.
     */
    fun runImportRoute(route: SkillImportRoute): IntegrationsFlowResult = when (route) {
        SkillImportRoute.FINDER_URL -> {
            openFinder()
            IntegrationsFlowResult.Accepted
        }
        SkillImportRoute.FOLDER_PICKER -> openFolderImport()
        SkillImportRoute.CREATOR -> {
            openCreator()
            IntegrationsFlowResult.Accepted
        }
    }

    /**
     * The host finished staging a picked folder: open the import-confirm
     * form with ONLY the opaque reference. Never called for the Finder
     * route; the finder sheet never passes through here.
     */
    fun onPackageStaged(reference: StagedPackageRefUi): SkillFormSlot {
        val slot = skillForms.open(IntegrationsPane.SKILL_IMPORT)
        slot.stagedReference.value = reference
        navigation.push(IntegrationsPane.SKILL_IMPORT, slot.formId)
        return slot
    }

    fun closeForm(formId: String) {
        val slot = skillForms.slot(formId) ?: return
        // Closing the form surface never cancels a host-started install:
        // if a dispatch is latched, the host service finishes and the row
        // updates; the outcome for a closed form is dropped as stale.
        skillForms.close(formId)
        navigation.closeTopIf(slot.pane, formId)
    }

    fun submitCreator(formId: String, hostWorking: Boolean): IntegrationsFlowResult {
        val slot = skillForms.slot(formId) ?: return rejected(RejectedReason.NO_SESSION)
        if (slot.dispatchInFlight || hostWorking) return rejected(RejectedReason.SAVE_IN_FLIGHT)
        val draft = slot.creatorDraft()
        if (!SkillsDisplayLogic.creatorInstallEnabled(draft, hostWorking = false)) {
            return rejected(RejectedReason.INPUT_INSUFFICIENT)
        }
        return if (host.createSkill(formId, draft)) {
            slot.markDispatched()
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    fun submitFinder(formId: String, hostWorking: Boolean): IntegrationsFlowResult {
        val slot = skillForms.slot(formId) ?: return rejected(RejectedReason.NO_SESSION)
        if (slot.dispatchInFlight || hostWorking) return rejected(RejectedReason.SAVE_IN_FLIGHT)
        val url = slot.finderUrl.value
        val modelId = slot.finderModelId.value
        if (!SkillsDisplayLogic.finderInstallEnabled(url, modelId, hostWorking = false)) {
            return rejected(RejectedReason.INPUT_INSUFFICIENT)
        }
        return if (host.installFromFinder(formId, url, modelId)) {
            slot.markDispatched()
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    fun submitImport(formId: String, hostWorking: Boolean): IntegrationsFlowResult {
        val slot = skillForms.slot(formId) ?: return rejected(RejectedReason.NO_SESSION)
        if (slot.dispatchInFlight || hostWorking) return rejected(RejectedReason.SAVE_IN_FLIGHT)
        val reference = slot.stagedReference.value ?: return rejected(RejectedReason.INPUT_INSUFFICIENT)
        return if (host.importStagedPackage(formId, reference)) {
            slot.markDispatched()
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    /**
     * Consume the host form outcome. Only the CURRENT open form with that id
     * is affected; a late outcome for a closed form is stale (ignored).
     * Success closes the sheet (⇄ iOS "dismiss if errorMessage == nil").
     */
    fun applyFormOutcome(outcome: SkillsFormOutcomeUi?): Boolean {
        outcome ?: return false
        val slot = skillForms.slot(outcome.formId) ?: return false
        slot.resolveOutcome()
        if (outcome.succeeded) {
            closeForm(outcome.formId)
        }
        // Failure: the sheet stays open showing the host message (page reads
        // skills.errorMessage / outcome.message via the destination).
        return true
    }

    /* ---------------------------- install review ---------------------------- */

    /** ⇄ sheet(item: $center.pendingInstallation): the destination mirrors a
     * host-staged review into the pane exactly once per reviewId. */
    fun syncInstallReviewPane(review: SkillInstallReviewUi?) {
        val existing = navigation.entryFor(IntegrationsPane.INSTALL_REVIEW)
        if (review != null) {
            // Already confirmed/cancelled: never resurrect the dialog.
            if (review.reviewId <= lastHandledReviewId) return
            if (presentedReviewId == review.reviewId) return
            // A NEW staged review replaces any sheet still showing an older
            // one; the old key must not linger (its projection is gone).
            if (existing != null) {
                navigation.closeTopIf(IntegrationsPane.INSTALL_REVIEW, existing.key)
            }
            presentedReviewId = review.reviewId
            navigation.push(IntegrationsPane.INSTALL_REVIEW, review.reviewId.toString())
        } else {
            if (existing != null) {
                navigation.closeTopIf(IntegrationsPane.INSTALL_REVIEW, existing.key)
            }
            presentedReviewId = null
        }
    }

    /** Explicit Install on the review sheet (⇄ confirmPendingInstallation). */
    fun confirmInstallReview(review: SkillInstallReviewUi): IntegrationsFlowResult {
        if (review.reviewId != presentedReviewId) return IntegrationsFlowResult.Stale
        return if (host.confirmPendingInstallation(review.reviewId)) {
            // The commit runs in the host service; closing the sheet here is
            // NOT a cancellation — rows keep projecting staging stages.
            lastHandledReviewId = maxOf(lastHandledReviewId, review.reviewId)
            presentedReviewId = null
            navigation.closeTopIf(IntegrationsPane.INSTALL_REVIEW, review.reviewId.toString())
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    /** Dismiss/cancel WITHOUT confirming drops the staged review only. */
    fun cancelInstallReview(review: SkillInstallReviewUi) {
        if (review.reviewId == presentedReviewId) {
            host.cancelPendingInstallation(review.reviewId)
            lastHandledReviewId = maxOf(lastHandledReviewId, review.reviewId)
            presentedReviewId = null
        }
        navigation.closeTopIf(IntegrationsPane.INSTALL_REVIEW, review.reviewId.toString())
    }

    /* -------------------------------- upgrade -------------------------------- */

    /** Open the upgrade sheet (⇄ sheet(item: $updatingSkill)). Null seed =
     * honest unavailable pane content (page renders the retry state). */
    fun openUpgrade(skillId: String) {
        upgradeSessions.putIfAbsent(skillId, UpgradeSession(skillId))
        navigation.push(IntegrationsPane.UPGRADE_REVIEW, skillId)
    }

    fun upgradeSession(skillId: String): UpgradeSession? = upgradeSessions[skillId]

    /** Seed for the open sheet; the host also decides the auto-check. */
    fun seedUpgrade(skillId: String): SkillUpgradeUi? = host.seedUpgrade(skillId)

    /**
     * ⇄ SkillGitHubUpgradeSheet.onAppear { if isOfficial || !owner.isEmpty {
     * checkForUpdate() } } — dispatched at most ONCE per open session; the
     * candidate/commit/notes still arrive only through the projection.
     */
    fun autoCheckUpgradeOnOpen(skillId: String, projection: SkillUpgradeUi?) {
        val session = upgradeSessions[skillId] ?: return
        if (session.autoCheckDispatched) return
        session.autoCheckDispatched = true
        val seed = projection?.takeIf { it.skillId == skillId } ?: host.seedUpgrade(skillId) ?: return
        if (!seed.isOfficial && seed.savedSource == null) return
        host.checkUpgrade(skillId, if (seed.isOfficial) null else seed.savedSource)
    }

    fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): IntegrationsFlowResult =
        if (host.checkUpgrade(skillId, source)) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)

    /** Apply/rollback dispatches stamp a fresh effect token; only THAT
     * token's outcome is honoured. */
    fun dispatchUpgradeEffect(
        skillId: String,
        projection: SkillUpgradeUi?,
        rollback: Boolean,
        confirmed: Boolean,
    ): IntegrationsFlowResult {
        val session = upgradeSessions[skillId] ?: return rejected(RejectedReason.NO_SESSION)
        if (projection == null || projection.skillId != skillId) return IntegrationsFlowResult.Stale
        if (!rollback && (projection.isLatest || projection.candidateVersion == null)) {
            return rejected(RejectedReason.INPUT_INSUFFICIENT)
        }
        if (rollback && !projection.canRollback) return rejected(RejectedReason.INPUT_INSUFFICIENT)
        if (rollback && !confirmed) return rejected(RejectedReason.CONFIRMATION_REQUIRED)
        session.effectToken += 1
        val started = if (rollback) {
            host.rollbackUpgrade(skillId, session.effectToken)
        } else {
            host.applyUpgrade(skillId, session.effectToken)
        }
        return if (started) IntegrationsFlowResult.Accepted else rejected(RejectedReason.HOST_UNAVAILABLE)
    }

    /** Consume a structured apply/rollback outcome for the open session. */
    fun applyUpgradeEffect(skillId: String, effect: UpgradeEffectUi?): Boolean {
        val session = upgradeSessions[skillId] ?: return false
        effect ?: return false
        if (effect.effectToken != session.effectToken) return false // stale
        when (effect.outcome) {
            UpgradeOutcomeUi.APPLIED, UpgradeOutcomeUi.ROLLED_BACK -> closeUpgrade(skillId, cancelStaging = false)
            UpgradeOutcomeUi.FAILED -> Unit // sheet stays open; host message renders
        }
        return true
    }

    /** Cancel/close drops the staged upgrade (⇄ center.cancelUpgrade + sheet
     * onDisappear) — except while the host is committing (in-flight work
     * continues in the service; a late effect outcome stays fenced). */
    fun cancelUpgrade(skillId: String) {
        closeUpgrade(skillId, cancelStaging = true)
    }

    private fun closeUpgrade(skillId: String, cancelStaging: Boolean) {
        if (cancelStaging) host.cancelUpgrade(skillId)
        upgradeSessions.remove(skillId)
        navigation.closeTopIf(IntegrationsPane.UPGRADE_REVIEW, skillId)
    }

    /** True while a pane may NOT be dismissed by gesture (⇄
     * interactiveDismissDisabled(center.isWorking)). */
    fun isUpgradeInFlight(projection: SkillUpgradeUi?): Boolean =
        projection?.applyInFlight == true || projection?.checkInFlight == true

    /* ------------------------------ connectors ------------------------------ */

    fun openConnectors() = navigation.push(IntegrationsPane.CONNECTORS, "connectors")

    fun openMcpServers() = navigation.push(IntegrationsPane.MCP_SERVERS, "mcp")

    fun openConnectorDestination(destinationId: String): Boolean =
        host.openConnectorDestination(destinationId)

    /* --------------------------------- MCP --------------------------------- */

    /** Row tap / Add: open the editor with a host seed (null seed = nothing
     * opens; the host error path surfaces via the list projection). */
    fun openMcpEditor(serverId: String?): IntegrationsFlowResult {
        val seed = host.seedMcpEditor(serverId) ?: return rejected(RejectedReason.HOST_UNAVAILABLE)
        val initial = draftFromSeed(seed)
        val slot = mcpEditors.open(seed, initial)
        navigation.push(IntegrationsPane.MCP_EDITOR, slot.identity.editorId)
        host.mcpEditorOpened(slot.identity)
        return IntegrationsFlowResult.Accepted
    }

    fun currentMcpEditorIdentity(): McpEditorIdentity? =
        navigation.snapshot().lastOrNull { it.pane == IntegrationsPane.MCP_EDITOR }
            ?.let { mcpEditors.slot(it.key)?.identity }

    fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean =
        host.setMcpServerEnabled(serverId, enabled)

    fun deleteMcpServer(serverId: String, confirmed: Boolean): IntegrationsFlowResult {
        if (!confirmed) return rejected(RejectedReason.CONFIRMATION_REQUIRED)
        return if (host.deleteMcpServer(serverId)) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)
    }

    fun setMcpToolEnabledDraft(identity: McpEditorIdentity, remoteName: String, enabled: Boolean): IntegrationsFlowResult =
        withEditor(identity) { it.update { draft -> McpDraftLogic.toggleTool(draft, remoteName, enabled) } }

    fun setMcpDisplayName(identity: McpEditorIdentity, value: String): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(displayName = value) } }

    fun setMcpEndpoint(identity: McpEditorIdentity, value: String): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(endpointText = value) } }

    fun setMcpEnabled(identity: McpEditorIdentity, enabled: Boolean): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(enabled = enabled) } }

    fun setMcpAllowInCanvas(identity: McpEditorIdentity, allowed: Boolean): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(allowInCanvas = allowed) } }

    fun setMcpAllowInsecureHttp(identity: McpEditorIdentity, allowed: Boolean): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(allowInsecureHttp = allowed) } }

    fun setMcpAuthentication(identity: McpEditorIdentity, auth: McpAuthenticationUi): IntegrationsFlowResult =
        withEditor(identity) { slot ->
            slot.update { s -> McpDraftLogic.onAuthenticationChanged(s, auth) }
            if (auth == McpAuthenticationUi.NONE) slot.clearSecureInput()
        }

    fun setMcpHeaderName(identity: McpEditorIdentity, value: String): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(credentialHeaderName = value) } }

    fun setMcpTimeout(identity: McpEditorIdentity, value: Int): IntegrationsFlowResult =
        withEditor(identity) { it.update { s -> s.copy(timeoutSeconds = McpFormPreflight.clampTimeoutSeconds(value)) } }

    fun setMcpSecureInput(identity: McpEditorIdentity, value: String?): IntegrationsFlowResult =
        withEditor(identity) { it.setSecureInput(value) }

    fun toggleMcpReveal(identity: McpEditorIdentity): IntegrationsFlowResult =
        withEditor(identity) { it.revealSecureInput.value = !it.revealSecureInput.value }

    /**
     * Save-and-connect. Gate: no duplicate dispatch for the epoch; in-flight
     * disables further Save (contract). The credential travels ONLY with a
     * SET intent; the host returning false means nothing started.
     */
    fun saveMcpEditor(identity: McpEditorIdentity, hostInFlight: Boolean): IntegrationsFlowResult {
        val slot = mcpEditors.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!mcpEditors.accepts(identity)) return IntegrationsFlowResult.Stale
        if (!mcpEditors.canDispatchSave(identity, hostInFlight)) {
            return rejected(RejectedReason.SAVE_IN_FLIGHT)
        }
        // ⇄ iOS save(): an empty/unparseable endpoint shows the local
        // "Enter a valid MCP URL." message and NOTHING is dispatched. All
        // other findings (plain-HTTP gate, header-name rules, embedded
        // credentials, empty name) are answered by the HOST's
        // MCPServerConfiguration.validate() via saveError — the original's
        // Swift validation stays the authority.
        val preflight = McpFormPreflight.looksInvalid(slot.snapshot.value)
        if (preflight == McpPreflightFinding.ENDPOINT_REQUIRED ||
            preflight == McpPreflightFinding.ENDPOINT_UNPARSEABLE
        ) {
            return rejected(RejectedReason.INPUT_INSUFFICIENT)
        }
        val request = slot.buildSaveRequest()
        val started = host.saveMcpServer(request)
        if (!started) return rejected(RejectedReason.HOST_UNAVAILABLE)
        slot.markSaveDispatched()
        return IntegrationsFlowResult.Accepted
    }

    /** Cancel closes the editor and discards the draft (never commits). */
    fun cancelMcpEditor(identity: McpEditorIdentity): IntegrationsFlowResult {
        val slot = mcpEditors.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        slot.discard()
        mcpEditors.close(identity)
        navigation.closeTopIf(IntegrationsPane.MCP_EDITOR, identity.editorId)
        host.mcpEditorClosed(identity, discarded = true)
        return IntegrationsFlowResult.Accepted
    }

    /** After the host confirmed a verified save: close + notify. Only the
     * CURRENT identity+epoch may finalize (late success cannot close a
     * newer editor). */
    fun finalizeSavedEditor(identity: McpEditorIdentity) {
        if (!mcpEditors.accepts(identity)) return
        mcpEditors.slot(identity.editorId)?.resolveSaveOutcome()
        mcpEditors.close(identity)
        navigation.closeTopIf(IntegrationsPane.MCP_EDITOR, identity.editorId)
        host.mcpEditorClosed(identity, discarded = false)
    }

    /**
     * Host reported the attempt finished without a structured success
     * outcome (a failure projection, either saveError or
     * [McpSaveOutcomeUi.Failed]): clear only the duplicate-save latch so
     * Retry can dispatch again. Never marks success, never closes.
     *
     * [saveFailureSequence] is the host's monotonic Save-failure event for
     * this exact identity+epoch. A value > 0 is consumed at most once per
     * editor session: a replayed/recomposed equal failure is Stale and
     * cannot release a newer attempt's latch. 0 keeps the legacy
     * message-only behavior for projections from hosts without the event.
     */
    fun noteMcpSaveAttemptFinished(
        identity: McpEditorIdentity,
        saveFailureSequence: Long = 0L,
    ): IntegrationsFlowResult {
        val slot = mcpEditors.slot(identity.editorId) ?: return IntegrationsFlowResult.Stale
        if (!mcpEditors.accepts(identity)) return IntegrationsFlowResult.Stale
        if (saveFailureSequence > 0L) {
            if (!slot.consumeSaveFailureEvent(saveFailureSequence)) {
                return IntegrationsFlowResult.Stale
            }
        } else {
            slot.resolveSaveOutcome()
        }
        return IntegrationsFlowResult.Accepted
    }

    /** Refresh / re-read tools (explicit network action). */
    fun refreshMcpServer(serverId: String): IntegrationsFlowResult =
        if (host.refreshMcpServer(serverId)) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)

    /** Request cancellation bound to the CURRENT projected generation. */
    fun cancelMcpRefresh(row: McpServerRowUi): IntegrationsFlowResult {
        val generation = (row.state as? McpConnectionStateUi.Connecting)?.generation
            ?: return rejected(RejectedReason.NO_SESSION)
        return if (host.cancelMcpRefresh(row.serverId, generation)) {
            refreshCancelLatched[row.serverId] = generation
            IntegrationsFlowResult.Accepted
        } else {
            rejected(RejectedReason.HOST_UNAVAILABLE)
        }
    }

    /**
     * The ONE explicit local-network permission/recovery action
     * (Android 17 / API 37). The module only forwards the user's tap on
     * the HOST-projected guidance row; the platform dialog/settings page,
     * the state read-back and the chained (captured) retry all stay host-
     * owned, so the seam gains no permission authority of its own — a
     * refusal here means nothing started.
     */
    fun localNetworkGuidanceAction(): IntegrationsFlowResult =
        if (host.localNetworkGuidanceAction()) IntegrationsFlowResult.Accepted
        else rejected(RejectedReason.HOST_UNAVAILABLE)

    /** Rendering latch: "Cancelling…" while the host still projects the SAME
     * connecting generation. Any other state clears it. */
    fun isMcpRefreshCancelling(row: McpServerRowUi): Boolean {
        val latched = refreshCancelLatched[row.serverId] ?: return false
        val current = (row.state as? McpConnectionStateUi.Connecting)?.generation
        if (current == latched) return true
        refreshCancelLatched.remove(row.serverId)
        return false
    }

    /* ------------------------------- panes ------------------------------- */

    /** Back closes the innermost module pane; the base hub never pops. */
    fun back(): Boolean {
        val top = navigation.top
        if (top.pane == IntegrationsPane.SKILLS_HUB) return false
        when (top.pane) {
            IntegrationsPane.CONNECTORS -> navigation.back()
            IntegrationsPane.MCP_SERVERS -> navigation.back()
            IntegrationsPane.MCP_EDITOR ->
                mcpEditors.slot(top.key)?.let { cancelMcpEditor(it.identity) }
            IntegrationsPane.SKILL_CREATOR, IntegrationsPane.SKILL_FINDER, IntegrationsPane.SKILL_IMPORT ->
                closeForm(top.key)
            IntegrationsPane.INSTALL_REVIEW -> top.key.toLongOrNull()?.let { key ->
                // Back on the review sheet without confirming = drop review.
                host.cancelPendingInstallation(key)
                if (presentedReviewId == key) presentedReviewId = null
                lastHandledReviewId = maxOf(lastHandledReviewId, key)
                navigation.closeTopIf(IntegrationsPane.INSTALL_REVIEW, top.key)
            }
            IntegrationsPane.UPGRADE_REVIEW -> cancelUpgrade(top.key)
            IntegrationsPane.SKILLS_HUB -> Unit
        }
        return true
    }

    /** Leaving settings: drop every open session and pane. Open upgrade
     * sheets lose their staged review (⇄ sheet onDisappear cancelUpgrade);
     * host-started installs/commits are service-owned and keep running —
     * their late outcomes stay fenced by the closed session ids. */
    fun closeAll() {
        mcpEditors.closeAll()
        skillForms.closeAll()
        upgradeSessions.keys.toList().forEach { host.cancelUpgrade(it) }
        upgradeSessions.clear()
        runCancelLatched.clear()
        refreshCancelLatched.clear()
        presentedReviewId = null
        hubSearchQuery.value = ""
        showingInstalled.value = false
        navigation.resetToBase()
        host.closeAll()
    }

    private inline fun withEditor(
        identity: McpEditorIdentity,
        block: (McpEditorSlot) -> Unit,
    ): IntegrationsFlowResult {
        val slot = mcpEditors.slot(identity.editorId) ?: return rejected(RejectedReason.NO_SESSION)
        if (!mcpEditors.accepts(identity)) return IntegrationsFlowResult.Stale
        block(slot)
        return IntegrationsFlowResult.Accepted
    }

    /** ⇄ MCPServerEditor init: the draft starts from the seed copy; the
     * disabled-tool set seeds from the projected tool list's enabled flags. */
    private fun draftFromSeed(seed: McpEditorSeedUi): McpDraftSnapshot = McpDraftSnapshot(
        displayName = seed.displayName,
        endpointText = seed.endpointText,
        enabled = seed.enabled,
        allowInCanvas = seed.allowInCanvas,
        allowInsecureHttp = seed.allowInsecureHttp,
        authentication = seed.authentication,
        credentialHeaderName = seed.credentialHeaderName,
        timeoutSeconds = seed.timeoutSeconds,
        disabledRemoteToolNames = seed.tools.filterNot { it.enabled }.map { it.remoteName }.toSet(),
    )
}
