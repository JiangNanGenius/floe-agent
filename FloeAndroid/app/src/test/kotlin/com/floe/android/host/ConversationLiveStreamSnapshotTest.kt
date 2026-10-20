// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.TimelineRowUi
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Live streaming -> canonical `run.snapshot` reconciliation regression.
 *
 * Authored NOTRUN (source only): Main compiles and runs the focused JVM
 * filter named in SOURCE_READY.json. Nothing here is a run/device claim.
 *
 * Contract under test (settled narrow design):
 * * The native `live` mirror of `floe.event-cursor/3` is an unsequenced,
 *   lossy DIRTY HINT. It never becomes a durable sequence and never carries
 *   projected text by itself.
 * * A hint coalesces into at most ONE in-flight authoritative `run.snapshot`
 *   read per run with a bounded throttled follow-up.
 * * The snapshot's `answerText`/`reasoningText` replace the already-durable
 *   prefix of the same streaming step (no double append vs durable segments),
 *   only for the selected, still-owned, non-terminal run.
 * * A `*ContinuationHandle` marks the inline text as a PREFIX: displayed but
 *   never complete, never clearing the durable tail.
 * * A terminal learned from the authoritative snapshot (pump died before any
 *   durable terminal frame) reconciles the committed message rows exactly
 *   once on the same screen, idempotently and without navigation.
 */
class ConversationLiveStreamSnapshotTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val secondRunId = "33333333-3333-4333-8333-333333333333"

    // ------------------------------------------------------------- transport

    /**
     * Scripted double of the actual v3 wire. Event polls serve a scripted
     * durable/live page; effect polls serve the queued `run.snapshot` pages
     * and the committed message rows the native store would return.
     */
    private class ReplayEvent(val sequence: Long, val kind: String, val payload: String)

    private inner class ScriptedExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        /** Durable run state reported by conversation.get (single-run mode). */
        @Volatile var runState: String = "streamingModel"

        /** Explicit run rows for conversation.get, newest-first. */
        val runs = CopyOnWriteArrayList<Pair<String, String>>()

        /** When set, returned verbatim as conversation.get `runs` (fencing). */
        @Volatile var runsOverride: String? = null

        /** Scripted event-poll window state (`attached`/`runGone`/...). */
        @Volatile var windowState: String = "attached"

        /** Scripted live document members (native shape). */
        @Volatile var liveState: String = "noConsumer"
        @Volatile var liveResync: Boolean = false
        @Volatile var omitLiveMember: Boolean = false
        val liveFramePayloads = CopyOnWriteArrayList<String>()

        /** Durable events queued for the next event polls (kind, payload). */
        private val pendingEvents = CopyOnWriteArrayList<Pair<String, String>>()
        private val eventSequence = AtomicInteger(0)

        /** Prior-incarnation durable events the native window would replay. */
        val replayEvents = CopyOnWriteArrayList<ReplayEvent>()

        /** Snapshot pages served to `run.snapshot` effect polls, in order. */
        private val snapshotPages = CopyOnWriteArrayList<String>()
        @Volatile private var lastSnapshotPage: String? = null
        val snapshotPolls = AtomicInteger(0)

        /** Committed rows served to `conversation.messagePage`. */
        @Volatile var messageRowsJson: String = "[]"

        /** One-shot typed failures for bounded negative-path tests. */
        @Volatile var snapshotFailuresRemaining: Int = 0
        @Volatile var messagePageFailuresRemaining: Int = 0

        /** Scripted `run.retry` terminal: accepted/rejected/failed. */
        @Volatile var retryOutcome: String = "accepted"

        /** Hold switch for the in-flight coalescing test. */
        @Volatile var holdSnapshotEffects = false
        val snapshotHeld = CountDownLatch(1)
        private val releaseSnapshot = CountDownLatch(1)

        fun releaseHeldSnapshot() = releaseSnapshot.countDown()

        fun queueEvent(kind: String, payloadJson: String) {
            pendingEvents.add(kind to payloadJson)
        }

        fun replayEvent(sequence: Long, kind: String, payloadJson: String) {
            replayEvents.add(ReplayEvent(sequence, kind, payloadJson))
        }

        fun queueSnapshot(pageJson: String) {
            snapshotPages.add(pageJson)
        }

        fun liveFrame(payloadJson: String) {
            liveFramePayloads.add(payloadJson)
        }

        fun clearLive() {
            liveFramePayloads.clear()
            liveResync = false
            liveState = "attached"
        }

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") -> eventPollPage(request, correlation)
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
                        "op:v1:cget" -> effect(correlation, "cget", accepted(conversationReply()))
                        "op:v1:messagePage" -> {
                            if (messagePageFailuresRemaining > 0) {
                                messagePageFailuresRemaining -= 1
                                effect(
                                    correlation, "messagePage",
                                    """{"sequence":1,"kind":"failed",""" +
                                        """"code":"messagePageUnavailable"}""",
                                )
                            } else {
                                effect(
                                    correlation, "messagePage",
                                    accepted(
                                        """{"rows":$messageRowsJson,"hasEarlier":false,""" +
                                            """"earlierCursor":null}""",
                                    ),
                                )
                            }
                        }
                        "op:v1:runSnapshot" -> {
                            // Select the scripted page BEFORE counting/holding
                            // so request order (and the incarnation-fence
                            // test) stays deterministic.
                            val page = if (snapshotPages.isNotEmpty()) {
                                snapshotPages.removeAt(0)
                            } else {
                                lastSnapshotPage ?: runSnapshot()
                            }
                            lastSnapshotPage = page
                            snapshotPolls.incrementAndGet()
                            if (holdSnapshotEffects) {
                                snapshotHeld.countDown()
                                releaseSnapshot.await(5, TimeUnit.SECONDS)
                            }
                            if (snapshotFailuresRemaining > 0) {
                                snapshotFailuresRemaining -= 1
                                effect(
                                    correlation, "runSnapshot",
                                    """{"sequence":1,"kind":"failed",""" +
                                        """"code":"snapshotUnavailable"}""",
                                )
                            } else {
                                effect(correlation, "runSnapshot", accepted(page))
                            }
                        }
                        "op:v1:runRetry" -> {
                            when (retryOutcome) {
                                "rejected" -> effect(
                                    correlation, "runRetry",
                                    """{"sequence":1,"kind":"rejected",""" +
                                        """"code":"staleRevision"}""",
                                )
                                "failed" -> effect(
                                    correlation, "runRetry",
                                    """{"sequence":1,"kind":"failed",""" +
                                        """"code":"retryUnavailable"}""",
                                )
                                else -> effect(
                                    correlation, "runRetry",
                                    accepted(
                                        null,
                                        """[{"key":"outcome","value":"retried"}]""",
                                    ),
                                )
                            }
                        }
                        else -> effect(correlation, receipt, accepted(null))
                    }
                }
                request.contains("\"command\":\"conversation.get\"") ->
                    receipt(correlation, "cget")
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "runSnapshot")
                request.contains("\"command\":\"run.retry\"") ->
                    receipt(correlation, "runRetry")
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

        private fun eventPollPage(request: String, correlation: String): String {
            val root = runCatching { Json.parseToJsonElement(request).jsonObject }.getOrNull()
            val envelope = root?.get("envelope")?.jsonObject
            val ownerRunID = envelope?.get("owner")?.jsonObject
                ?.get("runID")?.jsonPrimitive?.content ?: runId
            val cursor = envelope?.get("cursor")?.jsonObject
            val afterSequence = cursor?.get("sequence")?.jsonPrimitive?.content?.toLongOrNull() ?: 0L
            val events = StringBuilder()
            var nextSequence = afterSequence
            for (replay in replayEvents) {
                if (replay.sequence <= afterSequence) continue
                if (events.isNotEmpty()) events.append(',')
                val escaped = replay.payload.replace("\\", "\\\\")
                    .replace("\"", "\\\"")
                events.append(
                    """{"sequence":${replay.sequence},"kind":"${replay.kind}",""" +
                        """"createdAt":1,"payload":"$escaped"}""",
                )
                if (replay.sequence > nextSequence) nextSequence = replay.sequence
            }
            while (pendingEvents.isNotEmpty() && events.length < 24_000) {
                val (kind, payload) = pendingEvents.removeAt(0)
                nextSequence += 1
                if (events.isNotEmpty()) events.append(',')
                val escaped = payload.replace("\\", "\\\\").replace("\"", "\\\"")
                events.append(
                    """{"sequence":$nextSequence,"kind":"$kind","createdAt":1,"payload":"$escaped"}""",
                )
            }
            val live = if (omitLiveMember) {
                ""
            } else {
                val frames = StringBuilder()
                for ((index, payload) in liveFramePayloads.withIndex()) {
                    if (frames.isNotEmpty()) frames.append(',')
                    val escaped = payload.replace("\\", "\\\\").replace("\"", "\\\"")
                    frames.append(
                        """{"liveSeq":${index + 1},"priority":false,"payload":"$escaped"}""",
                    )
                }
                liveFramePayloads.clear()
                """,
                "live":{"liveState":"$liveState","frames":[$frames],""" +
                    """"resyncRequired":$liveResync,"droppedDeltas":0}"""
            }
            return """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"runID":"$ownerRunID","sequence":$afterSequence},""" +
                """"durable":{"windowState":"$windowState","events":[$events],""" +
                """"hasMore":false,"resyncRequired":false,""" +
                """"nextSequence":$nextSequence}""" + live +
                ""","resyncRequired":false}"""
        }

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

        private fun conversationReply(): String {
            val rows = if (runs.isEmpty()) {
                listOf(runId to runState)
            } else {
                runs.toList()
            }
            val runsJson = runsOverride ?: rows.joinToString(",") { (id, state) ->
                """{"runID":"$id","state":"$state","modelName":"DeepSeek Cloud QA",""" +
                    """"startedAt":"2026-10-20T01:00:00.000Z"}"""
            }
            return """{"conversationID":"$conversationId","title":"Task",""" +
                """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
                """"version":"digest-1"},"runs":[$runsJson],""" +
                """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""
        }

        /** Durable cursor sequences seen by event.poll (never advanced by live). */
        fun eventPollCursors(): List<Long> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "event.poll") return@mapNotNull null
            root["envelope"]?.jsonObject
                ?.get("cursor")?.jsonObject
                ?.get("sequence")?.jsonPrimitive?.content?.toLongOrNull()
        }

        private fun receipt(correlation: String, receiptTag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$receiptTag"}"""

        private fun accepted(valueJson: String?, detailJson: String = "", sequence: Int = 1): String {
            val value = if (valueJson == null) "" else ""","value":$valueJson"""
            val detail = if (detailJson.isBlank()) "" else ""","detail":$detailJson"""
            return """{"sequence":$sequence,"kind":"accepted"$value$detail}"""
        }

        private fun effect(
            correlation: String,
            receiptTag: String,
            effectsJson: String,
            sequence: Long = 2,
        ): String =
            """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
                """"sequence":$sequence},"effects":[$effectsJson],"hasMore":false,""" +
                """"resyncRequired":false}"""
    }

    // ----------------------------------------------------------------- hosts

    private fun client(exchange: HostBridgeExchange, pollMillis: Long = 1) =
        RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = pollMillis),
        )

    private fun host(exchange: HostBridgeExchange, pollMillis: Long = 1): RuntimeHost = RuntimeHost(
        commandClient = client(exchange, pollMillis),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private suspend fun readyHost(exchange: HostBridgeExchange, pollMillis: Long = 1): RuntimeHost {
        val host = host(exchange, pollMillis)
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

    private suspend fun awaitCondition(
        timeoutMillis: Long = 4_000,
        check: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(5)
        }
        return check()
    }

    // ------------------------------------------------------------- fixtures

    private fun runSnapshot(
        runID: String = this@ConversationLiveStreamSnapshotTest.runId,
        durableState: String = "streamingModel",
        isTerminal: Boolean = false,
        liveOwner: Boolean = true,
        answerText: String? = null,
        answerComplete: Boolean = false,
        answerHandle: String? = null,
        reasoningText: String? = null,
        reasoningHandle: String? = null,
    ): String {
        fun stringOrNull(value: String?): String =
            if (value == null) "null" else "\"" + value.replace("\\", "\\\\")
                .replace("\"", "\\\"") + "\""
        return """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
            """"runID":"$runID","durableState":"$durableState",""" +
            """"revision":{"resourceID":"run.${runID.uppercase()}",""" +
            """"version":"$durableState"},"isTerminal":$isTerminal,""" +
            """"conversationMode":"chat","goal":"hi","liveOwner":$liveOwner,""" +
            """"answerText":${stringOrNull(answerText)},""" +
            """"answerComplete":$answerComplete,""" +
            """"answerContinuationHandle":${stringOrNull(answerHandle)},""" +
            """"reasoningText":${stringOrNull(reasoningText)},""" +
            """"reasoningComplete":false,""" +
            """"reasoningContinuationHandle":${stringOrNull(reasoningHandle)},""" +
            """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
            """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
            """"version":"queue-digest-1"},"durableWatermark":4}"""
    }

    private fun committedRows(runID: String, userText: String, answerText: String): String =
        """[{"id":"u-$runID","role":"user","content":"$userText",""" +
            """"createdAt":"2026-10-20T01:00:00.000Z","runID":"$runID"},""" +
            """{"id":"a-$runID","role":"assistant","content":"$answerText",""" +
            """"createdAt":"2026-10-20T01:00:05.000Z","runID":"$runID"}]"""

    private fun liveAnswer(payloadText: String): String =
        """{"answerDelta":{"text":"$payloadText"}}"""

    private fun liveReasoning(payloadText: String): String =
        """{"reasoningDelta":{"text":"$payloadText"}}"""

    private fun assistantRowText(
        state: com.floe.android.feature.conversation.ThreadUiState?,
    ): List<String> = state?.rows.orEmpty().mapNotNull { row ->
        when (row) {
            is TimelineRowUi.AssistantMessage -> row.text
            else -> null
        }
    }

    // -------------------------------------------------- live page truth tests

    @Test
    fun malformedLiveDocumentIsADirtyHintButNeverFailsTheDurableSection() {
        val json = Json
        val malformed = json.parseToJsonElement(
            """{"live":{"liveState":"attached","frames":[{"liveSeq":"x"}]}}""",
        ).jsonObject
        val hint = LivePageHint.decode(malformed, 65_536)
        assertTrue("malformed live must still reconcile via snapshot", hint.dirty)
        assertEquals("malformed", hint.state)

        val overBudgetFrames = StringBuilder("""{"live":{"liveState":"attached","frames":[""")
        for (index in 0..LivePageHint.MAXIMUM_FRAMES) {
            if (index > 0) overBudgetFrames.append(',')
            overBudgetFrames.append(
                """{"liveSeq":$index,"priority":false,"payload":"{}"}""",
            )
        }
        overBudgetFrames.append("]}}")
        val overBudget = LivePageHint.decode(
            json.parseToJsonElement(overBudgetFrames.toString()).jsonObject, 65_536)
        assertTrue(overBudget.dirty)
        assertEquals("overBudget", overBudget.state)

        val absent = LivePageHint.decode(
            json.parseToJsonElement("""{"durable":{}}""").jsonObject, 65_536)
        assertFalse("an absent live member is not a hint", absent.dirty)
        assertEquals("absent", absent.state)

        val noConsumer = LivePageHint.decode(
            json.parseToJsonElement(
                """{"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false}}""",
            ).jsonObject, 65_536)
        assertFalse("cold/no-live-owner must not poll snapshots", noConsumer.dirty)

        val resync = LivePageHint.decode(
            json.parseToJsonElement(
                """{"live":{"liveState":"detached","frames":[],"resyncRequired":true}}""",
            ).jsonObject, 65_536)
        assertTrue("explicit resync is a dirty hint", resync.dirty)

        val frame = LivePageHint.decode(
            json.parseToJsonElement(
                """{"live":{"liveState":"attached","frames":[""" +
                    """{"liveSeq":7,"priority":true,"payload":"{}"}],"resyncRequired":false}}""",
            ).jsonObject, 65_536)
        assertTrue("a drained live frame is a dirty hint", frame.dirty)
    }

    @Test
    fun nativeLiveFramesTriggerTheCanonicalSnapshotInsteadOfDurableFrames() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02_OK"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(
            "load reads the authoritative snapshot",
            awaitCondition { exchange.commandsOf("run.snapshot").isNotEmpty() },
        )
        val snapshotsAfterLoad = exchange.commandsOf("run.snapshot").size
        // Native-shaped live frames only: no durable run event is fabricated.
        exchange.liveState = "attached"
        exchange.liveFrame(liveAnswer("FLOE_"))
        exchange.liveFrame(liveAnswer("G02_OK"))
        val refreshed = awaitCondition {
            exchange.commandsOf("run.snapshot").size > snapshotsAfterLoad
        }
        assertTrue("live frames must coalesce into a run.snapshot read", refreshed)
        val textApplied = awaitCondition {
            holder.snapshot.value?.liveAssistantText == "FLOE_G02_OK"
        }
        assertTrue("authoritative snapshot text replaces the live tail", textApplied)
        assertTrue(
            "live frames never advance or fabricate the durable cursor",
            exchange.eventPollCursors().all { it == 0L },
        )
    }

    @Test
    fun growingSnapshotsProjectBeforeTerminalWithoutDoubleAppend() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = "FLOE_"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "FLOE_" })

        exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02"))
        exchange.liveState = "attached"
        exchange.liveFrame(liveAnswer("_G02"))
        assertTrue(
            awaitCondition { holder.snapshot.value?.liveAssistantText == "FLOE_G02" },
        )
        // Still live: nothing is declared complete and the tail stays.
        assertTrue(holder.snapshot.value?.isRunning == true)

        exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02_OK"))
        exchange.liveFrame(liveAnswer("_OK"))
        assertTrue(
            awaitCondition { holder.snapshot.value?.liveAssistantText == "FLOE_G02_OK" },
        )
    }

    @Test
    fun reasoningSnapshotIsProjectedSeparatelyFromAnswer() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = null, reasoningText = "Think"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveReasoningText == "Think" })

        exchange.queueSnapshot(
            runSnapshot(answerText = "Answer", reasoningText = "Think more"),
        )
        exchange.liveState = "attached"
        exchange.liveFrame(liveReasoning(" more"))
        assertTrue(awaitCondition {
            val state = holder.snapshot.value
            state?.liveReasoningText == "Think more" && state.liveAssistantText == "Answer"
        })
    }

    @Test
    fun durableAssistantSegmentThenSnapshotNeverDoublesTheText() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = "Hello"))
        exchange.queueEvent("assistantText", """{"text":"Hello "}""")
        exchange.queueSnapshot(runSnapshot(answerText = "Hello world"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        // The durable segment lands first (segment boundary) …
        assertTrue(awaitCondition {
            holder.snapshot.value?.liveAssistantText?.contains("Hello") == true
        })
        // … and the authoritative snapshot then replaces its own prefix.
        exchange.liveState = "attached"
        exchange.liveFrame(liveAnswer("world"))
        assertTrue(awaitCondition {
            holder.snapshot.value?.liveAssistantText == "Hello world"
        })
        assertEquals(
            "the same characters are never rendered twice",
            "Hello world",
            holder.snapshot.value?.liveAssistantText,
        )
    }

    @Test
    fun continuationHandleDisplaysAPrefixAndNeverClaimsCompletion() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(
            runSnapshot(
                answerText = "FLOE_",
                answerComplete = false,
                answerHandle = "handle:answer:1",
            ),
        )
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "FLOE_" })
        // A truncated inline prefix keeps the run live and the tail intact:
        // the prefix is displayed honestly and never presented as final.
        assertEquals("FLOE_", holder.snapshot.value?.liveAssistantText)
        assertTrue(holder.snapshot.value?.isRunning == true)
        assertTrue(
            holder.snapshot.value?.rows.orEmpty()
                .any { it is TimelineRowUi.LiveAssistantTail },
        )
    }

    @Test
    fun coldSnapshotWithoutLiveOwnerKeepsTheDurableTail() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(liveOwner = false, answerText = null))
        exchange.queueEvent("assistantText", """{"text":"Durable tail"}""")
        exchange.queueSnapshot(runSnapshot(liveOwner = false, answerText = null))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        assertTrue(awaitCondition {
            holder.snapshot.value?.liveAssistantText == "Durable tail"
        })
        exchange.liveState = "attached"
        exchange.liveFrame(liveAnswer("ignored"))
        delay(200)
        assertEquals(
            "cold/no-live-owner snapshots never invent or wipe text",
            "Durable tail",
            holder.snapshot.value?.liveAssistantText,
        )
    }

    // ------------------------------------------------- terminal reconciliation

    @Test
    fun terminalSnapshotAfterPumpDeathReconcilesCommittedRowsExactlyOnce() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02_OK"))
            val host = readyHost(exchange)
            val holder = loadedHolder(host)
            assertTrue(
                "the initial committed page loads",
                awaitCondition {
                    exchange.commandsOf("conversation.messagePage").isNotEmpty()
                },
            )
            val messagePagesAfterLoad = exchange.commandsOf("conversation.messagePage").size

            // The run completes fast: the window detaches before any durable
            // terminal frame, the pump dies, and only the authoritative
            // snapshot reveals the terminal state.
            exchange.runState = "completed"
            exchange.messageRowsJson = committedRows(runId, "hi", "FLOE_G02_OK")
            exchange.queueSnapshot(
                runSnapshot(
                    durableState = "completed",
                    isTerminal = true,
                    answerText = "FLOE_G02_OK",
                ),
            )
            exchange.windowState = "runGone"
            val reloaded = awaitCondition {
                exchange.commandsOf("conversation.messagePage").size > messagePagesAfterLoad
            }
            assertTrue("a terminal snapshot must reload committed rows", reloaded)
            assertTrue(
                awaitCondition {
                    assistantRowText(holder.snapshot.value).contains("FLOE_G02_OK")
                },
            )
            // Bounded/idempotent: no polling loop of message pages.
            delay(400)
            assertEquals(
                "exactly one committed-row reconciliation per terminal run",
                messagePagesAfterLoad + 1,
                exchange.commandsOf("conversation.messagePage").size,
            )
            assertEquals(
                "the live tail is dropped once committed rows take over",
                "",
                holder.snapshot.value?.liveAssistantText,
            )
        }

    @Test
    fun secondRunOnTheSameScreenReconcilesItsOwnCommittedRows() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02_A"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        // Run A closes through its durable terminal status.
        exchange.queueEvent("status", """{"state":"completed"}""")
        exchange.messageRowsJson = committedRows(runId, "A", "FLOE_G02_A")
        assertTrue(
            awaitCondition { assistantRowText(holder.snapshot.value).contains("FLOE_G02_A") },
        )

        // A SECOND send on the same screen selects a new run (prepared echo);
        // the shell then re-reads the thread on the SAME route (no navigation).
        val builder = host.conversations.entryFor(conversationId)?.builder
        assertNotNull(builder)
        builder!!.applyPrepared(
            ConversationWire.Prepared(
                conversationID = conversationId,
                runID = secondRunId,
                resourceID = "run.${secondRunId.uppercase()}",
                version = "preparing",
            ),
        )
        holder.applyHostSnapshot(builder.build())
        exchange.runs.clear()
        exchange.runs.add(runId to "completed")
        exchange.runs.add(secondRunId to "streamingModel")
        exchange.windowState = "runGone"
        exchange.messageRowsJson = committedRows(secondRunId, "B", "FLOE_G02_B")
        exchange.queueSnapshot(
            runSnapshot(
                runID = secondRunId,
                durableState = "completed",
                isTerminal = true,
                answerText = "FLOE_G02_B",
            ),
        )
        val startsBefore = exchange.commandsOf("run.start").size
        host.conversations.loadThread(holder.session)
        assertTrue(
            "the second run's committed assistant answer must land on the same screen",
            awaitCondition(6_000) {
                assistantRowText(holder.snapshot.value).contains("FLOE_G02_B")
            },
        )
        assertEquals(
            "no duplicate run launch is issued by reconciliation",
            startsBefore,
            exchange.commandsOf("run.start").size,
        )
    }

    @Test
    fun terminalLearnedFromALiveHintClearsTheTailAndKeepsOnlyCommittedRows() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "FLOE_G02"))
            val host = readyHost(exchange)
            val holder = loadedHolder(host)
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "FLOE_G02" })
            exchange.messageRowsJson = committedRows(runId, "hi", "FLOE_G02_OK")
            // The final authoritative snapshot says terminal; the durable
            // terminal frame may never arrive (window detached).
            exchange.queueSnapshot(
                runSnapshot(
                    durableState = "completed",
                    isTerminal = true,
                    answerText = "FLOE_G02_OK",
                ),
            )
            exchange.liveState = "attached"
            exchange.liveFrame(liveAnswer("_OK"))
            assertTrue(
                awaitCondition {
                    assistantRowText(holder.snapshot.value).contains("FLOE_G02_OK")
                },
            )
            assertEquals(
                "the committed rows are the terminal authority",
                "",
                holder.snapshot.value?.liveAssistantText,
            )
            exchange.liveState = "attached"
            exchange.liveFrame(liveAnswer("late"))
            delay(300)
            assertEquals(
                "no late live hint can resurrect the closed tail",
                "",
                holder.snapshot.value?.liveAssistantText,
            )
        }

    @Test
    fun oneSnapshotInFlightCoalescesLiveHintsIntoABoundedFollowUp() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "A"))
            val host = readyHost(exchange, pollMillis = 5)
            val holder = loadedHolder(host)
            assertTrue(
                "the load snapshot read settles first",
                awaitCondition { exchange.commandsOf("run.snapshot").isNotEmpty() },
            )
            exchange.queueSnapshot(runSnapshot(answerText = "AB"))
            exchange.holdSnapshotEffects = true
            val baseline = exchange.commandsOf("run.snapshot").size
            exchange.liveState = "attached"
            repeat(40) { exchange.liveFrame(liveAnswer("x")) }
            assertTrue("the held snapshot read starts", exchange.snapshotHeld.await(3, TimeUnit.SECONDS))
            repeat(60) {
                exchange.liveFrame(liveAnswer("y"))
                delay(5)
            }
            val duringHold = exchange.commandsOf("run.snapshot").size
            assertTrue(
                "at most one snapshot read may be in flight per run",
                duringHold - baseline <= 1,
            )
            exchange.holdSnapshotEffects = false
            exchange.releaseHeldSnapshot()
            // Dirty hints during the read produce a bounded follow-up.
            assertTrue(awaitCondition(4_000) {
                exchange.commandsOf("run.snapshot").size > duringHold
            })
            assertTrue(awaitCondition(4_000) {
                holder.snapshot.value?.liveAssistantText == "AB"
            })
            delay(200)
            assertTrue(
                "coalescing stays bounded (no per-token snapshot storm)",
                exchange.commandsOf("run.snapshot").size - baseline <= 3,
            )
        }

    @Test
    fun staleEpochSnapshotReplyNeverMutatesTheReboundSession() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.queueSnapshot(runSnapshot(answerText = "OLD"))
        val host = readyHost(exchange)
        val holder = loadedHolder(host)
        exchange.queueSnapshot(runSnapshot(answerText = "STALE"))
        exchange.holdSnapshotEffects = true
        exchange.liveState = "attached"
        exchange.liveFrame(liveAnswer("x"))
        assertTrue("the held refresh is in flight", exchange.snapshotHeld.await(3, TimeUnit.SECONDS))
        // A genuine conversation change bumps the session epoch while the
        // read is awaiting; the reply must then be fenced entirely.
        exchange.runsOverride = "[]"
        holder.rebind("44444444-4444-4444-8444-444444444444")
        exchange.holdSnapshotEffects = false
        exchange.releaseHeldSnapshot()
        delay(400)
        assertFalse(
            "a stale-epoch snapshot never mutates the rebound session",
            holder.snapshot.value?.liveAssistantText?.contains("STALE") == true,
        )
    }

    // ------------------------------------- resume / late old-run termination

    /**
     * The event pump accepts an explicit resume cursor. A pump opened after a
     * known durable watermark must not replay the previous incarnation's
     * events (the old terminal) that the native window still holds.
     */
    @Test
    fun resumedPumpStartsWithTheDurableWatermark() = kotlinx.coroutines.runBlocking {
        val exchange = ScriptedExchange()
        exchange.replayEvent(1, "status", """{"state":"checkpointed"}""")
        exchange.replayEvent(2, "terminal", """{"stopReason":"paused"}""")
        val client = client(exchange)
        val frames = CopyOnWriteArrayList<HostRunEventFrame>()
        val failures = CopyOnWriteArrayList<HostPumpFailure>()
        val handle = client.openRunEventStream(
            taskID = conversationId,
            runID = runId,
            environmentID = null,
            jobID = null,
            onEvent = frames::add,
            onLiveHint = { },
            onFailure = failures::add,
            startSequence = 4L,
        )
        delay(80)
        handle.close()
        assertTrue("replayed prior-incarnation events must be excluded: $frames",
            frames.isEmpty())
        assertTrue(failures.isEmpty())
        assertEquals(4L, exchange.eventPollCursors().first())
    }

    /**
     * Main's actual same-screen A→B case: A's durable terminal callback and
     * its authoritative terminal snapshot arrive after B became selected (B is
     * still streaming). Old A's state may update, but B's live tail must not be
     * cleared, closed or reloaded away.
     */
    @Test
    fun lateOldRunTerminalAfterBSelectedPreservesTheSelectedLiveTail() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "A_LIVE"))
            val host = readyHost(exchange)
            val holder = loadedHolder(host)
            val builder = host.conversations.entryFor(conversationId)!!.builder
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "A_LIVE" })
            assertTrue(
                awaitCondition {
                    exchange.commandsOf("conversation.messagePage").isNotEmpty()
                },
            )
            val snapshotsBefore = exchange.snapshotPolls.get()

            // A second send on the same screen selects B through the real
            // prepared echo; B starts streaming into the selected tail.
            builder.applyPrepared(
                ConversationWire.Prepared(
                    conversationID = conversationId,
                    runID = secondRunId,
                    resourceID = "run.${secondRunId.uppercase()}",
                    version = "preparing",
                ),
            )
            builder.applyRunEvent(answerFrame(secondRunId, 1, "B_LIVE"))
            holder.applyHostSnapshot(builder.build())
            assertEquals("B_LIVE", holder.snapshot.value?.liveAssistantText)
            val pagesBefore = exchange.commandsOf("conversation.messagePage").size

            // Old A's pump is still open. Its durable terminal callback fires
            // and schedules A's terminal snapshot; neither may close B.
            exchange.queueSnapshot(
                runSnapshot(
                    runID = runId,
                    durableState = "failed",
                    isTerminal = true,
                    answerText = "A_LATE",
                ),
            )
            exchange.queueEvent("status", """{"state":"failed"}""")
            assertTrue(
                awaitCondition(6_000) { builder.runStateName(runId) == "failed" },
            )
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() > snapshotsBefore
                },
            )
            delay(250)
            assertEquals(
                "a late old-run terminal callback/snapshot never clears B's tail",
                "B_LIVE",
                holder.snapshot.value?.liveAssistantText,
            )
            assertEquals(
                "old A terminal must not reload committed rows for B's screen",
                pagesBefore,
                exchange.commandsOf("conversation.messagePage").size,
            )
            // B's tail is still live and accepts its next durable segment.
            builder.applyRunEvent(answerFrame(secondRunId, 2, "_MORE"))
            holder.applyHostSnapshot(builder.build())
            assertEquals("B_LIVE_MORE", holder.snapshot.value?.liveAssistantText)
        }

    /**
     * The real pause path: checkpointed/cancel-settled run, then an ACCEPTED
     * `run.retry` of the SAME run id. Only that accepted mutation may re-arm
     * the tail; the resumed stream must show new growing text and then its own
     * terminal committed rows.
     */
    @Test
    fun acceptedRetryOfTheSameRunShowsNewGrowingTextAndTerminalRows() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "BEFORE"))
            val host = readyHost(exchange)
            val holder = loadedHolder(host)
            val builder = host.conversations.entryFor(conversationId)!!.builder
            val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "BEFORE" })
            assertTrue(
                awaitCondition {
                    exchange.commandsOf("conversation.messagePage").isNotEmpty()
                },
            )
            val pagesBeforePause = exchange.commandsOf("conversation.messagePage").size
            val snapshotsBeforePause = exchange.snapshotPolls.get()

            // Pause/checkpoint settles through the durable status + terminal
            // snapshot. The live tail closes and the committed row is read.
            exchange.runState = "checkpointed"
            exchange.messageRowsJson = committedRows(runId, "hi", "BEFORE")
            exchange.queueSnapshot(
                runSnapshot(durableState = "checkpointed", isTerminal = true),
            )
            exchange.queueEvent("status", """{"state":"checkpointed"}""")
            assertTrue(
                awaitCondition(6_000) { builder.runStateName(runId) == "checkpointed" },
            )
            assertTrue(awaitCondition { holder.snapshot.value?.canContinue == true })
            assertTrue(
                awaitCondition {
                    exchange.commandsOf("conversation.messagePage").size > pagesBeforePause
                },
            )
            assertTrue(
                awaitCondition {
                    exchange.snapshotPolls.get() > snapshotsBeforePause
                },
            )
            assertEquals("", holder.snapshot.value?.liveAssistantText)
            delay(150)

            // A REAL accepted retry re-arms the SAME run id.
            exchange.queueSnapshot(runSnapshot(answerText = "NEW"))
            assertTrue(host.conversations.retryRun(session, runId))
            assertTrue(awaitCondition { exchange.commandsOf("run.retry").isNotEmpty() })
            assertEquals(
                "retry carries the durable checkpointed state",
                "checkpointed",
                exchange.commandsOf("run.retry").first()["payload"]!!
                    .jsonObject["expectedState"]!!.jsonPrimitive.content,
            )
            assertTrue(
                awaitCondition(6_000) {
                    holder.snapshot.value?.liveAssistantText == "NEW"
                },
            )
            assertTrue(
                "the resumed pump starts after the authoritative durable watermark (4)",
                awaitCondition(6_000) {
                    exchange.eventPollCursors().contains(4L)
                },
            )

            // New live deltas after the same-id resume grow the tail.
            exchange.queueSnapshot(runSnapshot(answerText = "NEW_2"))
            exchange.liveState = "attached"
            exchange.liveFrame(liveAnswer("_2"))
            assertTrue(
                awaitCondition(6_000) {
                    holder.snapshot.value?.liveAssistantText == "NEW_2"
                },
            )
            assertEquals(
                "the resumed text is never doubled",
                "NEW_2",
                holder.snapshot.value?.liveAssistantText,
            )

            // The resumed incarnation gets its OWN terminal committed rows.
            exchange.runState = "completed"
            exchange.messageRowsJson = committedRows(runId, "hi", "NEW_2")
            exchange.queueSnapshot(
                runSnapshot(
                    durableState = "completed",
                    isTerminal = true,
                    answerText = "NEW_2",
                ),
            )
            exchange.liveFrame(liveAnswer(""))
            assertTrue(
                awaitCondition(6_000) {
                    assistantRowText(holder.snapshot.value).contains("NEW_2")
                },
            )
            assertEquals(
                "the terminal close boundary replaces the resumed tail",
                "",
                holder.snapshot.value?.liveAssistantText,
            )
        }

    /**
     * A snapshot/frame requested by the PREVIOUS incarnation (before pause and
     * retry) is delivered after the accepted resume. The trusted local stream
     * generation must discard it; it cannot close or overwrite the new tail.
     */
    @Test
    fun prePauseSnapshotNeverMutatesTheResumedSameRunIncarnation() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "BASE"))
            val host = readyHost(exchange, pollMillis = 10)
            val holder = loadedHolder(host)
            val builder = host.conversations.entryFor(conversationId)!!.builder
            val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "BASE" })
            delay(60)

            // A pre-pause refresh is in flight (scripted page captured) while
            // the run is still streaming.
            exchange.queueSnapshot(runSnapshot(answerText = "STALE_PRE_PAUSE"))
            exchange.holdSnapshotEffects = true
            exchange.liveState = "attached"
            exchange.liveFrame(liveAnswer("x"))
            assertTrue("the pre-pause read starts", exchange.snapshotHeld.await(3, TimeUnit.SECONDS))
            val pollsBeforePause = exchange.snapshotPolls.get()

            // Pause/checkpoint. Its terminal refresh is also held but closes
            // the tail and loads the committed row on the current incarnation.
            exchange.runState = "checkpointed"
            exchange.messageRowsJson = committedRows(runId, "hi", "BASE")
            exchange.queueSnapshot(
                runSnapshot(durableState = "checkpointed", isTerminal = true),
            )
            exchange.queueEvent("status", """{"state":"checkpointed"}""")
            assertTrue(
                awaitCondition(6_000) { builder.runStateName(runId) == "checkpointed" },
            )
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() >= pollsBeforePause + 1
                },
            )
            val pollsBeforeRetry = exchange.snapshotPolls.get()

            // The accepted retry starts a NEW incarnation; its refresh is held
            // behind the resurrection-critical old replies.
            exchange.queueSnapshot(runSnapshot(answerText = "RESUMED"))
            assertTrue(host.conversations.retryRun(session, runId))
            assertTrue(awaitCondition { exchange.commandsOf("run.retry").isNotEmpty() })
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() >= pollsBeforeRetry + 1
                },
            )

            // Release every held reply: the old generation's stale page must
            // be discarded; only the resumed generation applies its text.
            exchange.holdSnapshotEffects = false
            exchange.releaseHeldSnapshot()
            assertTrue(
                awaitCondition(6_000) {
                    holder.snapshot.value?.liveAssistantText == "RESUMED"
                },
            )

            exchange.queueSnapshot(runSnapshot(answerText = "RESUMED_2"))
            exchange.liveFrame(liveAnswer("_2"))
            assertTrue(
                awaitCondition(6_000) {
                    holder.snapshot.value?.liveAssistantText == "RESUMED_2"
                },
            )
        }

    /**
     * A failed/stale retry never re-arms the closed tail. The controller's
     * honest rejection path may read a fresh snapshot, but only a real
     * accepted run.retry may lift the close boundary.
     */
    @Test
    fun rejectedRetryNeverRearmsTheClosedSameRunTail() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "BASE"))
            val host = readyHost(exchange)
            val holder = loadedHolder(host)
            val builder = host.conversations.entryFor(conversationId)!!.builder
            val session = ConversationSessionToken(conversationId, holder.session.sessionEpoch)
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "BASE" })
            val snapshotsBeforePause = exchange.snapshotPolls.get()

            exchange.runState = "checkpointed"
            exchange.messageRowsJson = committedRows(runId, "hi", "BASE")
            exchange.queueSnapshot(
                runSnapshot(durableState = "checkpointed", isTerminal = true),
            )
            exchange.queueEvent("status", """{"state":"checkpointed"}""")
            assertTrue(
                awaitCondition(6_000) { builder.runStateName(runId) == "checkpointed" },
            )
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "" })
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() > snapshotsBeforePause
                },
            )

            // Rejected retry: the stale-retry path reads one fresh snapshot,
            // but no accepted mutation exists to re-arm the tail.
            exchange.retryOutcome = "rejected"
            exchange.queueSnapshot(
                runSnapshot(durableState = "checkpointed", isTerminal = true),
            )
            val retriesBefore = exchange.commandsOf("run.retry").size
            val snapshotsBeforeReject = exchange.snapshotPolls.get()
            assertTrue(host.conversations.retryRun(session, runId))
            assertTrue(
                awaitCondition(6_000) {
                    exchange.commandsOf("run.retry").size >= retriesBefore + 1
                },
            )
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() > snapshotsBeforeReject
                },
            )
            delay(250)
            val snapshotsBeforeStale = exchange.snapshotPolls.get()

            // A stale NON-terminal page arrives on the failed-retry refresh.
            // If any failed retry had re-armed the tail this text would show.
            exchange.queueSnapshot(runSnapshot(answerText = "STALE_RETRY"))
            assertTrue(host.conversations.retryRun(session, runId))
            assertTrue(
                awaitCondition(6_000) {
                    exchange.commandsOf("run.retry").size >= retriesBefore + 2
                },
            )
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() > snapshotsBeforeStale
                },
            )
            delay(250)
            assertEquals(
                "a rejected/stale retry never revives the closed tail",
                "",
                holder.snapshot.value?.liveAssistantText,
            )
        }

    /**
     * A transiently failed snapshot keeps the existing honest tail and never
     * launches an automatic retry storm. The next REAL live hint performs the
     * one bounded retry.
     */
    @Test
    fun failedSnapshotKeepsTheTailAndWaitsForANewRealHint() =
        kotlinx.coroutines.runBlocking {
            val exchange = ScriptedExchange()
            exchange.queueSnapshot(runSnapshot(answerText = "TAIL"))
            val host = readyHost(exchange, pollMillis = 10)
            val holder = loadedHolder(host)
            assertTrue(awaitCondition { holder.snapshot.value?.liveAssistantText == "TAIL" })
            delay(60)
            val beforeFailure = exchange.snapshotPolls.get()

            exchange.snapshotFailuresRemaining = 1
            exchange.liveState = "attached"
            exchange.liveFrame(liveAnswer("_FAILED"))
            assertTrue(
                awaitCondition(6_000) {
                    exchange.snapshotPolls.get() > beforeFailure
                },
            )
            delay(200)
            assertEquals(
                "a failed snapshot keeps the last honest tail",
                "TAIL",
                holder.snapshot.value?.liveAssistantText,
            )
            val afterFailure = exchange.snapshotPolls.get()
            delay(400)
            assertEquals(
                "a failed snapshot does not auto-launch a retry loop",
                afterFailure,
                exchange.snapshotPolls.get(),
            )

            // Only a NEW real hint starts the bounded retry.
            exchange.queueSnapshot(runSnapshot(answerText = "TAIL_OK"))
            exchange.liveFrame(liveAnswer("_OK"))
            assertTrue(
                awaitCondition(6_000) {
                    holder.snapshot.value?.liveAssistantText == "TAIL_OK"
                },
            )
            assertEquals(
                "the recovered text is never double-appended",
                "TAIL_OK",
                holder.snapshot.value?.liveAssistantText,
            )
        }

    // ------------------------------------------------- projection unit fences

    private fun preparedBuilder(): ThreadProjectionBuilder {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applyPrepared(
            ConversationWire.Prepared(
                conversationID = conversationId,
                runID = runId,
                resourceID = "run.${runId.uppercase()}",
                version = "preparing",
            ),
        )
        return builder
    }

    private fun snapshotPage(
        runID: String = this.runId,
        durableState: String = "streamingModel",
        isTerminal: Boolean = false,
        liveOwner: Boolean = true,
        answerText: String? = null,
        answerHandle: String? = null,
        reasoningText: String? = null,
    ): ConversationWire.SnapshotPage = ConversationWire.SnapshotPage(
        runID = runID,
        durableState = durableState,
        revision = Revision("run.${runID.uppercase()}", durableState),
        isTerminal = isTerminal,
        pendingApproval = null,
        approvalRevision = null,
        pendingInputs = emptyList(),
        queueRevision = null,
        liveOwner = liveOwner,
        answerText = answerText,
        answerComplete = false,
        answerContinuationHandle = answerHandle,
        reasoningText = reasoningText,
        reasoningComplete = false,
        reasoningContinuationHandle = null,
    )

    private fun durableFrame(kind: String, text: String): HostRunEventFrame =
        answerFrame(runId, 1, text, kind)

    private fun answerFrame(
        runID: String,
        sequence: Long,
        text: String,
        kind: String = "assistantText",
    ): HostRunEventFrame = HostRunEventFrame(
        runID = runID,
        sequence = sequence,
        kind = kind,
        payload = buildJsonObject { put("text", JsonPrimitive(text)) },
        bytes = 32,
    )

    @Test
    fun projectionReplacesTheDurablePrefixAndKeepsForeignRunsUntouched() {
        val builder = preparedBuilder()
        builder.applyRunEvent(durableFrame("assistantText", "Hello "))
        assertEquals("Hello ", builder.build().liveAssistantText)

        builder.applySnapshotLiveText(snapshotPage(answerText = "Hello world"))
        assertEquals("Hello world", builder.build().liveAssistantText)

        // A snapshot for a different run never mutates the selected tail.
        builder.applySnapshotLiveText(
            snapshotPage(runID = secondRunId, answerText = "Other run"),
        )
        assertEquals("Hello world", builder.build().liveAssistantText)

        // A terminal page is refused as well.
        builder.applySnapshotLiveText(
            snapshotPage(durableState = "completed", isTerminal = true, answerText = "Late"),
        )
        assertEquals("Hello world", builder.build().liveAssistantText)
    }

    @Test
    fun projectionRefusesColdPartialAndClosedTails() {
        val builder = preparedBuilder()
        builder.applyRunEvent(durableFrame("assistantText", "Durable"))
        builder.applySnapshotLiveText(snapshotPage(liveOwner = false, answerText = null))
        assertEquals("Durable", builder.build().liveAssistantText)

        builder.applySnapshotLiveText(
            snapshotPage(answerText = "Durable prefix", answerHandle = "handle:1"),
        )
        assertEquals(
            "a continuation handle displays the honest prefix",
            "Durable prefix",
            builder.build().liveAssistantText,
        )
        assertNull(
            "a prefix never completes",
            builder.build().liveAssistantText?.takeIf { it.isEmpty() },
        )

        builder.clearLiveBuffers()
        builder.applySnapshotLiveText(snapshotPage(answerText = "Revived?"))
        assertEquals(
            "a closed tail is never revived",
            "",
            builder.build().liveAssistantText,
        )
    }

    @Test
    fun projectionIgnoresForeignRunDurableTextAfterSelection() {
        val builder = preparedBuilder()
        builder.applyRunEvent(durableFrame("assistantText", "Selected"))
        builder.applyRunEvent(
            HostRunEventFrame(
                runID = secondRunId,
                sequence = 2,
                kind = "assistantText",
                payload = buildJsonObject { put("text", JsonPrimitive("Foreign")) },
                bytes = 32,
            ),
        )
        assertEquals(
            "another run's durable segment never appends onto the selected tail",
            "Selected",
            builder.build().liveAssistantText,
        )
    }
}
