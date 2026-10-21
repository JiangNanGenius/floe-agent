// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.TimelineRowUi
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Root NEW-TASK -> NEW-CONVERSATION first-send committed-row projection.
 *
 * Reproduces the ACTUAL Alpha3 device failure Main observed on the current
 * signed Full APK (versionCode 3, `e5fcc493…`):
 *
 * * an ordinary New Task sends its first prompt through `conversation.create`
 *   + `run.start` on a BRAND-NEW conversation;
 * * the launch commit durably writes the user turn and the run completes with
 *   a real assistant answer (re-entering the thread later shows both rows);
 * * the LIVE thread body stayed at the pre-launch "No messages yet" page for
 *   the whole run: the first committed page read happens BEFORE the launch,
 *   and the only later read (the terminal close boundary) either raced the
 *   native commit or failed transiently. That read was treated as settled, so
 *   the close boundary was marked reconciled and nothing ever refreshed again
 *   until navigation re-read the thread.
 *
 * Contract under test (App producer/projection only — the native wire, the
 * command grammar, the durable store and the run contract are untouched):
 *
 * * the launch commit (`prepared`) is a real durable boundary: the committed
 *   user turn (and any already-committed assistant turn) is read from the
 *   ORIGINAL page authority, never synthesized;
 * * a close-boundary page that is empty for a run that just committed, or a
 *   transient page failure, is NOT the settled truth: it is retried a bounded
 *   number of times, forever fenced on holder/session/run/stream generation;
 * * an existing conversation's follow-up turn keeps appending exactly as it
 *   does today (follow-up live rendering already passes on the device);
 * * late replies for a retired holder or a replaced run never publish.
 *
 * Transport is a scripted double of the actual v3 wire (producer shapes:
 * effect pages with typed `value` carriers, event-cursor pages with a
 * JSON-string payload). No native code, no device, no network.
 */
class ConversationNewThreadFirstSendProjectionTest {

    @Test fun replacementHolderHasAUniqueSessionAndRejectsTheOldAttachmentOwner() = runBlocking {
        val host = host(ScriptedExchange())
        try {
            val first = host.conversations.holderFor(conversationId, isTemporary = false, incarnationId = null)
            val old = first.session
            host.conversations.releaseHolder(conversationId)
            val replacement = host.conversations.holderFor(conversationId, isTemporary = false, incarnationId = null)
            assertTrue(old.sessionEpoch != replacement.session.sessionEpoch)
            assertFalse(host.conversations.attachmentSessionIsCurrent(old))
            assertTrue(host.conversations.attachmentSessionIsCurrent(replacement.session))
            assertEquals(replacement.session, host.conversations.entryFor(conversationId)!!.builder.build().session)
        } finally { host.stop() }
    }

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val firstRunId = "22222222-2222-4222-8222-222222222222"
    private val secondRunId = "33333333-3333-4333-8333-333333333333"

    private val firstPrompt = "Reply only ALPHA3_LIVE_FIRST_OK."
    private val firstAnswer = "ALPHA3_LIVE_FIRST_OK"
    private val followupPrompt = "Reply only ALPHA3_LIVE_FOLLOWUP_OK."
    private val followupAnswer = "ALPHA3_LIVE_FOLLOWUP_OK"

    // ------------------------------------------------------------- transport

    /**
     * Scripted transport that models the REAL commit ordering of the original
     * launch store: the user turn is durable with the launch commit (before
     * `prepared`), the assistant turn becomes durable just before the terminal
     * event. [pageScript] can override individual `conversation.messagePage`
     * replies to reproduce the observed close-boundary race/failure.
     */
    private inner class ScriptedExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        val runStartCount = AtomicInteger(0)
        val messagePageReads = AtomicInteger(0)
        val messagePageSubmits = AtomicInteger(0)
        val conversationGetCount = AtomicInteger(0)

        /** The FIRST turn of this conversation is durably committed. */
        @Volatile var firstTurnDurable = false
        @Volatile var firstAssistantDurable = false

