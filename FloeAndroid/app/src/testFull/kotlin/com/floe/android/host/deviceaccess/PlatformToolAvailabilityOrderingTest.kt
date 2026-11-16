// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformToolAvailabilityOrderingTest {
    private class Transport : PlatformToolsTransport {
        val writes = Collections.synchronizedList(mutableListOf<String>())
        val blockNext = AtomicBoolean(false)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val emptyWritten = CountDownLatch(1)
        override fun bind(epoch: Long, catalog: ByteArray) = 0
        override fun setAvailability(epoch: Long, namesJson: ByteArray): Int {
            if (blockNext.compareAndSet(true, false)) {
                entered.countDown()
                check(release.await(3, TimeUnit.SECONDS))
            }
            val names = namesJson.toString(Charsets.UTF_8)
            writes.add(names)
            if (names == "[]") emptyWritten.countDown()
            return 0
        }
        override fun next(timeoutMillis: Int): Long { Thread.sleep(5); return 0 }
        override fun describe(claim: Long): ByteArray? = null
        override fun payload(claim: Long): ByteArray? = null
        override fun isLive(claim: Long) = 0
        override fun shouldStop(claim: Long) = 1
        override fun complete(claim: Long, status: Int, value: ByteArray) = 0
        override fun close(epoch: Long) = 0
        override fun artifactRootPath(): String? = null
    }

    private fun pump(scope: CoroutineScope, transport: Transport, availability: () -> Set<String>) =
        PlatformToolHostPump(scope, Dispatchers.IO, { 1L }, { PlatformToolOutcome.Failure("unused") },
            availability, {}, catalog = byteArrayOf(), transport = transport)

    @Test fun olderCalculationCannotOverwriteNewerAvailability() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = Transport()
        val state = AtomicReference(setOf(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS))
        val blockRead = AtomicBoolean(false)
        val firstRead = CountDownLatch(1)
        val releaseRead = CountDownLatch(1)
        val secondRead = CountDownLatch(1)
        val target = pump(scope, transport) {
            val snapshot = state.get()
            if (blockRead.compareAndSet(true, false)) {
                firstRead.countDown()
                check(releaseRead.await(3, TimeUnit.SECONDS))
            } else if (firstRead.count == 0L) secondRead.countDown()
            snapshot
        }
        assertTrue(target.start(1L))
        val a = Thread { target.publishAvailability() }
        val b = Thread { target.publishAvailability() }
        try {
            blockRead.set(true)
            a.start()
            assertTrue(firstRead.await(3, TimeUnit.SECONDS))
            state.set(setOf(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS, DeviceAccessToolCatalog.DEVICE_OBSERVE))
            b.start()
            // A owns the serialization boundary until its snapshot publishes.
            assertFalse(secondRead.await(200, TimeUnit.MILLISECONDS))
            releaseRead.countDown()
            a.join(3_000); b.join(3_000)
            assertFalse(a.isAlive); assertFalse(b.isAlive)
            assertTrue(transport.writes.last().contains("device.observe"))
        } finally {
            releaseRead.countDown()
            target.stopAndJoin()
            scope.cancel()
        }
    }

    @Test fun stopCannotBeFollowedByAnOlderAvailabilityPublication() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = Transport()
        val state = AtomicReference(setOf(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS))
        val target = pump(scope, transport) { state.get() }
        assertTrue(target.start(1L))
        state.set(setOf(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS, DeviceAccessToolCatalog.DEVICE_OBSERVE))
        transport.blockNext.set(true)
        val publishing = Thread { target.publishAvailability() }
        val stopping = Thread { runBlocking { target.stopAndJoin() } }
        try {
            publishing.start()
            assertTrue(transport.entered.await(3, TimeUnit.SECONDS))
            stopping.start()
            assertFalse(transport.emptyWritten.await(200, TimeUnit.MILLISECONDS))
            transport.release.countDown()
            publishing.join(3_000); stopping.join(3_000)
            assertFalse(publishing.isAlive); assertFalse(stopping.isAlive)
            assertEquals("[]", transport.writes.last())
        } finally {
            transport.release.countDown()
            if (target.boundEpoch != 0L) target.stopAndJoin()
            scope.cancel()
        }
    }
}
