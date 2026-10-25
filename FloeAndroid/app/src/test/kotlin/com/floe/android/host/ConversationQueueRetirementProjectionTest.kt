// SPDX-License-Identifier: MPL-2.0
//
// PROPOSED regression source (authored, NOT compiled or run — Main batches
// all checks per the G04R2 source-first policy; the native cohort and the
// feature/UI cohort are separately Main-qualified).
//
// C09 queue-settle observer + visible read-only recovery regressions.
// Rewritten from the parent job-75194 package (original preserved under
// the deep stage's reviewed-input/) per the VERIFIED IMPLEMENTATION
// CONTRACT §6–§7 with MAIN_ADDENDUM A–F and the settled NOTICE correction:
//
//  * The durable settle fact is an EXISTING `notice` frame with
//    `reason == "queueSettled"` and narrow lifecycle members `lane`/`chain`
//    — NEVER a trailing stateless `status` (which broke the original
//    durable last-status terminal truth in the unchanged RunControl suite),
//    never a `state` member. Queue authority remains the pages.
//  * ONE identity-fenced watch per conversation; the latest terminal arm
//    replaces the predecessor (identity-first registration BEFORE IO —
//    Addendum A). The watch is a QUEUE OBSERVER stream: opened with the
//    typed durable-resync consumer, which also opts it out of the legacy
//    notAttached COUNT cutoff (Addendum B) — no timers anywhere.
//  * Recovery is the authoritative conversation.get + ACTUAL run.snapshot
//    honoring the onApplied Boolean and page completeness (Addendum C):
//    snapshot failure or a truncated queue page is NEVER "recovered";
//    success may be quiet.
//  * A genuine recovery failure becomes a narrowly scoped, separately
//    owned queue-refresh failure token on the holder with a READ-ONLY
//    Retry (Addendum D): reads only, exact-token clear, failure persists
//    across failed retries, never touches `actionError`/continuation or
//    any business execution.
//  * Late terminal-B discovery and duty-anchor causality replace any
//    idle/poll cutoff: every settle/resync reconcile with pending rows
//    arms the newest unprocessed terminal run from its own page.
//
// Everything here is synthetic JSON over the frozen v3 wire doubles — no
// store, network, provider, device or native build.

package com.floe.android.host

import com.floe.android.feature.conversation.PendingInputStatusUi
import com.floe.android.feature.conversation.ThreadUiState
import com.floe.android.feature.conversation.TimelineRowUi
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
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
import org.junit.After
import kotlinx.coroutines.cancel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

class ConversationQueueRetirementProjectionTest {

