// SPDX-License-Identifier: MPL-2.0
//
// Synthetic unit tests for the editor session lifetime rules (no device, no
// real credential, no host):
//  - accepted steer g02-source-secret-print-and-endpoint-epoch-fix:
//    A→B boundary clears the typed key once and COMMITS B; further B path
//    edits keep the key; invalid intermediates clear nothing; scheme/port/
//    routing-family changes are real boundaries;
//  - epoch/replacement lifetime: a newer epoch replaces the session, a stale
//    epoch is rejected, close never touches a newer session;
//  - save dispatch lifetime: duplicate dispatch is blocked until the outcome
//    resolves the epoch;
//  - secret boundary: draft snapshots never contain the typed key, toString
//    output is masked, and close releases the reference.

package com.floe.android.feature.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderDraftStoreTest {

    private val openAiChoice = SupplierChoice(
        presetId = "openai",
        displayName = "OpenAI",
        catalogEntryId = null,
        absoluteEndpointDefault = "https://api.openai.com/v1",
        routeFamily = "openai",
        authStyle = "bearer",
        supportsPlainHttpChoice = false,
        suggestsToolNameCompatibility = false,
    )

    private fun seed(
        supplier: SupplierChoice = openAiChoice,
        protocol: WireProtocolUi = WireProtocolUi.OPENAI_RESPONSES,
        displayName: String = "OpenAI",
    ) = ProviderEditorSeedUi(
        snapshot = ProviderDraftSnapshot(
            role = ProviderServiceRoleUi.CONVERSATION,
            displayName = displayName,
            supplier = supplier,
            protocol = protocol,
            baseUrl = supplier.absoluteEndpointDefault,
        ),
        credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
        availableProtocols = WireProtocolUi.entries,
        discoverySupported = true,
        offers = emptyList(),
        officialMediaModels = emptyList(),
    )

    private fun identity(epoch: Long = 1, id: String = "new-conversation-1") =
        ProviderEditorIdentity(editorId = id, epoch = epoch, role = ProviderServiceRoleUi.CONVERSATION)

    private fun slotWithSecret(store: ProviderDraftStore, secret: String = "sk-synthetic-typed"): ProviderDraftSlot {
        val slot = store.open(identity(), seed())
        slot.setSecureInput(secret)
        slot.revealSecureInput.value = true
        return slot
    }

    /* ---------------------- endpoint identity transitions ---------------------- */

    @Test
    fun endpointBoundaryAtoB_clearsTypedSecretOnceAndCommitsB() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)

        slot.onEndpointEdited("https://api.anthropic.com/v1")

        assertNull("typed key must not cross a real connection boundary", slot.secureInput.value)
        assertFalse("reveal state must be released too", slot.revealSecureInput.value)
        assertTrue(slot.connectionToken!!.contains("api.anthropic.com"))
    }

    @Test
    fun endpointSameHostPathEdits_keepTypedSecretAfterBWasCommitted() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)
        slot.onEndpointEdited("https://api.anthropic.com/v1") // A → B clears once
        slot.setSecureInput("sk-typed-for-b")

        // This is the accepted-steer regression: B→B path edits must NOT be
        // compared against A again and must not clear the B key.
        slot.onEndpointEdited("https://api.anthropic.com/v2/other")
        assertEquals("sk-typed-for-b", slot.secureInput.value)
        assertTrue(slot.connectionToken!!.contains("api.anthropic.com"))

        slot.onEndpointEdited("https://api.anthropic.com/v2/other?alias=1")
        assertEquals("sk-typed-for-b", slot.secureInput.value)
    }

    @Test
    fun endpointInvalidIntermediate_clearsNothingAndKeepsLastValidIdentity() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)
        val tokenBefore = slot.connectionToken

        slot.onEndpointEdited("https://api.openai.com:notaport/v1")
        assertEquals("sk-synthetic-typed", slot.secureInput.value)
        assertEquals(tokenBefore, slot.connectionToken)

        // Overflow port is invalid too; the standard parser rejects it rather
        // than silently defaulting to 443.
        slot.onEndpointEdited("https://api.openai.com:99999999999999/v1")
        assertEquals("sk-synthetic-typed", slot.secureInput.value)
        assertEquals(tokenBefore, slot.connectionToken)

        // Mid-typing garbage.
        slot.onEndpointEdited("https://")
        assertEquals("sk-synthetic-typed", slot.secureInput.value)
        assertEquals(tokenBefore, slot.connectionToken)
    }

    @Test
    fun endpointSchemeOrPortChange_isARealBoundary() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)

        slot.onEndpointEdited("http://api.openai.com/v1") // https → http
        assertNull(slot.secureInput.value)

        slot.setSecureInput("sk-second")
        slot.onEndpointEdited("https://api.openai.com:8443/v1") // default → explicit port
        assertNull(slot.secureInput.value)
    }

    @Test
    fun supplierChangeSameHostDifferentRoutingFamily_clearsTypedSecret() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)
        // Same endpoint host, different adapter/auth family (⇄ routeFamily +
        // authStyle are part of the Swift connection identity key).
        val anthropicChoice = SpeciesFactory.anthropicSameHost()
        slot.applySupplierChoice(anthropicChoice, WireProtocolUi.ANTHROPIC_MESSAGES)

        assertNull(slot.secureInput.value)
        assertTrue(slot.connectionToken!!.contains("anthropic"))
    }

    @Test
    fun supplierSwitch_preservesCustomNameAndReplacesDefaultName() {
        val store = ProviderDraftStore()
        val slot = store.open(identity(), seed())

        // Untouched default name: replaced by the new supplier default.
        slot.applySupplierChoice(openAiChoice.copy(presetId = "x", displayName = "Anthropic"), WireProtocolUi.ANTHROPIC_MESSAGES)
        assertEquals("Anthropic", slot.snapshot.value.displayName)

        // Custom name: survives further supplier switches.
        slot.update { it.copy(displayName = "My gateway") }
        slot.applySupplierChoice(openAiChoice, WireProtocolUi.OPENAI_RESPONSES)
        assertEquals("My gateway", slot.snapshot.value.displayName)
    }

    /* ---------------------------- epoch lifetime ---------------------------- */

    @Test
    fun newerEpochReplacesSessionAndStaleEpochIsRejected() {
        val store = ProviderDraftStore()
        val first = store.open(identity(epoch = 1), seed())
        first.setSecureInput("sk-old")

        val second = store.open(identity(epoch = 2), seed(displayName = "Newer"))
        // Old secret reference is released by replacement.
        assertNull(first.secureInput.value)
        assertTrue(store.accepts(second.identity))
        assertFalse("stale epoch must be rejected", store.accepts(identity(epoch = 1)))

        store.close(identity(epoch = 1)) // must not remove the newer session
        assertEquals(1, store.openCount)
        assertTrue(store.accepts(identity(epoch = 2)))
    }

    @Test
    fun saveDispatchIsBlockedUntilOutcomeResolvesTheEpoch() {
        val store = ProviderDraftStore()
        val slot = store.open(identity(), seed())

        assertTrue(store.canDispatchSave(slot.identity, hostInFlight = false))
        assertFalse("host in-flight projection blocks dispatch", store.canDispatchSave(slot.identity, hostInFlight = true))

        store.markSaveDispatched(slot.identity)
        assertFalse("duplicate dispatch must be blocked", store.canDispatchSave(slot.identity, hostInFlight = false))

        store.resolveSaveOutcome(slot.identity)
        assertTrue(store.canDispatchSave(slot.identity, hostInFlight = false))
    }

    /* --------------------------- secret boundary --------------------------- */

    @Test
    fun draftSnapshotNeverCarriesTheTypedSecret() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)

        val snapshotText = slot.snapshot.value.toString()
        assertFalse(snapshotText.contains("sk-synthetic-typed"))
    }

    @Test
    fun slotToStringIsMasked() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)

        val text = slot.toString()
        assertFalse(text.contains("sk-synthetic-typed"))
        assertTrue(text.contains("masked"))
    }

    @Test
    fun closingReleasesSecretReferenceAndRemovesSession() {
        val store = ProviderDraftStore()
        val slot = slotWithSecret(store)

        store.close(slot.identity)

        assertEquals(0, store.openCount)
        assertNull(slot.secureInput.value)
        assertFalse(store.accepts(slot.identity))
    }

    @Test
    fun closeAllDropsEveryOpenSession() {
        val store = ProviderDraftStore()
        slotWithSecret(store)
        store.open(identity(id = "second-1"), seed())

        store.closeAll()

        assertEquals(0, store.openCount)
    }

    private object SpeciesFactory {
        fun anthropicSameHost() = SupplierChoice(
            presetId = "anthropic",
            displayName = "Anthropic",
            catalogEntryId = null,
            absoluteEndpointDefault = "https://api.openai.com/v1", // deliberately same host
            routeFamily = "anthropic",
            authStyle = "apiKeyHeader",
            supportsPlainHttpChoice = false,
            suggestsToolNameCompatibility = false,
        )
    }
}
