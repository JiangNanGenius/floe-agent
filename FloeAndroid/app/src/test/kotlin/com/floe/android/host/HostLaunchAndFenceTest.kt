// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored NOTRUN. Launch correlation + temporary navigation fence. */
class HostLaunchAndFenceTest {

    private class LaunchExchange : HostBridgeExchange {
        var failNextLaunch = false
        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    if (receipt == "op:v1:cget") {
                        // Conversation preload: the REAL session reply carries
                        // the row revision the launch CAS needs.
                        return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":{"conversationID":"c1","title":"Task","revision":{"resourceID":"conversation.c1","version":"v1"},"runs":[],"pendingInputs":[]}}],"hasMore":false,"resyncRequired":false}"""
                    }
                    if (failNextLaunch) {
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"needsConfiguration","detail":[{"key":"reason","value":"provider_unusable"}]}],"hasMore":false,"resyncRequired":false}"""
                    } else {
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},"effects":[{"sequence":1,"kind":"prepared","value":{"conversationID":"c1","runID":"r1"}},{"sequence":2,"kind":"accepted","value":{"conversationID":"c1","runID":"r1","launched":true}}],"hasMore":false,"resyncRequired":false}"""
                    }
                }
                request.contains("\"command\":\"conversation.get\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:cget"}"""
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:run1"}"""
            }
        }
    }

    /**
     * Scripted temp.start/temp.end transport double. The exact typed
     * acknowledgement shape is built from the REAL temp.end correlation and
     * the epoch bound by the host's TemporarySessionRef.
     */
    private class TempExchange : HostBridgeExchange {
        var includeAck = true
        var failEndSubmit = false
        var terminalCode: String? = null
        var ackConversation = "tc1"
        var ackIncarnation = "inc-1"
        var ackCorrelationOverride: String? = null
        var ackEpochDelta = 0L
        var ackAdmitted = true
        var ackReason: String? = null
        var epoch = 0L
        var startRootEpoch = 1L
        var endCorrelation: String? = null

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    if (receipt == START_RECEIPT) startPage(correlation, receipt)
                    else endPage(correlation, receipt)
                }
                request.contains("\"command\":\"temp.start\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$START_RECEIPT"}"""
                request.contains("\"command\":\"temp.end\"") -> {
                    endCorrelation = correlation
                    if (failEndSubmit) {
                        """{"version":3,"ok":false,"error":"invalidEnvelope","reason":"refused"}"""
                    } else {
                        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$END_RECEIPT"}"""
                    }
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:other"}"""
            }
        }

        private fun startPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":{"conversationID":"tc1","incarnation":"inc-1","rootEpoch":$startRootEpoch}}],"hasMore":false,"resyncRequired":false}"""

        private fun endPage(correlation: String, receipt: String): String {
            if (terminalCode != null) {
                return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"$terminalCode","detail":[{"key":"reason","value":"refused"}]}],"hasMore":false,"resyncRequired":false}"""
            }
            if (!includeAck) {
                return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
            }
            // The real producer echoes the temp.end COMMAND correlation, not
            // the effect-poll correlation of this page request.
            val acknowledgement = acknowledgementJson(endCorrelation ?: correlation)
            return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},"effects":[{"sequence":1,"kind":"prepared","value":$acknowledgement},{"sequence":2,"kind":"accepted","value":{"session":"ended"}}],"hasMore":false,"resyncRequired":false}"""
        }

        private fun acknowledgementJson(correlation: String): String {
            val reason = if (ackReason == null) "" else ",\"reason\":\"" + ackReason + "\""
            val requestCorrelation = ackCorrelationOverride ?: correlation
            return """{"navigationFence":{"admitted":$ackAdmitted,"conversationID":"$ackConversation","incarnationID":"$ackIncarnation","requestCorrelationID":"$requestCorrelation","epoch":${epoch + ackEpochDelta}$reason}}"""
        }

        companion object {
            const val START_RECEIPT = "op:v1:tstart"
            const val END_RECEIPT = "op:v1:tend"
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

    private companion object {
        const val PROVIDER_ID = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
        const val MODEL_ID = "B2F1A0C4-1111-4222-8333-444455556666"
    }

    private fun readyHost(exchange: TempExchange): RuntimeHost {
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        return host
    }

    private suspend fun startTemporary(host: RuntimeHost): com.floe.android.feature.conversation.TemporarySessionRef {
        var started: com.floe.android.feature.conversation.TemporarySessionRef? = null
        var failure: String? = null
        assertTrue(
            host.conversations.startTemporarySession(
                draft = "draft",
                preferredModelID = null,
                onStarted = { started = it },
                onFailure = { failure = it },
            ),
        )
        val deadline = System.nanoTime() + 1_500_000_000L
        while (started == null && failure == null && System.nanoTime() < deadline) {
            delay(10)
        }
        assertTrue("temp.start failed: $failure", started != null)
        return started!!
    }

    @Test
    fun preparedEchoesExactlyOnceWithRealCommittedIds() = runBlocking {
        val host = testHost(LaunchExchange())
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        val holder = host.conversations.holderFor("c1", isTemporary = false, incarnationId = null)
        // The frozen run.start grammar REQUIRES providerID + modelID.
        val request = com.floe.android.feature.conversation.RunLaunchRequest(
            conversationId = "c1",
            sessionEpoch = holder.session.sessionEpoch,
            goalText = "hello",
            attachments = emptyList(),
            executionMode = com.floe.android.feature.conversation.AgentExecutionModeUi.AGENT,
            modelId = MODEL_ID,
            workspaceId = null,
            temporaryIncarnationId = null,
            launchGeneration = 42,
            providerId = PROVIDER_ID,
        )
        val correlation = request.correlation()
        assertTrue(host.conversations.startRun(request))
        delay(200)
        val entry = host.conversations.entryFor("c1")
        assertTrue(entry != null)
        assertEquals("r1", entry!!.builder.selectedRunId)
        assertEquals(correlation.launchGeneration, 42L)
    }

    @Test
    fun launchFailureEchoRestoresDraftOnce() = runBlocking {
        val exchange = LaunchExchange()
        exchange.failNextLaunch = true
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        val holder = host.conversations.holderFor("c1", isTemporary = false, incarnationId = null)
        val request = com.floe.android.feature.conversation.RunLaunchRequest(
            conversationId = "c1",
            sessionEpoch = holder.session.sessionEpoch,
            goalText = "hello",
            attachments = emptyList(),
            executionMode = com.floe.android.feature.conversation.AgentExecutionModeUi.AGENT,
            modelId = MODEL_ID,
            workspaceId = null,
            temporaryIncarnationId = null,
            launchGeneration = 7,
            providerId = PROVIDER_ID,
        )
        assertTrue(host.conversations.startRun(request))
        delay(200)
        val entry = host.conversations.entryFor("c1")
        assertTrue(entry != null)
        assertEquals(null, entry!!.builder.selectedRunId)
        assertTrue(host.conversations.activeTemporarySession() == null)
    }

    @Test
    fun tempEndFenceAdmitsBeforeRouteTransition() = runBlocking {
        val exchange = TempExchange()
        val host = readyHost(exchange)
        val ref = startTemporary(host)
        assertEquals(ref, host.conversations.activeTemporarySession())
        exchange.epoch = ref.nativeRootEpoch
        host.conversations.tempFence.beginEnd(ref)
        val admitted = host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 1_000)
        assertTrue("route transition requires the exact typed fence admission", admitted)
        delay(30)
        assertTrue(host.conversations.tempFence.state.value is TemporaryNavigationFence.State.Admitted)
        // The exact admitted identity is retired; a stale begin for it cannot
        // fence a later session.
        assertNull(host.conversations.activeTemporarySession())
        host.conversations.tempFence.reset()
    }

    @Test
    fun genericTerminalWithoutExactAcknowledgementDoesNotAdmit() = runBlocking {
        val exchange = TempExchange()
        exchange.includeAck = false
        exchange.terminalCode = "invalidState"
        val host = readyHost(exchange)
        val ref = startTemporary(host)
        exchange.epoch = ref.nativeRootEpoch
        host.conversations.tempFence.beginEnd(ref)
        val admitted = host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 300)
        assertTrue(!admitted)
        assertTrue(host.conversations.tempFence.state.value is TemporaryNavigationFence.State.Ended)
        assertEquals(ref, host.conversations.activeTemporarySession())
        host.conversations.tempFence.reset()
    }

    @Test
    fun submittedRefusalNeverAdmits() = runBlocking {
        val exchange = TempExchange()
        exchange.failEndSubmit = true
        val host = readyHost(exchange)
        val ref = startTemporary(host)
        exchange.epoch = ref.nativeRootEpoch
        host.conversations.tempFence.beginEnd(ref)
        val admitted = host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 2_000)
        assertTrue(!admitted)
        assertTrue(host.conversations.tempFence.state.value is TemporaryNavigationFence.State.Refused)
        assertEquals(ref, host.conversations.activeTemporarySession())
        host.conversations.tempFence.reset()
    }

    @Test
    fun wrongIncarnationOrConversationOrEpochNeverAdmits() = runBlocking {
        data class Case(
            val name: String,
            val configure: (TempExchange) -> Unit,
        )
        val cases = listOf(
            Case("incarnation") { it.ackIncarnation = "other-inc" },
            Case("conversation") { it.ackConversation = "other-conv" },
            Case("epoch") { it.ackEpochDelta = 1L },
            Case("correlation") { it.ackCorrelationOverride = "tend-foreign" },
            Case("admittedFalse") { it.ackAdmitted = false },
        )
        for (case in cases) {
            val exchange = TempExchange()
            case.configure(exchange)
            val host = readyHost(exchange)
            val ref = startTemporary(host)
            exchange.epoch = ref.nativeRootEpoch
            host.conversations.tempFence.beginEnd(ref)
            val admitted = host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 200)
            assertTrue("${case.name} must not admit", !admitted)
            assertFalse(
                "${case.name} must never become an admission",
                host.conversations.tempFence.state.value is
                    TemporaryNavigationFence.State.Admitted,
            )
            host.conversations.tempFence.reset()
        }
    }

    @Test
    fun explicitEndEchoesExactlyOnceAfterTheExactAdmission() = runBlocking {
        val exchange = TempExchange()
        val host = readyHost(exchange)
        val target = java.util.concurrent.atomic.AtomicReference<
            com.floe.android.feature.conversation.TemporaryEndTargetUi?>(null)
        host.conversations.tempFence.endOutcomeListener = { _, value -> target.set(value) }
        val ref = startTemporary(host)
        exchange.epoch = ref.nativeRootEpoch
        assertTrue(host.conversations.endTemporaryChat(ref))
        val deadline = System.nanoTime() + 1_000_000_000L
        while (target.get() == null && System.nanoTime() < deadline) delay(10)
        assertTrue(
            target.get() is com.floe.android.feature.conversation.TemporaryEndTargetUi.OpenNewTask,
        )
        target.set(null)
        delay(100)
        assertNull(target.get())
        host.conversations.tempFence.reset()
    }

    @Test
    fun alreadyRetiredExactAcknowledgementAdmits() = runBlocking {
        val exchange = TempExchange()
        exchange.ackReason = "alreadyRetired"
        val host = readyHost(exchange)
        val ref = startTemporary(host)
        exchange.epoch = ref.nativeRootEpoch
        host.conversations.tempFence.beginEnd(ref)
        assertTrue(host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 500))
        val state = host.conversations.tempFence.state.value
        assertTrue(state is TemporaryNavigationFence.State.Admitted)
        assertEquals(
            "alreadyRetired",
            (state as TemporaryNavigationFence.State.Admitted).acknowledgement.reason,
        )
        host.conversations.tempFence.reset()
    }


}
