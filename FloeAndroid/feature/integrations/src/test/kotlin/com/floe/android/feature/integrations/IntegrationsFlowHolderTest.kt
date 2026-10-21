// SPDX-License-Identifier: MPL-2.0
//
// Holder fence tests against a recording fake host. These pin the behavior
// that must not regress silently:
//  - the distinct Discover import routes (finder URL sheet vs folder picker
//    vs creator — SkillsView.swift:84-86);
//  - MCP editor identity/epoch fencing (old success cannot close a reopen);
//  - save latch release on failure without closing the editor;
//  - install-review reviewId fencing and replacement;
//  - upgrade effect-token fencing and cancel semantics;
//  - owned-run stop latches and refresh-generation cancel latches;
//  - narrow destructive intents (confirmation required);
//  - form outcome fencing, latched initial load, and closeAll teardown.
//
// SOURCE ONLY in this stage: the source lane performed no Gradle/JVM build,
// so this file documents intended behavior and is not a passing-test claim.

package com.floe.android.feature.integrations

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationsFlowHolderTest {
    private companion object {
        /** The REAL opaque revision pair shape (resourceID + digest), like
         *  the Core row emits — never a counter. */
        val SEED_REVISION = McpServerRevisionUi(
            "mcp.6F7B2A1C-3D4E-5F60-7182-93A4B5C6D7E8",
            "rev-1",
        )
    }


    /* --------------------------------- fakes --------------------------------- */

    private class FakeHost : IntegrationUiCallbacks {
        var loadCount = 0
        var closeAllCount = 0
        var folderStagingRequests = 0
        var folderStagingAvailable = true
        var saveAccepted = true
        var confirmReviewAccepted = true
        var cancelRunAccepted = true
        val editorOpened = mutableListOf<McpEditorIdentity>()
        val editorClosed = mutableListOf<Pair<McpEditorIdentity, Boolean>>()
        val saveRequests = mutableListOf<McpSaveRequest>()
        val confirmedReviews = mutableListOf<Long>()
        val cancelledReviews = mutableListOf<Long>()
        val createdForms = mutableListOf<String>()
        val finderInstalls = mutableListOf<String>()
        val stagedImports = mutableListOf<String>()
        val upgradeChecks = mutableListOf<String>()
        val upgradeApplies = mutableListOf<Long>()
        val upgradeRollbacks = mutableListOf<Long>()
        val upgradeCancels = mutableListOf<String>()
        val connectorOpens = mutableListOf<String>()
        val deletedSkills = mutableListOf<String>()
        val deletedServers = mutableListOf<String>()
        val enabledSkills = mutableListOf<Triple<String, String, Boolean>>()
        val enabledServers = mutableListOf<Pair<String, Boolean>>()
        val cancelledRuns = mutableListOf<SkillRunScopeUi>()
        val cancelledRefreshes = mutableListOf<Pair<String, Long>>()
        val refreshes = mutableListOf<String>()
        var seed: McpEditorSeedUi? = null
        val localNetworkActions = mutableListOf<Unit>()
        var localNetworkActionAccepted = true

        override fun load() { loadCount++ }
        override fun closeAll() { closeAllCount++ }
        override fun refreshCatalog(force: Boolean): Boolean = true
        override fun installOfficialSkill(skillId: String): Boolean = true
        override fun setSkillEnabled(skillId: String, expectedRevision: String, enabled: Boolean): Boolean {
            enabledSkills += Triple(skillId, expectedRevision, enabled)
            return true
        }
        override fun deleteSkill(skillId: String, expectedRevision: String): Boolean {
            deletedSkills += skillId
            return true
        }
        override fun cancelSkillRun(scope: SkillRunScopeUi): Boolean {
            if (!cancelRunAccepted) return false
            cancelledRuns += scope
            return true
        }
        override fun setAutoScriptedUpdates(enabled: Boolean) = Unit
        override fun confirmPendingInstallation(reviewId: Long): Boolean {
            confirmedReviews += reviewId
            return confirmReviewAccepted
        }
        override fun cancelPendingInstallation(reviewId: Long) { cancelledReviews += reviewId }
        override fun createSkill(formId: String, draft: SkillCreatorDraftUi): Boolean {
            createdForms += formId
            return true
        }
        override fun installFromFinder(formId: String, urlText: String, rewriteModelId: String?): Boolean {
            finderInstalls += formId
            return true
        }
        override fun requestFolderStaging(): Boolean {
            folderStagingRequests++
            return folderStagingAvailable
        }
        override fun importStagedPackage(formId: String, reference: StagedPackageRefUi): Boolean {
            stagedImports += formId
            return true
        }
        override fun seedUpgrade(skillId: String): SkillUpgradeUi? = null
        override fun checkUpgrade(skillId: String, source: GitHubSourceFieldsUi?): Boolean {
            upgradeChecks += skillId
            return true
        }
        override fun applyUpgrade(skillId: String, effectToken: Long): Boolean {
            upgradeApplies += effectToken
            return true
        }
        override fun cancelUpgrade(skillId: String) { upgradeCancels += skillId }
        override fun rollbackUpgrade(skillId: String, effectToken: Long): Boolean {
            upgradeRollbacks += effectToken
            return true
        }
        override fun openConnectorDestination(destinationId: String): Boolean {
            connectorOpens += destinationId
            return true
        }
        override fun seedMcpEditor(serverId: String?): McpEditorSeedUi? = seed
        override fun mcpEditorOpened(identity: McpEditorIdentity) { editorOpened += identity }
        override fun mcpEditorClosed(identity: McpEditorIdentity, discarded: Boolean) {
            editorClosed += identity to discarded
        }
        override fun saveMcpServer(request: McpSaveRequest): Boolean {
            saveRequests += request
            return saveAccepted
        }
        override fun deleteMcpServer(serverId: String): Boolean {
            deletedServers += serverId
            return true
        }
        override fun setMcpServerEnabled(serverId: String, enabled: Boolean): Boolean {
            enabledServers += serverId to enabled
            return true
        }
        override fun setMcpToolEnabled(serverId: String, remoteName: String, enabled: Boolean): Boolean = true
        override fun refreshMcpServer(serverId: String): Boolean {
            refreshes += serverId
            return true
        }
        override fun cancelMcpRefresh(serverId: String, generation: Long): Boolean {
            cancelledRefreshes += serverId to generation
            return true
        }
        override fun localNetworkGuidanceAction(): Boolean {
            localNetworkActions += Unit
            return localNetworkActionAccepted
        }
    }

    private fun seed(serverId: String? = "server-1"): McpEditorSeedUi = McpEditorSeedUi(
        serverId = serverId,
        displayName = "Server",
        endpointText = "https://host/mcp",
        enabled = true,
        allowInCanvas = false,
        allowInsecureHttp = false,
        authentication = McpAuthenticationUi.BEARER_TOKEN,
        credentialHeaderName = "Authorization",
        credentialStored = true,
        timeoutSeconds = 30,
        transport = McpTransportUi.StreamableHttp,
        tools = emptyList(),
        networkActionsAvailable = true,
        networkActionsUnavailableReason = null,
        savedRevision = SEED_REVISION,
    )

    private fun installedRow(activity: SkillRunActivityUi = SkillRunActivityUi.None) = SkillInstalledRowUi(
        skillId = "skill-a",
        name = "Skill A",
        version = "1.0.0",
        summary = null,
        enabled = true,
        revision = "digest-a",
        availability = SkillAvailabilityUi.Usable,
        offerState = SkillOfferStateUi.OFFERED,
        runActivity = activity,
        sourceKind = SkillSourceKindUi.GITHUB,
    )

    private fun review(id: Long, inFlight: Boolean = false) = SkillInstallReviewUi(
        reviewId = id,
        sourceDisplay = "https://source.invalid/skill",
        skillName = "Staged Skill",
        version = "1.0.0",
        requestedCapabilities = listOf("network"),
        tools = listOf("exec.shell"),
        scriptPaths = emptyList(),
        pythonPackages = emptyList(),
        commitInFlight = inFlight,
    )

    private fun upgradeProjection(skillId: String, candidate: String? = "1.1.0") = SkillUpgradeUi(
        skillId = skillId,
        skillName = "Skill A",
        installedVersion = "1.0.0",
        isOfficial = true,
        savedSource = null,
        candidateVersion = candidate,
        commit = "abcdef",
        releaseNotes = null,
        addedCapabilities = emptyList(),
        addedTools = emptyList(),
        changedFiles = emptyList(),
        isLatest = candidate == null,
        checkInFlight = false,
        applyInFlight = false,
        canRollback = true,
        errorMessage = null,
        lastEffect = null,
    )

    /* ---------------------- distinct import route mapping ---------------------- */

    @Test
    fun `discover import rows map to three distinct routes`() {
        val finder = SkillsImportRouting.routeFor(DiscoverImportRowId.PLUGINS_IMPORT)
        val folder = SkillsImportRouting.routeFor(DiscoverImportRowId.IMPORT_FOLDER)
        val creator = SkillsImportRouting.routeFor(DiscoverImportRowId.CREATOR)
        assertEquals(SkillImportRoute.FINDER_URL, finder)
        assertEquals(SkillImportRoute.FOLDER_PICKER, folder)
        assertEquals(SkillImportRoute.CREATOR, creator)
        assertEquals(3, setOf(finder, folder, creator).size)
        // Explicit anti-collapse assertions: neither row may resolve to the
        // other's destination.
        assertNotEquals(folder, SkillsImportRouting.finderRowRoute())
        assertNotEquals(finder, SkillsImportRouting.folderRowRoute())
        assertEquals(SkillImportRoute.FINDER_URL, SkillsImportRouting.finderRowRoute())
        assertEquals(SkillImportRoute.FOLDER_PICKER, SkillsImportRouting.folderRowRoute())
    }

    @Test
    fun `finder route opens the URL sheet and never requests folder staging`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.runImportRoute(SkillImportRoute.FINDER_URL)
        assertEquals(IntegrationsPane.SKILL_FINDER, holder.navigation.top.pane)
        assertEquals(0, host.folderStagingRequests)
        assertTrue(holder.skillForms.slot(holder.navigation.top.key) != null)

        // The toolbar magnifier uses the same finder entry point.
        holder.back()
        holder.openFinder()
        assertEquals(IntegrationsPane.SKILL_FINDER, holder.navigation.top.pane)
        assertEquals(0, host.folderStagingRequests)
    }

    @Test
    fun `folder route asks the host for the picker and opens nothing`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.runImportRoute(SkillImportRoute.FOLDER_PICKER)
        assertEquals(1, host.folderStagingRequests)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
        assertTrue(holder.skillForms.slot("none") == null)

        val staged = StagedPackageRefUi("opaque-handle", "Picked Folder", "inode/directory", 128)
        holder.onPackageStaged(staged)
        assertEquals(IntegrationsPane.SKILL_IMPORT, holder.navigation.top.pane)
        assertEquals(staged, holder.skillForms.slot(holder.navigation.top.key)?.stagedReference?.value)
    }

    @Test
    fun `folder staging refusal is reported and opens nothing`() {
        val host = FakeHost().apply { folderStagingAvailable = false }
        val holder = IntegrationsFlowHolder(host)
        val result = holder.openFolderImport()
        assertTrue(result is IntegrationsFlowResult.Rejected)
        assertEquals(RejectedReason.HOST_UNAVAILABLE, (result as IntegrationsFlowResult.Rejected).reason)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
    }

    @Test
    fun `creator route opens the creator form`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.runImportRoute(SkillImportRoute.CREATOR)
        assertEquals(IntegrationsPane.SKILL_CREATOR, holder.navigation.top.pane)
        assertEquals(0, host.folderStagingRequests)
    }

    /* --------------------------- MCP editor fencing --------------------------- */

    @Test
    fun `old success cannot close a reopened editor`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpServers()
        assertEquals(IntegrationsFlowResult.Accepted, holder.openMcpEditor("server-1"))
        val first = holder.currentMcpEditorIdentity()!!
        holder.cancelMcpEditor(first)
        assertEquals(IntegrationsFlowResult.Accepted, holder.openMcpEditor("server-1"))
        val second = holder.currentMcpEditorIdentity()!!
        assertNotEquals(first.editorId, second.editorId)

        holder.finalizeSavedEditor(first)
        assertEquals(IntegrationsPane.MCP_EDITOR, holder.navigation.top.pane)
        assertTrue(host.editorClosed.none { it.first.sameEditor(first) && !it.second })
        assertEquals(first, host.editorClosed.single().first)
        assertTrue(host.editorClosed.single().second) // the cancel was discarded

        holder.finalizeSavedEditor(second)
        assertEquals(IntegrationsPane.MCP_SERVERS, holder.navigation.top.pane)
        assertEquals(2, host.editorClosed.size)
        assertEquals(false, host.editorClosed.last().second)
    }

    @Test
    fun `save latch releases on failure without closing the editor`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!

        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        val duplicate = holder.saveMcpEditor(identity, hostInFlight = false)
        assertEquals(RejectedReason.SAVE_IN_FLIGHT, (duplicate as IntegrationsFlowResult.Rejected).reason)
        assertEquals(1, host.saveRequests.size)

        holder.noteMcpSaveAttemptFinished(identity)
        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        assertEquals(2, host.saveRequests.size)
        assertEquals(IntegrationsPane.MCP_EDITOR, holder.navigation.top.pane)
        assertTrue(host.editorClosed.isEmpty())
    }

    @Test
    fun `same-frame retry failure event releases the latch exactly once per attempt`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!
        val slot = holder.mcpEditors.slot(identity.editorId)!!

        // First attempt is dispatched; the host fails synchronously with
        // begin+failure coalesced into event sequence 1.
        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        assertTrue(slot.saveDispatched)
        assertEquals(
            IntegrationsFlowResult.Accepted,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 1),
        )
        assertFalse(slot.saveDispatched)

        // Retry with the IDENTICAL message/outcome but a new event sequence 2.
        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        assertTrue(slot.saveDispatched)
        assertEquals(
            IntegrationsFlowResult.Accepted,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 2),
        )
        assertFalse(slot.saveDispatched)

        // Third retry dispatches exactly one request; a duplicate while that
        // attempt is in flight stays refused.
        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        assertEquals(3, host.saveRequests.size)
        val duplicate = holder.saveMcpEditor(identity, hostInFlight = false)
        assertEquals(RejectedReason.SAVE_IN_FLIGHT, (duplicate as IntegrationsFlowResult.Rejected).reason)
        assertEquals(3, host.saveRequests.size)
        assertEquals(IntegrationsPane.MCP_EDITOR, holder.navigation.top.pane)
        assertTrue(host.editorClosed.isEmpty())
    }

    @Test
    fun `replayed failure event cannot release a newer in-flight attempt`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!
        val slot = holder.mcpEditors.slot(identity.editorId)!!

        holder.saveMcpEditor(identity, hostInFlight = false)
        holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 1)
        assertFalse(slot.saveDispatched)

        holder.saveMcpEditor(identity, hostInFlight = false)
        assertTrue(slot.saveDispatched)
        // Recomposition/poll of the already-consumed failure: not a new
        // attempt outcome and therefore not allowed to unlock the retry.
        assertEquals(
            IntegrationsFlowResult.Stale,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 1),
        )
        assertTrue(slot.saveDispatched)
        val duplicate = holder.saveMcpEditor(identity, hostInFlight = false)
        assertEquals(RejectedReason.SAVE_IN_FLIGHT, (duplicate as IntegrationsFlowResult.Rejected).reason)
        assertEquals(2, host.saveRequests.size)

        // The real next event releases it, and a second replay is inert.
        assertEquals(
            IntegrationsFlowResult.Accepted,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 2),
        )
        assertFalse(slot.saveDispatched)
        assertEquals(
            IntegrationsFlowResult.Stale,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 2),
        )
        assertFalse(slot.saveDispatched)
    }

    @Test
    fun `stale editor identity or epoch failure cannot release the current attempt`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!
        val slot = holder.mcpEditors.slot(identity.editorId)!!

        holder.saveMcpEditor(identity, hostInFlight = false)
        assertTrue(slot.saveDispatched)
        assertEquals(
            IntegrationsFlowResult.Stale,
            holder.noteMcpSaveAttemptFinished(identity.copy(epoch = identity.epoch + 1), saveFailureSequence = 4),
        )
        assertEquals(
            IntegrationsFlowResult.Stale,
            holder.noteMcpSaveAttemptFinished(identity.copy(editorId = "other-editor-9"), saveFailureSequence = 4),
        )
        assertTrue(slot.saveDispatched)
        val duplicate = holder.saveMcpEditor(identity, hostInFlight = false)
        assertEquals(RejectedReason.SAVE_IN_FLIGHT, (duplicate as IntegrationsFlowResult.Rejected).reason)
        assertEquals(1, host.saveRequests.size)

        // The actual current identity+epoch event still works.
        assertEquals(
            IntegrationsFlowResult.Accepted,
            holder.noteMcpSaveAttemptFinished(identity, saveFailureSequence = 1),
        )
        assertFalse(slot.saveDispatched)
    }

    @Test
    fun `legacy projection without a failure sequence still releases the latch`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!
        val slot = holder.mcpEditors.slot(identity.editorId)!!

        holder.saveMcpEditor(identity, hostInFlight = false)
        assertTrue(slot.saveDispatched)
        assertEquals(IntegrationsFlowResult.Accepted, holder.noteMcpSaveAttemptFinished(identity))
        assertFalse(slot.saveDispatched)
        assertEquals(IntegrationsFlowResult.Accepted, holder.saveMcpEditor(identity, hostInFlight = false))
        assertEquals(2, host.saveRequests.size)
    }

    @Test
    fun `save request carries keep-existing intent for an untouched draft`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        holder.saveMcpEditor(holder.currentMcpEditorIdentity()!!, hostInFlight = false)
        val request = host.saveRequests.single()
        assertEquals(CredentialDraftIntent.KEEP_EXISTING, request.credentialIntent)
        assertNull(request.credentialDraft)
        assertEquals(SEED_REVISION, request.baseRevision)
    }

    @Test
    fun `seedless open is rejected without a pane`() {
        val host = FakeHost().apply { seed = null }
        val holder = IntegrationsFlowHolder(host)
        val result = holder.openMcpEditor(null)
        assertEquals(RejectedReason.HOST_UNAVAILABLE, (result as IntegrationsFlowResult.Rejected).reason)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
        assertTrue(host.editorOpened.isEmpty())
    }

    @Test
    fun `delete intents require explicit confirmation`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val denied = holder.deleteSkill("skill-a", "digest-a", confirmed = false)
        assertEquals(RejectedReason.CONFIRMATION_REQUIRED, (denied as IntegrationsFlowResult.Rejected).reason)
        assertTrue(host.deletedSkills.isEmpty())
        holder.deleteSkill("skill-a", "digest-a", confirmed = true)
        assertEquals(listOf("skill-a"), host.deletedSkills)

        val deniedServer = holder.deleteMcpServer("server-1", confirmed = false)
        assertEquals(
            RejectedReason.CONFIRMATION_REQUIRED,
            (deniedServer as IntegrationsFlowResult.Rejected).reason,
        )
        assertTrue(host.deletedServers.isEmpty())
        holder.deleteMcpServer("server-1", confirmed = true)
        assertEquals(listOf("server-1"), host.deletedServers)
    }

    @Test
    fun `enable and delete forward the saved revision verbatim`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.setSkillEnabled("skill-a", "digest-42", true)
        holder.deleteSkill("skill-a", "digest-42", confirmed = true)
        assertEquals(listOf(Triple("skill-a", "digest-42", true)), host.enabledSkills)
        assertEquals(listOf("skill-a"), host.deletedSkills)
    }

    @Test
    fun `unparseable endpoint is not dispatched to the host`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        val identity = holder.currentMcpEditorIdentity()!!
        holder.setMcpEndpoint(identity, "not a url")
        val result = holder.saveMcpEditor(identity, hostInFlight = false)
        assertEquals(RejectedReason.INPUT_INSUFFICIENT, (result as IntegrationsFlowResult.Rejected).reason)
        assertTrue(host.saveRequests.isEmpty())
        assertEquals(IntegrationsPane.MCP_EDITOR, holder.navigation.top.pane)
    }

    /* ------------------------------ install review ----------------------------- */

    @Test
    fun `review confirmation is fenced by review id and replaced when a newer review arrives`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.syncInstallReviewPane(review(7))
        assertEquals(IntegrationsPane.INSTALL_REVIEW, holder.navigation.top.pane)

        val stale = holder.confirmInstallReview(review(6))
        assertEquals(IntegrationsFlowResult.Stale, stale)
        assertTrue(host.confirmedReviews.isEmpty())

        // A newer staged review replaces the sheet and fences the old token.
        holder.syncInstallReviewPane(review(8))
        assertEquals("8", holder.navigation.top.key)
        assertEquals(IntegrationsFlowResult.Stale, holder.confirmInstallReview(review(7)))

        assertEquals(IntegrationsFlowResult.Accepted, holder.confirmInstallReview(review(8)))
        assertEquals(listOf(8L), host.confirmedReviews)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)

        // The host may keep projecting the confirmed review while its commit
        // runs; that projection must NOT resurrect the dialog.
        holder.syncInstallReviewPane(review(8, inFlight = true))
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
    }

    @Test
    fun `dismissing the review cancels only the staged review`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.syncInstallReviewPane(review(9))
        holder.cancelInstallReview(review(9))
        assertEquals(listOf(9L), host.cancelledReviews)
        assertTrue(host.confirmedReviews.isEmpty())
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
    }

    /* ---------------------------------- upgrade -------------------------------- */

    @Test
    fun `upgrade effect tokens fence late outcomes`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.openUpgrade("skill-a")
        val projection = upgradeProjection("skill-a")
        assertEquals(
            IntegrationsFlowResult.Accepted,
            holder.dispatchUpgradeEffect("skill-a", projection, rollback = false, confirmed = true),
        )
        assertEquals(listOf(1L), host.upgradeApplies)

        // A late outcome for an older token (or another sheet) is ignored.
        assertFalse(holder.applyUpgradeEffect("skill-a", UpgradeEffectUi(0, UpgradeOutcomeUi.APPLIED)))
        assertEquals(IntegrationsPane.UPGRADE_REVIEW, holder.navigation.top.pane)

        assertTrue(holder.applyUpgradeEffect("skill-a", UpgradeEffectUi(1, UpgradeOutcomeUi.APPLIED)))
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
        // Closing after a confirmed apply is not a staging cancel.
        assertTrue(host.upgradeCancels.isEmpty())
    }

    @Test
    fun `upgrade cancel tears down the staged review`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.openUpgrade("skill-b")
        holder.cancelUpgrade("skill-b")
        assertEquals(listOf("skill-b"), host.upgradeCancels)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
    }

    @Test
    fun `rollback requires confirmation and a rollbackable projection`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.openUpgrade("skill-a")
        val projection = upgradeProjection("skill-a").copy(canRollback = false)
        val denied = holder.dispatchUpgradeEffect("skill-a", projection, rollback = true, confirmed = true)
        assertEquals(RejectedReason.INPUT_INSUFFICIENT, (denied as IntegrationsFlowResult.Rejected).reason)
        val unconfirmed = holder.dispatchUpgradeEffect(
            "skill-a",
            projection.copy(canRollback = true),
            rollback = true,
            confirmed = false,
        )
        assertEquals(
            RejectedReason.CONFIRMATION_REQUIRED,
            (unconfirmed as IntegrationsFlowResult.Rejected).reason,
        )
        assertTrue(host.upgradeRollbacks.isEmpty())
        holder.dispatchUpgradeEffect(
            "skill-a",
            projection.copy(canRollback = true),
            rollback = true,
            confirmed = true,
        )
        assertEquals(listOf(1L), host.upgradeRollbacks)
    }

    @Test
    fun `upgrade auto check fires at most once per open sheet`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.openUpgrade("skill-a")
        val projection = upgradeProjection("skill-a", candidate = null)
        holder.autoCheckUpgradeOnOpen("skill-a", projection)
        holder.autoCheckUpgradeOnOpen("skill-a", projection)
        assertEquals(listOf("skill-a"), host.upgradeChecks)
    }

    /* --------------------------- cancellation latches --------------------------- */

    @Test
    fun `run stop is dispatched once and the latch clears on a terminal projection`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val scope = SkillRunScopeUi.JobOwned("task", "run", "env", "job", 3)
        val running = installedRow(SkillRunActivityUi.Running(scope))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        assertEquals(listOf(scope), host.cancelledRuns)
        assertTrue(holder.isRunCancelling(running))
        assertFalse(holder.isRunCancelling(running.copy(runActivity = SkillRunActivityUi.None)))
        // The latch is gone: the old running projection no longer reads as
        // cancelling, and an idle row cannot dispatch a stop at all.
        assertFalse(holder.isRunCancelling(running))
        val idle = holder.cancelSkillRun(running.copy(runActivity = SkillRunActivityUi.None))
        assertEquals(RejectedReason.NO_SESSION, (idle as IntegrationsFlowResult.Rejected).reason)
        assertEquals(1, host.cancelledRuns.size)
    }

    @Test
    fun `host projected cancelling reads as cancelling without a local latch`() {
        val holder = IntegrationsFlowHolder(FakeHost())
        val scope = SkillRunScopeUi.JobOwned("task", "run", "env", "job", 1)
        assertTrue(holder.isRunCancelling(installedRow(SkillRunActivityUi.Cancelling(scope))))
    }

    @Test
    fun `a genuine run-only scope displays and cancels without env or job identities`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        // G02 projects a real task+run with NO resolvable env/job roles:
        // the row must stop honestly without any fabricated identity.
        val scope = SkillRunScopeUi.RunOnly(taskId = "task-9", runId = "run-9", generation = 4)
        val running = installedRow(SkillRunActivityUi.Running(scope))
        assertTrue(SkillsDisplayLogic.canRequestStop(running))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        // The host receives the projected scope echoed back unchanged.
        assertEquals(listOf<SkillRunScopeUi>(scope), host.cancelledRuns)
        assertTrue(holder.isRunCancelling(running))
    }

    @Test
    fun `a job-owned scope echoes the real job and environment roles unchanged`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val scope = SkillRunScopeUi.JobOwned(
            taskId = "task-9",
            runId = "run-9",
            environmentId = "env-2",
            jobId = "job-7",
            generation = 4,
        )
        val running = installedRow(SkillRunActivityUi.Running(scope))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        val echoed = host.cancelledRuns.single() as SkillRunScopeUi.JobOwned
        assertEquals("job-7", echoed.jobId)
        assertEquals("env-2", echoed.environmentId)
        assertEquals("task-9", echoed.taskId)
        assertEquals("run-9", echoed.runId)
        assertEquals(4L, echoed.generation)
    }

    @Test
    fun `duplicate accepted cancel is rejected for the exact live scope`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val scope = SkillRunScopeUi.RunOnly("task-1", "run-1", null, 2)
        val running = installedRow(SkillRunActivityUi.Running(scope))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        val duplicate = holder.cancelSkillRun(running)
        assertEquals(
            RejectedReason.CANCEL_IN_FLIGHT,
            (duplicate as IntegrationsFlowResult.Rejected).reason,
        )
        // The holder guard — not just the disabled affordance — blocked the
        // second dispatch.
        assertEquals(1, host.cancelledRuns.size)
    }

    @Test
    fun `a refused stop does not latch and can be retried`() {
        val host = FakeHost()
        host.cancelRunAccepted = false
        val holder = IntegrationsFlowHolder(host)
        val scope = SkillRunScopeUi.JobOwned("task-1", "run-1", "env-1", "job-1", 1)
        val running = installedRow(SkillRunActivityUi.Running(scope))
        val first = holder.cancelSkillRun(running)
        assertEquals(RejectedReason.HOST_UNAVAILABLE, (first as IntegrationsFlowResult.Rejected).reason)
        assertFalse(holder.isRunCancelling(running))
        host.cancelRunAccepted = true
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        assertEquals(listOf<SkillRunScopeUi>(scope), host.cancelledRuns)
        assertTrue(holder.isRunCancelling(running))
    }

    @Test
    fun `equal job and generation on another task run is not the live latch`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val first = SkillRunScopeUi.JobOwned("task-a", "run-a", "env-x", "job-x", 7)
        val running = installedRow(SkillRunActivityUi.Running(first))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        assertTrue(holder.isRunCancelling(running))
        // The host replaced the projection: the SAME job/generation values
        // under a NEW task/run ownership. The old (jobId, generation) key
        // would wrongly render this row "Cancelling…" and swallow a real
        // stop; the full typed scope does not.
        val second = SkillRunScopeUi.JobOwned("task-b", "run-b", "env-x", "job-x", 7)
        assertNotEquals(first, second)
        val replaced = installedRow(SkillRunActivityUi.Running(second))
        assertFalse(holder.isRunCancelling(replaced))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(replaced))
        assertEquals(listOf(first, second), host.cancelledRuns)
        assertTrue(holder.isRunCancelling(replaced))
    }

    @Test
    fun `a run-only latch never matches a job-owned projection of the same run`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val runOnly = SkillRunScopeUi.RunOnly("task-a", "run-a", "env-1", 7)
        val running = installedRow(SkillRunActivityUi.Running(runOnly))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(running))
        // A later projection that carries a REAL job role is a different
        // typed scope: not covered by the run-only latch, and a genuine
        // job-owned command may still be dispatched for it.
        val jobOwned = SkillRunScopeUi.JobOwned("task-a", "run-a", "env-1", "job-a", 7)
        val jobRow = installedRow(SkillRunActivityUi.Running(jobOwned))
        assertFalse(holder.isRunCancelling(jobRow))
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelSkillRun(jobRow))
        assertEquals(listOf<SkillRunScopeUi>(runOnly, jobOwned), host.cancelledRuns)
    }

    @Test
    fun `scope identity guards reject sentinel roles`() {
        // The module must not accept an empty/sentinel identity that the
        // backend could mistake for a resolvable role.
        var blankJob = false
        try {
            SkillRunScopeUi.JobOwned("task-a", "run-a", null, "", 1)
        } catch (_: IllegalArgumentException) {
            blankJob = true
        }
        assertTrue(blankJob)
        var blankRun = false
        try {
            SkillRunScopeUi.RunOnly("task-a", " ", null, 1)
        } catch (_: IllegalArgumentException) {
            blankRun = true
        }
        assertTrue(blankRun)
    }

    @Test
    fun `refresh cancel binds the projected generation and clears on a new one`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val row = McpServerRowUi(
            serverId = "server-1",
            displayName = "Server",
            endpointDisplay = "https://host/mcp",
            enabled = true,
            allowInCanvas = false,
            authentication = McpAuthenticationUi.NONE,
            credentialStored = false,
            state = McpConnectionStateUi.Connecting(5),
            tools = null,
            revision = McpServerRevisionUi("mcp.6F7B2A1C-3D4E-5F60-7182-93A4B5C6D7E8", "rev-1"),
        )
        assertEquals(IntegrationsFlowResult.Accepted, holder.cancelMcpRefresh(row))
        assertEquals(listOf("server-1" to 5L), host.cancelledRefreshes)
        assertTrue(holder.isMcpRefreshCancelling(row))
        val newer = row.copy(state = McpConnectionStateUi.Connecting(6))
        assertFalse(holder.isMcpRefreshCancelling(newer))
        // The latch was cleared when the newer generation appeared.
        assertFalse(holder.isMcpRefreshCancelling(row))
        val idle = holder.cancelMcpRefresh(row.copy(state = McpConnectionStateUi.Ready(2)))
        assertEquals(RejectedReason.NO_SESSION, (idle as IntegrationsFlowResult.Rejected).reason)
    }

    /* ---------------------------------- forms ---------------------------------- */

    @Test
    fun `form outcomes close only the matching open form`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val slot = holder.openCreator()
        val otherForm = "skill_creator-999"
        assertFalse(holder.applyFormOutcome(SkillsFormOutcomeUi(otherForm, true, null)))
        assertEquals(IntegrationsPane.SKILL_CREATOR, holder.navigation.top.pane)
        val succeeded = holder.applyFormOutcome(SkillsFormOutcomeUi(slot.formId, true, null))
        assertTrue(succeeded)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
        assertNull(holder.skillForms.slot(slot.formId))
    }

    @Test
    fun `creator submit requires complete fields and marks the dispatch`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        val slot = holder.openCreator()
        val insufficient = holder.submitCreator(slot.formId, hostWorking = false)
        assertEquals(RejectedReason.INPUT_INSUFFICIENT, (insufficient as IntegrationsFlowResult.Rejected).reason)
        slot.creatorName.value = "Name"
        slot.creatorDescription.value = "Desc"
        slot.creatorInstructions.value = "Do things."
        assertEquals(IntegrationsFlowResult.Accepted, holder.submitCreator(slot.formId, hostWorking = false))
        assertEquals(listOf(slot.formId), host.createdForms)
        val duplicate = holder.submitCreator(slot.formId, hostWorking = false)
        assertEquals(RejectedReason.SAVE_IN_FLIGHT, (duplicate as IntegrationsFlowResult.Rejected).reason)
    }

    /* ------------------------------ lifecycle ------------------------------ */

    @Test
    fun `initial load is latched`() {
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        holder.loadOnce()
        holder.loadOnce()
        assertEquals(1, host.loadCount)
    }

    @Test
    fun `closeAll drops sessions notifies open upgrade staging and resets panes`() {
        val host = FakeHost().apply { seed = seed() }
        val holder = IntegrationsFlowHolder(host)
        holder.openMcpEditor("server-1")
        holder.openFinder()
        holder.openUpgrade("skill-c")
        holder.closeAll()
        assertEquals(1, host.closeAllCount)
        assertEquals(listOf("skill-c"), host.upgradeCancels)
        assertEquals(IntegrationsPane.SKILLS_HUB, holder.navigation.top.pane)
        assertEquals(1, holder.navigation.depth)
        assertNull(holder.currentMcpEditorIdentity())
    }

    @Test
    fun `local network guidance forwards the single explicit action`() {
        // Android 17 LAN permission: the module only forwards the user's
        // tap on the HOST-projected guidance row; a host refusal means
        // nothing started and is reported honestly. No module-side
        // permission state exists or is cached.
        val host = FakeHost()
        val holder = IntegrationsFlowHolder(host)
        assertEquals(IntegrationsFlowResult.Accepted, holder.localNetworkGuidanceAction())
        assertEquals(1, host.localNetworkActions.size)

        val refusing = FakeHost().apply { localNetworkActionAccepted = false }
        val refusingHolder = IntegrationsFlowHolder(refusing)
        val result = refusingHolder.localNetworkGuidanceAction()
        assertTrue(result is IntegrationsFlowResult.Rejected)
        assertEquals(RejectedReason.HOST_UNAVAILABLE,
            (result as IntegrationsFlowResult.Rejected).reason)
    }

}
