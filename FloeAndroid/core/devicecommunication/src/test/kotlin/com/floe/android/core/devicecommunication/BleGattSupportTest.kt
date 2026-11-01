// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BleGattSupportTest {
    @Test
    fun `payload limit follows the negotiated MTU`() {
        assertEquals(20, BleGattBounds.payloadLimit(23))
        assertEquals(244, BleGattBounds.payloadLimit(247))
        assertEquals(512, BleGattBounds.payloadLimit(517))
        assertEquals(20, BleGattBounds.payloadLimit(10))
    }

    @Test
    fun `write is split into exact bounded chunks`() {
        val data = ByteArray(45) { it.toByte() }
        val plan = BleGattBounds.planWrite(data, mtu = 23)
        assertEquals(3, plan.chunks.size)
        assertEquals(45, plan.totalBytes)
        assertEquals(20, plan.chunks[0].size)
        assertEquals(5, plan.chunks[2].size)
    }

    @Test
    fun `oversized write is refused not truncated`() {
        val error = assertThrows(DeviceCommunicationException::class.java) {
            BleGattBounds.planWrite(
                ByteArray(DeviceLimits.MAXIMUM_BLE_WRITE_TOTAL + 1),
                mtu = 247,
            )
        }
        assertEquals(DeviceErrorCode.INVALID_REQUEST, error.code)
    }

    @Test
    fun `generation fence invalidates old callbacks`() {
        val fence = GenerationFence()
        val first = fence.next()
        assertTrue(fence.isCurrent(first))
        val second = fence.next()
        assertFalse(fence.isCurrent(first))
        assertTrue(fence.isCurrent(second))
    }

    @Test
    fun `GATT uuid normalization accepts short and full forms`() {
        assertEquals(
            "0000180f-0000-1000-8000-00805f9b34fb",
            GattUuid.normalize("180f"),
        )
        assertEquals(
            "12345678-0000-1000-8000-00805f9b34fb",
            GattUuid.normalize("12345678"),
        )
        assertEquals(
            "12345678-1234-1234-1234-123456789abc",
            GattUuid.normalize("12345678-1234-1234-1234-123456789ABC"),
        )
        assertEquals(null, GattUuid.normalize("nope"))
    }

    @Test
    fun `MAC validation and Bluetooth address normalization`() {
        val address = DeviceEndpointSpec(
            protocol = DeviceProtocol.BLE,
            bleAddress = "aa:bb:cc:dd:ee:ff",
            bleServiceUuid = "180f",
            bleWriteUuid = "2a19",
        )
        val normalized = DeviceEndpointValidation.validateBle(address)
        assertEquals("AA:BB:CC:DD:EE:FF", normalized.bleAddress)
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", normalized.bleServiceUuid)
    }
}
