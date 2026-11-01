// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceSessionRegistryTest {
    private val ownerA = DeviceOwner("ui.a", 7)
    private val ownerB = DeviceOwner("tool.b", 7)

    @Test
    fun `session limit is enforced`() {
        val registry = DeviceSessionRegistry(maximumSessions = 2)
        registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1)
        registry.register(ownerA, DeviceProtocol.TELNET, "a:2", 2)
        val error = assertThrows(DeviceCommunicationException::class.java) {
            registry.register(ownerA, DeviceProtocol.USB, "usb", 3)
        }
        assertEquals(DeviceErrorCode.SESSION_LIMIT, error.code)
    }

    @Test
    fun `another owner cannot read a session`() {
        val registry = DeviceSessionRegistry()
        val record = registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1)
        val error = assertThrows(DeviceCommunicationException::class.java) {
            registry.require(record.id, ownerB, 7)
        }
        assertEquals(DeviceErrorCode.SESSION_NOT_FOUND, error.code)
    }

    @Test
    fun `stale epoch is refused`() {
        val registry = DeviceSessionRegistry()
        val record = registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1)
        val error = assertThrows(DeviceCommunicationException::class.java) {
            registry.require(record.id, ownerA, 8)
        }
        assertEquals(DeviceErrorCode.STALE_EPOCH, error.code)
    }

    @Test
    fun `list only returns the owner's sessions`() {
        val registry = DeviceSessionRegistry()
        val a = registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1)
        registry.register(ownerB, DeviceProtocol.BLE, "ble", 2)
        val listed = registry.list(ownerA, 7)
        assertEquals(1, listed.size)
        assertEquals(a.id, listed.first().id)
        assertNull(registry.find("missing"))
    }

    @Test
    fun `root stop selection uses the exact epoch`() {
        val registry = DeviceSessionRegistry()
        registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1)
        registry.register(DeviceOwner("ui.c", 9), DeviceProtocol.TCP, "c:1", 2)
        assertEquals(1, registry.forEpoch(7).size)
        assertEquals(1, registry.forEpoch(9).size)
        assertEquals(2, registry.all().size)
        assertNotNull(registry.remove(registry.forEpoch(7).first().id))
        assertTrue(registry.forEpoch(7).isEmpty())
    }

    @Test
    fun `idle selection is based on last activity`() {
        val registry = DeviceSessionRegistry()
        val record = registry.register(ownerA, DeviceProtocol.TCP, "a:1", 1_000)
        record.lastActivityMillis = 500
        assertEquals(1, registry.idleBefore(1_000).size)
        record.lastActivityMillis = 1_500
        assertEquals(0, registry.idleBefore(1_000).size)
    }
}
