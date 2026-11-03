// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CaptureDrainRegistryTest {
    private fun id(): String = UUID.randomUUID().toString()

    @Test
    fun vpnTimeoutKeepsEveryRealOwnerOutstanding() {
        val registry = CaptureDrainRegistry(now = { 10L })
        val session = id()
        registry.register(session, CaptureMode.VPN)
        registry.update(session) {
            it.copy(
                stopRequested = true,
                dataPlaneThreadStopped = true,
                forwardersStopped = true,
                vpnFdClosed = true,
                sinkDrained = false,
                sinkWriterJoined = false,
                vpnServiceStopped = true,
            )
        }
        assertFalse(registry.isSettled(session))
        assertEquals(
            listOf("sinkDrained", "sinkWriterJoined"),
            registry.snapshot(session)!!.outstanding(),
        )
        assertEquals(1, registry.outstanding().size)
        try {
            registry.complete(session)
            fail("an unproven entry must not disappear")
        } catch (_: IllegalStateException) {
            // expected: RootStop stays blocked
        }
        assertNull(registry.snapshot(id()))
    }

    @Test
    fun lateWriterJoinSettlesTheSameEntry() {
        val registry = CaptureDrainRegistry(now = { 10L })
        val session = id()
        registry.register(session, CaptureMode.VPN)
        registry.update(session) {
            it.copy(
                stopRequested = true,
                dataPlaneThreadStopped = true,
                forwardersStopped = true,
                vpnFdClosed = true,
                sinkDrained = false,
                sinkWriterJoined = false,
                vpnServiceStopped = true,
            )
        }
        registry.update(session) { it.copy(sinkDrained = true, sinkWriterJoined = true) }
        assertTrue(registry.isSettled(session))
        assertFalse(registry.hasOutstanding())
        registry.complete(session)
        assertNull(registry.snapshot(session))
    }

    @Test
    fun rootNeedsProcessFileAndStartJoinNotJustTerminalState() {
        val registry = CaptureDrainRegistry(now = { 10L })
        val session = id()
        registry.register(session, CaptureMode.ROOT)
        registry.update(session) {
            it.copy(stopRequested = true, rootProcessExited = true)
        }
        assertFalse(registry.isSettled(session))
        assertEquals(
            listOf("rootStartJobJoined", "rootFileOwnerClosed", "rootDrainProven"),
            registry.snapshot(session)!!.outstanding(),
        )
        registry.update(session) {
            it.copy(
                rootStartJobJoined = true,
                rootFileOwnerClosed = true,
                rootDrainProven = true,
            )
        }
        assertTrue(registry.isSettled(session))
    }

    @Test
    fun finalizeRemovesOnlyAfterEveryResourceSettled() {
        val registry = CaptureDrainRegistry(now = { 42L })
        val session = id()
        registry.register(session, CaptureMode.VPN)
        assertFalse(registry.completeAfterFinalize(session))
        assertEquals(42L, registry.snapshot(session)!!.finalizedAtMillis)
        assertEquals(1, registry.outstanding().size)
        registry.update(session) {
            it.copy(
                stopRequested = true,
                dataPlaneThreadStopped = true,
                forwardersStopped = true,
                vpnFdClosed = true,
                sinkDrained = true,
                sinkWriterJoined = true,
                vpnServiceStopped = true,
            )
        }
        assertTrue(registry.completeAfterFinalize(session))
        assertNull(registry.snapshot(session))
        assertTrue(registry.isSettled(session))
        // A repeated late finalize is idempotent and never recreates an owner.
        assertTrue(registry.completeAfterFinalize(session))
        assertFalse(registry.hasOutstanding())
    }

    @Test
    fun finalizeOfAnUnprovenRootSessionKeepsItOutstanding() {
        val registry = CaptureDrainRegistry(now = { 7L })
        val session = id()
        registry.register(session, CaptureMode.ROOT)
        registry.update(session) {
            it.copy(stopRequested = true, rootStartJobJoined = true, rootProcessExited = true)
        }
        assertFalse(registry.completeAfterFinalize(session))
        assertEquals(
            listOf("rootFileOwnerClosed", "rootDrainProven"),
            registry.snapshot(session)!!.outstanding(),
        )
        assertFalse(registry.isSettled(session))
    }
}
