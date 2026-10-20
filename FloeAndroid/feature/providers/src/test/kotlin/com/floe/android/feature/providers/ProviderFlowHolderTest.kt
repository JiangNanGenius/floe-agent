// SPDX-License-Identifier: MPL-2.0
//
// Synthetic unit tests for the flow holder's save/epoch/cancel lifetime and
// host-message honesty: the module only reports what the host confirms, never
// dispatches duplicate saves, and ignores late results from a replaced or
// closed editor. The fake host implements the exact ProviderUiCallbacks seam;
// no network, database or credential store is involved.

package com.floe.android.feature.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderFlowHolderTest {

    private val choice = SupplierChoice(
        presetId = "openai",
        displayName = "OpenAI",
        catalogEntryId = null,
        absoluteEndpointDefault = "https://api.openai.com/v1",
        routeFamily = "openai",
        authStyle = "bearer",
        supportsPlainHttpChoice = false,
        suggestsToolNameCompatibility = false,
    )

    private fun seed() = ProviderEditorSeedUi(
        snapshot = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            displayName = "OpenAI",
            supplier = choice,
            protocol = WireProtocolUi.OPENAI_RESPONSES,
            baseUrl = "https://api.openai.com/v1",
        ),
        credentialState = ProviderCredentialStateUi.CONFIGURED,
        availableProtocols = WireProtocolUi.entries,
        discoverySupported = true,
        offers = emptyList(),
        officialMediaModels = emptyList(),
    )

    private class FakeHost(
        var seed: ProviderEditorSeedUi? = null,
        var saveStarted: Boolean = true,
        var testStarted: Boolean = true,
        var discoveryStarted: Boolean = true,
        var catalogRefreshStarted: Boolean = true,
        var offerDiscoveryStarted: Boolean = true,
        var offerNeedsDiscovery: Boolean = false,
    ) : ProviderUiCallbacks {
        val events = mutableListOf<String>()
        var lastSaveDraft: ProviderDraftSnapshot? = null
        var lastCredential: String? = null
        var lastClosedDiscarded: Boolean? = null

        override fun openExistingProvider(providerId: String) { events += "openExisting:$providerId" }
        override fun requestNewProvider(role: ProviderServiceRoleUi) { events += "requestNew:${role.swiftRaw}" }
        override fun setProviderEnabled(providerId: String, enabled: Boolean): Boolean {
            events += "enable:$providerId:$enabled"; return true
        }
        override fun deleteProvider(providerId: String): Boolean { events += "delete:$providerId"; return true }
        override fun seedEditorFor(role: ProviderServiceRoleUi, existingProviderId: String?): ProviderEditorSeedUi? = seed
        override fun seedSeparateOfferEditor(seed: SeparateOfferSeedUi, role: ProviderServiceRoleUi): ProviderEditorSeedUi? = this.seed
        override fun editorOpened(identity: ProviderEditorIdentity) { events += "opened:${identity.editorId}" }
        override fun editorClosed(identity: ProviderEditorIdentity, discarded: Boolean) {
            events += "closed:${identity.editorId}"
            lastClosedDiscarded = discarded
        }
        override fun saveProvider(
            identity: ProviderEditorIdentity,
            draft: ProviderDraftSnapshot,
            credentialDraft: String?,
        ): Boolean {
            lastSaveDraft = draft
            lastCredential = credentialDraft
            // Record only saves the host actually started; a refused dispatch
            // is not an event (the holder must not latch it either).
            if (!saveStarted) return false
            events += "save:${identity.editorId}:${identity.epoch}"
            return true
        }
        override fun testConnection(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
            events += "test:${probe.endpointAbsoluteString}"
            return testStarted
        }
        override fun cancelConnectionTest(identity: ProviderEditorIdentity) { events += "cancelTest" }
        override fun discoverModels(identity: ProviderEditorIdentity, probe: ConnectionProbeUi): Boolean {
            events += "discover"
            return discoveryStarted
        }
        override fun cancelModelDiscovery(identity: ProviderEditorIdentity) { events += "cancelDiscovery" }
        override fun supplierPresetChosen(preset: SupplierPresetUi) { events += "preset:${preset.presetId}" }
        override fun supplierCatalogEntryChosen(entry: OfficialSupplierUi) { events += "catalog:${entry.catalogEntryId}" }
        override fun requestCatalogRefresh(): Boolean { events += "refreshCatalog"; return catalogRefreshStarted }
        override fun serviceOfferRequiresDiscovery(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi): Boolean =
            offerNeedsDiscovery
        override fun requestOfferDiscovery(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi): Boolean {
            events += "offerDiscovery:${role.swiftRaw}"
            return offerDiscoveryStarted
        }
        override fun offerDecisionChanged(identity: ProviderEditorIdentity, role: ProviderServiceRoleUi, enabled: Boolean) {
            events += "offer:$enabled"
        }
        override fun offerPromptConfirmed(identity: ProviderEditorIdentity, roles: Set<ProviderServiceRoleUi>) {
            events += "promptConfirmed:${roles.size}"
        }
        override fun offerPromptDeclined(identity: ProviderEditorIdentity) { events += "promptDeclined" }
    }

    private fun holder(host: FakeHost): ProviderFlowHolder {
        host.seed = seed()
        return ProviderFlowHolder(host)
    }

    private fun openedIdentity(holder: ProviderFlowHolder): ProviderEditorIdentity {
        holder.openRoleChooser()
        holder.chooseRole(ProviderServiceRoleUi.CONVERSATION)
        return requireNotNull(holder.currentEditorIdentity())
    }

    /* ------------------------------ open/seed ------------------------------ */

    @Test
    fun choosingRoleNotifiesHostThenOpensSeededEditor() {
        val host = FakeHost()
        val holder = holder(host)

        holder.openRoleChooser()
        assertEquals(ProviderPane.ROLE_CHOOSER, holder.navigation.top.pane)
        val result = holder.chooseRole(ProviderServiceRoleUi.CONVERSATION)

        assertEquals(ProviderFlowResult.Accepted, result)
        assertEquals(ProviderPane.EDITOR, holder.navigation.top.pane)
        assertEquals(1, holder.drafts.openCount)
        assertTrue(host.events.indexOf("requestNew:conversation") >= 0)
        assertTrue(host.events.any { it.startsWith("opened:") })
    }

    @Test
    fun missingSeedRejectsAndLeavesTheList(): Unit {
        val host = FakeHost()
        val holder = ProviderFlowHolder(host) // no seed
        holder.openRoleChooser()

        val result = holder.chooseRole(ProviderServiceRoleUi.IMAGE)

        assertTrue(result is ProviderFlowResult.Rejected)
        assertEquals(ProviderPane.LIST, holder.navigation.top.pane)
        assertEquals(0, holder.drafts.openCount)
    }

    /* ------------------------------ save lifetime ------------------------------ */

    @Test
    fun saveDispatchRespectsHostAvailabilityAndBlocksDuplicates() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.setSecureInput(identity, "sk-synthetic")
        holder.setDisplayName(identity, "My gateway")

        host.saveStarted = false
        assertTrue(holder.save(identity, hostInFlight = false) is ProviderFlowResult.Rejected)
        assertTrue("unstarted save must not latch the dispatched flag", holder.drafts.canDispatchSave(identity, false))

        host.saveStarted = true
        assertEquals(ProviderFlowResult.Accepted, holder.save(identity, hostInFlight = false))
        assertEquals("sk-synthetic", host.lastCredential)
        assertEquals("My gateway", host.lastSaveDraft?.displayName)

        val duplicate = holder.save(identity, hostInFlight = false)
        assertEquals(ProviderFlowResult.Rejected(RejectedReason.SAVE_IN_FLIGHT), duplicate)
        assertEquals(1, host.events.count { it.startsWith("save:") })

        assertEquals(ProviderFlowResult.Accepted, holder.applyHostSaveOutcome(identity, SaveOutcomeUi.Succeeded))
        assertTrue("resolved outcome re-enables a retry", holder.drafts.canDispatchSave(identity, false))
    }

    @Test
    fun failedAttemptReleasesDuplicateSaveLatchForRetry() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.save(identity, hostInFlight = false)
        assertFalse("dispatch is latched while the attempt is pending", holder.drafts.canDispatchSave(identity, false))

        assertEquals(ProviderFlowResult.Accepted, holder.noteSaveAttemptFinished(identity))
        assertTrue("failure must let the user retry", holder.drafts.canDispatchSave(identity, false))
        assertEquals(ProviderFlowResult.Accepted, holder.save(identity, hostInFlight = false))
        assertEquals(2, host.events.count { it.startsWith("save:") })
    }

    @Test
    fun staleSaveOutcomeIsRejectedWithoutTouchingTheLiveEditor() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.save(identity, hostInFlight = false)

        val stale = identity.copy(epoch = identity.epoch + 7)
        assertEquals(ProviderFlowResult.Stale, holder.applyHostSaveOutcome(stale, SaveOutcomeUi.Succeeded))
        // The live session is untouched: still open and still blocked until
        // ITS outcome arrives.
        assertTrue(holder.drafts.accepts(identity))
        assertFalse(holder.drafts.canDispatchSave(identity, false))
    }

    @Test
    fun finalizeSavedEditorClosesOnlyTheConfirmedSession() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)

        holder.finalizeSavedEditor(identity)

        assertEquals(ProviderPane.LIST, holder.navigation.top.pane)
        assertEquals(0, holder.drafts.openCount)
        assertEquals(false, host.lastClosedDiscarded)
    }

    @Test
    fun cancelEditorDiscardsDraftAndEveryNestedPane() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.setSecureInput(identity, "sk-synthetic")
        holder.openModelManager(identity)

        holder.cancelEditor(identity)

        assertEquals(ProviderPane.LIST, holder.navigation.top.pane)
        assertEquals(0, holder.drafts.openCount)
        assertEquals(true, host.lastClosedDiscarded)
        assertNull(holder.editingModelDraftId.value)
    }

    /* ------------------------------ network actions ------------------------------ */

    @Test
    fun blankEndpointNeverDispatchesAProbe() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.setBaseUrl(identity, "")

        val result = holder.testConnection(identity, hostInFlight = false)

        assertTrue(result is ProviderFlowResult.Rejected)
        assertFalse(host.events.any { it.startsWith("test:") })
    }

    @Test
    fun offerRequiringDiscoveryDoesNotEnableUntilTheHostStartsTheProbe() {
        val host = FakeHost(offerNeedsDiscovery = true, offerDiscoveryStarted = false)
        val holder = holder(host)
        val identity = openedIdentity(holder)

        val rejected = holder.setOfferDecision(identity, ProviderServiceRoleUi.IMAGE, enabled = true)
        assertTrue(rejected is ProviderFlowResult.Rejected)
        assertNull(holder.drafts.slot(identity.editorId)!!.snapshot.value.offerDecisions[ProviderServiceRoleUi.IMAGE])

        host.offerDiscoveryStarted = true
        assertEquals(
            ProviderFlowResult.Accepted,
            holder.setOfferDecision(identity, ProviderServiceRoleUi.IMAGE, enabled = true),
        )
        assertTrue(host.events.contains("offerDiscovery:image"))
        // The role stays OFF until discovery actually succeeds (host state).
        assertNull(holder.drafts.slot(identity.editorId)!!.snapshot.value.offerDecisions[ProviderServiceRoleUi.IMAGE])
    }

    /* ------------------------------ model staging ------------------------------ */

    @Test
    fun manualModelAddRequiresValidWireIdAndClearsEntryFields() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)

        holder.manualModelRemote.value = "   "
        assertTrue(holder.addManualModel(identity) is ProviderFlowResult.Rejected)

        holder.manualModelRemote.value = " gpt-5 "
        holder.manualModelName.value = "GPT-5"
        assertEquals(ProviderFlowResult.Accepted, holder.addManualModel(identity))

        val staged = holder.drafts.slot(identity.editorId)!!.snapshot.value.models.single()
        assertEquals("gpt-5", staged.remoteModelID)
        assertEquals("GPT-5", staged.displayName)
        assertNotNull(staged.draftModelId)
        assertNull(staged.savedModelId)
        assertEquals("", holder.manualModelRemote.value)
        assertEquals("", holder.manualModelName.value)
    }

    @Test
    fun modelEditorCommitsWorkCopyAndCancelDiscardsIt() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)
        holder.manualModelRemote.value = "gpt-5"
        holder.addManualModel(identity)
        val draftId = holder.drafts.slot(identity.editorId)!!.snapshot.value.models.single().draftModelId

        assertEquals(ProviderFlowResult.Accepted, holder.openModelEditor(identity, draftId))
        assertEquals(ProviderPane.MODEL_EDITOR, holder.navigation.top.pane)
        holder.editModelWorkingCopy { it.copy(displayName = "Renamed") }
        assertEquals(ProviderFlowResult.Accepted, holder.commitModelEditor(identity))
        assertEquals(ProviderPane.EDITOR, holder.navigation.top.pane)
        assertEquals("Renamed", holder.drafts.slot(identity.editorId)!!.snapshot.value.models.single().displayName)
        assertNull(holder.modelEditorWorkingCopy.value)

        // Cancel path: edit the working copy, close, draft unchanged.
        holder.openModelEditor(identity, draftId)
        holder.editModelWorkingCopy { it.copy(displayName = "Should not persist") }
        holder.closeModelEditor()
        assertEquals("Renamed", holder.drafts.slot(identity.editorId)!!.snapshot.value.models.single().displayName)
        assertNull(holder.modelEditorWorkingCopy.value)
    }

    @Test
    fun offerPromptPaneSyncAndDecision() {
        val host = FakeHost()
        val holder = holder(host)
        val identity = openedIdentity(holder)

        holder.syncOfferPromptPane(identity, hasPrompt = true)
        assertEquals(ProviderPane.OFFER_PROMPT, holder.navigation.top.pane)

        holder.toggleOfferPromptRole(ProviderServiceRoleUi.IMAGE)
        assertEquals(ProviderFlowResult.Accepted, holder.confirmOfferPrompt(identity))
        assertEquals(ProviderPane.EDITOR, holder.navigation.top.pane)
        assertTrue(host.events.contains("promptConfirmed:1"))
        assertEquals(emptySet<ProviderServiceRoleUi>(), holder.offerPromptSelection.value)
        assertTrue(
            holder.drafts.slot(identity.editorId)!!.snapshot.value.offerDecisions[ProviderServiceRoleUi.IMAGE] == true,
        )
    }
}
