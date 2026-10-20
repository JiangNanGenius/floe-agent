package com.floe.android

import com.floe.android.contracts.CredentialStore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * JVM source tests for the P4 dispatcher/capacity/ticket mechanics. They use a
 * scripted fake native facade and a gated fake CredentialStore; no Android
 * runtime, real Keystore, native library or device is touched. AUTHORED ONLY:
 * no Gradle/test execution is performed by the source package that produced
 * this file.
 */
class SecretGatewayDispatcherTest {
    private data class Completion(val claim: Long, val status: Int, val value: ByteArray?)

    private class FakeNative : SecretGatewayNativeApi {
        val claims = ConcurrentLinkedQueue<Long>()
        val described = ConcurrentHashMap<Long, String>()
        val payloads = ConcurrentHashMap<Long, ByteArray>()
        val nullPayloads = ConcurrentHashMap.newKeySet<Long>()
        val notLive = ConcurrentHashMap.newKeySet<Long>()
        val completions = CopyOnWriteArrayList<Completion>()
        val events = CopyOnWriteArrayList<String>()
        val removeCalls = AtomicInteger()
        val installCalls = AtomicInteger()
        val bindEpochs = CopyOnWriteArrayList<Long>()
        val awaitCalls = AtomicInteger()
        @Volatile var completeScript: ((Long, Int) -> Int?)? = null
        @Volatile var loaded = false

        /**
         * Deterministic gates for lifecycle interleaving. The waits swallow
         * interrupts: the fixture models real in-flight native work, which a
         * bounded join cannot dispose of.
         */
        @Volatile var awaitGate: CountDownLatch? = null
        @Volatile var bindGate: CountDownLatch? = null
        @Volatile var bindEntered: CountDownLatch? = null

        override fun ensureLoaded() {
            loaded = true
            events.add("load")
        }

        override fun bindSecretDispatcher(epoch: Long): Int {
            bindEpochs.add(epoch)
            events.add("bind:$epoch")
            val gate = bindGate
            if (gate != null) {
                bindEntered?.countDown()
                while (true) {
                    try {
                        gate.await()
                        break
                    } catch (ignored: InterruptedException) {
                        // Deliberately non-interruptible.
                    }
                }
            }
            return 0
        }

        override fun awaitSecretRequest(timeoutMillis: Int): Long {
            awaitCalls.incrementAndGet()
            val gate = awaitGate
            if (gate != null) {
                while (true) {
                    try {
                        gate.await()
                        break
                    } catch (ignored: InterruptedException) {
                        // Deliberately non-interruptible.
                    }
                }
                return 0L
            }
            val claim = claims.poll()
            if (claim != null) return claim
            Thread.sleep(minOf(timeoutMillis.toLong(), 2L))
            return 0L
        }

        override fun describeSecretRequest(claim: Long): String? = described[claim]

        override fun takeSecretPayload(claim: Long): ByteArray? =
            if (nullPayloads.contains(claim)) null else payloads[claim]

        override fun isSecretRequestLive(claim: Long): Boolean = !notLive.contains(claim)

        override fun completeSecretRequest(claim: Long, status: Int,
                                           value: ByteArray?): Int {
            completions.add(Completion(claim, status, value?.copyOf()))
            val scripted = completeScript?.invoke(claim, status)
            return scripted ?: 0
        }

        override fun secretMailboxStats(): String = "{}"

        override fun installSecretGateway(): Int {
            installCalls.incrementAndGet()
            events.add("install")
            return 0
        }

        override fun removeSecretGateway(): Int {
            removeCalls.incrementAndGet()
            events.add("remove")
            return 0
        }
    }

    private class FakeStore : CredentialStore {
        val writes = ConcurrentLinkedQueue<Pair<String, ByteArray>>()
        val reads = ConcurrentLinkedQueue<String>()
        val deletes = ConcurrentLinkedQueue<String>()
        val gates = ConcurrentHashMap<String, CountDownLatch>()
        val pendingWrites = ConcurrentHashMap<String, Continuation<Unit>>()
        val invocations = AtomicInteger()
        @Volatile var readResult: ByteArray? = null
        @Volatile var useNonCancellableWriteGate = false

        override suspend fun read(reference: String): ByteArray? {
            invocations.incrementAndGet()
            reads.add(reference)
            awaitGate(reference)
            return readResult?.copyOf()
        }

