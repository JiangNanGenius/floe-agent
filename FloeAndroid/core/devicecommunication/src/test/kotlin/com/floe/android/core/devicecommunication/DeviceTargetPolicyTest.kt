// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceTargetPolicyTest {
    @Test
    fun `metadata host and literal are refused`() {
        val host = assertThrows(DeviceCommunicationException::class.java) {
            DeviceTargetPolicy.checkPolicy("metadata.google.internal")
        }
        assertEquals(DeviceErrorCode.POLICY_DENIED, host.code)
        val literal = assertThrows(DeviceCommunicationException::class.java) {
            DeviceTargetPolicy.checkPolicy("169.254.169.254")
        }
        assertEquals(DeviceErrorCode.POLICY_DENIED, literal.code)
    }

    @Test
    fun `private and loopback are local candidates`() {
        assertTrue(DeviceTargetPolicy.isLocal(DeviceTargetClass.PRIVATE))
        assertTrue(DeviceTargetPolicy.isLocal(DeviceTargetClass.LOOPBACK))
        assertTrue(DeviceTargetPolicy.isLocal(DeviceTargetClass.LINK_LOCAL))
        assertFalse(DeviceTargetPolicy.isLocal(DeviceTargetClass.PUBLIC))
        assertTrue(DeviceTargetPolicy.isLocalLikely("192.168.1.10"))
        assertTrue(DeviceTargetPolicy.isLocalLikely("switch.local"))
        assertFalse(DeviceTargetPolicy.isLocalLikely("example.com"))
    }

    @Test
    fun `invalid syntax and ports are rejected`() {
        assertEquals(
            DeviceErrorCode.INVALID_TARGET,
            assertThrows(DeviceCommunicationException::class.java) {
                DeviceTargetPolicy.validateHost("")
            }.code,
        )
        assertEquals(
            DeviceErrorCode.INVALID_TARGET,
            assertThrows(DeviceCommunicationException::class.java) {
                DeviceTargetPolicy.validatePort(0)
            }.code,
        )
    }

    @Test
    fun `USB and TCP endpoint preflight is bounded`() {
        val usb = assertThrows(DeviceCommunicationException::class.java) {
            DeviceEndpointValidation.validateUsb(
                DeviceEndpointSpec(protocol = DeviceProtocol.USB, usbDeviceName = ""),
            )
        }
        assertEquals(DeviceErrorCode.INVALID_REQUEST, usb.code)
        val tcp = DeviceEndpointValidation.validateText(
            DeviceEndpointSpec(protocol = DeviceProtocol.TCP, host = "example.com", port = 443),
        )
        assertEquals("example.com", tcp.host)
        assertEquals(443, tcp.port)
    }
}