        /** A later turn was launched on the SAME conversation. */
        @Volatile var secondRunStarted = false
        @Volatile var secondAssistantDurable = false
        @Volatile var activeRunID = firstRunId
        @Volatile var runState = "preparing"

        /**
         * Read-ordinal (1 = the pre-launch load read) → effect frame body.
         * `null` uses the real committed-page projection.
         */
        @Volatile var pageScript: ((Int) -> String)? = null

        /**
         * Post-launch reads that must still answer EMPTY while the native
         * commit is not yet visible to the page reader (the observed race).
         */
        @Volatile var pageLagReads: Int = 0

        /** Post-launch reads that must fail transiently (pump/store edge). */
        @Volatile var failNextPageReads: Int = 0

        /** Controlled deferral of the NEXT message-page RESPONSE. */
        @Volatile var holdNextPage: Boolean = false
        @Volatile var nextPageOverride: String? = null
        val heldPageCaptured = CountDownLatch(1)
        val releaseHeldPage = CountDownLatch(1)

        /** Latest-window paging state served by the committed page. */
        @Volatile var latestHasEarlier: Boolean = false
        @Volatile var latestEarlierCursor: String? = null
        @Volatile var earlierRowsJson: String? = null

        private val pendingEvents = CopyOnWriteArrayList<Pair<String, String>>()
        private var nextSequence = 0L

