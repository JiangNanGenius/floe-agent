// SPDX-License-Identifier: MPL-2.0
//
// Authored, NOT RUN in this lane: the closed `floe.desktopassist/22` request
// shapes, secret-free list/hosts parsing and the one-time secret on
// create/update only.

package com.floe.android.host.desktopassist

import com.floe.android.feature.desktopassist.DesktopAssistKinds
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C05DesktopAssistClientTest {
    private class FakeTransport(var response: String) : C05RemoteTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return response
        }
    }

    @Test
    fun listUsesVersion22AndCarriesOnlyMetadata() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.desktopassist/22","operation":"c05.desktopassist.cards.list","cards":[""" +
                """{"id":"11111111-1111-4111-8111-111111111111","reference":"⟨credential:11111111-1111-4111-8111-111111111111⟩","label":"Desk login","kind":"websitePassword","ownerKind":"vault","hostID":null,"updatedAt":"2026-11-02T00:00:00Z","typingAllowed":true,"secretReturned":false}]}""",
        )
        val cards = C05DesktopAssistClient(transport, "owner-token-123").listCards(7)
        assertEquals(1, cards.size)
        assertEquals("Desk login", cards[0].label)
        assertTrue(cards[0].typingAllowed)
        assertFalse(cards[0].reference.isEmpty())
        val request = Json.parseToJsonElement(transport.requests.single()).jsonObject
        assertEquals(22, request["version"]!!.jsonPrimitive.content.toInt())
        val owner = request["owner"]!!.jsonObject
        assertEquals("owner-token-123", owner["token"]!!.jsonPrimitive.content)
        assertEquals(7L, owner["nativeEpoch"]!!.jsonPrimitive.content.toLong())
        assertFalse(transport.requests.single().contains("secret"))
    }

    @Test
    fun createCarriesTheOneTimeSecretAndNeverAReturnedSecret() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.desktopassist/22","operation":"c05.desktopassist.cards.create",""" +
                """"card":{"id":"22222222-2222-4222-8222-222222222222","reference":"⟨credential:22222222-2222-4222-8222-222222222222⟩","label":"NAS","kind":"genericToken","ownerKind":"vault","hostID":"33333333-3333-4333-8333-333333333333","updatedAt":"2026-11-02T00:00:00Z","typingAllowed":true,"secretReturned":false}}""",
        )
        val card = C05DesktopAssistClient(transport).createCard(
            epoch = 5,
            label = "NAS",
            kind = DesktopAssistKinds.GENERIC_TOKEN,
            secret = "one-time-secret",
            hostID = "33333333-3333-4333-8333-333333333333",
        )
        assertEquals("NAS", card.label)
        assertEquals(DesktopAssistKinds.GENERIC_TOKEN, card.kind)
        val request = transport.requests.single()
        assertTrue(request.contains("\"secret\":\"one-time-secret\""))
        assertFalse(request.contains("secretReturned"))
    }

    @Test
    fun bridgeRefusalsMapToTypedFailures() {
        val transport = FakeTransport(
            """{"ok":false,"code":"desktopAssistCardKindInvalid","reason":"invalidKind","retryable":false,"schema":"floe.desktopassist/22"}""",
        )
        val failure = runCatching {
            C05DesktopAssistClient(transport).createCard(1, "x", "sshPrivateKey", "s", null)
        }.exceptionOrNull()
        assertNotNull(failure)
        assertTrue(failure is C05RemoteFailure)
        assertEquals("desktopAssistCardKindInvalid", (failure as C05RemoteFailure).code)
    }

    @Test
    fun hostsParseWithoutAnySecretField() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.desktopassist/22","operation":"c05.desktopassist.hosts.list","hosts":[""" +
                """{"id":"44444444-4444-4444-8444-444444444444","displayName":"Studio","address":"10.0.0.9"}]}""",
        )
        val hosts = C05DesktopAssistClient(transport).listHosts(2)
        assertEquals(1, hosts.size)
        assertEquals("Studio", hosts[0].displayName)
        assertFalse(transport.requests.single().contains("password"))
    }

    @Test
    fun capabilitiesIncludeTypingKindsAndEpoch() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.desktopassist/22","coreReady":true,"epoch":11,"cardManagementReady":true,"typingKinds":["genericToken","websitePassword"],"maximumSecretBytes":4096,"linuxShellQualified":true,"ocrEngine":"linuxTesseract"}""",
        )
        val capabilities = C05DesktopAssistClient(transport).capabilities()
        assertTrue(capabilities.coreReady)
        assertEquals(11L, capabilities.epoch)
        assertTrue(capabilities.linuxShellQualified)
    }
}
