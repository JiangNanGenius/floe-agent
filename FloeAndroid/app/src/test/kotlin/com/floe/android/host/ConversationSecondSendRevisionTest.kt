// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import androidx.compose.ui.text.input.TextFieldValue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Second-send stale conversation-revision regression (App producer fix).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json.
 *
 * The scripted transport enforces the REAL Core `run.start` conversationProof
 * CAS: a `run.start` whose envelope revision version does not equal the
 * CURRENT conversation-row digest is rejected with the exact production
 * signature `{"kind":"rejected","code":"ordinaryRuntimeBlocked","reason":"revisionMismatch"}`,
 * and every accepted `run.start` advances the digest (the durable user-message
 * commit). Under the pre-fix cached-revision path the SECOND send on the same
 * screen reuses the first send's digest and is rejected here — the exact
 * observed production failure (E/FloeRunFailure op=run.start
 * code=ordinaryRuntimeBlocked reason=revisionMismatch phase=conversationProof).
 */
class ConversationSecondSendRevisionTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val runId = "22222222-2222-4222-8222-222222222222"

    // ------------------------------------------------------------- transport

    /**
     * CAS-enforcing double of the real v3 wire. [currentDigest] models the
     * Core conversation-row digest; it advances on every accepted run.start
     * exactly like the durable launch/message commits do.
     */
    private inner class CasExchange(
        /** Durable run state reported by conversation.get replies. */
        var runState: String = "idle",
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        /** Core-side conversation-row digest; advances per accepted launch. */
        @Volatile var currentDigest = "digest-1"

        /** run.start commands rejected for a stale revision (Core behavior). */
        val staleRunStartRejects = AtomicInteger(0)

        /** prepared effects emitted for accepted run.start commands. */
        val preparedCount = AtomicInteger(0)

        /** conversation.get commands seen (load + launch reads). */
        val conversationGetCount = AtomicInteger(0)

        /** Revision version the most recent run.start command carried. */
        @Volatile private var lastRunStartRevision: String? = null

        /** When true, effect polls for the launch conversation.get park. */
        @Volatile var holdLaunchConversationGetEffects = false
        val launchConversationGetSeen = CountDownLatch(1)
        private val releaseLaunchConversationGet = CountDownLatch(1)

        fun releaseHeldConversationGet() {
            releaseLaunchConversationGet.countDown()
        }

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") -> eventPollPage(correlation)
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    when (receipt) {
                        "op:v1:providers" -> effect(
                            correlation, "providers",
                            accepted("""{"rows":[${providerRow()}]}"""),
                        )
                        "op:v1:models" -> effect(
                            correlation, "models",
                            accepted("""{"rows":[${modelRow()}]}"""),
                        )
                        "op:v1:preferences" -> effect(
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
                        "op:v1:cget" -> {
                            if (holdLaunchConversationGetEffects &&
                                conversationGetCount.get() >= 2
                            ) {
                                launchConversationGetSeen.countDown()
                                releaseLaunchConversationGet.await(5, TimeUnit.SECONDS)
                            }
                            effect(correlation, "cget", accepted(conversationReply()))
                        }
                        "op:v1:runStart" -> {
                            val expected = currentDigest
                            val supplied = lastRunStartRevision
                            if (supplied == expected) {
                                // The durable commit advances the row digest.
                                currentDigest = nextDigest(currentDigest)
                                runState = "completed"
                                preparedCount.incrementAndGet()
                                effect(
                                    correlation, "runStart",
                                    """{"sequence":1,"kind":"prepared","detail":[""" +
                                        """{"key":"conversationID","value":"$conversationId"},""" +
                                        """{"key":"runID","value":"$runId"},""" +
                                        """{"key":"resourceID","value":"run.${runId.uppercase()}"},""" +
                                        """{"key":"version","value":"preparing"}]},""" +
                                        accepted(
                                            """{"conversationID":"$conversationId",""" +
                                                """"runID":"$runId"}""",
                                            sequence = 2,
                                        ),
                                )
                            } else {
                                staleRunStartRejects.incrementAndGet()
                                effect(
                                    correlation, "runStart",
                                    """{"sequence":1,"kind":"rejected",""" +
                                        """"code":"ordinaryRuntimeBlocked",""" +
                                        """"detail":[{"key":"reason","value":"revisionMismatch"}]}""",
                                )
                            }
                        }
                        "op:v1:runSnapshot" ->
                            effect(correlation, "runSnapshot", accepted(runSnapshot()))
                        "op:v1:queue" -> effect(
                            correlation, "queue",
                            accepted(
                                null,
                                detailJson = """[{"key":"inputID","value":"44444444-4444-4444-8444-444444444444"},""" +
                                    """{"key":"position","value":"0"},""" +
                                    """{"key":"status","value":"queued"},""" +
                                    """{"key":"inputVersion","value":"2026-10-20T01:02:04.000Z"}]""",
                            ),
                        )
                        "op:v1:messagePage" -> effect(
                            correlation, "messagePage",
                            accepted("""{"rows":[],"hasEarlier":false,"earlierCursor":null}"""),
                        )
                        else -> effect(correlation, receipt, accepted(null))
                    }
                }
                request.contains("\"command\":\"conversation.get\"") -> {
                    conversationGetCount.incrementAndGet()
                    receipt(correlation, "cget")
                }
                request.contains("\"command\":\"run.start\"") -> {
                    lastRunStartRevision = revisionVersionOf(request)
                    receipt(correlation, "runStart")
                }
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "runSnapshot")
                request.contains("\"command\":\"run.queue\"") ->
                    receipt(correlation, "queue")
                request.contains("\"command\":\"conversation.messagePage\"") ->
                    receipt(correlation, "messagePage")
                request.contains("\"command\":\"config.providers.list\"") ->
                    receipt(correlation, "providers")
                request.contains("\"command\":\"config.models.list\"") ->
                    receipt(correlation, "models")
                request.contains("\"command\":\"config.preferences.get\"") ->
                    receipt(correlation, "preferences")
                else -> receipt(correlation, "other")
            }
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") return@mapNotNull null
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) return@mapNotNull null
            envelope
        }

        private fun nextDigest(digest: String): String {
            val n = digest.removePrefix("digest-").toIntOrNull() ?: 1
            return "digest-${n + 1}"
        }

        private fun revisionVersionOf(raw: String): String? =
            runCatching {
                val root = Json.parseToJsonElement(raw).jsonObject
                root["envelope"]?.jsonObject
                    ?.get("revision")?.jsonObject
                    ?.get("version")?.jsonPrimitive?.content
            }.getOrNull()

        private fun providerRow(): String =
            """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
                """"baseURL":"https://example.invalid/v1","displayName":"DeepSeek Cloud QA",""" +
                """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
                """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
                """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
                """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

        private fun modelRow(): String =
            """{"id":"$modelId","providerID":"$providerId","remoteModelID":"deepseek-flash",""" +
                """"displayName":"DeepSeek Cloud QA","limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
                """"capabilities":{"rawValue":7},"explicitCapabilities":null,"useSurfaces":null,""" +
                """"reasoningEffort":"automatic","isEnabled":true,"isHiddenFromPrimaryPicker":false,""" +
                """"revision":{"resourceID":"model.$modelId","version":"digest"}}"""

        private fun conversationReply(): String =
            """{"conversationID":"$conversationId","title":"Task",""" +
                """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
                """"version":"$currentDigest"},""" +
                """"runs":[{"runID":"$runId","state":"$runState",""" +
                """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-20T01:00:00.000Z"}],""" +
                """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

        private fun runSnapshot(): String =
            """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
                """"runID":"$runId","durableState":"$runState",""" +
                """"revision":{"resourceID":"run.${runId.uppercase()}","version":"$runState"},""" +
                """"isTerminal":false,"conversationMode":"chat","goal":"hi","liveOwner":false,""" +
                """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
                """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
                """"version":"queue-digest-1"},"durableWatermark":4}"""

        private fun receipt(correlation: String, receiptTag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$receiptTag"}"""

        private fun accepted(valueJson: String?, detailJson: String = "", sequence: Int = 1): String {
            val value = if (valueJson == null) "" else ""","value":$valueJson"""
            val detail = if (detailJson.isBlank()) "" else ""","detail":$detailJson"""
            return """{"sequence":$sequence,"kind":"accepted"$value$detail}"""
        }

        private fun eventPollPage(correlation: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.event-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"runID":"$runId","sequence":0},""" +
                """"durable":{"windowState":"attached","events":[],"hasMore":false,""" +
                """"resyncRequired":false,"nextSequence":0},""" +
                """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
                """"resyncRequired":false}"""

        private fun effect(
            correlation: String,
            receiptTag: String,
            effectsJson: String,
            sequence: Long = 2,
        ): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
                """"sequence":$sequence},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""
    }

    // ----------------------------------------------------------------- hosts

    private fun client(exchange: HostBridgeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 1),
    )

    private fun host(exchange: HostBridgeExchange): RuntimeHost = RuntimeHost(
        commandClient = client(exchange),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private suspend fun readyHost(exchange: HostBridgeExchange): RuntimeHost {
        val host = host(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.providers.refreshProviders()
        host.conversations.refreshModels()
        val deadline = System.nanoTime() + 2_000_000_000L
        while (host.conversations.modelOptions().isEmpty() && System.nanoTime() < deadline) {
            delay(10)
        }
        return host
    }

    private suspend fun loadedHolder(
        host: RuntimeHost,
    ): com.floe.android.feature.conversation.ConversationFlowHolder {
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(holder.session)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (holder.snapshot.value == null && System.nanoTime() < deadline) delay(10)
        return holder
    }

    private suspend fun awaitCondition(timeoutMillis: Long = 3_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    // ----------------------------------------------------------------- tests

    /**
     * THE regression: first cloud send succeeds; the row digest advances with
     * the durable commit; the immediate second send on the same open screen
     * MUST re-read the current row and launch under the NEW digest. The
     * transport rejects any stale revision with the production signature, so
     * the pre-fix cached-revision path fails here (staleRunStartRejects > 0,
     * second prepared never arrives).
     */
    @Test
    fun secondSendOnSameScreenReadsFreshRowRevision() = runBlocking {
        val exchange = CasExchange(runState = "idle")
        val host = readyHost(exchange)
        val holder = loadedHolder(host)

        holder.onDraftChange(TextFieldValue("first question"))
        val first = holder.send()
        assertTrue(
            "first send must be admitted: $first",
            first is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )
        // Holder-side proof the prepared echo was consumed (commit released);
        // sending again before that would be an OPERATION_IN_FLIGHT rejection.
        assertTrue(
            "first prepared echo must land in the holder",
            awaitCondition {
                exchange.preparedCount.get() >= 1 &&
                    holder.snapshot.value?.selectedRunId == runId &&
                    holder.snapshot.value?.runs?.any { it.id == runId && it.stateName == "completed" } == true
            },
        )
        // The accepted run.start advanced the Core row digest.
        assertEquals("digest-2", exchange.currentDigest)

        holder.onDraftChange(TextFieldValue("second question"))
        val second = holder.send()
        assertTrue(
            "second send must be admitted: $second",
            second is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )
        assertTrue(
            "second prepared echo must land (pre-fix: stale revision rejected)",
            awaitCondition { exchange.preparedCount.get() >= 2 },
        )

        val starts = exchange.commandsOf("run.start")
        assertEquals("exactly two launches, no replay", 2, starts.size)
        assertEquals(
            "first launch uses the row revision read at open",
            "digest-1",
            starts[0]["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "second launch MUST use the fresh row revision, not the cached one",
            "digest-2",
            starts[1]["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "the transport enforces CAS: no stale revision ever left the App",
            0,
            exchange.staleRunStartRejects.get(),
        )
        host.stop()
    }

    /**
     * Draft restore contract: when the action-time revision read itself
     * fails, the launch never reaches the wire, the outcome listener gets the
     * typed failure and the COMPLETE original draft is restored.
     */
    @Test
    fun failedFreshRevisionReadRestoresDraftAndNeverStartsRun() = runBlocking {
        val inner = CasExchange(runState = "idle")
        val exchange = FailingGetExchange(inner, failFromGet = 2)
        val host = readyHost(exchange)
        val holder = loadedHolder(host)

        holder.onDraftChange(TextFieldValue("restore me"))
        val outcome = AtomicReference<Boolean?>(null)
        val result = holder.send { admitted, _ -> outcome.set(admitted) }
        assertTrue(
            "send must be admitted pre-flight: $result",
            result is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )
        assertTrue("launch must settle failed", awaitCondition { outcome.get() == false })
        assertTrue("no run.start may leave the App", inner.commandsOf("run.start").isEmpty())
        assertEquals("restore me", holder.draft.value.text)
        assertEquals("revision_unavailable", holder.actionError)
        host.stop()
    }

    /**
     * Owner/epoch fencing across the await: a launch whose action-time read
     * returns AFTER the holder was retired by a genuine navigation must never
     * issue run.start — the late reply cannot launch into a dead session.
     */
    @Test
    fun lateFreshReadNeverLaunchesAfterRetirement() = runBlocking {
        val exchange = CasExchange(runState = "idle")
        exchange.holdLaunchConversationGetEffects = true
        val host = readyHost(exchange)
        val holder = loadedHolder(host)

        holder.onDraftChange(TextFieldValue("into the void"))
        val outcome = AtomicReference<Boolean?>(null)
        val result = holder.send { admitted, _ -> outcome.set(admitted) }
        assertTrue(
            "send must be admitted pre-flight: $result",
            result is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )

        assertTrue(
            "launch revision read must be in flight",
            exchange.launchConversationGetSeen.await(5, TimeUnit.SECONDS),
        )
        holder.retireForNavigation()
        exchange.releaseHeldConversationGet()
        delay(300)

        assertTrue(
            "no run.start may leave the App after retirement",
            exchange.commandsOf("run.start").isEmpty(),
        )
        assertEquals("launch settles failed", false, outcome.get())
        host.stop()
    }

    /**
     * The while-live path is untouched: with a run in an ACTIVE state the
     * second send still goes through run.queue (never run.start) and the
     * queue CAS carries the action-time fresh row revision.
     */
    @Test
    fun liveRunningSendStillUsesQueuePathWithoutRunStart() = runBlocking {
        val exchange = CasExchange(runState = "streamingModel")
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(
            "scripted run must project as live",
            awaitCondition { holder.snapshot.value?.isRunning == true },
        )

        holder.onDraftChange(TextFieldValue("mid-run steer text"))
        val result = holder.send()
        assertTrue(
            "live send must be accepted: $result",
            result is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )
        assertTrue(
            "queue command must land",
            awaitCondition { exchange.commandsOf("run.queue").isNotEmpty() },
        )
        assertTrue(
            "a live send never mints a new run",
            exchange.commandsOf("run.start").isEmpty(),
        )
        val queue = exchange.commandsOf("run.queue").first()
        assertEquals(
            "conversation.${conversationId.uppercase()}",
            queue["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "queue revision is the action-time row revision",
            exchange.currentDigest,
            queue["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content,
        )
        host.stop()
    }

    /**
     * Wraps a [CasExchange] and turns the Nth conversation.get effect onward
     * into a typed failure, modelling a store read failure at action time.
     */
    private class FailingGetExchange(
        private val inner: CasExchange,
        private val failFromGet: Int,
    ) : HostBridgeExchange {
        private val getCount = AtomicInteger(0)

        override fun exchange(request: String): String {
            if (request.contains("\"command\":\"conversation.get\"")) {
                getCount.incrementAndGet()
                return inner.exchange(request)
            }
            if (request.contains("\"operation\":\"effect.poll\"") &&
                receiptOf(request) == "op:v1:cget" &&
                getCount.get() >= failFromGet
            ) {
                val correlation = correlationOf(request)
                inner.requests.add(request)
                return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                    """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:cget",""" +
                    """"sequence":1},"effects":[{"sequence":1,"kind":"rejected",""" +
                    """"code":"storeReadFailed","detail":[{"key":"reason","value":"read_failed"}]}],""" +
                    """"hasMore":false,"resyncRequired":false}"""
            }
            return inner.exchange(request)
        }
    }
}
