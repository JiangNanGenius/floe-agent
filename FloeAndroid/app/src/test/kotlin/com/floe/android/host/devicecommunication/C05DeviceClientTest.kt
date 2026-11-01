// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicecommunication

import com.floe.android.host.remote.C05RemoteOwner
import com.floe.android.host.remote.C05RemoteTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class C05DeviceClientTest {
    private class FakeTransport(
        var response: String,
        val requests: MutableList<String> = mutableListOf(),
    ) : C05RemoteTransport {
        override fun exchange(request: String): String {
            requests += request
            return response
        }
    }

    private val owner = C05RemoteOwner(token = "ui.test", nativeEpoch = 7)

    @Test
    fun `capabilities use the closed device channel version`() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.device.capabilities","coreReady":true,"epoch":7,
               "maximumSessions":4,"maximumProfiles":64,"maximumConnectionsPerProfile":8,
               "supportsTcp":true,"supportsTelnet":true,"supportsBle":true,"supportsUsb":true,
               "modelTools":true}""",
        )
        val caps = C05DeviceClient(transport).capabilities()
        assertTrue(caps.coreReady)
        assertEquals(7L, caps.epoch)
        assertTrue(caps.supportsUsb)
        assertTrue(transport.requests.single().contains("\"version\":14"))
        assertTrue(transport.requests.single().contains("c05.device.capabilities"))
    }

    @Test
    fun `profile list parses TCP Telnet and BLE connections`() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.device.profile.list","profiles":[
               {"id":"p1","displayName":"Lab","connections":[
                 {"id":"c1","displayName":"Console","kind":"telnet","host":"192.168.1.2","port":23},
                 {"id":"c2","displayName":"Sensor","kind":"bluetoothSerial","peripheralAddress":"AA:BB:CC:DD:EE:FF",
                  "serviceUUID":"0000180f-0000-1000-8000-00805f9b34fb","writeUUID":"00002a19-0000-1000-8000-00805f9b34fb"}
               ]}]}""",
        )
        val profiles = C05DeviceClient(transport).profiles(owner)
        assertEquals(1, profiles.size)
        assertEquals(2, profiles.single().connections.size)
        assertEquals("telnet", profiles.single().connections[0].kind)
        assertEquals("AA:BB:CC:DD:EE:FF", profiles.single().connections[1].peripheralAddress)
    }

    @Test
    fun `profile save sends only metadata and returns the saved profile`() {
        val transport = FakeTransport(
            """{"ok":true,"operation":"c05.device.profile.save","profile":{
               "id":"p1","displayName":"Lab","connections":[
                 {"id":"c1","displayName":"Console","kind":"tcp","host":"example.com","port":9000}]}}""",
        )
        val saved = C05DeviceClient(transport).saveProfile(
            C05DeviceProfileDraft(
                id = null,
                displayName = "Lab",
                connections = listOf(
                    C05DeviceConnectionDraft(
                        id = null,
                        displayName = "Console",
                        kind = "tcp",
                        host = "example.com",
                        port = 9000,
                    ),
                ),
            ),
            owner,
        )
        assertEquals("Lab", saved.displayName)
        assertEquals(9000, saved.connections.single().port)
        val request = transport.requests.single()
        assertTrue(request.contains("\"kind\":\"tcp\""))
        assertTrue(request.contains("\"owner\""))
        assertTrue(!request.contains("password", ignoreCase = true))
    }

    @Test
    fun `bridge failures retain their typed code`() {
        val transport = FakeTransport(
            """{"ok":false,"code":"profileNotFound","reason":"profileNotFound","retryable":false}""",
        )
        val error = runCatching {
            C05DeviceClient(transport).profiles(owner)
        }.exceptionOrNull()
        assertTrue(error is com.floe.android.host.remote.C05RemoteFailure)
        assertEquals("profileNotFound", (error as com.floe.android.host.remote.C05RemoteFailure).code)
    }
}