        override suspend fun write(reference: String, value: ByteArray) {
            invocations.incrementAndGet()
            writes.add(reference to value.copyOf())
            if (useNonCancellableWriteGate) {
                // Frozen AndroidKeystoreCredentialStore.dispatchIo uses a
                // non-cancellable suspendCoroutine. Model that exact behavior:
                // cancelling the Job does not complete this write.
                suspendCoroutine<Unit> { continuation ->
                    pendingWrites[reference] = continuation
                }
            } else {
                awaitGate(reference)
            }
        }

        fun completePendingWrite(reference: String) {
            pendingWrites.remove(reference)?.resume(Unit)
        }

        override suspend fun delete(reference: String) {
            invocations.incrementAndGet()
            deletes.add(reference)
            awaitGate(reference)
        }

        private suspend fun awaitGate(reference: String) {
            val latch = gates[reference] ?: return
            withContext(Dispatchers.IO) {
                latch.await(10, TimeUnit.SECONDS)
            }
        }
    }

    private val timings = DispatcherTimings(
        pollerJoinMillis = 500,
        drainChildrenMillis = 40,
        readyAckMillis = 1_000,
    )

    private fun newDispatcher(
        native: FakeNative,
        store: FakeStore,
        unlocked: Boolean = true,
        status: Boolean = true,
        timingsOverride: DispatcherTimings = timings,
        statusReaderOverride: (() -> Boolean)? = null,
    ): Pair<SecretGatewayDispatcher, CoroutineScope> {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val effectiveStatusReader = statusReaderOverride ?: { status }
        val dispatcher = SecretGatewayDispatcher(
            native = native,
            storeProvider = { store },
            unlockChecker = { unlocked },
            statusReader = effectiveStatusReader,
            scope = scope,
            ioDispatcher = Dispatchers.Default,
            timings = timingsOverride,
            diagnostics = {},
        )
        return dispatcher to scope
    }

    private fun reference(index: Int): String {
        val alphabet = "0123456789abcdef"
        return "ref:v1:" + alphabet[index % alphabet.length].toString().repeat(64)
    }

    private fun descriptor(op: String, reference: String): String =
        """{"op":"$op","reference":"$reference"}"""

    private fun enqueue(native: FakeNative, claim: Long, op: String, reference: String,
                        payload: ByteArray? = null) {
        native.claims.add(claim)
        native.described[claim] = descriptor(op, reference)
        if (payload == null) native.nullPayloads.add(claim) else native.payloads[claim] = payload
    }

