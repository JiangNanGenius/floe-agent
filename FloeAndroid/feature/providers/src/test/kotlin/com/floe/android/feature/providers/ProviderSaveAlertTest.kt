// SPDX-License-Identifier: MPL-2.0
//
// Pure JVM tests for the save-failure alert lifecycle: current-identity
// fencing, first failure, acknowledgement without editor close, same-message
// retry after a host attempt boundary, and the new-editor reset. No Android
// runtime, backend, credential or database is involved.

package com.floe.android.feature.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProviderSaveAlertTest {

    private val identity = ProviderEditorIdentity(
        editorId = "editor-1",
        epoch = 1,
        role = ProviderServiceRoleUi.CONVERSATION,
    )

    private fun editor(
        id: ProviderEditorIdentity = identity,
        saveError: String? = null,
        outcome: SaveOutcomeUi? = null,
    ) = ProviderEditorUiState(
        identity = id,
        isEditingExisting = true,
        role = id.role,
        credentialState = ProviderCredentialStateUi.CONFIGURED,
        credentialRequirementMessage = null,
        availableProtocols = WireProtocolUi.entries,
        testState = ConnectionTestUi.Idle,
        discoverySupported = true,
        offers = emptyList(),
        pendingOfferPrompt = null,
        saveInFlight = false,
        saveError = saveError,
        saveOutcome = outcome,
        formMessage = null,
        fieldIssues = emptyList(),
        hostCandidateModels = emptyList(),
        officialMediaModels = emptyList(),
        networkActionsAvailable = true,
        networkActionsUnavailableReason = null,
    )

    @Test
    fun currentSaveErrorIsReadForTheCurrentIdentity() {
        assertEquals(
            "Synthetic save failure",
            currentSaveFailureMessage(editor(saveError = "Synthetic save failure"), identity),
        )
    }

    @Test
    fun structuredFailureIsUsedWhenPlainSaveErrorIsAbsent() {
        assertEquals(
            "Structured failure",
            currentSaveFailureMessage(
                editor(outcome = SaveOutcomeUi.Failed(SaveFailurePhaseUi.LOCAL_COMMIT, "Structured failure")),
                identity,
            ),
        )
    }

    @Test
    fun plainSaveErrorWinsOverTheStructuredOutcome() {
        assertEquals(
            "Plain failure",
            currentSaveFailureMessage(
                editor(
                    saveError = "Plain failure",
                    outcome = SaveOutcomeUi.Failed(SaveFailurePhaseUi.PREFLIGHT, "Structured failure"),
                ),
                identity,
            ),
        )
    }

    @Test
    fun differentEditorIdCannotSupplyAFailure() {
        val stale = identity.copy(editorId = "editor-old")
        assertNull(currentSaveFailureMessage(editor(id = stale, saveError = "Stale"), identity))
    }

    @Test
    fun sameEditorIdWithAnOldEpochCannotSupplyAFailure() {
        val stale = identity.copy(epoch = identity.epoch - 1)
        assertNull(currentSaveFailureMessage(editor(id = stale, saveError = "Stale"), identity))
    }

    @Test
    fun blankFailureIsIgnored() {
        assertNull(currentSaveFailureMessage(editor(saveError = "   "), identity))
    }

    @Test
    fun firstFailureOpensTheAlert() {
        val state = ProviderSaveAlertUi().observe("Save failed", saveInFlight = false)
        assertEquals("Save failed", state.message)
        assertNull(state.acknowledgedMessage)
    }

    @Test
    fun recompositionWithTheSameFailureDoesNotReopenAnAcknowledgedAlert() {
        val shown = ProviderSaveAlertUi().observe("Save failed", saveInFlight = false)
        val acknowledged = shown.acknowledge()
        assertNull(acknowledged.message)
        assertEquals("Save failed", acknowledged.acknowledgedMessage)

        val recomposed = acknowledged.observe("Save failed", saveInFlight = false)
        assertNull(recomposed.message)
        assertEquals("Save failed", recomposed.acknowledgedMessage)
    }

    @Test
    fun sameMessageFromANewAttemptAlertsAgainAfterTheHostBoundary() {
        val acknowledged = ProviderSaveAlertUi()
            .observe("Save failed", saveInFlight = false)
            .acknowledge()
            .observe("Save failed", saveInFlight = true) // retry is now in flight
        assertNull(acknowledged.message)
        assertNull(acknowledged.acknowledgedMessage)

        val failedAgain = acknowledged.observe("Save failed", saveInFlight = false)
        assertEquals("Save failed", failedAgain.message)
    }

    @Test
    fun sameMessageFromANewHostFailureSequenceAlertsWithoutAnInFlightFrame() {
        val acknowledged = ProviderSaveAlertUi()
            .observe("Save failed", saveInFlight = false, failureSequence = 7L)
            .acknowledge()
        assertNull(acknowledged.message)
        assertEquals(7L, acknowledged.acknowledgedFailureSequence)

        // Recomposition of the SAME acknowledged failure/sequence stays quiet.
        val recomposed = acknowledged.observe("Save failed", saveInFlight = false, failureSequence = 7L)
        assertNull(recomposed.message)

        // A synchronously-failing retry can move only the host sequence: the
        // message and in-flight flag can look identical to the old attempt.
        val failedAgain = recomposed.observe("Save failed", saveInFlight = false, failureSequence = 8L)
        assertEquals("Save failed", failedAgain.message)
        assertEquals(8L, failedAgain.failureSequence)
    }

    @Test
    fun sameMessageAlertsAgainWhenTheHostClearsTheErrorAtRetryStart() {
        val acknowledged = ProviderSaveAlertUi()
            .observe("Save failed", saveInFlight = false)
            .acknowledge()
        val cleared = acknowledged.observe(null, saveInFlight = true)
        assertNull(cleared.acknowledgedMessage)

        val failedAgain = cleared.observe("Save failed", saveInFlight = false)
        assertEquals("Save failed", failedAgain.message)
    }

    @Test
    fun aNewEditorIdentityStartsWithNoAcknowledgedFailure() {
        val acknowledged = ProviderSaveAlertUi()
            .observe("Save failed", saveInFlight = false)
            .acknowledge()
        assertEquals("Save failed", acknowledged.acknowledgedMessage)

        // The editor composable keys this state by editorId+epoch; a new
        // editor therefore starts from the default state and may alert.
        val newEditor = ProviderSaveAlertUi().observe("Save failed", saveInFlight = false)
        assertEquals("Save failed", newEditor.message)
    }
}
