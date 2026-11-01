// SPDX-License-Identifier: MPL-2.0
//
// Focused JVM tests for the C05 host bridge client. No Swift core, no
// network, no credential and no device are involved: a fake transport
// returns canned `floe.remote/9` JSON and the exact request is inspected.

package com.floe.android.host.remote

import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C05RemoteClientTest {
    private class FakeTransport(var response: String) : C05RemoteTransport {
        var lastRequest: String? = null
        override fun exchange(request: String): String {
            lastRequest = request
            return response
        }
    }

    private val owner = C05RemoteOwner(token = "owner-token-123", nativeEpoch = 7)

    private fun requestJson(transport: FakeTransport) =
        Json.parseToJsonElement(requireNotNull(transport.lastRequest)).jsonObject

    private val profileJson = """
        {
          "id":"00000000-0000-4000-8000-000000000001",
          "displayName":"Lab",
          "address":"server.example",
          "port":2222,
          "user":"operator",
          "auth":{"kind":"password","credential":{"keychainAccount":"floe.ssh.lab.password","synchronizable":false}},
          "deviceKind":"linux",
          "isRemoteExecutionEnvironment":true,
          "hostKeyPolicy":"pinned",
          "pinnedFingerprintSHA256":"ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0",
          "allowsLegacyAlgorithms":false,
          "jumpHopCount":1,
          "vncEndpointCount":0,
          "auxiliaryConnectionCount":0
        }
    """.trimIndent()

    @Test
    fun capabilitiesUsesVersionNineAndParsesFlags() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.remote/9","operation":"c05.capabilities","coreReady":true,"epoch":7,"credentialGatewayReady":true,"maximumSessions":4,"maximumPTYsPerSession":4,"maximumExecsPerSession":4,"maximumTunnelsPerSession":8,"maximumJumpHops":5,"supportsPTY":true,"supportsExec":true,"supportsTunnels":true,"modelTools":false}"""
        )
        val capabilities = C05RemoteClient(transport).capabilities()
        val request = requestJson(transport)
        assertEquals(9, request["version"]?.jsonPrimitive?.content?.toInt())
        assertEquals("c05.capabilities", request["operation"]?.jsonPrimitive?.content)
        assertTrue(capabilities.coreReady)
        assertTrue(capabilities.supportsPty)
        assertEquals(5, capabilities.maximumJumpHops)
    }

    @Test
    fun profileListParsesReferenceAndPinnedFingerprint() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.profile.list","hosts":[$profileJson],"unreadableProfileIDs":[]}"""
        )
        val hosts = C05RemoteClient(transport).profileList(owner)
        assertEquals(1, hosts.size)
        val host = hosts.first()
        assertEquals("floe.ssh.lab.password", host.auth.credential?.keychainAccount)
        assertEquals("pinned", host.hostKeyPolicy)
        assertEquals("ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0", host.pinnedFingerprint)
        assertEquals(7L, requestJson(transport)["owner"]?.jsonObject?.get("nativeEpoch")?.jsonPrimitive?.content?.toLong())
    }

    @Test
    fun profileSaveSendsOnlyTheCredentialReference() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.profile.save","host":$profileJson}"""
        )
        val payload = C05ProfilePayload(
            id = "00000000-0000-4000-8000-000000000001",
            displayName = "Lab",
            address = "server.example",
            port = 2222,
            user = "operator",
            auth = C05Auth("password", null, C05CredentialRef("floe.ssh.lab.password", false)),
            jumpChain = emptyList(),
            hostKeyPolicy = "trustOnFirstUse",
            pinnedFingerprint = null,
            allowsLegacyAlgorithms = false,
            deviceKind = "unspecified",
            isRemoteExecutionEnvironment = true,
            vncEndpoints = emptyList(),
            auxiliaryConnections = emptyList(),
        )
        C05RemoteClient(transport).profileSave(payload, owner)
        val request = requestJson(transport)
        val profile = request["profile"]?.jsonObject ?: error("missing profile")
        val auth = profile["auth"]?.jsonObject ?: error("missing auth")
        assertEquals("floe.ssh.lab.password", auth["credential"]?.jsonObject?.get("keychainAccount")?.jsonPrimitive?.content)
        assertTrue(!request.toString().contains("hunter2"))
    }

    @Test
    fun ptyReadDecodesBytesAndCursor() {
        val encoded = Base64.getEncoder().encodeToString("hello".toByteArray())
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.pty.read","ptyID":"pty-1","state":"running","dataBase64":"$encoded","bytes":5,"nextCursor":5,"lostBytes":0,"totalBytes":5,"rolledOverBytes":0}"""
        )
        val page = C05RemoteClient(transport).ptyRead("pty-1", 0, 1024, owner)
        assertEquals("hello", String(page.bytes))
        assertEquals(5L, page.nextCursor)
        assertEquals("running", page.state)
    }

    @Test
    fun execReadPreservesChannelTags() {
        val stdout = Base64.getEncoder().encodeToString("out".toByteArray())
        val stderr = Base64.getEncoder().encodeToString("err".toByteArray())
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.exec.read","exec":{"id":"e1","sessionID":"s1","state":"exited","stdoutBytes":3,"stderrBytes":3,"rolledOverBytes":0,"exitCode":0,"remoteOutcomeUnknown":false},"chunks":[{"channel":"stdout","dataBase64":"$stdout"},{"channel":"stderr","dataBase64":"$stderr"}],"nextCursor":6,"lostBytes":0}"""
        )
        val page = C05RemoteClient(transport).execRead("e1", 0, 1024, owner)
        assertEquals(listOf("stdout", "stderr"), page.chunks.map { it.channel })
        assertEquals("out", String(page.chunks[0].data))
        assertEquals("err", String(page.chunks[1].data))
        assertEquals(0, page.exec.exitCode)
    }

    @Test
    fun hostKeyChallengeIsCarriedOnFailure() {
        val transport = FakeTransport(
            """{"ok":false,"code":"hostKeyChallenge","reason":"hostKeyConfirmationRequired","retryable":false,"challenge":{"id":"c1","profileID":"p1","address":"server.example","port":22,"keyType":"ssh-ed25519","fingerprintSHA256":"SHA256:new","kind":"firstUse","createdAt":"now","expiresAt":"later"}}"""
        )
        var failure: C05RemoteFailure? = null
        try {
            C05RemoteClient(transport).connect("p1", owner)
        } catch (error: C05RemoteFailure) {
            failure = error
        }
        assertEquals("hostKeyChallenge", failure?.code)
        assertEquals("SHA256:new", failure?.challenge?.fingerprintSHA256)
        assertEquals(false, failure?.retryable)
    }

    @Test
    fun unsupportedVersionFailsClosedAsNeedsCoreUpdate() {
        val transport = FakeTransport("""{"ok":false,"error":"unsupportedVersion"}""")
        var failure: C05RemoteFailure? = null
        try {
            C05RemoteClient(transport).capabilities()
        } catch (error: C05RemoteFailure) {
            failure = error
        }
        assertEquals("needsCoreUpdate", failure?.code)
    }

    @Test
    fun rootStopSendsExpectedEpoch() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.rootStop","drained":true,"closedSessions":1,"closedPTYs":1,"closedExecs":0,"closedTunnels":1}"""
        )
        val result = C05RemoteClient(transport).rootStop(7)
        assertTrue(result.drained)
        assertEquals(1, result.closedTunnels)
        assertEquals(7L, requestJson(transport)["expectedEpoch"]?.jsonPrimitive?.content?.toLong())
    }

    @Test
    fun sessionStatusParsesNestedResources() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.session.status","session":{"id":"s1","profileID":"p1","displayName":"Lab","address":"server.example","port":22,"user":"operator","state":"connected","transportConnected":true,"createdAt":"a","lastActivityAt":"b","ptyCount":1,"execCount":0,"tunnelCount":1},"ptys":[{"id":"pty-1","sessionID":"s1","state":"running","columns":120,"rows":32,"totalBytes":10,"rolledOverBytes":0}],"execs":[],"tunnels":[{"id":"t1","sessionID":"s1","targetHost":"127.0.0.1","targetPort":5900,"localHost":"127.0.0.1","localPort":49152,"state":"open","acceptedConnections":2,"activeConnections":1,"bytesToRemote":10,"bytesFromRemote":20}]}"""
        )
        val detail = C05RemoteClient(transport).sessionStatus("s1", owner)
        assertEquals("s1", detail.session.id)
        assertEquals(1, detail.ptys.size)
        assertEquals(49152, detail.tunnels.first().localPort)
        assertNull(detail.tunnels.first().lastErrorCode)
    }
}