    private fun waitUntil(timeoutMillis: Long = 3_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(5)
        }
        fail("condition not met before timeout")
    }

    private fun completion(native: FakeNative, claim: Long): Completion {
        waitUntil { native.completions.any { it.claim == claim } }
        return native.completions.first { it.claim == claim }
    }

    private fun waitIdle(dispatcher: SecretGatewayDispatcher) {
        waitUntil { dispatcher.snapshot().capacity.outstandingOps == 0 }
    }

    // MARK: Store operations / empty-vs-absent

    @Test
    fun testWriteReadDeleteAndEmptyVersusAbsent() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 1, "write", reference(1), byteArrayOf(0x01, 0x02, 0x03))
            assertNotNull(dispatcher.installGeneration(false))
            assertEquals(3, completion(native, 1).status)
            assertEquals(listOf(reference(1)), store.writes.map { it.first })
            waitIdle(dispatcher)

            store.readResult = null
            enqueue(native, 2, "read", reference(2))
            assertEquals(2, completion(native, 2).status)
            waitIdle(dispatcher)

            store.readResult = ByteArray(0)
            enqueue(native, 3, "read", reference(3))
            val empty = completion(native, 3)
            assertEquals(1, empty.status)
            assertNotNull(empty.value)
            assertEquals(0, empty.value!!.size)
            waitIdle(dispatcher)

            enqueue(native, 4, "delete", reference(4))
            assertEquals(4, completion(native, 4).status)
            assertEquals(listOf(reference(4)), store.deletes.toList())
            waitIdle(dispatcher)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    // MARK: Pre-submit branches / reservation tickets

    @Test
    fun testDeviceLockedPrecheckHasZeroStoreInvocations() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store, unlocked = false)
        try {
            enqueue(native, 11, "write", reference(1), byteArrayOf(0x01))
            assertNotNull(dispatcher.installGeneration(false))
            assertEquals(-9, completion(native, 11).status)
            assertEquals(0, store.invocations.get())
            waitIdle(dispatcher)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testTakeFailureAndNotLiveReleaseReservation() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 21, "write", reference(1), payload = null)
            enqueue(native, 22, "write", reference(2), byteArrayOf(0x01))
            native.notLive.add(22)
            assertNotNull(dispatcher.installGeneration(false))
            assertEquals(-14, completion(native, 21).status)
            assertEquals(-13, completion(native, 22).status)
            assertEquals("no store call on either branch", 0, store.invocations.get())
            waitIdle(dispatcher)
            assertEquals(0L, dispatcher.snapshot().capacity.outstandingBytes)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testReservationTicketExactOnceRelease() {
        val capacity = DispatcherCapacity()
        val ticket = capacity.reserve(generationId = 1, bytes = 128)
        assertNotNull(ticket)
        assertTrue(ticket!!.release())
        assertFalse(ticket.release())
        assertEquals(0, capacity.snapshot(0, 0).outstandingOps)
        assertEquals(0L, capacity.snapshot(0, 0).outstandingBytes)

        val oneOp = DispatcherCapacity(maxOps = 1, maxBytes = 16)
        val held = oneOp.reserve(1, 8)!!
        assertNull("op cap", oneOp.reserve(1, 1))
        held.release()
        assertNotNull(oneOp.reserve(1, 8))
        val bytesCap = DispatcherCapacity(maxOps = 4, maxBytes = 16)
        assertNull("byte cap", bytesCap.reserve(1, 17))
    }

    @Test
    fun testMalformedAndOverlongDescriptorsAbandonWithoutStoreCall() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 61, "read", reference(0))
            native.described[61] =
                "{\"op\":\"read\",\"reference\":\"ref:v1:${"a".repeat(65)}\"}"
            enqueue(native, 62, "read", reference(1))
            native.described[62] = "not-json"
            assertNotNull(dispatcher.installGeneration(false))
            assertEquals(-14, completion(native, 61).status)
            assertEquals(-14, completion(native, 62).status)
            assertEquals(0, store.invocations.get())
            waitIdle(dispatcher)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testMinusOneHundredFiveTriggersExactlyOneFallback() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        native.completeScript = { _, status -> if (status == -14) 0 else -105 }
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 31, "read", reference(1))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { native.completions.any { it.claim == 31L && it.status == -14 } }
            val statuses = native.completions.filter { it.claim == 31L }.map { it.status }
            assertEquals(listOf(2, -14), statuses)
            assertEquals(0, dispatcher.snapshot().generationFailures.toInt())
            waitIdle(dispatcher)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testThrowingFallbackIsGenerationFailure() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        native.completeScript = { _, status ->
            if (status == -14) throw IllegalStateException("fallback") else -105
        }
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 41, "read", reference(1))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { dispatcher.capability.value is SecretGatewayCapability.Failed }
            val failed = dispatcher.capability.value as SecretGatewayCapability.Failed
            assertEquals("generation_failure", failed.reason)
            waitUntil { native.removeCalls.get() > 0 }
            assertEquals(1L, dispatcher.snapshot().generationFailures)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    // MARK: Bootstrap cleanup invariant

    @Test
    fun testBootstrapInstallsThenReadbackFailureRemovesGateway() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store, status = false)
        try {
            dispatcher.bootstrapForTest()
            val failed = dispatcher.capability.value as SecretGatewayCapability.Failed
            assertEquals("readback_failed", failed.reason)
            assertEquals(1, native.installCalls.get())
            assertTrue(native.removeCalls.get() > 0)
            val bindIndex = native.events.indexOfFirst { it.startsWith("bind:") }
            val installIndex = native.events.indexOf("install")
            assertTrue(bindIndex >= 0 && installIndex > bindIndex)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testBootstrapReadyRequiresRealAwaitAckBeforeInstall() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val (dispatcher, scope) = newDispatcher(native, store, status = true)
        try {
            dispatcher.bootstrapForTest()
            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals(1, native.installCalls.get())
            assertTrue(native.awaitCalls.get() > 0)
            val bindIndex = native.events.indexOfFirst { it.startsWith("bind:") }
            val installIndex = native.events.indexOf("install")
            assertTrue(bindIndex >= 0 && installIndex > bindIndex)
        } finally {
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    // MARK: Quarantine / same-ref refcount / generation cap

    @Test
    fun testQuarantineRefusesOnlyTheAffectedReference() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val blocked = reference(1)
        val latch = CountDownLatch(1)
        store.gates[blocked] = latch
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 51, "write", blocked, byteArrayOf(0x01))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { store.writes.any { it.first == blocked } }
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil {
                dispatcher.snapshot().capacity.quarantinedRefs == 1 &&
                    dispatcher.snapshot().capacity.quarantinedJobs == 1
            }

            enqueue(native, 52, "write", blocked, byteArrayOf(0x02))
            assertEquals(-15, completion(native, 52).status)

            enqueue(native, 53, "write", reference(2), byteArrayOf(0x03))
            assertEquals(3, completion(native, 53).status)

            latch.countDown()
            waitUntil {
                dispatcher.snapshot().capacity.quarantinedJobs == 0 &&
                    dispatcher.snapshot().capacity.outstandingOps == 0
            }
        } finally {
            latch.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testSixteenSameReferenceJobsAreOneQuarantineEntry() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val blocked = reference(1)
        val latch = CountDownLatch(1)
        store.gates[blocked] = latch
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            for (index in 0 until 16) {
                enqueue(native, 100L + index, "write", blocked, byteArrayOf(0x01))
            }
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { store.writes.count { it.first == blocked } == 16 }
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil {
                val snapshot = dispatcher.snapshot().capacity
                snapshot.quarantinedRefs == 1 && snapshot.quarantinedJobs == 16 &&
                    snapshot.outstandingOps == 16
            }
            latch.countDown()
            waitUntil {
                val snapshot = dispatcher.snapshot().capacity
                snapshot.quarantinedRefs == 0 && snapshot.quarantinedJobs == 0 &&
                    snapshot.outstandingOps == 0
            }
        } finally {
            latch.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testRepeatedRebindsEnforceLiveGenerationCap() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val latches = mutableListOf<CountDownLatch>()
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            for (index in 0 until 3) {
                val ref = reference(index)
                val latch = CountDownLatch(1)
                latches.add(latch)
                store.gates[ref] = latch
                enqueue(native, 200L + index, "write", ref, byteArrayOf(0x01))
                assertNotNull(dispatcher.installGeneration(false))
                waitUntil { store.writes.any { it.first == ref } }
            }
            assertNull(dispatcher.installGeneration(false))
            val failed = dispatcher.capability.value as SecretGatewayCapability.Failed
            assertEquals("install_busy", failed.reason)
            assertEquals(3, native.bindEpochs.size)
            assertEquals(3, dispatcher.snapshot().capacity.liveGenerations)

            for (latch in latches) latch.countDown()
            waitUntil { dispatcher.snapshot().capacity.liveGenerations == 0 }
            assertNotNull(dispatcher.installGeneration(false))
        } finally {
            for (latch in latches) latch.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testHungIoKeepsReservationUntilRealJobEnd() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val blocked = reference(1)
        val latch = CountDownLatch(1)
        store.gates[blocked] = latch
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 301, "write", blocked, ByteArray(32))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { store.writes.any { it.first == blocked } }
            val first = dispatcher.snapshot().capacity
            assertEquals(1, first.outstandingOps)
            assertEquals(32L, first.outstandingBytes)
            delay(150)
            val second = dispatcher.snapshot().capacity
            assertEquals(1, second.outstandingOps)
            assertEquals(32L, second.outstandingBytes)
            assertEquals(0, dispatcher.snapshot().capacity.quarantinedJobs)

            latch.countDown()
            waitUntil { dispatcher.snapshot().capacity.outstandingOps == 0 }
        } finally {
            latch.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testCancelledBlockedIoRemainsQuarantinedUntilRealCompletion() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        store.useNonCancellableWriteGate = true
        val blocked = reference(1)
        val (dispatcher, scope) = newDispatcher(native, store)
        try {
            enqueue(native, 401, "write", blocked, ByteArray(32))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { dispatcher.trackedJobForTest(401) != null && store.pendingWrites.containsKey(blocked) }
            val job = dispatcher.trackedJobForTest(401)!!
            job.cancel()
            waitUntil { !job.isActive && !job.isCompleted }

            // isActive is false, but the real non-cancellable store I/O is not
            // complete: replacement must still drain/quarantine this child.
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { dispatcher.snapshot().capacity.quarantinedJobs == 1 }
            assertEquals(1, dispatcher.snapshot().capacity.outstandingOps)
            assertEquals(32L, dispatcher.snapshot().capacity.outstandingBytes)

            enqueue(native, 402, "write", blocked, byteArrayOf(0x02))
            assertEquals(-15, completion(native, 402).status)

            store.completePendingWrite(blocked)
            waitUntil {
                dispatcher.snapshot().capacity.quarantinedJobs == 0 &&
                    dispatcher.snapshot().capacity.outstandingOps == 0
            }
        } finally {
            store.completePendingWrite(blocked)
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    @Test
    fun testDelayedOldFailureCleanupCannotRemoveReplacementGeneration() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        native.completeScript = { claim, status ->
            if (claim == 70L && status == 2) throw IllegalStateException("complete") else null
        }
        val hooks = FailureCleanupHooks()
        val (dispatcher, scope) = newDispatcher(native, store, status = true)
        dispatcher.failureCleanupHooksForTest = hooks
        try {
            enqueue(native, 70, "read", reference(0))
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil { dispatcher.capability.value is SecretGatewayCapability.Failed }
            withTimeout(5_000) { hooks.reached.await() }

            // Replacement is serialized while the old cleanup is paused
            // outside the install lock.
            dispatcher.bootstrapForTest()
            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals(1, native.installCalls.get())
            hooks.release.complete(Unit)
            withTimeout(5_000) { hooks.finished.await() }

            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals("delayed old cleanup must not remove the replacement gateway",
                0, native.removeCalls.get())

            enqueue(native, 71, "write", reference(1), byteArrayOf(0x01))
            assertEquals(3, completion(native, 71).status)
            waitIdle(dispatcher)
        } finally {
            dispatcher.failureCleanupHooksForTest = null
            hooks.release.complete(Unit)
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    // MARK: GWS3B lifecycle ownership gates

    /**
     * GWS3B-1: the exact bootstrap attempt must survive the await. Old A's
     * readback fails after B is installed and Ready; A may only clean its own
     * identity, so B's registry and capability stay authoritative.
     */
    @Test
    fun testOldReadbackFailureAfterNewerReadyKeepsNewGeneration() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val firstReadbackEntered = CountDownLatch(1)
        val releaseFirstReadback = CountDownLatch(1)
        val readbacks = AtomicInteger()
        val (dispatcher, scope) = newDispatcher(native, store, statusReaderOverride = {
            if (readbacks.incrementAndGet() == 1) {
                firstReadbackEntered.countDown()
                while (true) {
                    try {
                        releaseFirstReadback.await()
                        break
                    } catch (ignored: InterruptedException) {
                        // Deliberately non-interruptible fixture await.
                    }
                }
                false
            } else {
                true
            }
        })
        val oldBootstrap = launch(Dispatchers.IO) { dispatcher.bootstrapForTest() }
        try {
            assertTrue("old bootstrap did not reach readback",
                firstReadbackEntered.await(10, TimeUnit.SECONDS))
            assertEquals(1, native.installCalls.get())
            assertEquals(listOf(1L), native.bindEpochs.toList())

            // A newer bootstrap replaces A and reaches Ready while A's
            // readback is still paused.
            dispatcher.bootstrapForTest()
            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals(2, native.installCalls.get())
            assertEquals(listOf(1L, 2L), native.bindEpochs.toList())

            // Old A now fails its readback. Its cleanup must not re-capture
            // currentGeneration and tear down B.
            releaseFirstReadback.countDown()
            oldBootstrap.join()
            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals(2, native.installCalls.get())
            assertEquals(listOf(1L, 2L), native.bindEpochs.toList())
            assertEquals("old readback cleanup must not remove the newer gateway",
                0, native.removeCalls.get())

            // B's poller remains authoritative for real work.
            enqueue(native, 601, "write", reference(3), byteArrayOf(0x01))
            assertEquals(3, completion(native, 601).status)
            waitIdle(dispatcher)
        } finally {
            releaseFirstReadback.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    /**
     * GWS3B-2: a non-interruptible await outlives the bounded join. The real
     * non-joined poller is retained/fenced; no later bind may occur until the
     * old thread is explicitly released and actually joined.
     */
    @Test
    fun testJoinTimeoutFencesBindUntilPollerActuallyJoined() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val awaitGate = CountDownLatch(1)
        native.awaitGate = awaitGate
        val shortTimings = DispatcherTimings(
            pollerJoinMillis = 150,
            drainChildrenMillis = 40,
            readyAckMillis = 200,
        )
        val (dispatcher, scope) = newDispatcher(native, store,
            timingsOverride = shortTimings)
        try {
            assertNull(dispatcher.installGeneration(false))
            assertEquals(1, native.bindEpochs.size)
            assertEquals("ready_timeout",
                (dispatcher.capability.value as SecretGatewayCapability.Failed).reason)

            // The old poller is still blocked. Rebind attempts may publish a
            // timeout but must never reach native bind.
            assertNull(dispatcher.installGeneration(false))
            assertEquals("poller_join_timeout",
                (dispatcher.capability.value as SecretGatewayCapability.Failed).reason)
            assertNull(dispatcher.installGeneration(false))
            val bindEpochsWhileFenced = native.bindEpochs.toList()
            assertEquals(1, bindEpochsWhileFenced.size)

            // Explicitly release the real await; only an actual join may
            // unblock the next bind. Remove the global fake gate so the new
            // poller can claim real queued work after the join.
            awaitGate.countDown()
            native.awaitGate = null
            var installed: SecretGatewayDispatcher.Generation? = null
            val deadline = System.currentTimeMillis() + 5_000
            while (installed == null && System.currentTimeMillis() < deadline) {
                installed = dispatcher.installGeneration(false)
                if (installed == null) delay(20)
            }
            assertNotNull("poller was not joined in bounded retries", installed)
            assertEquals(2, native.bindEpochs.size)
            assertEquals(bindEpochsWhileFenced, native.bindEpochs.take(1))
            assertTrue("replacement bind must use a strictly newer epoch",
                native.bindEpochs[1] > native.bindEpochs[0])

            enqueue(native, 701, "write", reference(4), byteArrayOf(0x02))
            assertEquals(3, completion(native, 701).status)
            waitIdle(dispatcher)
        } finally {
            awaitGate.countDown()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }

    /**
     * GWS3B-3: a late old-child completion failure while the replacement bind
     * is paused. Failure belongs to old A, so it may not mark B failed or
     * suppress B's legitimate Ready publication.
     */
    @Test
    fun testLateOldChildFailureDuringReplacementBindPreservesNewReady() = runBlocking {
        val native = FakeNative()
        val store = FakeStore()
        val blocked = reference(5)
        val oldChildGate = CountDownLatch(1)
        val bindGate = CountDownLatch(1)
        val bindEntered = CountDownLatch(1)
        store.gates[blocked] = oldChildGate
        native.completeScript = { claim, status ->
            if (claim == 901L && status == 2) {
                throw IllegalStateException("late-old-child-completion")
            }
            null
        }
        val (dispatcher, scope) = newDispatcher(native, store,
            timingsOverride = DispatcherTimings(
                pollerJoinMillis = 500,
                drainChildrenMillis = 40,
                readyAckMillis = 1_000,
            ))
        var replacement: Job? = null
        try {
            enqueue(native, 901, "read", blocked)
            assertNotNull(dispatcher.installGeneration(false))
            waitUntil(5_000) { store.reads.any { it == blocked } }

            // Arm the irreversible bind gate only for the replacement bind
            // (epoch 2); old A's bind already completed above.
            native.bindGate = bindGate
            native.bindEntered = bindEntered
            replacement = launch(Dispatchers.Default) { dispatcher.bootstrapForTest() }

            // Replacement stops A, quarantines the still-blocked child and
            // pauses inside the new native bind.
            assertTrue("replacement did not reach bind",
                bindEntered.await(10, TimeUnit.SECONDS))

            // Old A's child now settles and its completion throws while B is
            // still installing. The failure must be stale, not B's.
            oldChildGate.countDown()
            waitUntil(5_000) { dispatcher.snapshot().generationFailures >= 1L }
            assertEquals("old failure must not publish Failed for the replacement",
                SecretGatewayCapability.Loading, dispatcher.capability.value)

            bindGate.countDown()
            replacement?.join()
            assertEquals(SecretGatewayCapability.Ready, dispatcher.capability.value)
            assertEquals(listOf(1L, 2L), native.bindEpochs.toList())
            assertEquals(1, native.installCalls.get())
            assertEquals(0, native.removeCalls.get())

            enqueue(native, 902, "write", reference(6), byteArrayOf(0x03))
            assertEquals(3, completion(native, 902).status)
            waitIdle(dispatcher)
        } finally {
            oldChildGate.countDown()
            bindGate.countDown()
            native.bindGate = null
            native.bindEntered = null
            replacement?.join()
            dispatcher.shutdownForTest()
            scope.cancel()
        }
    }
}
