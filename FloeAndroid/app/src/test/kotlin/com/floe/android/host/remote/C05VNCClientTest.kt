// SPDX-License-Identifier: MPL-2.0
//
// Authored, NOT RUN in this lane: closed floe.vnc/11 request shapes, VNC-only
// profile fields, input event encoding and the metadata-only frame contract.

package com.floe.android.host.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C05VNCClientTest {
    private class FakeTransport(var response: String) : C05RemoteTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return response
        }
    }

    private val owner = C05RemoteOwner(token = "vnc-owner-token", nativeEpoch = 9)

    @Test
    fun capabilitiesAreReadFromTheClosedWire() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.vnc/11","operation":"c05.vnc.capabilities","coreReady":true,"epoch":9,"credentialGatewayReady":true,"maximumSessions":2,"maximumProfiles":64,"maximumEndpointsPerProfile":8,"maximumInputEvents":32,"maximumTextBytes":4096,"maximumCredentialBytes":40960,"maximumFrameBytes":33177600,"maximumLeases":8,"pixelFormat":"RGBA8888","supportsDirect":true,"supportsSSHTunnel":true,"supportsPointer":true,"supportsKeyboard":true,"supportsWheel":true,"modelTools":false}""",
        )
        val capabilities = C05VNCClient(transport).capabilities()
        assertEquals(2, capabilities.maximumSessions)
        assertEquals(33_177_600, capabilities.maximumFrameBytes)
        assertEquals("RGBA8888", capabilities.pixelFormat)
        assertFalse(capabilities.modelTools)
        assertEquals(11, Json.parseToJsonElement(transport.requests.single()).jsonObject["version"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun vncOnlyProfileCarriesNoSshIdentity() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.vnc/11","operation":"c05.vnc.profile.save",""" +
                """"host":{"id":"11111111-1111-1111-1111-111111111111","displayName":"Desk",""" +
                """"address":"","port":0,"user":"","auth":{"kind":"none"},"deviceKind":"unspecified",""" +
                """"isRemoteExecutionEnvironment":false,"hostKeyPolicy":"trustOnFirstUse",""" +
                """"pinnedFingerprintSHA256":null,"allowsLegacyAlgorithms":false,"jumpHopCount":0,""" +
                """"vncEndpointCount":1,"auxiliaryConnectionCount":0,"jumpChain":[],"vncEndpoints":[],"auxiliaryConnections":[]}}""",
        )
        C05VNCClient(transport).profileSaveVNCOnly(
            C05VncProfileDraft(
                id = "11111111-1111-1111-1111-111111111111",
                displayName = "Desk",
                deviceKind = "unspecified",
                endpoints = listOf(
                    C05VncEndpointDraft(
                        id = "22222222-2222-2222-2222-222222222222",
                        displayName = "VNC",
                        transport = "direct",
                        host = "192.168.1.20",
                        port = 5900,
                        passwordRef = C05VncPasswordRef("floe.vnc.22222222-2222-2222-2222-222222222222.password", false),
                    )
                ),
            ),
            owner,
        )
        val request = Json.parseToJsonElement(transport.requests.single()).jsonObject
        val profile = request["profile"]!!.jsonObject
        assertFalse(profile.containsKey("auth"))
        assertFalse(profile.containsKey("user"))
        assertEquals("Desk", profile["displayName"]!!.jsonPrimitive.content)
        val endpoint = profile["vncEndpoints"]!!.jsonArray.single().jsonObject
        assertEquals("direct", endpoint["transport"]!!.jsonPrimitive.content)
        assertTrue(endpoint["passwordRef"]!!.jsonObject["keychainAccount"]!!.jsonPrimitive.content.startsWith("floe.vnc."))
    }

    @Test
    fun inputBatchIsOrderedAndBounded() {
        val transport = FakeTransport(
            """{"ok":true,"schema":"floe.vnc/11","operation":"c05.vnc.input","accepted":4}""",
        )
        val accepted = C05VNCClient(transport).input(
            "33333333-3333-3333-3333-333333333333",
            listOf(
                C05VncInput.PointerMove(10, 20),
                C05VncInput.PointerButton("left", true, 10, 20),
                C05VncInput.Wheel("down", 2, 10, 20),
                C05VncInput.Key(0x61, true),
            ),
            owner,
        )
        assertEquals(4, accepted)
        val events = Json.parseToJsonElement(transport.requests.single())
            .jsonObject["events"]!!.jsonArray
        assertEquals(4, events.size)
        assertEquals("pointerMove", events[0].jsonObject["kind"]!!.jsonPrimitive.content)
        assertEquals("left", events[1].jsonObject["button"]!!.jsonPrimitive.content)
        assertEquals("down", events[2].jsonObject["axis"]!!.jsonPrimitive.content)
        assertEquals("97", events[3].jsonObject["keysym"]!!.jsonPrimitive.content)
    }
}
