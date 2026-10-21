// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.FloeFoundation
import com.floe.android.HomeDraftTransfer
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Launch correlation, Home request ownership and the temporary navigation fence. */
class HostLaunchAndFenceTest {

    private class LaunchExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        var failNextLaunch = false
        override fun exchange(request: String): String {
            requests.add(request)
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
        val requests = CopyOnWriteArrayList<String>()
        var startGate: CountDownLatch? = null
        var failStart = false
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
        var keepConversationID = "tc1"
        var keepRequests = 0

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    when (receipt) {
                        START_RECEIPT -> startPage(correlation, receipt)
                        KEEP_RECEIPT -> keepPage(correlation, receipt)
                        else -> endPage(correlation, receipt)
                    }
                }
                request.contains("\"command\":\"temp.start\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$START_RECEIPT"}"""
                request.contains("\"command\":\"temp.keep\"") -> {
                    keepRequests += 1
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$KEEP_RECEIPT"}"""
                }
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

        private fun startPage(correlation: String, receipt: String): String {
            startGate?.await(5, TimeUnit.SECONDS)
            if (failStart) {
                return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"runtimeUnavailable","detail":[{"key":"reason","value":"refused"}]}],"hasMore":false,"resyncRequired":false}"""
            }
            return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":{"conversationID":"tc1","incarnation":"inc-1","rootEpoch":$startRootEpoch}}],"hasMore":false,"resyncRequired":false}"""
        }

        fun commandsOf(command: String): List<kotlinx.serialization.json.JsonObject> =
            requests.mapNotNull { raw ->
                val root = runCatching { Json.parseToJsonElement(raw).jsonObject }
                    .getOrNull() ?: return@mapNotNull null
                if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") {
                    return@mapNotNull null
                }
                val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
                if ((envelope["command"]?.jsonPrimitive?.content) != command) {
                    return@mapNotNull null
                }
                envelope
            }

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

        private fun keepPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":{"keep":"committed","conversationID":"$keepConversationID"}}],"hasMore":false,"resyncRequired":false}"""

        private fun acknowledgementJson(correlation: String): String {
            val reason = if (ackReason == null) "" else ",\"reason\":\"" + ackReason + "\""
            val requestCorrelation = ackCorrelationOverride ?: correlation
            return """{"navigationFence":{"admitted":$ackAdmitted,"conversationID":"$ackConversation","incarnationID":"$ackIncarnation","requestCorrelationID":"$requestCorrelation","epoch":${epoch + ackEpochDelta}$reason}}"""
        }

        companion object {
            const val START_RECEIPT = "op:v1:tstart"
            const val END_RECEIPT = "op:v1:tend"
            const val KEEP_RECEIPT = "op:v1:tkeep"
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
        assertTrue(host.conversations.startRun(request, null))
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
        assertTrue(host.conversations.startRun(request, null))
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


    @Test
    fun delayedTempStartAfterActualNewTaskIsFencedAndCannotStealTheNewHome() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
            startGate = CountDownLatch(1)
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "same text")
        var admitted = 0
        var failure: String? = null
        var newHomeField = "same text"
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "same text",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
            onAdmitted = { _: HomeSendToken, _: Boolean ->
                admitted += 1
                newHomeField = ""
            },
        ) { failure = it }
        assertTrue(
            "temp.start must be submitted (failure=$failure, " +
                "temporaryAdmitted=${host.readiness.value.temporaryDomainAdmitted}, " +
                "sending=${host.home.sending.value}, requests=${exchange.requests.size})",
            awaitUntil { exchange.commandsOf("temp.start").isNotEmpty() },
        )
        // ACTUAL New Task from the current Home invalidates the pending start.
        host.home.onNavigation(
            SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
        // The canceled attempt's exact private draft is gone: returning to
        // Home without retyping must NOT restore it into an ordinary Home.
        assertEquals("", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        // Re-enter Home and type the SAME text (a NEW owner) before the old
        // native callback completes; that newer draft must survive untouched.
        newHomeField = "same text"
        HomeDraftTransfer.update(FloeFoundation.draftStore, "same text")
        exchange.startGate!!.countDown()
        assertTrue(awaitUntil { exchange.commandsOf("temp.end").isNotEmpty() })
        assertTrue(awaitUntil { host.conversations.activeTemporarySession() == null })
        delay(100)
        assertEquals(0, admitted)
        assertEquals("same text", newHomeField)
        assertEquals("same text", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        assertNull(host.conversations.navigationRequest.value)
        assertTrue(exchange.commandsOf("run.start").isEmpty())
        assertNull(failure)
        host.stop()
    }

    @Test
    fun delayedTempStartFailureCannotOpenPopupInTheNewHome() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
            startGate = CountDownLatch(1)
            failStart = true
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "same text")
        var admitted = 0
        var failure: String? = null
        var newHomeField = "same text"
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "same text",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
            onAdmitted = { _: HomeSendToken, _: Boolean -> admitted += 1 },
        ) { failure = it }
        assertTrue(
            "temp.start must be submitted (failure=$failure, " +
                "temporaryAdmitted=${host.readiness.value.temporaryDomainAdmitted}, " +
                "sending=${host.home.sending.value}, requests=${exchange.requests.size})",
            awaitUntil { exchange.commandsOf("temp.start").isNotEmpty() },
        )
        host.home.onNavigation(
            SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
        assertEquals("", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        newHomeField = "same text"
        HomeDraftTransfer.update(FloeFoundation.draftStore, "same text")
        exchange.startGate!!.countDown()
        delay(150)
        assertEquals(0, admitted)
        assertEquals("same text", newHomeField)
        assertEquals("same text", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        assertNull(failure)
        assertNull(host.conversations.activeTemporarySession())
        assertNull(host.conversations.navigationRequest.value)
        assertTrue(exchange.commandsOf("run.start").isEmpty())
        host.stop()
    }

    @Test
    fun pendingTempStartSurvivesRotationLikeRecompositionAndStillAdmits() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
            startGate = CountDownLatch(1)
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "")
        var admitted = 0
        var transferred = false
        val generationBefore = host.home.currentHomeGeneration()
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
            onAdmitted = { _: HomeSendToken, draftTransferred: Boolean ->
                admitted += 1
                transferred = draftTransferred
            },
        ) {}
        assertTrue(
            "temp.start must be submitted (admitted=$admitted, " +
                "temporaryAdmitted=${host.readiness.value.temporaryDomainAdmitted}, " +
                "sending=${host.home.sending.value}, requests=${exchange.requests.size})",
            awaitUntil { exchange.commandsOf("temp.start").isNotEmpty() },
        )
        // No actual navigation: rotation/view reconstruction preserves the
        // service-owned Home identity and the pending request.
        exchange.startGate!!.countDown()
        assertTrue(awaitUntil { admitted == 1 })
        assertTrue(transferred)
        assertEquals(generationBefore, host.home.currentHomeGeneration())
        assertNotNull(host.conversations.activeTemporarySession())
        val navigation = host.conversations.navigationRequest.value
        assertEquals(SidebarSelection.Conversation("tc1"), navigation)
        val route = navigation!!
        // The published route carries one-shot ownership: the FIRST apply
        // consumes it, a SECOND apply of the same id is ordinary navigation.
        host.conversations.navigationRequest.value = null
        var applied: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(route, { true }) { applied = it })
        assertEquals(route, applied)
        var second: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(route, { true }) { second = it })
        assertEquals(route, second)
        assertTrue(exchange.commandsOf("run.start").isEmpty())
        val ref = host.conversations.activeTemporarySession()!!
        exchange.epoch = ref.nativeRootEpoch
        host.conversations.tempFence.beginEnd(ref)
        host.conversations.tempFence.awaitAdmission(ref, timeoutMillis = 1_000)
        host.stop()
    }

    @Test
    fun midAdmissionInvalidationPublishesNothingAndDiscardsTheCanceledDraft() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "private prompt")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        host.home.admissionPublishBarrier = {
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        var admitted = 0
        var failure: String? = null
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "private prompt",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
            onAdmitted = { _: HomeSendToken, _: Boolean -> admitted += 1 },
        ) { failure = it }
        assertTrue(
            "the native admission must reach the pre-publication barrier",
            entered.await(3, TimeUnit.SECONDS),
        )
        // The native start WAS admitted, but the IO callback is paused before
        // publication. An ACTUAL New Task (Main) invalidates the request now.
        host.home.onNavigation(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
        assertNull(host.conversations.navigationRequest.value)
        assertEquals("", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        release.countDown()
        assertTrue(awaitUntil { exchange.commandsOf("temp.end").isNotEmpty() })
        assertTrue(awaitUntil { host.conversations.activeTemporarySession() == null })
        delay(100)
        assertEquals(0, admitted)
        assertNull(failure)
        assertNull(host.conversations.navigationRequest.value)
        assertTrue(exchange.commandsOf("run.start").isEmpty())
        // Exactly ONE bounded native temp.end for the exact stale ref (the
        // invalidation owns it; the resumed stale callback never re-sends).
        assertEquals(1, exchange.commandsOf("temp.end").size)
        // No retype: the next ordinary Home starts from an EMPTY draft.
        assertEquals("", HomeDraftTransfer.draft(FloeFoundation.draftStore))
        host.stop()
    }

    @Test
    fun staleOwnedNavigationInvalidatedDuringFenceWaitCannotCommitOrBlacklistTheId() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "")
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
        ) {}
        assertTrue(awaitUntil { host.conversations.navigationRequest.value != null })
        val target = host.conversations.navigationRequest.value!!
        assertEquals(SidebarSelection.Conversation("tc1"), target)
        host.conversations.navigationRequest.value = null
        var committed: SidebarSelection? = null
        val claimed = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val invalidator = launch(Dispatchers.Default) {
            claimed.await()
            // The origin is genuinely invalidated WHILE the route application
            // is suspended waiting for the temporary fence admission.
            host.home.onNavigation(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
            release.complete(Unit)
        }
        val applied = host.home.applyHostNavigation(
            target = target,
            waitForAdmission = {
                claimed.complete(Unit)
                release.await()
                true
            },
            commit = { committed = it },
        )
        invalidator.join()
        assertFalse("an invalidated owned intent must never commit", applied)
        assertNull(committed)
        // The id is NOT globally blacklisted: a later generic TaskCenter/
        // history open of the exact same conversation still commits.
        var reopened: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(target, { true }) { reopened = it })
        assertEquals(target, reopened)
        host.stop()
    }

    @Test
    fun cancelingAPublishedButNotYetAppliedRouteRetiresTheExactSessionOnce() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "")
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
        ) {}
        assertTrue(awaitUntil { host.conversations.navigationRequest.value != null })
        val target = host.conversations.navigationRequest.value!!
        assertEquals(SidebarSelection.Conversation("tc1"), target)
        // The shell has NOT applied the owned route yet; an ACTUAL New Task
        // cancels it. The exact admitted native session must be retired once
        // and its published intent withdrawn.
        host.home.onNavigation(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
        assertTrue(awaitUntil { exchange.commandsOf("temp.end").isNotEmpty() })
        assertTrue(awaitUntil { host.conversations.activeTemporarySession() == null })
        delay(100)
        assertEquals(1, exchange.commandsOf("temp.end").size)
        assertNull(host.conversations.navigationRequest.value)
        // The id is not denied: a generic open after the cancel still commits.
        var reopened: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(target, { true }) { reopened = it })
        assertEquals(target, reopened)
        host.stop()
    }

    @Test
    fun ownNavigationHandoffThenKeepAllowsGenericHistoryReopenOfTheSameId() = runBlocking {
        val exchange = TempExchange().apply {
            epoch = 1L
            startRootEpoch = 1L
            keepConversationID = "tc1"
        }
        val host = readyHost(exchange)
        HomeDraftTransfer.update(FloeFoundation.draftStore, "")
        var admitted = 0
        var transferred = false
        val origin = host.home.currentHomeGeneration()
        host.home.send(
            "",
            "chat",
            temporary = true,
            originHomeGeneration = origin,
            onAdmitted = { _: HomeSendToken, draftTransferred: Boolean ->
                admitted += 1
                transferred = draftTransferred
            },
        ) {}
        assertTrue(awaitUntil { admitted == 1 })
        assertTrue(transferred)
        val published = host.conversations.navigationRequest.value
        assertEquals(SidebarSelection.Conversation("tc1"), published)
        host.conversations.navigationRequest.value = null
        var applied: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(published!!, { true }) { applied = it })
        assertEquals(published, applied)
        // Explicit Keep promotes the SAME hosted id to an ordinary
        // conversation (real Core receipt shape). The same-id promotion is
        // the SCOPED adoption signal, NOT a generic navigationRequest: the
        // shell persists the durable saved selection only while the exact
        // origin surface is still current (Main late-Keep ownership fence),
        // and the projection adopts the receipt-returned identity.
        val ref = host.conversations.activeTemporarySession()!!
        exchange.epoch = ref.nativeRootEpoch
        assertTrue(host.conversations.keepTemporaryChat(ref))
        assertTrue(
            awaitUntil {
                host.conversations.keptPromotion.value?.durableConversationId == "tc1"
            },
        )
        assertEquals(ref, host.conversations.keptPromotion.value?.originRef)
        assertNull(host.conversations.navigationRequest.value)
        val keptEntry = host.conversations.entryFor("tc1")!!
        assertFalse(keptEntry.holder.snapshot.value!!.isTemporary)
        assertEquals("tc1", keptEntry.holder.snapshot.value!!.promotedConversationId)
        assertEquals(1, exchange.keepRequests)
        host.conversations.keptPromotion.value = null
        var kept: SidebarSelection? = null
        assertTrue(
            host.home.applyHostNavigation(
                SidebarSelection.Conversation("tc1"), { true }) { kept = it },
        )
        assertEquals(SidebarSelection.Conversation("tc1"), kept)
        // Unrelated navigation still works...
        val newTask = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
        var unrelated: SidebarSelection? = null
        assertTrue(host.home.applyHostNavigation(newTask, { true }) { unrelated = it })
        assertEquals(newTask, unrelated)
        // ...and the kept ordinary conversation reopens from TaskCenter.
        var reopened: SidebarSelection? = null
        assertTrue(
            host.home.applyHostNavigation(
                SidebarSelection.Conversation("tc1"), { true }) { reopened = it },
        )
        assertEquals(SidebarSelection.Conversation("tc1"), reopened)
        host.stop()
    }

    private suspend fun awaitUntil(
        timeoutMillis: Long = 2_000,
        check: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

}
