// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.devicecommunication

import com.floe.android.core.devicecommunication.DeviceErrorCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceDraftValidationTest {
    @Test
    fun `valid TCP and Telnet drafts produce concrete specs`() {
        val tcp = DeviceDraft(tab = DeviceTab.TCP, displayName = "PLC", host = "10.0.0.2", port = "502")
        assertNull(tcp.validationCode())
        assertEquals(502, tcp.toSpecOrNull()?.port)

        val telnet = tcp.copy(tab = DeviceTab.TELNET, port = "23")
        assertNull(telnet.validationCode())
        assertEquals("10.0.0.2", telnet.toSpecOrNull()?.host)
    }

    @Test
    fun `invalid port and host fail validation`() {
        assertEquals(
            DeviceErrorCode.INVALID_TARGET.wire,
            DeviceDraft(tab = DeviceTab.TCP, host = "example.com", port = "99999").validationCode(),
        )
        assertEquals(
            DeviceErrorCode.INVALID_TARGET.wire,
            DeviceDraft(tab = DeviceTab.TCP, host = "", port = "23").validationCode(),
        )
    }

    @Test
    fun `BLE draft normalizes identifiers and keeps optional notify`() {
        val draft = DeviceDraft(
            tab = DeviceTab.BLE,
            peripheralAddress = "aa:bb:cc:dd:ee:ff",
            serviceUuid = "180f",
            writeUuid = "2a19",
        )
        assertNull(draft.validationCode())
        val spec = draft.toSpecOrNull()
        assertNotNull(spec)
        assertEquals("AA:BB:CC:DD:EE:FF", spec!!.bleAddress)
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", spec.bleServiceUuid)
        assertNull(spec.bleNotifyUuid)
    }

    @Test
    fun `BLE draft rejects malformed UUID`() {
        val draft = DeviceDraft(
            tab = DeviceTab.BLE,
            peripheralAddress = "aa:bb:cc:dd:ee:ff",
            serviceUuid = "not-a-uuid",
            writeUuid = "2a19",
        )
        assertEquals(DeviceErrorCode.INVALID_REQUEST.wire, draft.validationCode())
    }

    @Test
    fun `USB draft requires a device and bounded serial settings`() {
        assertNull(
            DeviceDraft(
                tab = DeviceTab.USB,
                usbDeviceKey = "/dev/bus/usb/001/002",
                baudRate = "115200",
            ).validationCode(),
        )
        assertEquals(
            DeviceErrorCode.INVALID_REQUEST.wire,
            DeviceDraft(tab = DeviceTab.USB, baudRate = "115200").validationCode(),
        )
        assertEquals(
            DeviceErrorCode.INVALID_REQUEST.wire,
            DeviceDraft(
                tab = DeviceTab.USB,
                usbDeviceKey = "/dev/bus/usb/001/002",
                baudRate = "5",
            ).validationCode(),
        )
    }

    @Test
    fun `saved connection opens into the matching tab`() {
        val connection = DeviceConnectionUi(
            id = "c1",
            profileId = "p1",
            displayName = "Switch",
            tab = DeviceTab.TELNET,
            host = "192.168.1.2",
            port = 23,
        )
        val draft = connection.toDraft()
        assertEquals("p1", draft.profileId)
        assertEquals(DeviceTab.TELNET, draft.tab)
        assertEquals("192.168.1.2", draft.host)
    }
}
