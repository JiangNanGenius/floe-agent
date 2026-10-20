// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TemporarySessionRef
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN. MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION_20261019 controlled
 * epoch separation: the wire acknowledgement epoch is the ACTUAL trusted
 * native root generation (31 in the controlled fixtures), NEVER the UI
 * holder counter (9). A stale root generation (30) or a stale UI epoch (8)
 * alone can never admit. Mirrors the real temp.start binding: the ref
 * carries both epochs and only the native one certifies the fence.
 */
class HostTempFenceNativeEpochTest {

    private class FenceExchange : HostBridgeExchange {
        @Volatile var ackFor: ((String) -> String?)? = null
        val submitCount = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile var lastSubmittedCorrelation: String? = null
        private val receiptToCorrelation = ConcurrentHashMap<String, String>()

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    val target = receiptToCorrelation[receipt]
                    val ack = target?.let { ackFor?.invoke(it) }
                    if (target == null || ack == null) {
                        emptyPage(correlation, receipt)
                    } else {
                        valueWithAck(correlation, receipt, ack)
                    }
                }
                request.contains("\"command\":\"temp.end\"") -> {
                    submitCount.incrementAndGet()
                    lastSubmittedCorrelation = correlation
                    val receipt = "op:v1:$correlation"
                    receiptToCorrelation[receipt] = correlation
                    queued(correlation, receipt)
                }
                else -> queued(correlation, "op:v1:other")
            }
        }

        private fun queued(correlation: String, receipt: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""

        private fun emptyPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""

        private fun valueWithAck(correlation: String, receipt: String, ack: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},"effects":[{"sequence":1,"kind":"prepared","value":$ack},{"sequence":2,"kind":"accepted","value":{"session":"ended"}}],"hasMore":false,"resyncRequired":false}"""
    }

    private fun testHost(exchange: HostBridgeExchange): RuntimeHost = RuntimeHost(
        commandClient = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        ),
        gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
            com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
            com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private fun ack(ref: TemporarySessionRef, correlation: String): String =
        """{"navigationFence":{"admitted":true,"conversationID":"${ref.conversationId}","incarnationID":"${ref.incarnationId}","requestCorrelationID":"$correlation","epoch":${ref.nativeRootEpoch}}}"""

    /** Bounded await for the ASYNC temp.end submission (the fence submits on
     *  the host scope; a bare read right after beginEnd races it). */
    private suspend fun awaitSubmission(exchange: FenceExchange,
                                        timeoutMillis: Long = 2_000) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (exchange.lastSubmittedCorrelation != null) return
            delay(5)
        }
        error("temp.end not submitted")
    }

    private suspend fun awaitAdmission(
        fence: TemporaryNavigationFence,
        ref: TemporarySessionRef,
        timeoutMillis: Long = 400,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (fence.awaitAdmission(ref, 60)) return true
        }
        return false
    }

    @Test
    fun nativeRootEpochAdmitsWhileUiCounterDiffers() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        // Controlled split: native root generation 31, UI holder epoch 9.
        val ref = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 31)
        val admitted = CopyOnWriteArrayList<TemporarySessionRef>()
        val fence = TemporaryNavigationFence(host, activeRefProvider = { ref },
            onAdmitted = { admitted.add(it) })

        // The ack provider is installed BEFORE the asynchronous submit so a
        // fast effect poll can never miss it.
        exchange.ackFor = { ack(ref, it) }
        assertTrue(fence.beginEnd(ref))
        awaitSubmission(exchange)
        val ok = awaitAdmission(fence, ref)
        println("DIAG admitted=$ok state=${fence.state.value} submits=${exchange.submitCount.get()} corr=${exchange.lastSubmittedCorrelation}")
        assertTrue(ok)
        assertTrue(admitted.any { it.nativeRootEpoch == 31L && it.sessionEpoch == 9L })
    }

    @Test
    fun staleRootGenerationThirtyNeverAdmits() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        // The LIVE ref is root generation 31; a stale coordinator presents 30.
        val ref = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 31)
        val stale = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 30)
        val fence = TemporaryNavigationFence(host, activeRefProvider = { ref })
        exchange.ackFor = { ack(stale, it) }
        assertTrue(fence.beginEnd(ref))
        awaitSubmission(exchange)
        assertFalse(awaitAdmission(fence, ref))
    }

    @Test
    fun staleUiHolderEpochEightAloneNeverAdmits() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        // ORIGINAL epoch-only intent, preserved: the SAME conversation,
        // incarnation and native root generation; ONLY the UI holder epoch
        // differs (8 = superseded holder, 9 = current holder).
        val staleHolder = TemporarySessionRef("t31", 8, "inc-31", nativeRootEpoch = 31)
        val currentHolder = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 31)
        var currentRef: TemporarySessionRef = staleHolder
        val fence = TemporaryNavigationFence(host, activeRefProvider = { currentRef })
        // Controlled ordering (no sleeps): no ack is released while the
        // stale holder's begin is submitted.
        exchange.ackFor = null
        assertTrue(fence.beginEnd(staleHolder))
        awaitSubmission(exchange)
        // The UI holder advances (only its sessionEpoch). The stale holder's
        // later begin is REFUSED against the live owner ...
        currentRef = currentHolder
        assertFalse(fence.beginEnd(staleHolder))
        // ... and the BYTE-VALID acknowledgement for the pending stale
        // holder (same native epoch + ids + correlation) must never admit it.
        exchange.ackFor = { ack(staleHolder, it) }
        assertFalse(awaitAdmission(fence, staleHolder))
        assertFalse(awaitAdmission(fence, currentHolder))
    }

    @Test
    fun staleIncarnationAloneNeverAdmits() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        // EXTRA case (never a substitute for the epoch-only intent above):
        // same conversation/UI epoch/native root, a DIFFERENT incarnation is
        // a different session surface and must not admit.
        val ref = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 31)
        val otherIncarnation = TemporarySessionRef("t31", 9, "inc-30", nativeRootEpoch = 31)
        val fence = TemporaryNavigationFence(host, activeRefProvider = { ref })
        exchange.ackFor = { ack(otherIncarnation, it) }
        assertTrue(fence.beginEnd(ref))
        awaitSubmission(exchange)
        assertFalse(awaitAdmission(fence, ref))
        assertFalse(awaitAdmission(fence, otherIncarnation))
    }

    @Test
    fun unboundNativeRootEpochFailsClosedAtBeginEnd() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        // A ref constructed without a trusted native readback (-1) can never
        // begin: no fabricated 0 and no UI-counter echo can certify it.
        val unbound = TemporarySessionRef("t-unbound", 9, "inc-unbound")
        val fence = TemporaryNavigationFence(host, activeRefProvider = { unbound })
        assertFalse(fence.beginEnd(unbound))
    }

    @Test
    fun navigationFenceAckCarriesNativeRootEpochThirtyOne() = runBlocking {
        // The exact tuple the temp.start binding produced: the ack JSON
        // echoes 31 while the holder counter stays 9 — the value.decode
        // path must route it to the fence, not to a generic terminal.
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val ref = TemporarySessionRef("t31", 9, "inc-31", nativeRootEpoch = 31)
        val fence = TemporaryNavigationFence(host, activeRefProvider = { ref })
        exchange.ackFor = { ack(ref, it) }
        assertTrue(fence.beginEnd(ref))
        awaitSubmission(exchange)
        val admitted = fence.awaitAdmission(ref, 1_000)
        assertTrue(admitted)
        val state = fence.state.value
        assertTrue(state is TemporaryNavigationFence.State.Admitted)
        val admittedAck = (state as TemporaryNavigationFence.State.Admitted).acknowledgement
        assertEquals(31L, admittedAck.epoch)
    }
}
