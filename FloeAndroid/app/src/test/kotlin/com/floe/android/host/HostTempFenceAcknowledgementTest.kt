// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TemporarySessionRef
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN. Exact TMP-NAV-2 acknowledgement ordering: value-only
 * carrier, whole-tuple equality, superseding fences and stale callbacks.
 */
class HostTempFenceAcknowledgementTest {

    private class FenceExchange : HostBridgeExchange {
        var ackFor: ((String) -> String?)? = null
        var ackInPage = false
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
                    } else if (ackInPage) {
                        pageWithAck(correlation, receipt, ack, page = true)
                    } else {
                        pageWithAck(correlation, receipt, ack, page = false)
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

        private fun pageWithAck(correlation: String, receipt: String, ack: String, page: Boolean): String {
            val carrier = if (page) "page" else "value"
            return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},"effects":[{"sequence":1,"kind":"prepared","$carrier":$ack},{"sequence":2,"kind":"accepted","value":{"session":"ended"}}],"hasMore":false,"resyncRequired":false}"""
        }
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

    private fun ack(
        ref: TemporarySessionRef,
        correlation: String,
        admitted: Boolean = true,
        reason: String? = null,
        extra: String? = null,
    ): String {
        val reasonSuffix = if (reason == null) "" else ",\"reason\":\"$reason\""
        val extraSuffix = if (extra == null) "" else extra
        return """{"navigationFence":{"admitted":$admitted,"conversationID":"${ref.conversationId}","incarnationID":"${ref.incarnationId}","requestCorrelationID":"$correlation","epoch":${ref.nativeRootEpoch}$reasonSuffix$extraSuffix}}"""
    }

    private suspend fun admit(
        fence: TemporaryNavigationFence,
        ref: TemporarySessionRef,
        timeoutMillis: Long = 600,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (fence.awaitAdmission(ref, 80)) return true
        }
        return false
    }

    private suspend fun awaitSubmit(
        exchange: FenceExchange,
        previousCount: Int = 0,
    ): String {
        val deadline = System.nanoTime() + 1_000_000_000L
        while (exchange.submitCount.get() <= previousCount && System.nanoTime() < deadline) {
            delay(5)
        }
        return exchange.lastSubmittedCorrelation ?: error("temp.end was not submitted")
    }

    @Test
    fun rapidDoubleNavigationSupersedesTheOldRequest() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val refA = TemporarySessionRef("ta", 3, "inc-a", nativeRootEpoch = 3L)
        val refB = TemporarySessionRef("tb", 4, "inc-b", nativeRootEpoch = 4L)
        var active: TemporarySessionRef? = refA
        val admitted = CopyOnWriteArrayList<TemporarySessionRef>()
        val fence = TemporaryNavigationFence(
            host = host,
            activeRefProvider = { active },
            onAdmitted = { admitted += it },
        )
        fence.beginEnd(refA)
        awaitSubmit(exchange)
        delay(30)
        active = refB
        val beforeB = exchange.submitCount.get()
        fence.beginEnd(refB)
        val correlationB = awaitSubmit(exchange, beforeB)
        exchange.ackFor = { correlation ->
            if (correlation == correlationB) ack(refB, correlation) else null
        }
        assertTrue(admit(fence, refB))
        assertFalse(fence.awaitAdmission(refA, timeoutMillis = 80))
        val state = fence.state.value
        assertTrue(state is TemporaryNavigationFence.State.Admitted)
        assertEquals(refB, (state as TemporaryNavigationFence.State.Admitted).ref)
        assertEquals(listOf(refB), admitted)
        fence.reset()
    }

    @Test
    fun lateOldAcknowledgementCannotMutateTheAdmittedLaterFence() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val refA = TemporarySessionRef("ta", 5, "inc-a", nativeRootEpoch = 5L)
        val refB = TemporarySessionRef("tb", 6, "inc-b", nativeRootEpoch = 6L)
        var active: TemporarySessionRef? = refA
        val admitted = CopyOnWriteArrayList<TemporarySessionRef>()
        val fence = TemporaryNavigationFence(
            host = host,
            activeRefProvider = { active },
            onAdmitted = { admitted += it },
        )
        fence.beginEnd(refA)
        val correlationA = awaitSubmit(exchange)
        // A's first page is a generic progress frame; no admission.
        delay(30)
        active = refB
        val beforeB = exchange.submitCount.get()
        fence.beginEnd(refB)
        val correlationB = awaitSubmit(exchange, beforeB)
        exchange.ackFor = { correlation ->
            if (correlation == correlationB) ack(refB, correlation) else null
        }
        assertTrue(admit(fence, refB))
        // A late A acknowledgement is offered by the scripted transport, but
        // A's pump was closed by the superseding fence. State stays B.
        exchange.ackFor = { correlation ->
            if (correlation == correlationA) ack(refA, correlation) else ack(refB, correlation)
        }
        delay(60)
        val state = fence.state.value
        assertTrue(state is TemporaryNavigationFence.State.Admitted)
        assertEquals(refB, (state as TemporaryNavigationFence.State.Admitted).ref)
        assertEquals(listOf(refB), admitted)
        fence.reset()
    }

    @Test
    fun repeatingTheSamePendingNavigationIsIdempotent() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val ref = TemporarySessionRef("ta", 7, "inc-a", nativeRootEpoch = 7L)
        val admitted = CopyOnWriteArrayList<TemporarySessionRef>()
        val fence = TemporaryNavigationFence(
            host = host,
            activeRefProvider = { ref },
            onAdmitted = { admitted += it },
        )
        val before = exchange.submitCount.get()
        fence.beginEnd(ref)
        awaitSubmit(exchange, before)
        val firstCount = exchange.submitCount.get()
        fence.beginEnd(ref)
        delay(30)
        assertEquals(firstCount, exchange.submitCount.get())
        val correlation = awaitSubmit(exchange, before)
        exchange.ackFor = { ack(ref, it) }
        assertTrue(admit(fence, ref))
        assertEquals(listOf(ref), admitted)
        fence.reset()
    }

    @Test
    fun timeoutLeavesTheFencePendingAndFailClosed() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val ref = TemporarySessionRef("ta", 8, "inc-a", nativeRootEpoch = 8L)
        val fence = TemporaryNavigationFence(host, { ref }, { })
        fence.beginEnd(ref)
        assertFalse(fence.awaitAdmission(ref, timeoutMillis = 120))
        assertTrue(fence.state.value is TemporaryNavigationFence.State.Pending)
        fence.reset()
        assertTrue(fence.state.value is TemporaryNavigationFence.State.Idle)
    }

    @Test
    fun acknowledgementInPageCarrierIsNotTrusted() = runBlocking {
        val exchange = FenceExchange()
        exchange.ackInPage = true
        val host = testHost(exchange)
        val ref = TemporarySessionRef("ta", 9, "inc-a", nativeRootEpoch = 9L)
        val fence = TemporaryNavigationFence(host, { ref }, { })
        fence.beginEnd(ref)
        awaitSubmit(exchange)
        exchange.ackFor = { ack(ref, it) }
        assertFalse(fence.awaitAdmission(ref, timeoutMillis = 400))
        assertTrue(fence.state.value is TemporaryNavigationFence.State.Ended)
        fence.reset()
    }

    @Test
    fun admittedFalseOrUnknownReasonOrExtraFieldIsRefused() = runBlocking {
        data class Case(
            val name: String,
            val build: (TemporarySessionRef, String) -> String,
            val expectEnded: Boolean,
        )
        val cases = listOf(
            Case("admittedFalse", { ref, corr -> ack(ref, corr, admitted = false) }, false),
            Case("unknownReason", { ref, corr -> ack(ref, corr, reason = "refused") }, false),
            Case(
                "extraField",
                { ref, corr -> ack(ref, corr, extra = ",\"route\":\"provider.save\"") },
                false,
            ),
        )
        for (case in cases) {
            val exchange = FenceExchange()
            val host = testHost(exchange)
            val ref = TemporarySessionRef("ta", 10, "inc-a", nativeRootEpoch = 10L)
            val fence = TemporaryNavigationFence(host, { ref }, { })
            fence.beginEnd(ref)
            awaitSubmit(exchange)
            exchange.ackFor = { corr -> case.build(ref, corr) }
            assertFalse("${case.name} must not admit", fence.awaitAdmission(ref, timeoutMillis = 200))
            assertFalse(
                fence.state.value is TemporaryNavigationFence.State.Admitted,
            )
            fence.reset()
        }
    }

    @Test
    fun exactAlreadyAbsentAcknowledgementAdmits() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val ref = TemporarySessionRef("ta", 11, "inc-a", nativeRootEpoch = 11L)
        val admitted = CopyOnWriteArrayList<TemporarySessionRef>()
        val fence = TemporaryNavigationFence(host, { ref }, { admitted += it })
        fence.beginEnd(ref)
        awaitSubmit(exchange)
        exchange.ackFor = { ack(ref, it, reason = "alreadyAbsent") }
        assertTrue(admit(fence, ref))
        assertEquals(listOf(ref), admitted)
        fence.reset()
    }

    @Test
    fun genericProgressAndTerminalDoNotAdmit() = runBlocking {
        val exchange = FenceExchange()
        val host = testHost(exchange)
        val ref = TemporarySessionRef("ta", 12, "inc-a", nativeRootEpoch = 12L)
        val fence = TemporaryNavigationFence(host, { ref }, { })
        fence.beginEnd(ref)
        // The scripted exchange offers an empty/progress page; the terminal
        // path is covered in HostLaunchAndFenceTest. A timeout here proves
        // neither queued nor progress state is promoted to admission.
        assertFalse(fence.awaitAdmission(ref, timeoutMillis = 120))
        assertNull((fence.state.value as? TemporaryNavigationFence.State.Admitted))
        fence.reset()
    }


}
