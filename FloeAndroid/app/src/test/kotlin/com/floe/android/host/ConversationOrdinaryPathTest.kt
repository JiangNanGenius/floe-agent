// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ApprovalScopeChoiceUi
import com.floe.android.feature.conversation.ApprovalUserDecisionUi
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.GoalCreateRequest
import com.floe.android.feature.conversation.RunningInputModeUi
import com.floe.android.feature.conversation.RunningInputRequest
import androidx.compose.ui.text.input.TextFieldValue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ordinary conversation App path against the ACTUAL current Core contract:
 * model projection (F1), closed run.start grammar (F2), run-state CAS
 * controls (F3/F5), approval projection/resolve (F4), durable event
 * vocabulary + terminal close + committed-row reload (F6), native terminal
 * sets (F8), pump-failure surfacing (F9), goal/child projections (F10) and
 * the unopened-history CAS resolution.
 *
 * Transport is a scripted double of the real v3 wire (producer-side shapes:
 * effect pages with typed value/detail carriers, event-cursor pages with a
 * JSON-string payload). No native code, no device, no network.
 */
class ConversationOrdinaryPathTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val secondModelId = "C3F2B1D5-2222-4333-8444-555566667777"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val childId = "33333333-3333-4333-8333-333333333333"
    private val callId = "call_abc123"
    private val requestedAt = "2026-10-20T01:02:03.456Z"

    // ------------------------------------------------------------------ wire

    private class ScriptedExchange(
        private val script: (String) -> String,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        val responses = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            val response = script(request)
            requests.add(request)
            responses.add(response)
            return response
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") return@mapNotNull null
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) return@mapNotNull null
            envelope
        }
    }

    private fun commandsSummary(exchange: ScriptedExchange): String =
        exchange.requests.joinToString(",") { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
            val operation = root?.get("operation")?.jsonPrimitive?.content ?: "?"
            if (operation == "command.submit") {
                root?.get("envelope")?.jsonObject?.get("command")?.jsonPrimitive?.content
                    ?: "command?"
            } else {
                operation
            }
        }

    private fun receipt(correlation: String, receiptTag: String): String =
        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
            """"operationReceiptID":"op:v1:$receiptTag"}"""

    private fun effectPage(
        correlation: String,
        receiptTag: String,
        effectsJson: String,
        sequence: Long = 2,
    ): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
            """"sequence":$sequence},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""

    private fun accepted(
        valueJson: String?,
        detailJson: String = "",
        sequence: Int = 1,
    ): String {
        val value = if (valueJson == null) "" else ""","value":$valueJson"""
        val detail = if (detailJson.isBlank()) "" else ""","detail":$detailJson"""
        return """{"sequence":$sequence,"kind":"accepted"$value$detail}"""
    }

    private fun detail(vararg pairs: Pair<String, String>): String =
        pairs.joinToString(",", "[", "]") { (key, value) ->
            """{"key":"$key","value":"$value"}"""
        }

    private fun eventPage(
        correlation: String,
        windowState: String,
        eventsJson: String = "[]",
        nextSequence: Long = 0,
    ): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.event-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"runID":"$runId","sequence":$nextSequence},""" +
            """"durable":{"windowState":"$windowState","events":$eventsJson,"hasMore":false,""" +
            """"resyncRequired":false,"nextSequence":$nextSequence},""" +
            """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
            """"resyncRequired":false}"""

    private fun event(sequence: Long, kind: String, payload: String): String =
        """{"sequence":$sequence,"kind":"$kind","createdAt":123,"payload":${jsonString(payload)}}"""

    private fun jsonString(raw: String): String =
        JsonPrimitive(raw).toString()

    private fun providerRow(): String =
        """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
            """"baseURL":"https://example.invalid/v1","displayName":"DeepSeek Cloud QA",""" +
            """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
            """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
            """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
            """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

    private fun modelRow(id: String, remote: String, display: String, enabled: Boolean = true): String =
        """{"id":"$id","providerID":"$providerId","remoteModelID":"$remote",""" +
            """"displayName":"$display","limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
            """"capabilities":{"rawValue":7},"explicitCapabilities":null,"useSurfaces":null,""" +
            """"reasoningEffort":"automatic","isEnabled":$enabled,""" +
            """"isHiddenFromPrimaryPicker":false,""" +
            """"revision":{"resourceID":"model.$id","version":"digest"}}"""

    private fun conversationReply(state: String, runsJson: String? = null): String {
        val runs = runsJson ?: """[{"runID":"$runId","state":"$state","modelName":"DeepSeek Cloud QA",""" +
            """"startedAt":"2026-10-20T01:00:00.000Z"}]"""
        return """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}","version":"digest-1"},""" +
            """"runs":$runs,"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""
    }

    private fun snapshotValue(
        state: String,
        pendingApproval: Boolean = false,
        pendingInputs: String = "[]",
        queueVersion: String = "queue-digest-1",
    ): String {
        val approval = if (!pendingApproval) "null" else
            """{"callID":"$callId","tool":"workspace.writeFile","reason":"Needs approval",""" +
                """"requestedAt":"$requestedAt"}"""
        val approvalRevision = if (!pendingApproval) "null" else
            """{"resourceID":"approval.$callId","version":"$requestedAt"}"""
        return """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
            """"runID":"$runId","durableState":"$state",""" +
            """"revision":{"resourceID":"run.${runId.uppercase()}","version":"$state"},""" +
            """"isTerminal":false,"conversationMode":"chat","goal":"hi","liveOwner":true,""" +
            """"pendingApproval":$approval,"approvalRevision":$approvalRevision,""" +
            """"pendingInputs":$pendingInputs,""" +
            """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
            """"version":"$queueVersion"},"durableWatermark":4}"""
    }

    /**
     * Default scripted transport: every read answers a REAL producer-shaped
     * page; control commands settle accepted unless a test overrides them.
     */
    private class LocalScript {
        var runState = "streamingModel"
        var freshConversation = false
        var eventScript: ((String) -> String)? = null
        var cancelRejectOnce = false
        var snapshotStateAfterReject = "executingTool"
        var cancelCount = 0
        var extraModelRows = ""
        var pendingInputsJson = "[]"
        var pendingApproval = false
        var archiveAccepted = true
    }

    private fun client(exchange: HostBridgeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 1),
    )

    private fun host(
        script: LocalScript,
        exchange: ScriptedExchange,
    ): RuntimeHost = RuntimeHost(
        commandClient = client(exchange),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private fun buildExchange(script: LocalScript): ScriptedExchange = ScriptedExchange { raw ->
        val correlation = correlationOf(raw)
        when {
            raw.contains("\"operation\":\"effect.poll\"") -> {
                val receiptTag = receiptOf(raw)
                when (receiptTag) {
                    "op:v1:providers" -> effectPage(
                        correlation, "providers",
                        accepted("""{"rows":[${providerRow()}]}"""),
                    )
                    "op:v1:models" -> effectPage(
                        correlation, "models",
                        accepted("""{"rows":[${modelRow(modelId, "deepseek-flash", "DeepSeek Cloud QA")}${script.extraModelRows}]}"""),
                    )
                    "op:v1:prefsave" -> effectPage(
                        correlation, "prefsave",
                        accepted(
                            """{"revision":{"resourceID":"preferences","version":"2"},""" +
                                """"preferences":{"defaultAgentModelID":"$modelId","syncRevision":2}}""",
                        ),
                    )
                    "op:v1:preferences" -> effectPage(
                        correlation, "preferences",
                        accepted(
                            """{"revision":{"resourceID":"preferences","version":"1"},""" +
                                """"preferences":{"onboardingStatus":"seen",""" +
                                """"defaultAgentModelID":"$modelId",""" +
                                """"generalAuxiliaryLLMModelID":null,""" +
                                """"canvasAgentModelID":null,"visionModelID":null,""" +
                                """"canvasVisionModelID":null,"approvalModelID":null,""" +
                                """"packageReviewModelID":null,"autonomousImageRouting":false,""" +
                                """"auxiliaryImageMode":"shared","sharedImageModelID":null,""" +
                                """"imageGenerationModelID":null,"imageEditingModelID":null,""" +
                                """"defaultVideoModelID":null,""" +
                                """"updatedAt":770000000.0,"syncRevision":1}}""",
                        ),
                    )
                    "op:v1:conversationGet" -> effectPage(
                        correlation, "conversationGet",
                        accepted(
                            if (script.freshConversation) {
                                conversationReply(script.runState, runsJson = "[]")
                            } else {
                                conversationReply(script.runState)
                            },
                        ),
                    )
                    "op:v1:runStart" -> effectPage(
                        correlation, "runStart",
                        """{"sequence":1,"kind":"prepared","detail":${detail(
                            "conversationID" to conversationId,
                            "runID" to runId,
                            "resourceID" to "run.${runId.uppercase()}",
                            "version" to "preparing",
                        )}},""" + accepted(
                            """{"conversationID":"$conversationId","runID":"$runId"}""",
                            sequence = 2,
                        ),
                    )
                    "op:v1:runSnapshot" -> effectPage(
                        correlation, "runSnapshot",
                        accepted(
                            snapshotValue(
                                script.runState,
                                pendingApproval = script.pendingApproval,
                                pendingInputs = script.pendingInputsJson,
                            ),
                        ),
                    )
                    "op:v1:cancel" -> {
                        script.cancelCount += 1
                        if (script.cancelRejectOnce && script.cancelCount == 1) {
                            script.runState = script.snapshotStateAfterReject
                            effectPage(
                                correlation, "cancel",
                                """{"sequence":1,"kind":"rejected","code":"ordinaryRuntimeBlocked",""" +
                                    """"detail":${detail("reason" to "staleRevision")}}""",
                            )
                        } else {
                            effectPage(
                                correlation, "cancel",
                                accepted(null, detail("cancel" to "requested")),
                            )
                        }
                    }
                    "op:v1:queue" -> effectPage(
                        correlation, "queue",
                        accepted(
                            null,
                            detail(
                                "inputID" to "44444444-4444-4444-8444-444444444444",
                                "position" to "0",
                                "status" to "queued",
                                "inputVersion" to "2026-10-20T01:02:04.000Z",
                            ),
                        ),
                    )
                    "op:v1:steer" -> effectPage(
                        correlation, "steer",
                        accepted(null, detail("inputID" to "44444444-4444-4444-8444-444444444444")),
                    )
                    "op:v1:inputEdit", "op:v1:inputRemove", "op:v1:inputReorder" ->
                        effectPage(correlation, receiptTag, accepted(null, detail("mutated" to "true")))
                    "op:v1:approvalResolve" -> effectPage(
                        correlation, "approvalResolve",
                        accepted(null, detail("bound" to "true", "awaitReceipt" to "approvalResolved")),
                    )
                    "op:v1:childList" -> effectPage(
                        correlation, "childList",
                        accepted(
                            """{"parentRunID":"$runId","children":[{"childRunID":"$childId",""" +
                                """"parentRunID":"$runId","rootRunID":"$runId","kind":"delegate",""" +
                                """"taskSummary":"Research","state":"completed","terminal":true,""" +
                                """"iterationCount":1,"startedAt":"2026-10-20T01:00:00.000Z",""" +
                                """"endedAt":"2026-10-20T01:01:00.000Z","resultSummary":"done"}],""" +
                                """"childrenTruncated":false}""",
                        ),
                    )
                    "op:v1:childEntries" -> effectPage(
                        correlation, "childEntries",
                        accepted(
                            """{"childRunID":"$childId","entries":[{"sequence":1,""" +
                                """"kind":"assistantText","payload":"{\"text\":\"child answer\"}",""" +
                                """"createdAt":"2026-10-20T01:00:30.000Z"}],"hasMore":false,""" +
                                """"nextSequence":1}""",
                        ),
                    )
                    "op:v1:archive" -> {
                        if (script.archiveAccepted) {
                            effectPage(correlation, "archive", accepted(null, detail("archived" to "true")))
                        } else {
                            effectPage(
                                correlation, "archive",
                                """{"sequence":1,"kind":"rejected","code":"ordinaryRuntimeBlocked",""" +
                                    """"detail":${detail("reason" to "staleRevision")}}""",
                            )
                        }
                    }
                    "op:v1:messagePage" -> effectPage(
                        correlation, "messagePage",
                        accepted("""{"rows":[],"hasEarlier":false,"earlierCursor":null}"""),
                    )
                    "op:v1:catalog" -> effectPage(
                        correlation, "catalog",
                        accepted("""{"rows":[]}"""),
                    )
                    else -> effectPage(correlation, receiptTag, accepted(null))
                }
            }
            raw.contains("\"operation\":\"event.poll\"") -> {
                script.eventScript?.invoke(correlation) ?: eventPage(correlation, "attached")
            }
            raw.contains("\"command\":\"config.providers.list\"") ->
                receipt(correlation, "providers")
            raw.contains("\"command\":\"config.models.list\"") ->
                receipt(correlation, "models")
            raw.contains("\"command\":\"config.preferences.get\"") ->
                receipt(correlation, "preferences")
            raw.contains("\"command\":\"config.preferences.save\"") ->
                receipt(correlation, "prefsave")
            raw.contains("\"command\":\"conversation.get\"") ->
                receipt(correlation, "conversationGet")
            raw.contains("\"command\":\"run.start\"") ->
                receipt(correlation, "runStart")
            raw.contains("\"command\":\"run.snapshot\"") ->
                receipt(correlation, "runSnapshot")
            raw.contains("\"command\":\"run.cancel\"") ->
                receipt(correlation, "cancel")
            raw.contains("\"command\":\"run.queue\"") ->
                receipt(correlation, "queue")
            raw.contains("\"command\":\"run.steer\"") ->
                receipt(correlation, "steer")
            raw.contains("\"command\":\"run.input.edit\"") ->
                receipt(correlation, "inputEdit")
            raw.contains("\"command\":\"run.input.remove\"") ->
                receipt(correlation, "inputRemove")
            raw.contains("\"command\":\"run.input.reorder\"") ->
                receipt(correlation, "inputReorder")
            raw.contains("\"command\":\"run.approval.resolve\"") ->
                receipt(correlation, "approvalResolve")
            raw.contains("\"command\":\"child.list\"") ->
                receipt(correlation, "childList")
            raw.contains("\"command\":\"child.entries\"") ->
                receipt(correlation, "childEntries")
            raw.contains("\"command\":\"conversation.archive\"") ->
                receipt(correlation, "archive")
            raw.contains("\"command\":\"conversation.messagePage\"") ->
                receipt(correlation, "messagePage")
            raw.contains("\"command\":\"config.catalog.search\"") ->
                receipt(correlation, "catalog")
            else -> receipt(correlation, "other")
        }
    }

    private suspend fun readyHost(script: LocalScript, exchange: ScriptedExchange): RuntimeHost {
        val host = host(script, exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.providers.refreshProviders()
        host.conversations.refreshModels()
        host.conversations.refreshHistory()
        // Bounded wait for the real projection round-trips.
        val deadline = System.nanoTime() + 2_000_000_000L
        while (host.conversations.modelOptions().isEmpty() && System.nanoTime() < deadline) {
            delay(10)
        }
        return host
    }

    private suspend fun loadedHolder(
        host: RuntimeHost,
    ): com.floe.android.feature.conversation.ConversationFlowHolder {
        val holder = host.conversations.holderFor(conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(holder.session)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (holder.snapshot.value == null && System.nanoTime() < deadline) delay(10)
        return holder
    }

    private suspend fun awaitCondition(timeoutMillis: Long = 2_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    // ---------------------------------------------------------------- tests

    @Test
    fun modelProjectionUsesRealModelRowsAndDefaultSelection() = runBlocking {
        val script = LocalScript().apply {
            extraModelRows = "," + modelRow(secondModelId, "deepseek-reasoner", "DeepSeek Reasoner", enabled = false)
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val options = host.conversations.modelOptions()
        // Disabled rows never reach the picker; the saved default leads.
        assertEquals(1, options.size)
        assertEquals(modelId, options[0].modelId)
        assertEquals(providerId, options[0].providerId)
        assertEquals("deepseek-flash", options[0].remoteModelId)
        assertTrue(options[0].isUsable)
        // The provider row's model count is the REAL page count (both rows),
        // never the previously invented default 0.
        host.providers.refreshProviders()
        assertTrue(
            awaitCondition {
                host.providers.destination.value.list.conversationProviders
                    .firstOrNull()?.modelCount == 2
            },
        )
        host.stop()
    }

    @Test
    fun sendDispatchesTheClosedRunStartGrammar() = runBlocking {
        val script = LocalScript().apply { freshConversation = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        holder.onDraftChange(TextFieldValue("Hello there"))
        val result = holder.send()
        assertTrue("send must be admitted: $result", result !is com.floe.android.feature.conversation.ConversationFlowResult.Rejected)
        assertTrue(
            "run.start must be submitted for the admitted send",
            awaitCondition { exchange.commandsOf("run.start").isNotEmpty() },
        )
        val envelope = exchange.commandsOf("run.start").first()
        val payload = envelope["payload"]!!.jsonObject
        val keys = payload.keys
        // Closed native allowedKeys only (no workspaceID/temporaryIncarnation).
        assertTrue(keys.all { it in EXPECTED_RUN_START_KEYS })
        assertEquals("chat", payload["mode"]!!.jsonPrimitive.content)
        assertEquals(providerId, payload["providerID"]!!.jsonPrimitive.content)
        assertEquals(modelId, payload["modelID"]!!.jsonPrimitive.content)
        assertTrue((payload["stagedAttachments"] as JsonArray).isEmpty())
        assertTrue(
            "prepared echo must bind the real run",
            awaitCondition { holder.snapshot.value?.selectedRunId == runId },
        )
        host.stop()
    }

    @Test
    fun modelSelectionPersistsTheFullPreferencesDocument() = runBlocking {
        val script = LocalScript().apply { extraModelRows = "," + modelRow(secondModelId, "deepseek-reasoner", "DeepSeek Reasoner") }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(host.conversations.selectModel(session, secondModelId))
        assertTrue(awaitCondition { exchange.commandsOf("config.preferences.save").isNotEmpty() })
        val envelope = exchange.commandsOf("config.preferences.save").first()
        val revision = envelope["revision"]!!.jsonObject
        assertEquals("preferences", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("1", revision["version"]!!.jsonPrimitive.content)
        val payload = envelope["payload"]!!.jsonObject
        // The ORIGINAL document is echoed whole (writer-owned fields kept).
        assertEquals(secondModelId, payload["defaultAgentModelID"]!!.jsonPrimitive.content)
        assertEquals("1", payload["syncRevision"]!!.jsonPrimitive.content)
        assertTrue(payload.containsKey("onboardingStatus"))
        assertTrue(payload.containsKey("auxiliaryImageMode"))
        assertTrue(payload.containsKey("updatedAt"))
        assertFalse(payload.containsKey("selectedModelID"))
        host.stop()
    }

    @Test
    fun runStartModeVocabularyMatchesNativeLaunchModes() {
        assertEquals("chat", ConversationWire.runLaunchMode(AgentExecutionModeUi.AGENT))
        assertEquals("chat", ConversationWire.runLaunchMode(AgentExecutionModeUi.CHAT))
        assertEquals("plan", ConversationWire.runLaunchMode(AgentExecutionModeUi.PLAN))
        assertEquals("goal", ConversationWire.runLaunchMode(AgentExecutionModeUi.GOAL))
    }

    @Test
    fun cancelCarriesDurableStateRevisionAndExpectedState() = runBlocking {
        val script = LocalScript().apply { runState = "streamingModel" }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(host.conversations.cancelRun(session, runId))
        assertTrue(awaitCondition { exchange.commandsOf("run.cancel").isNotEmpty() })
        val envelope = exchange.commandsOf("run.cancel").first()
        val revision = envelope["revision"]!!.jsonObject
        assertEquals("run.${runId.uppercase()}", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("streamingModel", revision["version"]!!.jsonPrimitive.content)
        assertEquals("streamingModel", envelope["payload"]!!.jsonObject["expectedState"]!!.jsonPrimitive.content)
        host.stop()
    }

    @Test
    fun cancelRetriesOnceWithAFreshSnapshotOnStaleRevision() = runBlocking {
        val script = LocalScript().apply {
            runState = "streamingModel"
            cancelRejectOnce = true
            snapshotStateAfterReject = "executingTool"
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(host.conversations.cancelRun(session, runId))
        assertTrue(awaitCondition(3_000) { exchange.commandsOf("run.cancel").size >= 2 })
        val retried = exchange.commandsOf("run.cancel")[1]
        assertEquals(
            "executingTool",
            retried["payload"]!!.jsonObject["expectedState"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "executingTool",
            retried["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content,
        )
        host.stop()
    }

    @Test
    fun approvalRequestProjectsCardAndResolveUsesRealRevision() = runBlocking {
        val script = LocalScript().apply {
            runState = "waitingApproval"
            pendingInputsJson = "[]"
        }
        val exchange = buildExchange(script)
        // The live event channel delivers the durable approval REQUEST once;
        // later polls see the attached window with no new events.
        val delivered = AtomicInteger(0)
        script.eventScript = { correlation ->
            if (delivered.getAndIncrement() == 0) {
                script.pendingApproval = true
                eventPage(
                    correlation, "attached",
                    eventsJson = "[" + event(
                        1, "approval",
                        """{"tool":"workspace.writeFile","callID":"$callId",""" +
                            """"scope":"workspace/notes.md","reason":"Needs approval"}""",
                    ) + "]",
                    nextSequence = 1,
                )
            } else {
                eventPage(correlation, "attached", nextSequence = 1)
            }
        }
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val cardOk = awaitCondition { holder.snapshot.value?.pendingApprovals?.isNotEmpty() == true }
        assertTrue("approval card must render from the durable approval kind", cardOk)
        val card = holder.snapshot.value!!.pendingApprovals.first()
        assertEquals(callId, card.approvalId)
        assertEquals("workspace/notes.md", card.scopeDescription)
        // The snapshot's approvalRevision supplies the requestedAt CAS version.
        val snapshotJson = snapshotValue("waitingApproval", pendingApproval = true)
        assertEquals(true, snapshotJson.contains("approval.$callId"))
        script.eventScript = { correlation -> eventPage(correlation, "attached", nextSequence = 1) }
        host.conversations.resolveApproval(
            com.floe.android.feature.conversation.ApprovalDecisionRequest(
                conversationId = conversationId,
                sessionEpoch = holder.session.sessionEpoch,
                approvalId = callId,
                runId = runId,
                workspaceId = null,
                toolName = "workspace.writeFile",
                decision = ApprovalUserDecisionUi.Allow(ApprovalScopeChoiceUi.ONCE),
                grant = null,
                reason = null,
            ),
        )
        assertTrue(awaitCondition { exchange.commandsOf("run.approval.resolve").isNotEmpty() })
        val envelope = exchange.commandsOf("run.approval.resolve").first()
        val payload = envelope["payload"]!!.jsonObject
        assertEquals(callId, payload["callID"]!!.jsonPrimitive.content)
        assertEquals("allow", payload["decision"]!!.jsonPrimitive.content)
        assertEquals(requestedAt, payload["expectedApprovalVersion"]!!.jsonPrimitive.content)
        assertFalse("scope is never chosen by the payload", payload.containsKey("scope"))
        val revision = envelope["revision"]!!.jsonObject
        assertEquals("approval.$callId", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals(requestedAt, revision["version"]!!.jsonPrimitive.content)
        host.stop()
    }

    @Test
    fun queueAndSteerUseExactNativeGrammars() = runBlocking {
        val script = LocalScript()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(
            host.conversations.submitRunningInput(
                RunningInputRequest(
                    conversationId = conversationId,
                    sessionEpoch = session.sessionEpoch,
                    expectedRunId = runId,
                    content = "queued text",
                    mode = RunningInputModeUi.QUEUE,
                    modelId = modelId,
                    workspaceId = null,
                    executionMode = AgentExecutionModeUi.AGENT,
                    attachments = emptyList(),
                    temporaryIncarnationId = null,
                ),
            ),
        )
        assertTrue(awaitCondition { exchange.commandsOf("run.queue").isNotEmpty() })
        val queueEnvelope = exchange.commandsOf("run.queue").first()
        val queuePayload = queueEnvelope["payload"]!!.jsonObject
        assertEquals(setOf("content", "mode", "selectedModelID"), queuePayload.keys)
        assertEquals("queue", queuePayload["mode"]!!.jsonPrimitive.content)
        assertEquals(
            "conversation.${conversationId.uppercase()}",
            queueEnvelope["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content,
        )
        // Steer: durable queue row first, then run.steer against the run CAS.
        val before = exchange.commandsOf("run.queue").size
        assertTrue(
            host.conversations.submitRunningInput(
                RunningInputRequest(
                    conversationId = conversationId,
                    sessionEpoch = session.sessionEpoch,
                    expectedRunId = runId,
                    content = "steer text",
                    mode = RunningInputModeUi.STEER,
                    modelId = modelId,
                    workspaceId = null,
                    executionMode = AgentExecutionModeUi.AGENT,
                    attachments = emptyList(),
                    temporaryIncarnationId = null,
                ),
            ),
        )
        assertTrue(awaitCondition { exchange.commandsOf("run.steer").isNotEmpty() })
        assertTrue("the steer row is queued first", exchange.commandsOf("run.queue").size > before)
        val steerEnvelope = exchange.commandsOf("run.steer").first()
        val steerPayload = steerEnvelope["payload"]!!.jsonObject
        assertEquals(setOf("inputID", "expectedState"), steerPayload.keys)
        assertEquals(
            "44444444-4444-4444-8444-444444444444",
            steerPayload["inputID"]!!.jsonPrimitive.content,
        )
        assertTrue(steerPayload["expectedState"]!!.jsonPrimitive.content.isNotBlank())
        assertEquals(
            "run.${runId.uppercase()}",
            steerEnvelope["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content,
        )
        host.stop()
    }

    @Test
    fun pendingInputMutationsUseRowVersionsAndQueueRevision() = runBlocking {
        val script = LocalScript().apply {
            pendingInputsJson =
                """[{"inputID":"44444444-4444-4444-8444-444444444444","position":0,""" +
                    """"status":"queued","mode":"queue","inputVersion":"2026-10-20T01:02:04.000Z"}]"""
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(host.conversations.editPendingInput(session, "44444444-4444-4444-8444-444444444444", "edited"))
        assertTrue(awaitCondition { exchange.commandsOf("run.input.edit").isNotEmpty() })
        val edit = exchange.commandsOf("run.input.edit").first()
        assertEquals(
            setOf("inputID", "content", "expectedInputVersion"),
            edit["payload"]!!.jsonObject.keys,
        )
        assertEquals(
            "2026-10-20T01:02:04.000Z",
            edit["payload"]!!.jsonObject["expectedInputVersion"]!!.jsonPrimitive.content,
        )
        assertTrue(host.conversations.removePendingInput(session, "44444444-4444-4444-8444-444444444444"))
        assertTrue(awaitCondition { exchange.commandsOf("run.input.remove").isNotEmpty() })
        assertEquals(
            setOf("inputID", "expectedInputVersion"),
            exchange.commandsOf("run.input.remove").first()["payload"]!!.jsonObject.keys,
        )
        assertTrue(
            host.conversations.reorderPendingInputs(
                session, listOf("44444444-4444-4444-8444-444444444444"),
            ),
        )
        assertTrue(awaitCondition { exchange.commandsOf("run.input.reorder").isNotEmpty() })
        val reorder = exchange.commandsOf("run.input.reorder").first()
        assertEquals(
            setOf("orderedIDs", "expectedQueueVersion"),
            reorder["payload"]!!.jsonObject.keys,
        )
        assertEquals(
            "pendingQueue.${conversationId.uppercase()}",
            reorder["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content,
        )
        host.stop()
    }

    @Test
    fun terminalStatusClosesPumpAndReloadsCommittedRows() = runBlocking {
        val script = LocalScript().apply { runState = "streamingModel" }
        val exchange = buildExchange(script)
        val delivered = AtomicInteger(0)
        script.eventScript = { correlation ->
            if (delivered.getAndIncrement() == 0) {
                // The durable row settles with the same transition the event
                // reports (the later snapshot must not resurrect a dead run).
                script.runState = "failed"
                eventPage(
                    correlation, "attached",
                    eventsJson = "[" + event(
                        1, "status", """{"state":"failed","reason":"provider error"}""",
                    ) + "]",
                    nextSequence = 1,
                )
            } else {
                eventPage(correlation, "attached", nextSequence = 1)
            }
        }
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        assertTrue(
            "the durable terminal status must settle the run",
            awaitCondition {
                val snapshot = holder.snapshot.value
                snapshot != null && snapshot.isRunning == false &&
                    snapshot.liveStateName == "failed" && snapshot.canContinue
            },
        )
        assertTrue(
            "committed message rows must be re-read at the close boundary",
            awaitCondition { exchange.commandsOf("conversation.messagePage").isNotEmpty() },
        )
        // The pump stopped: the event-poll count settles.
        val polls = exchange.requests.count { it.contains("\"operation\":\"event.poll\"") }
        delay(120)
        val after = exchange.requests.count { it.contains("\"operation\":\"event.poll\"") }
        assertTrue("pump must stop after the terminal frame ($polls → $after)", after - polls <= 1)
        host.stop()
    }

    @Test
    fun protocolMismatchSurfacesTypedFailureAndStopsPump() = runBlocking {
        val script = LocalScript().apply { runState = "streamingModel" }
        val exchange = buildExchange(script)
        script.eventScript = { correlation ->
            """{"version":3,"requestID":"$correlation","ok":false,"error":"invalidEnvelope"}"""
        }
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        assertTrue(
            "a pump protocol break must surface a typed line",
            awaitCondition { holder.snapshot.value?.continuationDetail != null },
        )
        assertEquals("eventProtocolMismatch", holder.snapshot.value!!.continuationDetail)
        val polls = exchange.requests.count { it.contains("\"operation\":\"event.poll\"") }
        delay(120)
        val after = exchange.requests.count { it.contains("\"operation\":\"event.poll\"") }
        assertTrue("failed pump must not poll forever ($polls → $after)", after - polls <= 1)
        host.stop()
    }

    @Test
    fun interruptedRunIsNotRunningAndOffersContinue() = runBlocking {
        val script = LocalScript().apply { runState = "interrupted" }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        // A parked dead-generation row opens NO pump: no live window exists.
        delay(80)
        assertTrue(
            "interrupted must not resume a dead pump",
            exchange.requests.none { it.contains("\"operation\":\"event.poll\"") },
        )
        val snapshot = holder.snapshot.value!!
        assertFalse(snapshot.isRunning)
        assertTrue(snapshot.canContinue)
        host.stop()
    }

    @Test
    fun goalCreationLaunchesGoalModeRunStart() = runBlocking {
        val script = LocalScript().apply { freshConversation = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        assertTrue(
            host.conversations.createGoal(
                GoalCreateRequest(
                    conversationId = conversationId,
                    sessionEpoch = holder.session.sessionEpoch,
                    objective = "Ship the ordinary chat path",
                    criteria = listOf("send works", "cancel works"),
                    blockingConditions = listOf("no provider"),
                    stoppingConditions = listOf("verified"),
                ),
            ),
        )
        assertTrue(awaitCondition { exchange.commandsOf("run.start").isNotEmpty() })
        val payload = exchange.commandsOf("run.start").first()["payload"]!!.jsonObject
        assertEquals("goal", payload["mode"]!!.jsonPrimitive.content)
        val goal = payload["goal"]!!.jsonPrimitive.content
        assertTrue(goal.contains("Ship the ordinary chat path"))
        assertTrue(goal.contains("send works"))
        assertEquals(modelId, payload["modelID"]!!.jsonPrimitive.content)
        assertEquals(providerId, payload["providerID"]!!.jsonPrimitive.content)
        host.stop()
    }

    @Test
    fun childListAndEntriesProjectRealPages() = runBlocking {
        val script = LocalScript()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        assertTrue(
            awaitCondition { holder.snapshot.value?.childRuns?.isNotEmpty() == true },
        )
        val child = holder.snapshot.value!!.childRuns.first()
        assertEquals(childId, child.id)
        assertEquals("completed", child.stateName)
        assertTrue(child.isTerminal)
        val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
        assertTrue(host.conversations.loadChildRunDetail(session, childId))
        assertTrue(
            awaitCondition {
                holder.snapshot.value?.childDetails?.get(childId)?.rows?.isNotEmpty() == true
            },
        )
        val rows = holder.snapshot.value!!.childDetails.getValue(childId).rows
        val event = rows.first() as com.floe.android.feature.conversation.TimelineRowUi.Event
        assertEquals("child answer", event.event.assistantText)
        host.stop()
    }

    @Test
    fun unopenedHistoryMutationResolvesTheRealRevision() = runBlocking {
        val script = LocalScript()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        // No holder exists for this row: the previous code refused it.
        assertTrue(host.conversations.archiveConversation(conversationId))
        assertTrue(awaitCondition { exchange.commandsOf("conversation.archive").isNotEmpty() })
        assertTrue(
            "the action-time revision read is required",
            exchange.commandsOf("conversation.get").isNotEmpty(),
        )
        val envelope = exchange.commandsOf("conversation.archive").first()
        assertEquals(
            "conversation.${conversationId.uppercase()}",
            envelope["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content,
        )
        assertEquals("digest-1", envelope["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content)
        assertEquals("true", envelope["payload"]!!.jsonObject["archived"]!!.jsonPrimitive.content)
        host.stop()
    }

    @Test
    fun runSnapshotTypedCarrierFeedsTheCasProjection() = runBlocking {
        val script = LocalScript().apply {
            runState = "waitingApproval"
            pendingInputsJson =
                """[{"inputID":"44444444-4444-4444-8444-444444444444","position":0,""" +
                    """"status":"queued","mode":"queue","inputVersion":"2026-10-20T09:09:09.000Z"}]"""
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val holder = loadedHolder(host)
        assertTrue(
            awaitCondition { exchange.commandsOf("run.snapshot").isNotEmpty() },
        )
        // The typed page settles as the effect `value` (F7 carrier) and the
        // builder reads the real revision + pending-input version from it.
        assertTrue(
            awaitCondition {
                holder.snapshot.value?.pendingInputs?.any {
                    it.id == "44444444-4444-4444-8444-444444444444"
                } == true
            },
        )
        val entry = host.conversations.entryFor(conversationId)!!
        assertEquals(
            "run.${runId.uppercase()}",
            entry.builder.runRevision(runId)?.resourceID,
        )
        assertEquals(
            "2026-10-20T09:09:09.000Z",
            entry.builder.inputVersion("44444444-4444-4444-8444-444444444444"),
        )
        host.stop()
    }

    private companion object {
        val EXPECTED_RUN_START_KEYS = setOf(
            "goal", "mode", "providerID", "modelID", "stagedAttachments",
            "toolCeiling", "approvalMode", "recoveryPolicy", "notificationPolicy",
            "environmentID", "jobID",
        )
    }
}