    private val scopes = CopyOnWriteArrayList<kotlinx.coroutines.CoroutineScope>()
    private fun ownedScope() = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.Dispatchers.Default).also { scopes.add(it) }
    @After fun releaseScopes() { scopes.forEach { it.cancel() } }

    private class HeldRead(val tag: String, val value: String?, val fail: Boolean) {
        val released = AtomicBoolean(false)
        val polled = AtomicInteger(0)
    }

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val secondRunId = "33333333-3333-4333-8333-333333333333"
    private val inputId = "44444444-4444-4444-8444-444444444444"
    private val inputVersion = "2026-10-25T03:40:00.000Z"
    private val queuedBody = "C09_QUEUE_ONCE abcdefghijklmnopqrstuvwxyz0123456789 END_C09_ONCE"

    // ------------------------------------------------------------- transport

    /**
     * Scripted double of the actual v3 wire. PER-RUN durable event queues
     * (drained by the request's owner runID) plus PER-RUN poll counters —
     * the watch and the ordinary pump of different runs are distinguished
     * observably (the >260-poll slow-drain proof and the replacement arms
     * need exactly this). The `durableResync` flag emits the EXISTING
     * `resyncRequired` wire member; `failConversationGet` /
     * `failRunSnapshot` script authoritative read failures. No idle limits,
     * no timers — baseline budgets only.
     */
    private inner class ScriptedExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        /** Sequential `conversation.get` replies (last one repeats). */
        private val conversationReplies = CopyOnWriteArrayList<String>()
        @Volatile private var lastConversationReply: String? = null

        /** Sequential `run.snapshot` pages (last one repeats). */
        private val snapshotPages = CopyOnWriteArrayList<String>()
        @Volatile private var lastSnapshotPage: String? = null
        val snapshotPolls = AtomicInteger(0)

        /** Durable event frames queued per run for the next polls. */
        private val eventsByRun =
            ConcurrentHashMap<String, CopyOnWriteArrayList<Triple<Long, String, String>>>()
        private val eventSequence = AtomicInteger(0)
        val firstCursorByRun = ConcurrentHashMap<String, Long>()
        private val held = ConcurrentHashMap<String, HeldRead>()
        private val nextGets = ConcurrentLinkedQueue<HeldRead>()
        private val nextSnapshots = ConcurrentLinkedQueue<HeldRead>()
        private val heldSequence = AtomicInteger(0)
        fun holdGet(value: String?, fail: Boolean = false): HeldRead =
            hold("heldGet", value, fail, nextGets)
        fun holdSnapshot(value: String?, fail: Boolean = false): HeldRead =
            hold("heldSnapshot", value, fail, nextSnapshots)
        private fun hold(prefix: String, value: String?, fail: Boolean,
            queue: ConcurrentLinkedQueue<HeldRead>): HeldRead {
            val read = HeldRead("$prefix-${heldSequence.incrementAndGet()}", value, fail)
            held["op:v1:${read.tag}"] = read
            queue.add(read)
            return read
        }
        private fun heldPage(read: HeldRead, correlation: String): String {
            read.polled.incrementAndGet()
            if (read.released.get()) return effect(correlation, read.tag,
                if (read.fail) failed("readUnavailable") else accepted(read.value))
            return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:${read.tag}","sequence":0},"effects":[],"hasMore":false,"resyncRequired":false}"""
        }
        val eventPollsByRun = ConcurrentHashMap<String, AtomicInteger>()

        /** Committed rows served to `conversation.messagePage`. */
        @Volatile var messageRowsJson: String = "[]"

        /** Scripted event-poll window state (`attached`/`notAttached`/...). */
        @Volatile var windowState: String = "attached"

        /** Emits `resyncRequired` in the durable section (typed degraded
         *  window signal — an existing frozen wire member). */
        @Volatile var durableResync: Boolean = false

        /** Force `conversation.get` to land Failed (no reply served). */
        @Volatile var failConversationGet: Boolean = false

        /** Force `run.snapshot` to land Failed (decoded/applied false). */
        @Volatile var failRunSnapshot: Boolean = false

        fun queueConversationReply(reply: String) {
            conversationReplies.add(reply)
        }

        fun queueSnapshot(pageJson: String) {
            snapshotPages.add(pageJson)
        }

        fun queueEvent(runID: String, kind: String, payloadJson: String) {
            eventsByRun
                .computeIfAbsent(runID) { CopyOnWriteArrayList() }
                .add(Triple(eventSequence.incrementAndGet().toLong(), kind, payloadJson))
        }

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") ->
                    eventPollPage(request, correlation)
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    val heldRead = held[receipt]
                    if (heldRead != null) return heldPage(heldRead, correlation)
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
                            if (failConversationGet) {
                                effect(correlation, "cget", failed("sessionUnavailable"))
                            } else {
                                val reply = if (conversationReplies.isNotEmpty()) {
                                    conversationReplies.removeAt(0)
                                } else {
                                    lastConversationReply
                                }
                                if (reply == null) {
                                    effect(correlation, "cget", failed("sessionUnavailable"))
                                } else {
                                    lastConversationReply = reply
                                    effect(correlation, "cget", accepted(reply))
                                }
                            }
                        }
                        "op:v1:messagePage" -> effect(
                            correlation, "messagePage",
                            accepted(
                                """{"rows":$messageRowsJson,"hasEarlier":false,""" +
                                    """"earlierCursor":null}""",
                            ),
                        )
                        "op:v1:runSnapshot" -> {
                            snapshotPolls.incrementAndGet()
                            if (failRunSnapshot) {
                                effect(correlation, "runSnapshot",
                                    failed("snapshotUnavailable"))
                            } else {
                                val page = if (snapshotPages.isNotEmpty()) {
                                    snapshotPages.removeAt(0)
                                } else {
                                    lastSnapshotPage
                                }
                                if (page == null) {
                                    effect(correlation, "runSnapshot",
                                        failed("snapshotUnavailable"))
                                } else {
                                    lastSnapshotPage = page
                                    effect(correlation, "runSnapshot", accepted(page))
                                }
                            }
                        }
                        else -> effect(correlation, receipt, accepted(null))
                    }
                }
                request.contains("\"command\":\"conversation.get\"") ->
                    receipt(correlation, nextGets.poll()?.tag ?: "cget")
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, nextSnapshots.poll()?.tag ?: "runSnapshot")
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

        fun countOf(operation: String): Int =
            requests.count { it.contains("\"operation\":\"$operation\"") }

        fun countCommand(command: String): Int =
            requests.count { it.contains("\"command\":\"$command\"") }

        fun countCorrelation(prefix: String): Int =
            requests.count { it.contains("\"correlationID\":\"$prefix") }

        fun pollsFor(runID: String): Int =
            eventPollsByRun[runID]?.get() ?: 0

        private fun eventPollPage(request: String, correlation: String): String {
            val root = runCatching { Json.parseToJsonElement(request).jsonObject }.getOrNull()
            val envelope = root?.get("envelope")?.jsonObject
            val ownerRunID = envelope?.get("owner")?.jsonObject
                ?.get("runID")?.jsonPrimitive?.content ?: runId
            eventPollsByRun
                .computeIfAbsent(ownerRunID) { AtomicInteger() }
                .incrementAndGet()
            val cursor = envelope?.get("cursor")?.jsonObject
            val afterSequence =
                cursor?.get("sequence")?.jsonPrimitive?.content?.toLongOrNull() ?: 0L
            firstCursorByRun.putIfAbsent(ownerRunID, afterSequence)
            val events = StringBuilder()
            var nextSequence = afterSequence
            // Durable frames receive their sequence AT APPEND, stay in the
            // journal, and are never returned below the requested cursor.
            val pending = eventsByRun[ownerRunID].orEmpty().filter { it.first > afterSequence }
            for ((sequence, kind, payload) in pending) {
                if (events.length >= 24_000) break
                nextSequence = sequence
                if (events.isNotEmpty()) events.append(',')
                val escaped = payload.replace("\\", "\\\\").replace("\"", "\\\"")
                events.append(
                    """{"sequence":$sequence,"kind":"$kind","createdAt":1,""" +
                        """"payload":"$escaped"}""",
                )
            }
            return """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"runID":"$ownerRunID","sequence":$afterSequence},""" +
                """"durable":{"windowState":"$windowState","events":[$events],""" +
                """"hasMore":false,"resyncRequired":$durableResync,""" +
                """"nextSequence":$nextSequence},""" +
                """"live":{"liveState":"noConsumer","frames":[],""" +
                """"resyncRequired":false,"droppedDeltas":0},""" +
                """"resyncRequired":false}"""
        }

        private fun providerRow(): String =
            """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
                """"baseURL":"https://example.invalid/v1","displayName":"Local QA Fixture",""" +
                """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
                """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
                """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
                """"secret":{"configured":true,"opaqueReference":"ref:v1:abc",""" +
                """"synchronizable":false}}"""

        private fun modelRow(): String =
            """{"id":"$modelId","providerID":"$providerId",""" +
                """"remoteModelID":"fixture-local-qa","displayName":"Local QA Fixture",""" +
                """"limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
                """"capabilities":{"rawValue":7},"explicitCapabilities":null,""" +
                """"useSurfaces":null,"reasoningEffort":"automatic","isEnabled":true,""" +
                """"isHiddenFromPrimaryPicker":false,""" +
                """"revision":{"resourceID":"model.$modelId","version":"digest"}}"""

        private fun receipt(correlation: String, receiptTag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$receiptTag"}"""

        private fun accepted(valueJson: String?, detailJson: String = ""): String {
            val value = if (valueJson == null) "" else ""","value":$valueJson"""
            val detail = if (detailJson.isBlank()) "" else ""","detail":$detailJson"""
            return """{"sequence":1,"kind":"accepted"$value$detail}"""
        }

        private fun failed(code: String): String =
            """{"sequence":1,"kind":"failed","code":"$code"}"""

        private fun effect(
            correlation: String,
            receiptTag: String,
            effectsJson: String,
        ): String =
            """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"operationReceiptID":"op:v1:$receiptTag","sequence":2},""" +
                """"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""
    }

    // ----------------------------------------------------------------- hosts

    /** Baseline budgets ONLY — the rejected idle machinery is gone. */
    private fun client(
        exchange: HostBridgeExchange,
        pollMillis: Long = 1,
    ) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = ownedScope(),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = pollMillis),
    )

    private suspend fun readyHost(
        exchange: HostBridgeExchange,
        pollMillis: Long = 1,
    ): Pair<RuntimeHost, RuntimeHostCommandClient> {
        val commandClient = client(exchange, pollMillis)
        val host = RuntimeHost(
            commandClient = commandClient,
            gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = ownedScope(),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
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
        return host to commandClient
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

    private fun sessionRow(status: String = "queued"): String =
        """{"id":"$inputId","status":"$status","mode":"queue","position":1,""" +
            """"contentBytes":${queuedBody.toByteArray().size},"executionMode":"agent"}"""

    private fun snapshotRow(status: String = "queued"): String =
        """{"inputID":"$inputId","inputVersion":"$inputVersion","position":1,""" +
            """"status":"$status","mode":"queue","preview":"$queuedBody",""" +
            """"previewComplete":true,""" +
            """"contentBytes":${queuedBody.toByteArray().size},""" +
            """"executionMode":"agent"}"""

    /** Deterministic per-run started stamps (the discovery arm orders the
     *  NEWEST terminal lexicographically — B is genuinely later). */
    private fun startedAtOf(runID: String): String =
        if (runID == secondRunId) "2026-10-25T03:45:00.000Z"
        else "2026-10-25T03:40:00.000Z"

    /** Session reply with an explicit run list and queue window. */
    private fun conversationReply(
        runs: List<Pair<String, String>> = listOf(runId to "waitingApproval"),
        pendingInputs: String = "[${sessionRow()}]",
        truncated: Boolean = false,
        revision: String = "digest-1",
    ): String {
        val runsJson = runs.joinToString(",") { (id, state) ->
            """{"runID":"$id","state":"$state","modelName":"Local QA Fixture",""" +
                """"startedAt":"${startedAtOf(id)}"}"""
        }
        return """{"conversationID":"$conversationId","title":"Queue QA",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"$revision"},"runs":[$runsJson],""" +
            """"pendingInputs":$pendingInputs,""" +
            """"pendingInputsTruncated":$truncated,"taskPolicy":{"resolvedApprovalMode":"ask"}}"""
    }

    /** Authoritative `run.snapshot` page for the anchor run. */
    private fun snapshotPage(
        durableState: String,
        isTerminal: Boolean,
        pendingInputs: String,
        truncated: Boolean,
        watermark: Long,
        withApproval: Boolean = false,
    ): String {
        val approval = if (withApproval) {
            """{"callID":"call-1","tool":"exec.shell","reason":"probe command",""" +
                """"requestedAt":"2026-10-25T03:41:00.000Z"}"""
        } else {
            "null"
        }
        val approvalRevision = if (withApproval) {
            """{"resourceID":"approval.call-1",""" +
                """"version":"2026-10-25T03:41:00.000Z"}"""
        } else {
            "null"
        }
        return """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
            """"runID":"$runId","durableState":"$durableState",""" +
            """"revision":{"resourceID":"run.${runId.uppercase()}",""" +
            """"version":"$durableState"},"isTerminal":$isTerminal,""" +
            """"conversationMode":"chat","goal":"queue QA initialization",""" +
            """"liveOwner":${!isTerminal},"pendingApproval":$approval,""" +
            """"approvalRevision":$approvalRevision,""" +
            """"pendingInputs":$pendingInputs,"pendingInputsTruncated":$truncated,""" +
            """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
            """"version":"queue-digest-$watermark"},"durableWatermark":$watermark}"""
    }

    private fun messageRows(includeSecondRun: Boolean): String {
        val base = """[{"id":"u-$runId","role":"user","content":"probe",""" +
            """"createdAt":"2026-10-25T03:40:00.000Z","runID":"$runId"},""" +
            """{"id":"a-$runId","role":"assistant","content":"probe finished",""" +
            """"createdAt":"2026-10-25T03:42:00.000Z","runID":"$runId"}"""
        if (!includeSecondRun) return "$base]"
        return base + "," +
            """{"id":"u-$secondRunId","role":"user","content":"$queuedBody",""" +
            """"createdAt":"2026-10-25T03:42:30.000Z","runID":"$secondRunId"},""" +
            """{"id":"a-$secondRunId","role":"assistant",""" +
            """"content":"fixture reply echoing $queuedBody",""" +
            """"createdAt":"2026-10-25T03:42:31.000Z","runID":"$secondRunId"}]"""
    }

    /** The settle fact: an EXISTING `notice` frame carrying the stateless
     *  invalidation vocabulary. Kind `status` is the OLD REJECTED shape —
     *  it must NEVER be treated as the fact again. */
    private fun settleFact(lane: String, chain: String): String =
        """{"reason":"queueSettled","lane":"$lane","chain":"$chain"}"""

    private fun queueSettle(
        exchange: ScriptedExchange,
        runID: String,
        lane: String,
        chain: String,
    ) = exchange.queueEvent(runID, "notice", settleFact(lane, chain))

    private val terminalFramePayload = """{"state":"completed"}"""
    private val approvalRequestPayload =
        """{"tool":"exec.shell","callID":"call-1","scope":"local",""" +
            """"reason":"probe command","requestedAt":"2026-10-25T03:41:00.000Z"}"""
    private val approvalOutcomePayload =
        """{"tool":"exec.shell","callID":"call-1","outcome":"approved"}"""

    /**
     * Boots the host, loads the thread with the queued row projected while
     * the anchor run waits at its live inline approval, and returns the
     * loaded surface. Snapshot pages #1/#2 and the session reply #1 are
     * consumed here; the caller scripts the terminal phase.
     */
    private suspend fun bootWithQueuedRowUnderApproval(
        exchange: ScriptedExchange,
    ): Triple<RuntimeHost, com.floe.android.feature.conversation.ConversationFlowHolder, RuntimeHostCommandClient> {
        exchange.queueConversationReply(conversationReply())
        // #1: the load-time selected-run refresh (live inline Ask + row).
        exchange.queueSnapshot(
            snapshotPage("waitingApproval", isTerminal = false,
                pendingInputs = "[${snapshotRow()}]", truncated = false,
                watermark = 1, withApproval = true))
        // #2: the approval-request frame's CAS refresh.
        exchange.queueSnapshot(
            snapshotPage("waitingApproval", isTerminal = false,
                pendingInputs = "[${snapshotRow()}]", truncated = false,
                watermark = 2, withApproval = true))
        // #3: the terminal-frame refresh — the drain has NOT consumed yet
        // (the real race the device reproduction observed): row present.
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false,
                watermark = 3))
        exchange.messageRowsJson = messageRows(includeSecondRun = false)
        val (host, commandClient) = readyHost(exchange)
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(holder.session)
        assertTrue("thread must load", awaitCondition { holder.snapshot.value != null })
        // The row is queued WHILE the live approval is pending (the real
        // pre-approval device state).
        exchange.queueEvent(runId, "approval", approvalRequestPayload)
        assertTrue("approval card must project", awaitCondition {
            holder.snapshot.value?.pendingApprovals?.any { it.approvalId == "call-1" } == true
        })
        assertTrue("row queued while approval live", awaitCondition {
            holder.snapshot.value?.pendingInputs?.singleOrNull()?.status ==
                PendingInputStatusUi.QUEUED
        })
        assertTrue("both load and approval snapshots really applied", awaitCondition {
            host.conversations.entryFor(conversationId)?.builder?.queueRevision?.version ==
                "queue-digest-2"
        })
        return Triple(host, holder, commandClient)
    }

    /** Drives the real terminal boundary: approval outcome + completed. */
    private suspend fun settleTerminal(exchange: ScriptedExchange, host: RuntimeHost) {
        exchange.queueEvent(runId, "approval", approvalOutcomePayload)
        exchange.queueEvent(runId, "status", terminalFramePayload)
        assertTrue("terminal snapshot and queue observer both settled", awaitCondition {
            host.conversations.entryFor(conversationId)?.builder?.queueRevision?.version ==
                "queue-digest-3" &&
                host.conversations.queueSettleWatches[conversationId] != null
        })
    }

    private fun pendingRow(holder: com.floe.android.feature.conversation.ConversationFlowHolder)
        : Boolean =
        holder.snapshot.value?.pendingInputs?.any { it.status.isPending } == true

    // ---------------------------------------------------------------- tests

    /** K1 — the core device gap: a durably consumed row retires on the
     *  ACTIVE screen from the settle fact alone, with no navigation. */
    @Test
    fun consumedRowRetiresOnSettleFactWithoutNavigation() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue("run must reach terminal state", awaitCondition {
            holder.snapshot.value?.liveStateName == "completed"
        })
        // The row is STILL projected at the terminal boundary (page #3 was
        // honest: the drain had not consumed yet) — nothing may hide it.
        assertEquals(1, holder.snapshot.value?.pendingInputs?.size)
        // The terminal armed the per-conversation watch (real pending rows).
        val watch = host.conversations.queueSettleWatches[conversationId]
        assertNotNull("the pumped terminal with pending rows arms the watch", watch)

        // The native lane consumed the row and published its settle fact on
        // the anchor journal; the durable inbox now proves absence.
        exchange.messageRowsJson = messageRows(includeSecondRun = true)
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", revision = "digest-2"))
        // #4: the reconcile's selected-run snapshot — complete, absent.
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 4))
        queueSettle(exchange, runId, lane = "consumed", chain = "closed")

        assertTrue("consumed row must retire on the active screen, no navigation",
            awaitCondition(timeoutMillis = 6_000) {
                holder.snapshot.value?.pendingInputs?.isEmpty() == true
            })
        // The automatic second round's committed rows are visible too.
        assertTrue("second run's reply must project", awaitCondition {
            assistantTexts(holder.snapshot.value).any { it.contains("fixture reply echoing") }
        })
        // The reconcile re-reads; it NEVER launches or fabricates.
        assertEquals("no run.start may leave the App", 0, exchange.countCommand("run.start"))
        assertEquals("load + settle reconcile = exactly two session reads",
            2, exchange.countCommand("conversation.get"))
        // QUIET success: no queue failure token, no continuation error.
        assertNull(holder.queueRefreshFailureToken)
        assertNull(holder.snapshot.value?.continuationDetail)
        // Quiescent queue: the watch released itself (event polls stopped).
        val pollsAtSettle = exchange.pollsFor(runId)
        delay(250)
        assertEquals("the watch must close at quiescence",
            pollsAtSettle, exchange.pollsFor(runId))
        assertNull(host.conversations.queueSettleWatches[conversationId])
        host.conversations.releaseHolder(conversationId)
    }

    /** K2 (MAIN_ADDENDUM B) — replaces the parent's rejected timer test:
     *  a slow drain beyond ANY former bound still retires. A queue observer
     *  survives >260 consecutive `notAttached` polls (the REJECTED legacy
     *  ~10 s cutoff would have killed the ordinary pump at 201), then a
     *  REAL late fact retires the row. */
    @Test
    fun slowDrainBeyondAnyFormerIdleBoundStillRetires() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        // The anchor's window goes unavailable (evicted retired window). The
        // watch must NOT self-close at any count: it is a QUEUE OBSERVER.
        exchange.windowState = "notAttached"
        val grew = awaitCondition(timeoutMillis = 8_000) {
            exchange.pollsFor(runId) > 260
        }
        assertTrue("a queue observer must keep watching past 260 notAttached polls", grew)
        // Still growing, still armed, NO failure surfaced, NO repeated reads.
        val before = exchange.pollsFor(runId)
        delay(120)
        assertTrue("polls keep flowing (no idle cutoff fired)",
            exchange.pollsFor(runId) > before)
        assertNotNull("the watch is still the current one",
            host.conversations.queueSettleWatches[conversationId])
        assertNull("a slow drain is not a user-visible failure",
            holder.queueRefreshFailureToken)
        assertNull(holder.snapshot.value?.continuationDetail)
        assertEquals("no repeated conversation polling while observing",
            1, exchange.countCommand("conversation.get"))
        // The real late fact arrives (window re-attached through the SAME
        // binder poll): retirement happens without navigation.
        exchange.windowState = "attached"
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 4))
        queueSettle(exchange, runId, lane = "consumed", chain = "closed")
        assertTrue("the late fact retires the row",
            awaitCondition(timeoutMillis = 6_000) {
                holder.snapshot.value?.pendingInputs?.isEmpty() == true
            })
        assertEquals(0, exchange.countCommand("run.start"))
        host.conversations.releaseHolder(conversationId)
    }

    /** K3 — refusal-at-rest closes honestly; a chained OPEN fact keeps the
     *  (causally re-armed) watch until real pages retire the row. Phase 2's
     *  second arm comes from the LATE-B DISCOVERY on the phase-1 page (no
     *  manual re-kick): the newest unprocessed terminal run is armed. */
    @Test
    fun refusedRestClosesWatchAndChainedOpenFactKeepsIt() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })

        // PHASE 1: the lane REFUSED and restored the row; the fact says
        // refused + chain closed. Pages prove the row queued → retain.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[${sessionRow()}]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false, watermark = 4))
        queueSettle(exchange, runId, lane = "refused", chain = "closed")
        assertTrue("the settle reconcile must run", awaitCondition {
            exchange.countCommand("conversation.get") == 2
        })
        assertTrue(awaitCondition(timeoutMillis = 6_000) {
            val rows = holder.snapshot.value?.pendingInputs
            rows?.singleOrNull()?.status == PendingInputStatusUi.QUEUED
        })
        assertEquals("a restored row is never fabricated as consumed",
            queuedBody, holder.snapshot.value?.pendingInputs?.single()?.content)
        // No forever-hot watch on the CLOSED chain: A's stream stopped…
        val aAtClose = exchange.pollsFor(runId)
        delay(150)
        assertEquals("the honest chain-closed fact releases its watch",
            aAtClose, exchange.pollsFor(runId))
        // …but the phase-1 page's NEWEST terminal (B, later startedAt) was
        // causally discovered while rows stayed pending: B now carries the
        // single watch (one watch per conversation, latest arm wins).
        assertTrue("the discovery arm keeps observation causal on B",
            awaitCondition { exchange.pollsFor(secondRunId) > 3 })
        assertEquals("the replacement moved the conversation watch to B",
            secondRunId, host.conversations.queueSettleWatches[conversationId]?.anchorRunID)
        assertNull("a refusal at rest is honest state, not a failure",
            holder.queueRefreshFailureToken)
        assertEquals("no extra session read between facts", 2,
            exchange.countCommand("conversation.get"))

        // PHASE 2: the chained lane publishes refused + chain OPEN on B.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[${sessionRow()}]", revision = "digest-3"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false, watermark = 5))
        queueSettle(exchange, secondRunId, lane = "refused", chain = "open")
        assertTrue("the open-chain fact triggers the next reconcile", awaitCondition {
            exchange.countCommand("conversation.get") == 3
        })
        val bWhileOpen = exchange.pollsFor(secondRunId)
        delay(150)
        assertTrue("chain open + real pending rows keeps the watch armed",
            exchange.pollsFor(secondRunId) > bWhileOpen)
        assertTrue(pendingRow(holder))

        // PHASE 3: the successor really consumed: absent complete pages +
        // consumed/closed retire the row — and only then.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[]", revision = "digest-4"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 6))
        queueSettle(exchange, secondRunId, lane = "consumed", chain = "closed")
        assertTrue("the row retires only when real pages prove absence",
            awaitCondition(timeoutMillis = 6_000) {
                holder.snapshot.value?.pendingInputs?.isEmpty() == true
            })
        assertEquals(0, exchange.countCommand("run.start"))
        host.conversations.releaseHolder(conversationId)
    }

    /** K4 (QREV-03 host path) — the degraded-window resync signal drives
     *  ONE authoritative reconcile that recovers QUIETLY from real pages;
     *  once-per-watch bounds keep it finite. */
    @Test
    fun degradedWindowResyncRecoversQuietlyFromAuthoritativePages() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        // No settle fact EVER arrives (append failed on the native side):
        // the typed signal on the same stream is the recovery trigger.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 4))
        exchange.durableResync = true   // stays true: once-per-watch bounds
        assertTrue("the resync signal runs the authoritative reconcile", awaitCondition {
            exchange.countCorrelation("cget-qstl") == 1
        })
        assertTrue("the row RETIRES (real recovery)",
            awaitCondition(timeoutMillis = 6_000) {
                holder.snapshot.value?.pendingInputs?.isEmpty() == true
            })
        // QUIET success per the Main steer.
        assertNull(holder.queueRefreshFailureToken)
        assertNull(holder.snapshot.value?.continuationDetail)
        // Watch closed at the resync reconcile (quiet): polls stop, and the
        // still-true flag fires NO second reconcile (once per watch).
        val pollsAtSettle = exchange.pollsFor(runId)
        delay(250)
        assertEquals("the watch must stop polling after the bounded resync",
            pollsAtSettle, exchange.pollsFor(runId))
        assertEquals("durableResync still true ⇒ still exactly one reconcile",
            1, exchange.countCorrelation("cget-qstl"))
        host.conversations.releaseHolder(conversationId)
    }

    /** K5 (MAIN_ADDENDUM C+D) — a GENUINE recovery failure is visible with
     *  a READ-ONLY Retry: snapshot failure with conversation-get success is
     *  NOT "recovered"; the failed retry persists the SAME token; a busy
     *  retry refuses; only a successful complete recovery clears the exact
     *  token, and the unrelated generic actionError is never touched. */
    @Test
    fun recoveryFailureSurfacesReadOnlyRetryAndPersists() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        // A generic error pre-exists on the independent surface.
        holder.noteHostActionError("generic_unrelated")
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        // conversation.get SUCCEEDS, the snapshot FAILS → must not look
        // recovered (honoring the onApplied Boolean, not just completion).
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[${sessionRow()}]", revision = "digest-2"))
        exchange.failRunSnapshot = true
        exchange.durableResync = true
        assertTrue("the incomplete recovery surfaces a queue failure token",
            awaitCondition { holder.queueRefreshFailureToken != null })
        // …on the COMPLETED run whose continuation bar renders nothing:
        // the queue surface is independent of canContinue/continuationDetail.
        assertEquals("completed", holder.snapshot.value?.liveStateName)
        assertNull("the generic continuation surface stays uninvolved",
            holder.snapshot.value?.continuationDetail)
        assertTrue(pendingRow(holder))
        assertEquals(1, exchange.countCorrelation("cget-qstl"))

        // RETRY #1 fails again (snapshot still down): the SAME token stays.
        val token = holder.queueRefreshFailureToken
        assertNotNull(token)
        assertTrue("the visible Retry is available and accepted",
            holder.retryQueueRefresh())
        assertTrue(awaitCondition { exchange.countCorrelation("cget-qrr") == 1 })
        delay(120)
        assertEquals("a failed retry never clears or stacks the token",
            token, holder.queueRefreshFailureToken)
        // RETRY #2 succeeds with complete pages: exact-token clear.
        exchange.failRunSnapshot = false
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", revision = "digest-3"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 5))
        assertTrue(holder.retryQueueRefresh())
        assertTrue("only a successful authoritative recovery clears the failure",
            awaitCondition(timeoutMillis = 6_000) {
                holder.queueRefreshFailureToken == null
            })
        assertTrue(awaitCondition {
            holder.snapshot.value?.pendingInputs?.isEmpty() == true
        })
        // READ-ONLY: retries emit commands ONLY (no business execution ever).
        assertEquals(0, exchange.countCommand("run.start"))
        assertEquals(0, exchange.countCommand("run.retry"))
        assertEquals(0, exchange.countCommand("run.cancel"))
        assertEquals(0, exchange.countCommand("run.approve"))
        // The click path never cleared anything UNRELATED:
        assertEquals("generic_unrelated", holder.actionError)
        // Stale clears cannot erase a NEWER failure (exact-token rule):
        assertNotNull(token)
        holder.noteQueueRefreshFailure("newer-token")
        assertFalse("a stale token never clears the newer failure",
            holder.clearQueueRefreshFailure(token!!))
        assertEquals("newer-token", holder.queueRefreshFailureToken)
        assertTrue(holder.clearQueueRefreshFailure("newer-token"))
        host.conversations.releaseHolder(conversationId)
    }

    /** K6 — the named late-B gap: B retired BETWEEN the session read and
     *  the consumption pages; discovery arms B from the reconcile's own
     *  page and B's fact retires row2 with exactly ONE user bubble. */
    @Test
    fun lateRunBDiscoveredFromSessionPageAcrossTheNamedGap() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        // A's fact: consumed but CHAIN OPEN (a fast internally launched B is
        // still settling). B already retired but only appears on THIS page.
        exchange.messageRowsJson = messageRows(includeSecondRun = true)
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[${sessionRow()}]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false, watermark = 4))
        queueSettle(exchange, runId, lane = "consumed", chain = "open")
        // Discovery replaces the watch onto B (the newest unprocessed
        // terminal): A's stream stops, B's stream starts.
        assertTrue("B is discovered and armed from the reconcile's own page",
            awaitCondition {
                host.conversations.queueSettleWatches[conversationId]?.anchorRunID ==
                    secondRunId && exchange.pollsFor(secondRunId) > 3
            })
        val aAtReplace = exchange.pollsFor(runId)
        delay(150)
        assertEquals("the replaced A watch stops polling",
            aAtReplace, exchange.pollsFor(runId))

        // B's fact (durable cursor delivered through the binder at the
        // first real poll) + absent complete pages retire row2.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[]", revision = "digest-3"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 5))
        queueSettle(exchange, secondRunId, lane = "consumed", chain = "closed")
        assertTrue("row2 retires through the discovered watch",
            awaitCondition(timeoutMillis = 6_000) {
                holder.snapshot.value?.pendingInputs?.isEmpty() == true
            })
        assertEquals(0, exchange.countCommand("run.start"))
        val userBubbles = holder.snapshot.value?.rows.orEmpty().filter {
            it is TimelineRowUi.UserMessage &&
                it.message.text.contains("C09_QUEUE_ONCE")
        }
        assertEquals("exactly one user bubble for row2 — never duplicated",
            1, userBubbles.size)
        host.conversations.releaseHolder(conversationId)
    }

    /** K7 — replacement and lifecycle fences: a live B pumps normally and
     *  its own terminal replaces the watch; after holder retire EVERYTHING
     *  stops and a late stale fact drives no reconcile and cannot mutate
     *  the replacement surface. */
    @Test
    fun replacementAndLifecycleFences() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        val watchA = host.conversations.queueSettleWatches[conversationId]
        assertNotNull(watchA)
        // A's open-chain fact; the page lists B as LIVE — resumeLiveRuns
        // re-attaches B through the ORIGINAL pump lifecycle (read-only).
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "streamingModel"),
                pendingInputs = "[${sessionRow()}]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false, watermark = 4))
        queueSettle(exchange, runId, lane = "consumed", chain = "open")
        assertTrue("the reconcile re-attaches the live B", awaitCondition {
            exchange.countCorrelation("cget-qstl") == 1 &&
                exchange.pollsFor(secondRunId) > 3
        })
        val aWhileOpen = exchange.pollsFor(runId)
        delay(120)
        assertTrue("chain open keeps A's watch armed",
            exchange.pollsFor(runId) > aWhileOpen)
        // B's own terminal frame replaces the watch (latest terminal wins).
        exchange.queueEvent(secondRunId, "status", terminalFramePayload)
        assertTrue("B's terminal boundary arms the replacement watch",
            awaitCondition(timeoutMillis = 6_000) {
                host.conversations.queueSettleWatches[conversationId]?.anchorRunID ==
                    secondRunId
            })
        val aAtReplace = exchange.pollsFor(runId)
        delay(150)
        assertEquals("A polls stop at replacement", aAtReplace, exchange.pollsFor(runId))
        val bWatchPolls = exchange.pollsFor(secondRunId)
        assertTrue("the replacement watch polls B",
            awaitCondition { exchange.pollsFor(secondRunId) > bWatchPolls })
        // B's fact + absence retires the row.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed", secondRunId to "completed"),
                pendingInputs = "[]", revision = "digest-3"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 5))
        queueSettle(exchange, secondRunId, lane = "consumed", chain = "closed")
        assertTrue(awaitCondition(timeoutMillis = 6_000) {
            holder.snapshot.value?.pendingInputs?.isEmpty() == true
        })
        // Holder retire: every poll stops.
        host.conversations.releaseHolder(conversationId)
        val pollsAfterRetire = exchange.pollsFor(secondRunId)
        delay(250)
        assertEquals("holder retire ends ALL observation",
            pollsAfterRetire, exchange.pollsFor(secondRunId))
        assertNull(host.conversations.queueSettleWatches[conversationId])
        // A late STALE callback (retired watch A) can neither close/mutate
        // the replacement nor start a new reconcile.
        val reconcilesBefore = exchange.countCorrelation("cget-qstl")
        watchA?.let {
            host.conversations.onQueueSettleFrame(
                host.conversations.entryFor(conversationId) ?: return@let,
                it,
                settleFrame(runId, "consumed", "closed"),
                conversationId,
                holder.session.sessionEpoch,
            )
        }
        delay(150)
        assertEquals("a retired callback drives no reconcile",
            reconcilesBefore, exchange.countCorrelation("cget-qstl"))
    }

    /** K8 — arm guards + settle vocabulary purity, INCLUDING the settled
     *  NOTICE correction: a `.status` frame with `reason == queueSettled`
     *  is NOT the fact anymore (the old shape was retired by the actual
     *  native interrupted-truth regression); the terminal `status` frame
     *  keeps driving terminal truth untouched. */
    @Test
    fun armGuardsAndSettleVocabulary() = runBlockingTest {
        fun frame(kind: String, payload: JsonObject?) = HostRunEventFrame(
            runID = runId, sequence = 9, kind = kind, payload = payload, bytes = 64)
        val settle = buildJsonObject {
            put("reason", JsonPrimitive("queueSettled"))
            put("lane", JsonPrimitive("consumed"))
            put("chain", JsonPrimitive("closed"))
        }
        assertTrue("the fact is a NOTICE frame", isQueueSettleFrame(frame("notice", settle)))
        assertFalse("the OLD stateless status shape is REJECTED (never assume it again)",
            isQueueSettleFrame(frame("status", settle)))
        assertFalse("a state member makes it a run-state frame, never the fact",
            isQueueSettleFrame(frame("notice", buildJsonObject {
                put("reason", JsonPrimitive("queueSettled"))
                put("state", JsonPrimitive("completed"))
            })))
        assertFalse(isQueueSettleFrame(frame("terminal", settle)))
        assertFalse(isQueueSettleFrame(frame("notice", null)))
        assertFalse(isQueueSettleFrame(frame("notice", buildJsonObject {
            put("reason", JsonPrimitive("somethingElse"))
        })))
        assertFalse(isQueueSettleFrame(frame("notice", buildJsonObject {
            put("reason", JsonPrimitive(7))
        })))
        // decode defaults are CONSERVATIVE (keep observing) — never a guess
        // that a later fact is absent.
        val open = decodeQueueSettleFact(frame("notice", buildJsonObject {
            put("reason", JsonPrimitive("queueSettled"))
        }))
        assertTrue("absent chain decodes OPEN", open.chainOpen)
        assertEquals("absent lane decodes the ordinary consumed exit",
            "consumed", open.lane)
        val closed = decodeQueueSettleFact(frame("notice", settle))
        assertFalse(closed.chainOpen)
        assertEquals("consumed", closed.lane)

        // Empty queue arms nothing.
        val exchange = ScriptedExchange()
        exchange.queueConversationReply(conversationReply(pendingInputs = "[]"))
        exchange.queueSnapshot(
            snapshotPage("waitingApproval", isTerminal = false, pendingInputs = "[]",
                truncated = false, watermark = 1, withApproval = true))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 2))
        exchange.messageRowsJson = messageRows(includeSecondRun = false)
        val (host, _) = readyHost(exchange)
        val emptyHolder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(emptyHolder.session)
        assertTrue(awaitCondition { emptyHolder.snapshot.value != null })
        exchange.queueEvent(runId, "status", terminalFramePayload)
        assertTrue(awaitCondition { emptyHolder.snapshot.value?.liveStateName == "completed" })
        val pollsAtTerminal = exchange.pollsFor(runId)
        delay(200)
        assertEquals("an empty queue keeps no stream warm",
            pollsAtTerminal, exchange.pollsFor(runId))
        assertEquals("no settle reconcile without pending rows",
            0, exchange.countCorrelation("cget-qstl"))
        host.conversations.releaseHolder(conversationId)

        // A temporary surface arms nothing.
        val exchange2 = ScriptedExchange()
        exchange2.queueConversationReply(
            conversationReply(pendingInputs = "[${sessionRow()}]"))
        exchange2.queueSnapshot(
            snapshotPage("waitingApproval", isTerminal = false,
                pendingInputs = "[${snapshotRow()}]", truncated = false,
                watermark = 1, withApproval = true))
        exchange2.queueSnapshot(
            snapshotPage("completed", isTerminal = true,
                pendingInputs = "[${snapshotRow()}]", truncated = false, watermark = 2))
        exchange2.messageRowsJson = messageRows(includeSecondRun = false)
        val (host2, _) = readyHost(exchange2)
        val tempHolder = host2.conversations.holderFor(
            conversationId, isTemporary = true, incarnationId = "temp-inc-1")
        host2.conversations.loadThread(tempHolder.session)
        assertTrue(awaitCondition { tempHolder.snapshot.value != null })
        exchange2.queueEvent(runId, "status", terminalFramePayload)
        assertTrue(awaitCondition { tempHolder.snapshot.value?.liveStateName == "completed" })
        val tempPolls = exchange2.pollsFor(runId)
        delay(200)
        assertEquals("a temporary queue belongs to its RAM run lifecycle",
            tempPolls, exchange2.pollsFor(runId))
        assertEquals(0, exchange2.countCorrelation("cget-qstl"))
        host2.conversations.releaseHolder(conversationId)
    }

    /** Addendum A — the registration ORDER proof. The watch identity must
     *  exist BEFORE the stream's IO can deliver: a synchronous early close
     *  (Superseded-style lifecycle) only removes state and the arm's
     *  post-open check DISPOSES the late-created handle (no orphan stream);
     *  a synchronous early FACT/resync is NEVER discarded by the identity
     *  fence and drives the real reconcile. */
    @Test
    fun queueObserverRegistersBeforeItsOwnIo() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, commandClient) = bootWithQueuedRowUnderApproval(exchange)
        val controller = host.conversations
        val entry = controller.entryFor(conversationId)!!
        val epoch = holder.session.sessionEpoch

        // PHASE 1: an immediate lifecycle close BEFORE the handle exists.
        var injected: EventPumpHandle? = null
        controller.maybeArmQueueSettleWatch(
            entry, secondRunId, 0L,
        ) { watch ->
            val handle = commandClient.openRunEventStream(
                taskID = conversationId,
                runID = secondRunId,
                environmentID = null,
                jobID = null,
                onEvent = {},
                onLiveHint = {},
                onFailure = {},
            )
            injected = handle
            // The "early callback": a Superseded pump exit delivered before
            // the arm stored the handle.
            controller.onQueueSettleWatchFailure(
                entry, watch, HostPumpFailure.Superseded, conversationId, epoch,
            )
            handle
        }
        // The early close removed the watcher state while handleRef was null.
        assertNull("early close removed the watcher state",
            controller.queueSettleWatches[conversationId])
        delay(120)
        // The post-open check disposed the late-created handle: no orphan.
        val orphan = injected
        assertNotNull(orphan)
        assertTrue("the disposed late handle is really closed",
            orphan?.job?.isActive != true)
        assertEquals("no reconcile from a lifecycle exit",
            0, controller.queueSettleReconcilesInFlight.size +
                exchange.countCorrelation("cget-qstl"))

        settleTerminal(exchange, host)
        assertTrue(awaitCondition { entry.builder.queueRevision?.version == "queue-digest-3" })
        // PHASE 2: an immediate settle FACT before the handle returns is
        // not discarded — it drives the real authoritative reconcile.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 4))
        controller.maybeArmQueueSettleWatch(
            entry, secondRunId, 0L,
        ) { watch ->
            controller.onQueueSettleFrame(
                entry, watch,
                settleFrame(secondRunId, "consumed", "closed"),
                conversationId, epoch,
            )
            commandClient.openRunEventStream(
                taskID = conversationId,
                runID = secondRunId,
                environmentID = null,
                jobID = null,
                onEvent = {},
                onLiveHint = {},
                onFailure = {},
            )
        }
        // The early fact is CURRENT (identity installed first): reconcile ran.
        assertTrue("the early fact was NOT discarded", awaitCondition {
            exchange.countCorrelation("cget-qstl") >= 1
        })
        // …and it retired the row (the second complete-absent page pair).
        assertTrue(awaitCondition(timeoutMillis = 6_000) {
            holder.snapshot.value?.pendingInputs?.isEmpty() == true
        })
        assertTrue("committed rows finish before recovery releases its watch", awaitCondition {
            controller.queueSettleReconcilesInFlight.isEmpty() &&
                controller.queueSettleWatches[conversationId] == null
        })
        assertNull("the watch closed at the quiet success",
            controller.queueSettleWatches[conversationId])
        host.conversations.releaseHolder(conversationId)
    }

    /** Addendum C — a TRUNCATED authoritative queue page is never complete
     *  truth: recovery reports itself INCOMPLETE (visible read-only Retry)
     *  while the unknown row stays projected; a later complete-page retry
     *  succeeds and clears. No snapshot polling workaround anywhere. */
    @Test
    fun truncatedPageNeverClaimsRecovery() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        // The reconcile's session page is TRUNCATED (native budget): the
        // absent rows below are UNKNOWN, not gone.
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", truncated = true, revision = "digest-2"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = true, watermark = 4))
        queueSettle(exchange, runId, lane = "consumed", chain = "closed")
        assertTrue("the incomplete recovery surfaces a queue failure",
            awaitCondition { holder.queueRefreshFailureToken != null })
        // Nothing was fabricated: the projection still shows the ORIGINAL
        // row (an unknown row is never a gone row — the baseline rule held).
        assertTrue("a truncated page may not retire the row", pendingRow(holder))
        // The honest read-only retry with COMPLETE pages: clears + retires.
        val token = holder.queueRefreshFailureToken
        exchange.queueConversationReply(
            conversationReply(
                runs = listOf(runId to "completed"),
                pendingInputs = "[]", truncated = false, revision = "digest-3"))
        exchange.queueSnapshot(
            snapshotPage("completed", isTerminal = true, pendingInputs = "[]",
                truncated = false, watermark = 5))
        assertTrue(holder.retryQueueRefresh())
        assertTrue(awaitCondition(timeoutMillis = 6_000) {
            holder.queueRefreshFailureToken == null
        })
        // The consumed token can never clear anything again (exact-token rule):
        assertNotNull(token)
        assertFalse(holder.clearQueueRefreshFailure(token!!))
        assertTrue(holder.snapshot.value?.pendingInputs?.isEmpty() == true)
        assertEquals(0, exchange.countCommand("run.start"))
        host.conversations.releaseHolder(conversationId)
    }

    /** Addendum C fences — a stale owner after holder release must NEVER
     *  surface a failure or mutate another owner: close is quiet. */
    @Test
    fun releasedOwnerReconcileStaysQuiet() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        settleTerminal(exchange, host)
        assertTrue(awaitCondition { holder.snapshot.value?.liveStateName == "completed" })
        val controller = host.conversations
        val entry = controller.entryFor(conversationId)!!
        val epoch = holder.session.sessionEpoch
        // Drop the surface, THEN deliver a late settle fact through the
        // production reconcile entry (a late binder callback shape).
        holder.retireForNavigation()
        controller.releaseHolder(conversationId)
        controller.reconcileQueueAfterDrainSettle(
            entry, conversationId, epoch,
            watch = null,
            fact = QueueSettleFact("consumed", chainOpen = false),
            resync = false,
        )
        delay(250)
        assertFalse(holder.retired == false)
        assertNull("a retired owner surfaces no queue failure",
            holder.queueRefreshFailureToken)
        host.conversations.stop()
    }


    @Test fun immediateFinishedPumpKeepsFailedRecoveryOwned() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, commandClient) = bootWithQueuedRowUnderApproval(exchange)
        val controller = host.conversations
        val entry = controller.entryFor(conversationId)!!
        val get = exchange.holdGet(conversationReply(
            runs = listOf(runId to "completed"), pendingInputs = "[]"))
        exchange.failRunSnapshot = true
        controller.maybeArmQueueSettleWatch(entry, secondRunId, 0L) { watch ->
            val finishedHandle = commandClient.openRunEventStream(
                taskID = conversationId, runID = secondRunId,
                environmentID = null, jobID = null,
                onEvent = {}, onLiveHint = {}, onFailure = {})
            finishedHandle.close()
            controller.onQueueSettleWatchFailure(entry, watch,
                HostPumpFailure.Recoverable("fixtureFailure", "synthetic read failure"), conversationId,
                holder.session.sessionEpoch)
            finishedHandle
        }
        assertTrue(awaitCondition { get.polled.get() > 0 })
        assertNotNull("a finished poll is not a finished recovery",
            controller.queueSettleWatches[conversationId])
        get.released.set(true)
        assertTrue("failed snapshot stays visible even after absent get",
            awaitCondition { holder.queueRefreshFailureToken != null })
        assertNull(controller.queueSettleWatches[conversationId])
    }

    @Test fun healthyManualReadClearsErrorWhileQueuedRowRemains() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        holder.noteQueueRefreshFailure("owned-read-error")
        exchange.messageRowsJson = messageRows(includeSecondRun = true)
        assertTrue(holder.retryQueueRefresh())
        assertTrue(awaitCondition { holder.queueRefreshFailureToken == null })
        assertTrue("real queued work is retained", pendingRow(holder))
        assertTrue(awaitCondition { assistantTexts(holder.snapshot.value)
            .any { it.contains("fixture reply echoing") } })
        for (command in listOf("run.start", "run.retry", "run.cancel"))
            assertEquals(command, 0, exchange.countCommand(command))
    }

    @Test fun replacedWatchCannotApplyOldGetOrReleaseNewOperation() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        val c = host.conversations
        val entry = c.entryFor(conversationId)!!
        c.maybeArmQueueSettleWatch(entry, runId, 0L) { null }
        val a = c.queueSettleWatches[conversationId]!!
        val oldGet = exchange.holdGet(conversationReply(pendingInputs = "[]")
            .replace("Queue QA", "STALE-A"))
        c.onQueueSettleFrame(entry, a, settleFrame(runId, "consumed", "closed"),
            conversationId, holder.session.sessionEpoch)
        assertTrue(awaitCondition { oldGet.polled.get() > 0 })
        val oldRead = c.queueSettleReconcilesInFlight[conversationId]!!
        c.maybeArmQueueSettleWatch(entry, secondRunId, 0L) { null }
        val b = c.queueSettleWatches[conversationId]!!
        val newGet = exchange.holdGet(conversationReply().replace("Queue QA", "CURRENT-B"))
        c.onQueueSettleFrame(entry, b, settleFrame(secondRunId, "consumed", "open"),
            conversationId, holder.session.sessionEpoch)
        assertTrue(awaitCondition { newGet.polled.get() > 0 })
        val newRead = c.queueSettleReconcilesInFlight[conversationId]!!
        oldGet.released.set(true)
        assertTrue(awaitCondition { oldRead.completed.get() })
        assertTrue(c.queueSettleReconcilesInFlight[conversationId] === newRead)
        assertTrue(c.queueSettleWatches[conversationId] === b)
        assertTrue("stale absent page cannot retire current row", pendingRow(holder))
        assertFalse(holder.snapshot.value.toString().contains("STALE-A"))
        newGet.released.set(true)
        assertTrue(awaitCondition { newRead.completed.get() })
        assertTrue(pendingRow(holder))
    }

    @Test fun supersededManualTokenRejectsPendingGetBeforeApplication() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        val c = host.conversations
        holder.noteQueueRefreshFailure("old-token")
        val get = exchange.holdGet(conversationReply(pendingInputs = "[]"))
        assertTrue(holder.retryQueueRefresh())
        assertTrue(awaitCondition { get.polled.get() > 0 })
        val read = c.queueSettleReconcilesInFlight[conversationId]!!
        holder.noteQueueRefreshFailure("new-token")
        get.released.set(true)
        assertTrue(awaitCondition { read.completed.get() })
        assertEquals("new-token", holder.queueRefreshFailureToken)
        assertTrue(pendingRow(holder))
    }

    @Test fun generationChangeRejectsAlreadyPendingSnapshotApplication() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        val c = host.conversations
        val entry = c.entryFor(conversationId)!!
        c.maybeArmQueueSettleWatch(entry, runId, 0L) { null }
        val watch = c.queueSettleWatches[conversationId]!!
        val snapshot = exchange.holdSnapshot(snapshotPage("completed", true,
            "[]", false, 90))
        c.onQueueSettleFrame(entry, watch, settleFrame(runId, "consumed", "closed"),
            conversationId, holder.session.sessionEpoch)
        assertTrue(awaitCondition { snapshot.polled.get() > 0 })
        val read = c.queueSettleReconcilesInFlight[conversationId]!!
        c.rearmRunStreamAfterRetry(entry, runId)
        snapshot.released.set(true)
        assertTrue(awaitCondition { read.completed.get() })
        assertTrue("old snapshot cannot clear resumed pending work", pendingRow(holder))
        assertNull("obsolete read fails quietly", holder.queueRefreshFailureToken)
    }


    @Test fun precommittedNoticeIsNotSkippedBySnapshotWatermark() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        // Ordinary pump consumes the notice but never learns a terminal
        // event. Its real notAttached failure learns terminal from page #3
        // (watermark 3 >= already-appended notice 2). The newly armed QUEUE
        // reader must not seed from that snapshot header.
        exchange.queueConversationReply(conversationReply(
            runs = listOf(runId to "completed"), pendingInputs = "[]"))
        exchange.queueSnapshot(snapshotPage("completed", true, "[]", false, 100))
        queueSettle(exchange, runId, "consumed", "closed")
        exchange.windowState = "notAttached"
        assertTrue("snapshot-learned terminal recovers the precommitted fact",
            awaitCondition(8_000) { !pendingRow(holder) })
        assertEquals(2, exchange.countCommand("conversation.get"))
        assertNull(holder.queueRefreshFailureToken)
    }

    @Test fun retiredEntryCompletionCannotReleaseSameIdReplacementRead() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        val c = host.conversations
        holder.noteQueueRefreshFailure("old-entry-token")
        val oldGet = exchange.holdGet(conversationReply(pendingInputs = "[]"))
        assertTrue(holder.retryQueueRefresh())
        assertTrue(awaitCondition { oldGet.polled.get() > 0 })
        val oldRead = c.queueSettleReconcilesInFlight[conversationId]!!
        c.releaseHolder(conversationId)
        val replacement = c.holderFor(conversationId, false, null)
        c.loadThread(replacement.session)
        assertTrue(awaitCondition { pendingRow(replacement) })
        replacement.noteQueueRefreshFailure("replacement-token")
        val newGet = exchange.holdGet(conversationReply())
        assertTrue(replacement.retryQueueRefresh())
        assertTrue(awaitCondition { newGet.polled.get() > 0 })
        val newRead = c.queueSettleReconcilesInFlight[conversationId]!!
        oldGet.released.set(true)
        assertTrue(awaitCondition { oldRead.completed.get() })
        assertTrue(c.queueSettleReconcilesInFlight[conversationId] === newRead)
        assertEquals("replacement-token", replacement.queueRefreshFailureToken)
        assertTrue(pendingRow(replacement))
        newGet.released.set(true)
        assertTrue(awaitCondition { newRead.completed.get() })
        assertNull(replacement.queueRefreshFailureToken)
    }

    @Test fun supersededManualTokenRejectsPendingSnapshotBeforeApplication() = runBlockingTest {
        val exchange = ScriptedExchange()
        val (host, holder, _) = bootWithQueuedRowUnderApproval(exchange)
        holder.noteQueueRefreshFailure("old-token")
        val snapshot = exchange.holdSnapshot(snapshotPage("completed", true,
            "[]", false, 90))
        assertTrue(holder.retryQueueRefresh())
        assertTrue(awaitCondition { snapshot.polled.get() > 0 })
        val read = host.conversations.queueSettleReconcilesInFlight[conversationId]!!
        holder.noteQueueRefreshFailure("new-token")
        snapshot.released.set(true)
        assertTrue(awaitCondition { read.completed.get() })
        assertEquals("new-token", holder.queueRefreshFailureToken)
        assertTrue(pendingRow(holder))
    }

    // ---------------------------------------------------------------- helpers

    private fun settleFrame(runID: String, lane: String, chain: String) =
        HostRunEventFrame(
            runID = runID,
            sequence = 4_000_000L,
            kind = "notice",
            payload = buildJsonObject {
                put("reason", JsonPrimitive("queueSettled"))
                put("lane", JsonPrimitive(lane))
                put("chain", JsonPrimitive(chain))
            },
            bytes = 64,
        )

    private fun assistantTexts(state: ThreadUiState?): List<String> =
        state?.rows.orEmpty().mapNotNull { row ->
            when (row) {
                is TimelineRowUi.AssistantMessage -> row.text
                else -> null
            }
        }

    /**
     * The existing suite runs on a real coroutine scope with bounded waits;
     * these are controller-level async regressions, so each test body runs
     * inside a bounded blocking scope (no test dispatcher virtual time —
     * the pumps use real delays exactly like production).
     */
    private fun runBlockingTest(body: suspend () -> Unit) {
        kotlinx.coroutines.runBlocking { body() }
    }
}