        fun queueEvent(kind: String, payload: String) {
            pendingEvents.add(kind to payload)
        }

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") -> eventPage(correlation)
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val polled = receiptOf(request)
                    when {
                        polled == "op:v1:providers" -> effect(
                            correlation, "providers",
                            accepted("""{"rows":[${providerRow()}]}"""),
                        )
                        polled == "op:v1:models" -> effect(
                            correlation, "models",
                            accepted("""{"rows":[${modelRow()}]}"""),
                        )
                        polled == "op:v1:preferences" -> effect(
                            correlation, "preferences", accepted(preferencesValue()),
                        )
                        polled == "op:v1:conversationCreate" -> effect(
                            correlation, "conversationCreate",
                            accepted("""{"conversationID":"$conversationId"}"""),
                        )
                        polled == "op:v1:conversationGet" -> {
                            conversationGetCount.incrementAndGet()
                            effect(correlation, "conversationGet", accepted(conversationReply()))
                        }
                        polled.startsWith("op:v1:messagePage") -> {
                            val ordinal = messagePageReads.incrementAndGet()
                            val isEarlier = request.contains("\"before\"")
                            val override = nextPageOverride.also { nextPageOverride = null }
                            val scripted = pageScript?.invoke(ordinal)
                            val body = override ?: when {
                                isEarlier -> accepted(earlierPageValue())
                                scripted != null -> scripted
                                firstTurnDurable && failNextPageReads > 0 -> {
                                    failNextPageReads -= 1
                                    """{"sequence":1,"kind":"failed",""" +
                                        """"code":"messagePageUnavailable"}"""
                                }
                                firstTurnDurable && pageLagReads > 0 -> {
                                    pageLagReads -= 1
                                    accepted(
                                        """{"rows":[],"hasEarlier":false,"earlierCursor":null}""",
                                    )
                                }
                                else -> accepted(messagePageValue())
                            }
                            if (holdNextPage) {
                                holdNextPage = false
                                heldPageCaptured.countDown()
                                releaseHeldPage.await(10, TimeUnit.SECONDS)
                            }
                            effect(correlation, polled.removePrefix("op:v1:"), body)
                        }
                        polled == "op:v1:runStart" -> {
                            runStartCount.incrementAndGet()
                            if (!firstTurnDurable) {
                                firstTurnDurable = true
                                activeRunID = firstRunId
                            } else {
                                secondRunStarted = true
                                activeRunID = secondRunId
                            }
                            runState = "streamingModel"
                            effect(
                                correlation, "runStart",
                                """{"sequence":1,"kind":"prepared","detail":${detail(
                                    "conversationID" to conversationId,
                                    "runID" to activeRunID,
                                    "resourceID" to "run.${activeRunID.uppercase()}",
                                    "version" to "preparing",
                                )}},""" + accepted(
                                    """{"conversationID":"$conversationId","runID":"$activeRunID"}""",
                                    sequence = 2,
                                ),
                            )
                        }
                        polled == "op:v1:runSnapshot" -> effect(
                            correlation, "runSnapshot",
                            accepted(snapshotValue(runState)),
                        )
                        else -> effect(correlation, polled.removePrefix("op:v1:"), accepted(null))
                    }
                }
                request.contains("\"command\":\"config.providers.list\"") ->
                    receipt(correlation, "providers")
                request.contains("\"command\":\"config.models.list\"") ->
                    receipt(correlation, "models")
                request.contains("\"command\":\"config.preferences.get\"") ->
                    receipt(correlation, "preferences")
                request.contains("\"command\":\"conversation.create\"") ->
                    receipt(correlation, "conversationCreate")
                request.contains("\"command\":\"conversation.get\"") ->
                    receipt(correlation, "conversationGet")
                request.contains("\"command\":\"conversation.messagePage\"") ->
                    // The real native producer mints a UNIQUE operation
                    // receipt per submission; a constant tag would collide
                    // two page pumps in the double.
                    receipt(correlation, "messagePage-" + messagePageSubmits.incrementAndGet())
                request.contains("\"command\":\"run.start\"") ->
                    receipt(correlation, "runStart")
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "runSnapshot")
                else -> receipt(correlation, "other")
            }
        }

        fun pageRowsJson(): String {
            if (!firstTurnDurable) return "[]"
            val rows = mutableListOf(firstUserRow())
            if (firstAssistantDurable) rows.add(firstAssistantRow())
            if (secondRunStarted) {
                rows.add(followupUserRow())
                if (secondAssistantDurable) rows.add(followupAssistantRow())
            }
            return rows.joinToString(",")
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") return@mapNotNull null
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) return@mapNotNull null
            envelope
        }

        private fun conversationReply(): String {
            fun stateOf(id: String): String = if (id == activeRunID) runState else "completed"
            val runs = buildList {
                if (secondRunStarted) {
                    add("""{"runID":"$secondRunId","state":"${stateOf(secondRunId)}",""" +
                        """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-21T10:08:00.000Z"}""")
                }
                if (firstTurnDurable) {
                    add("""{"runID":"$firstRunId","state":"${stateOf(firstRunId)}",""" +
                        """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-21T10:05:00.000Z"}""")
                }
            }
            return """{"conversationID":"$conversationId","title":"$firstPrompt",""" +
                """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
                """"version":"digest-1"},"runs":[${runs.joinToString(",")}],"pendingInputs":[],""" +
                """"taskPolicy":{"resolvedApprovalMode":"ask"}}"""
        }

        /** The ACTUAL committed `conversation.messagePage` producer page. */
        private fun messagePageValue(): String {
            val cursor = latestEarlierCursor?.let { "\"$it\"" } ?: "null"
            return """{"rows":[${pageRowsJson()}],"hasEarlier":$latestHasEarlier,""" +
                """"earlierCursor":$cursor}"""
        }

        /** An earlier-history (`before != null`) page append. */
        private fun earlierPageValue(): String =
            """{"rows":[${earlierRowsJson ?: ""}],"hasEarlier":false,"earlierCursor":null}"""

        fun firstUserRow(): String =
            """{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"user",""" +
                """"content":"$firstPrompt","createdAt":"2026-10-21T10:05:00.000Z",""" +
                """"runID":"$firstRunId"}"""

        fun firstAssistantRow(): String =
            """{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"assistant",""" +
                """"content":"$firstAnswer","createdAt":"2026-10-21T10:06:30.000Z",""" +
                """"runID":"$firstRunId"}"""

        fun followupUserRow(): String =
            """{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","role":"user",""" +
                """"content":"$followupPrompt","createdAt":"2026-10-21T10:08:00.000Z",""" +
                """"runID":"$secondRunId"}"""

        fun followupAssistantRow(): String =
            """{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","role":"assistant",""" +
                """"content":"$followupAnswer","createdAt":"2026-10-21T10:09:00.000Z",""" +
                """"runID":"$secondRunId"}"""

        private fun eventPage(correlation: String): String {
            val events = StringBuilder()
            var next = nextSequence
            while (pendingEvents.isNotEmpty() && events.length < 24_000) {
                val (kind, payload) = pendingEvents.removeAt(0)
                next += 1
                if (kind == "status" && payload.contains("\"completed\"")) {
                    // The assistant row becomes durable just before the
                    // terminal marker (native ordering rule).
                    if (secondRunStarted) {
                        secondAssistantDurable = true
                    } else {
                        firstAssistantDurable = true
                    }
                    runState = "completed"
                }
                if (events.isNotEmpty()) events.append(',')
                val escaped = payload.replace("\\", "\\\\").replace("\"", "\\\"")
                events.append(
                    """{"sequence":$next,"kind":"$kind","createdAt":1,"payload":"$escaped"}""",
                )
            }
            nextSequence = next
            return """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"runID":"$activeRunID","sequence":$next},""" +
                """"durable":{"windowState":"attached","events":[$events],"hasMore":false,""" +
                """"resyncRequired":false,"nextSequence":$next},""" +
                """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
                """"resyncRequired":false}"""
        }

        private fun snapshotValue(state: String): String =
            """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
                """"runID":"$activeRunID","durableState":"$state",""" +
                """"revision":{"resourceID":"run.${activeRunID.uppercase()}","version":"$state"},""" +
                """"isTerminal":${state == "completed"},"conversationMode":"chat","goal":"hi",""" +
                """"liveOwner":true,"pendingApproval":null,"approvalRevision":null,""" +
                """"pendingInputs":[],"queueRevision":null,"durableWatermark":4}"""

        private fun providerRow(): String =
            """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
                """"baseURL":"https://example.invalid/v1","displayName":"DeepSeek Cloud QA",""" +
                """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
                """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
                """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
                """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

        private fun modelRow(): String =
            """{"id":"$modelId","providerID":"$providerId","remoteModelID":"deepseek-flash",""" +
                """"displayName":"DeepSeek Cloud QA","limits":{"contextTokens":128000,""" +
                """"maxOutputTokens":8192},"capabilities":{"rawValue":7},""" +
                """"explicitCapabilities":null,"useSurfaces":null,""" +
                """"reasoningEffort":"automatic","isEnabled":true,"isHiddenFromPrimaryPicker":false,""" +
                """"revision":{"resourceID":"model.$modelId","version":"digest"}}"""

        private fun preferencesValue(): String =
            """{"revision":{"resourceID":"preferences","version":"1"},""" +
                """"preferences":{"onboardingStatus":"seen",""" +
                """"defaultAgentModelID":"$modelId","generalAuxiliaryLLMModelID":null,""" +
                """"canvasAgentModelID":null,"visionModelID":null,"canvasVisionModelID":null,""" +
                """"approvalModelID":null,"packageReviewModelID":null,"autonomousImageRouting":false,""" +
                """"auxiliaryImageMode":"shared","sharedImageModelID":null,""" +
                """"imageGenerationModelID":null,"imageEditingModelID":null,""" +
                """"defaultVideoModelID":null,""" +
                """"updatedAt":770000000.0,"syncRevision":1}}"""

        private fun receipt(correlation: String, tag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$tag"}"""

        private fun accepted(valueJson: String?, sequence: Int = 1): String {
            val value = if (valueJson == null) "" else ""","value":$valueJson"""
            return """{"sequence":$sequence,"kind":"accepted"$value}"""
        }

        private fun detail(vararg pairs: Pair<String, String>): String =
            pairs.joinToString(",", "[", "]") { (k, v) -> """{"key":"$k","value":"$v"}""" }

        private fun effect(correlation: String, tag: String, effectsJson: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$tag",""" +
                """"sequence":2},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""
    }

    // ------------------------------------------------------------------ host

    private fun host(exchange: HostBridgeExchange): RuntimeHost = RuntimeHost(
        commandClient = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        ),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private suspend fun readyHost(exchange: HostBridgeExchange): RuntimeHost {
        val host = host(exchange)
        host.conversations.start()
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.home.start()
        val deadline = System.nanoTime() + 3_000_000_000L
        while (host.home.modelLabel.value == null && System.nanoTime() < deadline) delay(10)
        return host
    }

    private suspend fun awaitUntil(timeoutMillis: Long = 5_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    private fun texts(host: RuntimeHost): List<String> =
        host.conversations.entryFor(conversationId)?.holder?.snapshot?.value
            ?.rows.orEmpty().mapNotNull { row ->
                when (row) {
                    is TimelineRowUi.UserMessage -> row.message.text
                    is TimelineRowUi.AssistantMessage -> row.text
                    else -> null
                }
            }

    private fun emptyPageFrame(): String =
        """{"sequence":1,"kind":"accepted","value":""" +
            """{"rows":[],"hasEarlier":false,"earlierCursor":null}}"""

    private fun rowsPageFrame(exchange: ScriptedExchange): String =
        """{"sequence":1,"kind":"accepted","value":""" +
            """{"rows":[${exchange.pageRowsJson()}],"hasEarlier":false,"earlierCursor":null}}"""

    private fun failedPageFrame(): String =
        """{"sequence":1,"kind":"failed","code":"messagePageUnavailable"}"""

    // --------------------------------------------------------------- scenario

    /**
     * The exact Alpha3 reproduction: a brand-new ordinary conversation whose
     * first page read is empty BEFORE the launch, and whose terminal
     * close-boundary read is still empty because it raced the native commit.
     * The real durable rows must still reach the SAME screen, without any
     * navigation and without an optimistic fabricated row.
     */
    @Test
    fun newConversationFirstSendSettlesDurableRowsWithoutNavigation() = runBlocking {
        val exchange = ScriptedExchange()
        // Two post-launch reads (the launch read and the first close-boundary
        // read) still race the native commit and answer empty.
        exchange.pageLagReads = 2
        val host = readyHost(exchange)
        try {
            var failure: String? = null
            host.home.send(firstPrompt, "chat", temporary = false) { failure = it }
            assertTrue(
                "the first-send launch must be submitted",
                awaitUntil { exchange.runStartCount.get() == 1 },
            )
            exchange.queueEvent("assistantText", """{"text":"$firstAnswer"}""")
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                "the run must reach its durable terminal state",
                awaitUntil { exchange.runState == "completed" },
            )
            assertTrue(
                "committed user + assistant rows must appear on the same screen " +
                    "(texts=${texts(host)}, reads=${exchange.messagePageReads.get()})",
                awaitUntil { texts(host).containsAll(listOf(firstPrompt, firstAnswer)) },
            )
            val snapshot = host.conversations.entryFor(conversationId)!!.holder.snapshot.value!!
            assertFalse(snapshot.isConversationMissing)
            assertTrue(snapshot.hasLoaded)
            assertNull(failure)
        } finally {
            host.stop()
        }
    }

    /**
     * A transient close-boundary failure is NOT the settled truth: the page is
     * retried a bounded number of times and the real rows land.
     */
    @Test
    fun transientCloseBoundaryFailureIsRetriedWithinItsBound() = runBlocking {
        val exchange = ScriptedExchange()
        // The launch read races (empty) and the FIRST close-boundary read
        // fails transiently; the bounded settlement must retry it.
        exchange.pageLagReads = 1
        exchange.failNextPageReads = 1
        val host = readyHost(exchange)
        try {
            host.home.send(firstPrompt, "chat", temporary = false) { }
            assertTrue(awaitUntil { exchange.runStartCount.get() == 1 })
            exchange.queueEvent("assistantText", """{"text":"$firstAnswer"}""")
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                "a failed committed-page read must not strand the thread " +
                    "(texts=${texts(host)}, reads=${exchange.messagePageReads.get()})",
                awaitUntil { texts(host).containsAll(listOf(firstPrompt, firstAnswer)) },
            )
        } finally {
            host.stop()
        }
    }

    /**
     * Existing-conversation follow-up freshness is UNCHANGED: the second turn
     * appends to the first pair (this already passes on the device).
     */
    @Test
    fun followupTurnAppendsToTheAlreadyVisiblePair() = runBlocking {
        val exchange = ScriptedExchange()
        exchange.firstTurnDurable = true
        exchange.firstAssistantDurable = true
        exchange.runState = "completed"
        val host = readyHost(exchange)
        try {
            val holder = host.conversations.holderFor(
                conversationId,
                isTemporary = false,
                incarnationId = null,
            )
            host.conversations.loadThread(holder.session)
            assertTrue(
                "the reopened first pair must be visible first",
                awaitUntil {
                    host.conversations.entryFor(conversationId)?.holder?.snapshot?.value
                        ?.rows.orEmpty().size >= 2
                },
            )
            holder.onDraftChange(androidx.compose.ui.text.input.TextFieldValue(followupPrompt))
            val send = holder.send()
            assertTrue(
                "the follow-up launch must be submitted (result=$send)",
                awaitUntil { exchange.runStartCount.get() == 1 },
            )
            exchange.queueEvent("assistantText", """{"text":"$followupAnswer"}""")
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                "the new user + assistant turn must append on the same screen " +
                    "(texts=${texts(host)})",
                awaitUntil {
                    texts(host).containsAll(
                        listOf(firstPrompt, firstAnswer, followupPrompt, followupAnswer),
                    )
                },
            )
            assertEquals(4, texts(host).count { it in setOf(firstPrompt, firstAnswer, followupPrompt, followupAnswer) })
            // The first pair is never cleared by the newer turn.
            assertTrue(texts(host).contains(firstAnswer))
        } finally {
            host.stop()
        }
    }

    /**
     * The retry must stay fenced: once the holder is retired for a real
     * navigation, a later committed page never publishes into the old view
     * and no further read is issued for it.
     */
    @Test
    fun retiredHolderStopsTheCommittedRowSettlement() = runBlocking {
        val exchange = ScriptedExchange()
        exchange.pageLagReads = 8
        val host = readyHost(exchange)
        try {
            var failure: String? = null
            host.home.send(firstPrompt, "chat", temporary = false) { failure = it }
            assertTrue(awaitUntil { exchange.runStartCount.get() == 1 })
            val entry = host.conversations.entryFor(conversationId)!!
            val readsBeforeRetire = exchange.messagePageReads.get()
            entry.holder.retireForNavigation()
            exchange.queueEvent("status", """{"state":"completed"}""")
            delay(400)
            assertTrue(
                "a retired holder must not issue committed-row reads " +
                    "($readsBeforeRetire -> ${exchange.messagePageReads.get()})",
                exchange.messagePageReads.get() <= readsBeforeRetire + 1,
            )
            assertNull(
                "a retired holder publishes nothing",
                entry.holder.snapshot.value,
            )
        } finally {
            host.stop()
        }
    }

    /**
     * Controlled deferred OLDER latest-window response: the initial activate
     * read is issued before the launch (it captured nothing), and its
     * response is released only AFTER the launch/terminal page already
     * settled. It must be dropped WHOLE (no row, no earlier-cursor/hasEarlier
     * mutation, no content fetch) because a newer latest-window read was
     * issued for the same surface.
     *
     * The stale page carries an instrumentation row + hasEarlier=true so a
     * dropped-vs-applied outcome is directly observable.
     */
    @Test
    fun deferredOlderActivatePageIsDroppedBeforeAnyMutation() = runBlocking {
        val exchange = ScriptedExchange()
        exchange.nextPageOverride =
            """{"sequence":1,"kind":"accepted","value":""" +
                """{"rows":[{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","role":"assistant",""" +
                """"content":"STALE_ACTIVATE_PAGE","createdAt":"2026-10-21T10:04:00.000Z",""" +
                """"runID":"$firstRunId"}],"hasEarlier":true,"earlierCursor":null}}"""
        exchange.holdNextPage = true
        val host = readyHost(exchange)
        try {
            host.home.send(firstPrompt, "chat", temporary = false) { }
            assertTrue(awaitUntil { exchange.runStartCount.get() == 1 })
            assertTrue(
                "the pre-launch activate read must be the deferred one",
                exchange.heldPageCaptured.await(2, TimeUnit.SECONDS),
            )
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                "the launch/terminal settlement lands while the older read is held",
                awaitUntil { texts(host).containsAll(listOf(firstPrompt, firstAnswer)) },
            )
            val readsBeforeRelease = exchange.messagePageReads.get()
            exchange.releaseHeldPage.countDown()
            delay(500)
            val textsAfter = texts(host)
            assertTrue(
                "a late OLDER latest-page response must not inject or overwrite rows " +
                    "(texts=$textsAfter)",
                "STALE_ACTIVATE_PAGE" !in textsAfter,
            )
            assertEquals(
                "the real pair is unchanged by the stale response",
                listOf(firstPrompt, firstAnswer),
                textsAfter.filter { it in setOf(firstPrompt, firstAnswer) },
            )
            assertFalse(
                "the stale page's hasEarlier must not mutate the paging projection",
                host.conversations.entryFor(conversationId)!!.holder.snapshot.value!!
                    .hasEarlierMessages,
            )
            assertTrue(
                "no newer read was issued by the stale response",
                exchange.messagePageReads.get() >= readsBeforeRelease,
            )
        } finally {
            exchange.releaseHeldPage.countDown()
            host.stop()
        }
    }

    /**
     * A committed-page response for a run that is no longer selected (a
     * newer launch already owns the same holder/session) must not mutate the
     * new run's projection: the run+stream fence is evaluated BEFORE rows or
     * UI state change.
     */
    @Test
    fun settlementPageForAReplacedRunNeverTouchesTheNewerRun() = runBlocking {
        val exchange = ScriptedExchange()
        val host = readyHost(exchange)
        try {
            host.home.send(firstPrompt, "chat", temporary = false) { }
            assertTrue(awaitUntil { exchange.runStartCount.get() == 1 })
            val holder = host.conversations.entryFor(conversationId)!!.holder
            // Hold the FIRST run's close-boundary settlement response.
            exchange.nextPageOverride =
                """{"sequence":1,"kind":"accepted","value":""" +
                    """{"rows":[{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff","role":"assistant",""" +
                    """"content":"RUN1_SETTLEMENT_STALE","createdAt":"2026-10-21T10:06:30.000Z",""" +
                    """"runID":"$firstRunId"}],"hasEarlier":true,"earlierCursor":null}}"""
            exchange.holdNextPage = true
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                "the settlement read is in flight",
                exchange.heldPageCaptured.await(3, TimeUnit.SECONDS),
            )
            // A newer launch takes over the SAME surface before the old page
            // returns.
            holder.onDraftChange(androidx.compose.ui.text.input.TextFieldValue(followupPrompt))
            val send = holder.send()
            assertTrue("newer launch admitted ($send)", send !is com.floe.android.feature.conversation.ConversationFlowResult.Rejected)
            assertTrue(awaitUntil { exchange.runStartCount.get() == 2 })
            exchange.releaseHeldPage.countDown()
            delay(300)
            assertTrue(
                "the replaced run's settlement page must not publish " +
                    "(texts=${texts(host)})",
                "RUN1_SETTLEMENT_STALE" !in texts(host),
            )
            // The newer run's own terminal still settles the real rows.
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(
                awaitUntil {
                    texts(host).containsAll(listOf(firstPrompt, firstAnswer, followupPrompt))
                },
            )
            assertTrue("RUN1_SETTLEMENT_STALE" !in texts(host))
        } finally {
            exchange.releaseHeldPage.countDown()
            host.stop()
        }
    }

    /**
     * Earlier-history paging is an APPEND continuation and is not gated by
     * the LATEST-window freshness identity:
     *
     * * the builder merges an earlier page by row identity (oldest-first) and
     *   never clears the newer window;
     * * the admission gate admits every earlier page (`latest = false`) while
     *   a superseded/older LATEST page is rejected, even after a newer latest
     *   page advanced the sequence.
     */
    @Test
    fun earlierHistoryAppendSemanticsSurviveTheLatestPageFreshnessGate() = runBlocking {
        val exchange = ScriptedExchange()
        exchange.firstTurnDurable = true
        exchange.firstAssistantDurable = true
        exchange.runState = "completed"
        val host = readyHost(exchange)
        try {
            val holder = host.conversations.holderFor(
                conversationId, isTemporary = false, incarnationId = null,
            )
            host.conversations.loadThread(holder.session)
            assertTrue(awaitUntil { texts(host).containsAll(listOf(firstPrompt, firstAnswer)) })
            val entry = host.conversations.entryFor(conversationId)!!

            // Projection: an earlier page appends older rows, newest kept.
            val earlier = ConversationWire.decodeMessagePage(
                Json.parseToJsonElement(
                    """{"rows":[""" +
                        """{"id":"99999999-9999-4999-8999-999999999999","role":"user",""" +
                        """"content":"Older prompt","createdAt":"2026-10-21T09:00:00.000Z"},""" +
                        """{"id":"88888888-8888-4888-8888-888888888888","role":"assistant",""" +
                        """"content":"Older answer","createdAt":"2026-10-21T09:01:00.000Z"}],""" +
                        """"hasEarlier":false,"earlierCursor":null}""",
                ),
            )!!
            entry.builder.applyMessagePage(earlier, earlier = true)
            entry.holder.applyHostSnapshot(entry.builder.build())
            assertTrue(texts(host).containsAll(listOf(
                "Older prompt", "Older answer", firstPrompt, firstAnswer,
            )))

            // Admission: an older LATEST page is refused, every EARLIER page
            // is admitted.
            val newerSeq = entry.nextLatestPageReadSeq()
            var applied = 0
            val olderLatestAdmitted = entry.withAdmittedMessagePage(
                latest = true,
                issuedSeq = newerSeq - 1,
                check = { true },
            ) { applied += 1 }
            assertFalse("a superseded latest page must be refused", olderLatestAdmitted)
            assertEquals(0, applied)
            repeat(2) {
                val earlierAdmitted = entry.withAdmittedMessagePage(
                    latest = false,
                    issuedSeq = 0,
                    check = { true },
                ) { applied += 1 }
                assertTrue("earlier-history appends are never gated by latest freshness", earlierAdmitted)
            }
            assertEquals(2, applied)
        } finally {
            host.stop()
        }
    }

    /**
     * The settlement is BOUNDED and never fabricates content: when the page
     * keeps answering empty (a genuinely broken/absent commit), the App stops
     * after its attempt budget, keeps the honest empty surface and never
     * invents a user or assistant row.
     */
    @Test
    fun emptyPagesRemainBoundedAndNeverFabricateRows() = runBlocking {
        val exchange = ScriptedExchange()
        exchange.pageScript = { _ -> emptyPageFrame() }
        val host = readyHost(exchange)
        try {
            host.home.send(firstPrompt, "chat", temporary = false) { }
            assertTrue(awaitUntil { exchange.runStartCount.get() == 1 })
            exchange.queueEvent("status", """{"state":"completed"}""")
            assertTrue(awaitUntil { exchange.runState == "completed" })
            delay(1_200)
            val reads = exchange.messagePageReads.get()
            assertTrue("the settlement must retry (reads=$reads)", reads >= 3)
            assertTrue("the settlement must stay bounded (reads=$reads)", reads <= 10)
            assertTrue("no fabricated timeline row may appear", texts(host).isEmpty())
            val snapshot = host.conversations.entryFor(conversationId)!!.holder.snapshot.value!!
            assertTrue(snapshot.hasLoaded)
            assertFalse(snapshot.isConversationMissing)
        } finally {
            host.stop()
        }
    }
}
