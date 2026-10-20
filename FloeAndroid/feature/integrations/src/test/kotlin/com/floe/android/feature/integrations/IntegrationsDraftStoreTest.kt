// SPDX-License-Identifier: MPL-2.0
//
// RAM-only draft/identity tests for the MCP editor store:
//  - the seed fills the non-secret draft and the saved revision;
//  - the typed secret is passed only with a SET intent, is cleared when the
//    endpoint ORIGIN changes, survives same-origin edits, and never appears
//    in toString();
//  - reopening produces a NEW editorId and the old identity is stale
//    (late success cannot close a newer editor);
//  - reseed bumps the epoch and invalidates the previous one;
//  - the duplicate-save latch releases only on a resolved outcome.
//
// SOURCE ONLY in this stage: no Gradle/JVM run was performed by the source
// lane; these tests document the intended fences, they are not a result
// claim.

package com.floe.android.feature.integrations

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationsDraftStoreTest {

    private fun seed(
        serverId: String? = "server-1",
        endpoint: String = "https://host/mcp",
        stored: Boolean = true,
        revision: Long? = 4L,
    ) = McpEditorSeedUi(
        serverId = serverId,
        displayName = "Saved Server",
        endpointText = endpoint,
        enabled = true,
        allowInCanvas = true,
        allowInsecureHttp = false,
        authentication = McpAuthenticationUi.BEARER_TOKEN,
        credentialHeaderName = "Authorization",
        credentialStored = stored,
        timeoutSeconds = 30,
        transport = McpTransportUi.StreamableHttp,
        tools = listOf(
            McpToolRowUi("search", "Search", "d", enabled = true, readOnlyHint = true, destructiveHint = false),
            McpToolRowUi("write", "Write", "d", enabled = false, readOnlyHint = false, destructiveHint = true),
        ),
        networkActionsAvailable = true,
        networkActionsUnavailableReason = null,
        savedRevision = revision,
    )

    private fun draftFor(seed: McpEditorSeedUi) = McpDraftSnapshot(
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

    @Test
    fun `opening seeds the draft origin tools and revision`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        assertEquals("Saved Server", slot.snapshot.value.displayName)
        assertEquals("https://host:443", slot.currentOriginToken)
        assertEquals(setOf("write"), slot.snapshot.value.disabledRemoteToolNames)
        assertEquals(4L, slot.baseRevision)
        assertTrue(store.accepts(slot.identity))
    }

    @Test
    fun `empty typed draft keeps the stored secret on the same origin`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        val request = slot.buildSaveRequest()
        assertEquals(CredentialDraftIntent.KEEP_EXISTING, request.credentialIntent)
        assertNull(request.credentialDraft)
    }

    @Test
    fun `typed secret is carried with a SET intent and masked in toString`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        slot.setSecureInput("super-secret-token")
        val request = slot.buildSaveRequest()
        assertEquals(CredentialDraftIntent.SET, request.credentialIntent)
        assertEquals("super-secret-token", request.credentialDraft)
        assertFalse(request.toString().contains("super-secret-token"))
        assertFalse(slot.toString().contains("super-secret-token"))
        assertTrue(request.toString().contains("redacted"))
    }

    @Test
    fun `changing the endpoint origin drops the typed secret`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        slot.setSecureInput("origin-bound-secret")
        slot.update { it.copy(endpointText = "https://host/mcp/v2") }
        assertEquals("origin-bound-secret", slot.secureInput.value)
        slot.update { it.copy(endpointText = "https://other-host/mcp") }
        assertNull(slot.secureInput.value)
        assertEquals(
            CredentialDraftIntent.MISSING,
            slot.buildSaveRequest().credentialIntent,
        )
    }

    @Test
    fun `unparseable intermediate text never clears the secret`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        slot.setSecureInput("keep-me")
        slot.update { it.copy(endpointText = "https://") }
        assertEquals("keep-me", slot.secureInput.value)
        assertEquals("https://host:443", slot.currentOriginToken)
    }

    @Test
    fun `switching auth to none clears the typed secret and computes CLEAR`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        slot.setSecureInput("secret")
        slot.update { it.copy(authentication = McpAuthenticationUi.NONE) }
        slot.clearSecureInput()
        val request = slot.buildSaveRequest()
        assertEquals(CredentialDraftIntent.CLEAR, request.credentialIntent)
        assertNull(request.credentialDraft)
    }

    @Test
    fun `reopening creates a new id and the old identity is stale`() {
        val store = McpEditorStore()
        val s = seed()
        val first = store.open(s, draftFor(s))
        val second = store.open(s, draftFor(s))
        assertNotEquals(first.identity.editorId, second.identity.editorId)
        store.close(first.identity)
        assertFalse(store.accepts(first.identity))
        assertTrue(store.accepts(second.identity))
        assertNull(store.slot(first.identity.editorId))
    }

    @Test
    fun `reseed bumps the epoch and invalidates the old identity`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        val old = slot.identity
        val reseeded = store.reseed(old, s, draftFor(s))
        assertEquals(old.epoch + 1, reseeded.epoch)
        assertFalse(store.accepts(old))
        assertTrue(store.accepts(reseeded))
    }

    @Test
    fun `duplicate save dispatch is latched per identity`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        assertTrue(store.canDispatchSave(slot.identity, hostInFlight = false))
        slot.markSaveDispatched()
        assertFalse(store.canDispatchSave(slot.identity, hostInFlight = false))
        slot.resolveSaveOutcome()
        assertTrue(store.canDispatchSave(slot.identity, hostInFlight = false))
        assertFalse(store.canDispatchSave(slot.identity, hostInFlight = true))
    }

    @Test
    fun `closing drops the typed secret reference`() {
        val store = McpEditorStore()
        val s = seed()
        val slot = store.open(s, draftFor(s))
        slot.setSecureInput("dropped-on-close")
        store.close(slot.identity)
        assertNull(slot.secureInput.value)
    }

    @Test
    fun `skill form ids are unique per open and closing removes them`() {
        val store = SkillFormStore()
        val creator = store.open(IntegrationsPane.SKILL_CREATOR)
        val finder = store.open(IntegrationsPane.SKILL_FINDER)
        assertNotEquals(creator.formId, finder.formId)
        assertTrue(creator.formId.startsWith("skill_creator"))
        assertTrue(finder.formId.startsWith("skill_finder"))
        store.close(creator.formId)
        assertNull(store.slot(creator.formId))
        assertTrue(store.slot(finder.formId) != null)
        store.closeAll()
        assertNull(store.slot(finder.formId))
    }
}
