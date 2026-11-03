// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP client wire tests (authored, not run in this lane). The fake
// transport proves the request version/operation, bounded input encoding and
// typed certificate challenge parsing; no socket or FreeRDP session is
// created.

package com.floe.android.host.rdp

import com.floe.android.host.remote.C05RemoteOwner
import com.floe.android.host.remote.C05RemoteTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C05RDPClientTest {
    private val owner = C05RemoteOwner("rdp-test-owner", 7)
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun capabilitiesUseTheReservedSchemaVersion() {
        var captured = ""
        val client = C05RDPClient(
            transport = C05RemoteTransport { request ->
                captured = request
                """
                {"ok":true,"schema":"floe.rdp/17","operation":"c05.rdp.capabilities",
                 "coreReady":true,"epoch":7,"credentialGatewayReady":true,
                 "runtimeVersion":"3.31.1","maximumSessions":2,
                 "maximumEndpointsPerProfile":4,"maximumInputEvents":32,
                 "maximumTextBytes":4096,"maximumFrameBytes":33554432,
                 "maximumLeases":8,"pixelFormat":"RGBA8888",
                 "supportsCertificateTrust":true,"modelTools":true}
                """.trimIndent()
            },
        )
        val capabilities = client.capabilities()
        val request = json.parseToJsonElement(captured).jsonObject
        assertEquals("17", request["version"]?.jsonPrimitive?.content)
        assertEquals("c05.rdp.capabilities", request["operation"]?.jsonPrimitive?.content)
        assertTrue(capabilities.coreReady)
        assertEquals("3.31.1", capabilities.runtimeVersion)
        assertTrue(capabilities.supportsCertificateTrust)
    }

    @Test
    fun certificateChallengeIsTypedAndNeverAutoApproved() {
        val client = C05RDPClient(
            transport = C05RemoteTransport {
                """
                {"ok":false,"code":"certificateConfirmationRequired",
                 "reason":"certificateConfirmationRequired","retryable":false,
                 "challenge":{"profileID":"11111111-1111-4111-8111-111111111111",
                 "endpointID":"22222222-2222-4222-8222-222222222222",
                 "host":"10.0.0.4","port":3389,
                 "fingerprintSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 "subject":"DESKTOP-1","kind":"firstUse",
                 "reason":"Confirm this RDP server certificate before connecting",
                 "expiresAt":"2026-11-01T00:00:00Z"}}
                """.trimIndent()
            },
        )
        try {
            client.connect(
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222",
                owner,
            )
            throw AssertionError("expected a certificate challenge")
        } catch (failure: C05RDPException) {
            assertEquals("certificateConfirmationRequired", failure.code)
            val challenge = failure.challenge
            assertNotNull(challenge)
            assertEquals(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                challenge?.fingerprintSHA256,
            )
            assertEquals("firstUse", challenge?.kind)
            assertFalse(failure.retryable)
        }
    }

    @Test
    fun inputEncodingIsBoundedAndCarriesProtocolScancodes() {
        var captured = ""
        val client = C05RDPClient(
            transport = C05RemoteTransport { request ->
                captured = request
                """{"ok":true,"schema":"floe.rdp/17","operation":"c05.rdp.input","accepted":4}"""
            },
        )
        val accepted = client.input(
            "33333333-3333-4333-8333-333333333333",
            listOf(
                C05RdpInput.PointerMove(10, 20),
                C05RdpInput.PointerButton("left", true, 10, 20),
                C05RdpInput.NamedKey("Return"),
                C05RdpInput.Text("hello", false),
            ),
            owner,
        )
        assertEquals(4, accepted)
        val request = json.parseToJsonElement(captured).jsonObject
        assertEquals("17", request["version"]?.jsonPrimitive?.content)
        val events = request["events"]!!.let { it as kotlinx.serialization.json.JsonArray }
        assertEquals("pointerMove", events[0].jsonObject["kind"]?.jsonPrimitive?.content)
        assertEquals("namedKey", events[2].jsonObject["kind"]?.jsonPrimitive?.content)
        assertEquals("text", events[3].jsonObject["kind"]?.jsonPrimitive?.content)
    }

    @Test
    fun profileListParsesTrustedAndUntrustedEndpoints() {
        val client = C05RDPClient(
            transport = C05RemoteTransport {
                """
                {"ok":true,"schema":"floe.rdp/17","operation":"c05.rdp.profile.list",
                 "hosts":[{"summary":{"id":"11111111-1111-4111-8111-111111111111",
                 "displayName":"Desk","deviceKind":"windows",
                 "isRemoteExecutionEnvironment":false,"endpointCount":1},
                 "endpoints":[{"id":"22222222-2222-4222-8222-222222222222",
                 "displayName":"RDP","host":"10.0.0.4","port":3389,
                 "username":"floe","domain":"LAB","hasPassword":true,
                 "approvedFingerprintSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                 "passwordRef":{"keychainAccount":"floe.rdp.22222222-2222-4222-8222-222222222222.password",
                 "synchronizable":false}}]}]}
                """.trimIndent()
            },
        )
        val hosts = client.listProfiles(owner)
        assertEquals(1, hosts.size)
        val endpoint = hosts[0].endpoints.single()
        assertEquals("LAB", endpoint.domain)
        assertEquals("floe.rdp.22222222-2222-4222-8222-222222222222.password",
            endpoint.passwordRef?.keychainAccount)
        assertTrue(endpoint.hasPassword)
        assertTrue(endpoint.approvedFingerprintSHA256?.length == 64)
    }
}
