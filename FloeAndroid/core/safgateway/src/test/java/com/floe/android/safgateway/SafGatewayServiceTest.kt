// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Service-owned IO context, typed cancellation and shutdown semantics. */
class SafGatewayServiceTest {

    private fun acceptedTreeService(): Pair<SafGatewayService, FakeSafBackend> {
        val fake = FakeSafBackend()
        val tree = fake.treeUri()
        fake.seedRoot(tree)
        val service = SafGatewayService(fake.backend)
        fake.session[tree.uriString] = setOf(SafAccessFlag.READ)
        val accept = service.grants.acceptPickResult(
            service.grants.pickerForTree(),
            tree.uriString,
            SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.PERSISTABLE,
        )
        assertTrue(accept is PickAcceptResult.Accepted)
        return service to fake
    }

    @Test
    fun submitRunsOffCallerThreadAndAwaitReturnsOutcome() {
        val (service, fake) = acceptedTreeService()
        val tree = fake.treeUri()
        val doc = fake.seedDoc(tree, "a.txt", content = "service".toByteArray())
        val op = service.submit { cancel ->
            service.operations.readBounded(fake.refOf(tree, doc), 4096, null, cancel)
        }
        val outcome = op.await(5_000)
        assertTrue(outcome is SafOutcome.Success)
        assertEquals("service", String((outcome as SafOutcome.Success).value))
        service.close()
    }

    @Test
    fun cancelStopsAnOngoingStreamPass() {
        val (service, fake) = acceptedTreeService()
        val tree = fake.treeUri()
        val doc = fake.seedDoc(tree, "big.bin", content = ByteArray(5 * 1024 * 1024))
        val enteredRead = CountDownLatch(1)
        val releaseRead = CountDownLatch(1)
        fake.onNthRead = { count ->
            if (count == 1) {
                enteredRead.countDown()
                check(releaseRead.await(5, TimeUnit.SECONDS))
            }
        }
        val op = service.submit { cancel ->
            service.operations.streamRead(fake.refOf(tree, doc), byteLimit = null, typedAcceptMime = null, cancel) { _, _ -> }
        }
        try {
            assertTrue(enteredRead.await(2, TimeUnit.SECONDS))
            assertTrue(op.cancel())
            assertTrue(!op.isDone)
            assertEquals(1, service.pendingOperationCount)
            assertTrue(!service.awaitIdle(1))
            releaseRead.countDown()
            val outcome = op.await(5_000)
            val cancelled = outcome is SafOutcome.Failure && outcome.failure is SafFailure.Cancelled
            assertTrue("expected a cancelled outcome, got $outcome", cancelled)
            assertTrue(op.isDone)
            assertTrue(service.awaitIdle(2_000))
        } finally {
            releaseRead.countDown(); service.close()
        }
    }

    @Test
    fun closeReleasesCursorsAndRefusesNewWork() {
        val (service, fake) = acceptedTreeService()
        var sawCursorRelease = false
        val backendWrapper = object : SafPlatformBackend by fake.backend {
            override fun releaseAllCursors() {
                sawCursorRelease = true
                fake.backend.releaseAllCursors()
            }
        }
        val service2 = SafGatewayService(backendWrapper)
        service2.close()
        assertTrue(sawCursorRelease)
        assertThrows(IllegalStateException::class.java) {
            service2.submit { SafOutcome.success(Unit) }
        }
        service.close()
    }

    @Test
    fun closeKeepsBlockedIOOwnedAndDefersResourceCleanupUntilActualSettlement() {
        val fake = FakeSafBackend()
        val cleanup = java.util.concurrent.atomic.AtomicBoolean(false)
        val backend = object : SafPlatformBackend by fake.backend {
            override fun releaseAllCursors() { cleanup.set(true) }
        }
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        val service = SafGatewayService(backend, ioExecutor = executor)
        val entered = CountDownLatch(1); val finish = CountDownLatch(1)
        val op = service.submit<Unit> { token ->
            entered.countDown()
            check(finish.await(5, TimeUnit.SECONDS))
            if (token.isCancelled) SafOutcome.failure(SafFailure.Cancelled) else SafOutcome.success(Unit)
        }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            service.close()
            assertTrue(service.isClosed)
            assertEquals(1, service.pendingOperationCount)
            assertTrue(!op.isDone && !service.isDrained && !cleanup.get())
            finish.countDown()
            assertTrue(op.await(5_000) is SafOutcome.Failure)
            assertTrue(service.awaitIdle(2_000))
            assertTrue(cleanup.get() && service.isDrained)
        } finally {
            finish.countDown(); service.close(); executor.shutdown()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun persistedGrantsSurviveServiceClose() {
        val (service, fake) = acceptedTreeService()
        val tree = fake.treeUri()
        val before = fake.persisted[tree.uriString]?.toSet()
        service.close()
        assertEquals(before, fake.persisted[tree.uriString]?.toSet())
        // close never calls platform release.
        assertTrue(fake.releaseLog.isEmpty())
    }
}
