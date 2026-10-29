// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesruntime

import com.floe.android.host.HostBridgeExchange
import com.floe.android.host.HostWireBudgets
import com.floe.android.host.RuntimeHostCommandClient
import com.floe.android.feature.notes.ui.api.NotesAssistantContext
import com.floe.android.feature.notes.ui.api.NotesAssistantEvent
import com.floe.android.feature.notes.ui.api.NotesAssistantSendRequest
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Notes assistant stream adapter — regressions at the ACTUAL pump boundary.
 *
 * These drive the real [RuntimeHostCommandClient] over a scripted
 * [HostBridgeExchange] (the same mechanism the G02 live-stream regression
 * uses): the real `floe.event-cursor/3` durable/live page, the real
 * `run.snapshot` effect carrier, the real single-flight coalescing and the
 * real per-run terminal settlement. Nothing here is a device/App claim.
 */
class NotesAssistantRunStreamTest {
    private val conversationID = "11111111-1111-4111-8111-111111111111"
    private val documentID = "22222222-2222-4222-8222-222222222222"
    private val runID = "33333333-3333-4333-8333-333333333333"

    // ------------------------------------------------------------- transport

    private inner class Wire : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        @Volatile var windowState: String = "attached"
        @Volatile var liveState: String = "attached"
        @Volatile var resyncRequired: Boolean = false
        val liveFrames = CopyOnWriteArrayList<String>()
        private val durable = CopyOnWriteArrayList<Pair<String, String>>()
        private val nextDurableSequence = AtomicLong(0L)

        val snapshotPages = CopyOnWriteArrayList<String>()
        @Volatile private var lastSnapshotPage: String? = null
        val snapshotPolls = AtomicInteger(0)
        @Volatile var snapshotFailuresRemaining: Int = 0

        fun queueEvent(kind: String, payloadJson: String) {
            durable.add(kind to payloadJson)
        }

        fun live(payloadJson: String) {
            liveFrames.add(payloadJson)
        }

        fun queueSnapshot(pageJson: String) {
            snapshotPages.add(pageJson)
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if (root.string("operation") != "command.submit") return@mapNotNull null
            val envelope = root["envelope"] as? JsonObject ?: return@mapNotNull null
            if (envelope.string("command") != command) return@mapNotNull null
            envelope
        }

        fun eventPollCursors(): List<Long> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if (root.string("operation") != "event.poll") return@mapNotNull null
            ((root["envelope"] as? JsonObject)?.get("cursor") as? JsonObject)
                ?.let { (it["sequence"] as? JsonPrimitive)?.content?.toLongOrNull() }
        }

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") ->
                    eventPollPage(request, correlation)
                request.contains("\"operation\":\"effect.poll\"") ->
                    effectPollPage(request, correlation)
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "notesnap")
                else -> receipt(correlation, "other")
            }
        }

        private fun correlationOf(request: String): String =
            ((runCatching { Json.parseToJsonElement(request).jsonObject }.getOrNull()
                ?.get("requestID")) as? JsonPrimitive)?.content ?: "correlation"

        private fun eventPollPage(request: String, correlation: String): String {
            val root = runCatching { Json.parseToJsonElement(request).jsonObject }.getOrNull()
            val envelope = root?.get("envelope") as? JsonObject
            val ownerRunID = ((envelope?.get("owner") as? JsonObject)
                ?.get("runID") as? JsonPrimitive)?.content ?: runID
            val after = ((envelope?.get("cursor") as? JsonObject)
                ?.get("sequence") as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L
            val builder = StringBuilder()
            var next = after
            while (durable.isNotEmpty() && builder.length < 24_000) {
                val (kind, payload) = durable.removeAt(0)
                next += 1
                if (builder.isNotEmpty()) builder.append(',')
                builder.append(
                    """{"sequence":$next,"kind":"${escape(kind)}","createdAt":1,""" +
                        """"payload":"${escape(payload)}"}""",
                )
            }
            val liveJson = if (liveFrames.isEmpty()) "" else {
                val frames = liveFrames.joinToString(",") { payload ->
                    """{"liveSeq":1,"priority":false,"payload":"${escape(payload)}"}"""
                }
                liveFrames.clear()
                ""","live":{"liveState":"$liveState","frames":[$frames],""" +
                    """"resyncRequired":false,"droppedDeltas":0}"""
            }
            return """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"runID":"$ownerRunID","sequence":$after},""" +
                """"durable":{"windowState":"$windowState","events":[$builder],""" +
                """"hasMore":false,"resyncRequired":$resyncRequired,"nextSequence":$next}""" +
                liveJson + ""","resyncRequired":$resyncRequired}"""
        }

        private fun effectPollPage(request: String, correlation: String): String {
            val root = runCatching { Json.parseToJsonElement(request).jsonObject }.getOrNull()
            val envelope = root?.get("envelope") as? JsonObject
            val receiptID = ((envelope?.get("effect") as? JsonObject)
                ?.get("operationReceiptID") as? JsonPrimitive)?.content ?: ""
            val page = if (snapshotPages.isNotEmpty()) snapshotPages.removeAt(0)
                else lastSnapshotPage ?: nonTerminalPage()
            lastSnapshotPage = page
            snapshotPolls.incrementAndGet()
            val effect = if (snapshotFailuresRemaining > 0) {
                snapshotFailuresRemaining -= 1
                """{"sequence":1,"kind":"failed","code":"snapshotUnavailable"}"""
            } else {
                """{"sequence":1,"kind":"accepted","value":$page}"""
            }
            return """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"operationReceiptID":"$receiptID","sequence":2},""" +
                """"effects":[$effect],"hasMore":false,"resyncRequired":false}"""
        }

        private fun receipt(correlation: String, tag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$tag"}"""

        private fun escape(value: String): String =
            value.replace("\\", "\\\\").replace("\"", "\\\"")
    }

    private fun nonTerminalPage(
        answerText: String? = null,
        watermark: Long = 0L,
        liveOwner: Boolean = true,
        state: String = "streamingModel",
    ): String = page(
        answerText = answerText,
        watermark = watermark,
        liveOwner = liveOwner,
        state = state,
        isTerminal = false,
    )

    private fun terminalPage(
        answerText: String? = null,
        watermark: Long = 4L,
        state: String = "completed",
    ): String = page(
        answerText = answerText,
        watermark = watermark,
        liveOwner = true,
        state = state,
        isTerminal = true,
    )

    private fun page(
        answerText: String?,
        watermark: Long,
        liveOwner: Boolean,
        state: String,
        isTerminal: Boolean,
    ): String {
        fun text(value: String?): String =
            if (value == null) "null" else "\"" + value.replace("\\", "\\\\")
                .replace("\"", "\\\"") + "\""
        return """{"schema":"floe.command-envelope/3","conversationID":"$conversationID",""" +
            """"runID":"$runID","durableState":"$state",""" +
            """"revision":{"resourceID":"run.${runID.uppercase()}","version":"$state"},""" +
            """"isTerminal":$isTerminal,"conversationMode":"chat","goal":"hi",""" +
            """"liveOwner":$liveOwner,"answerText":${text(answerText)},""" +
            """"answerComplete":${isTerminal && answerText != null},""" +
            """"answerContinuationHandle":null,"reasoningText":null,""" +
            """"reasoningComplete":false,"reasoningContinuationHandle":null,""" +
            """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
            """"queueRevision":null,"durableWatermark":$watermark}"""
    }

    private class Commands : NotesAssistantCommandPort {
        val actions = CopyOnWriteArrayList<String>()

        override suspend fun command(action: String, payload: JsonObject): JsonObject {
            actions.add(action)
            return when (action) {
                "assistant.start" -> JsonObject(mapOf(
                    "ok" to JsonPrimitive(true),
                    "runID" to JsonPrimitive("33333333-3333-4333-8333-333333333333"),
                    "started" to JsonPrimitive(true),
                ))
                else -> JsonObject(mapOf("ok" to JsonPrimitive(true)))
            }
        }
    }

    private fun request() = NotesAssistantSendRequest(
        conversationID = conversationID,
        documentID = documentID,
        revision = 4,
        text = "Summarise",
        context = NotesAssistantContext(documentID = documentID, revision = 4),
    )

    private fun scope() = CoroutineScope(Dispatchers.Default)

    private fun client(wire: Wire): RuntimeHostCommandClient = RuntimeHostCommandClient(
        exchange = wire,
        scope = CoroutineScope(Dispatchers.Default),
        ioDispatcher = Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 5L),
    )

    private suspend fun awaitCondition(
        timeoutMillis: Long = 5_000,
        check: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(5)
        }
        return check()
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.content

    // --------------------------------------------------------------- tests

    @Test
    fun liveHintReadsTheCanonicalSnapshotAndFinalTextIsEmittedOnce() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }

        assertTrue("the owned turn opens the real event pump",
            awaitCondition { wire.eventPollCursors().isNotEmpty() })
        // The native live mirror carries content, but only as a dirty hint:
        // the authoritative text comes from one run.snapshot read.
        wire.queueSnapshot(nonTerminalPage(answerText = "FLOE_"))
        wire.live("""{"answerDelta":{"text":"ignored-live-delta"}}""")
        assertTrue("a live hint must read the canonical snapshot",
            awaitCondition { wire.snapshotPolls.get() > 0 })
        assertTrue(awaitCondition { subject.activeTurn(conversationID)?.text == "FLOE_" })

        wire.queueSnapshot(nonTerminalPage(answerText = "FLOE_G02_OK", watermark = 1L))
        wire.live("""{"answerDelta":{"text":"_OK"}}""")
        assertTrue(awaitCondition {
            subject.activeTurn(conversationID)?.text == "FLOE_G02_OK"
        })

        // The real durable terminal settles the turn; the same text is never
        // appended twice and exactly one Finished frame is emitted.
        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
        val deltas = events.filterIsInstance<NotesAssistantEvent.Delta>()
        val snapshots = events.filterIsInstance<NotesAssistantEvent.Snapshot>()
        val finished = events.filterIsInstance<NotesAssistantEvent.Finished>()
        assertEquals(1, finished.size)
        assertEquals("FLOE_G02_OK", finished.single().finalText)
        assertEquals("FLOE_G02_OK", deltas.joinToString("") { it.text })
        assertTrue(snapshots.isEmpty())
        assertTrue(events.none { it is NotesAssistantEvent.Failed })
        assertTrue(events.none { it is NotesAssistantEvent.Cancelled })
        assertEquals("FLOE_G02_OK", subject.activeTurn(conversationID)?.text)
        assertFalse(subject.activeTurn(conversationID)!!.streaming)
        // The durable cursor was never advanced by a live frame.
        assertTrue(wire.eventPollCursors().all { it == 0L })
        assertEquals("detach removed the local observation", 0, factory.trackedRunCount())
    }

    @Test
    fun durableSegmentAndAuthoritativeSnapshotNeverDoubleTheText() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        wire.queueEvent("assistantText", """{"text":"Hello "}""")
        wire.queueSnapshot(nonTerminalPage(answerText = "Hello world", watermark = 1L))
        wire.live("""{"answerDelta":{"text":"world"}}""")
        assertTrue(awaitCondition {
            subject.activeTurn(conversationID)?.text == "Hello world"
        })
        // The snapshot replaced its own already-durable prefix, not appended.
        assertEquals("Hello world", subject.activeTurn(conversationID)?.text)
        val composed = events.filterIsInstance<NotesAssistantEvent.Delta>()
            .joinToString("") { it.text } +
            events.filterIsInstance<NotesAssistantEvent.Snapshot>().lastOrNull()?.text.orEmpty()
        assertEquals("Hello world", composed)

        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
        assertEquals("Hello world",
            events.filterIsInstance<NotesAssistantEvent.Finished>().single().finalText)
    }

    @Test
    fun staleSnapshotWatermarkCannotOverwriteNewerDurableText() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val turn = async(Dispatchers.Default) { subject.send(request()) { } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        // A durable frame with sequence 5 lands first.
        wire.queueEvent("assistantText", """{"text":"FLOE_G02_OK"}""")
        assertTrue(awaitCondition {
            subject.activeTurn(conversationID)?.text == "FLOE_G02_OK"
        })
        // A read that started BEFORE that frame reports only watermark 4 and
        // an older prefix: it may not replace the fresher journal tail.
        wire.queueSnapshot(nonTerminalPage(answerText = "FLOE_", watermark = 4L))
        wire.live("""{"answerDelta":{"text":"x"}}""")
        assertTrue(awaitCondition { wire.snapshotPolls.get() > 0 })
        delay(120)
        assertEquals("FLOE_G02_OK", subject.activeTurn(conversationID)?.text)

        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
        assertEquals("FLOE_G02_OK",
            subject.activeTurn(conversationID)?.text)
    }

    @Test
    fun pumpDeathSettlesTheTurnAndNeverFabricatesANativeCancel() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        wire.windowState = "runGone"
        wire.queueSnapshot(nonTerminalPage(answerText = "partial"))
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }

        val settled = withTimeoutOrNull(6_000) { turn.await(); true } ?: false
        assertTrue("a dead pump must settle the UI", settled)
        val failed = events.filterIsInstance<NotesAssistantEvent.Failed>().single()
        assertEquals(NotesPortFailure.FAILED, failed.failure.code)
        assertEquals("runGone", failed.failure.detail)
        assertTrue(events.none { it is NotesAssistantEvent.Cancelled })
        assertTrue("a pump death is never a native cancel",
            wire.commandsOf("run.cancel").isEmpty() &&
                commands.actions.none { it == "assistant.cancel" })
        assertEquals(0, factory.trackedRunCount())
    }

    @Test
    fun supersededGenerationSettlesWithoutCancellingTheRun() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        var epoch = 7L
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { epoch })
        val subject = NotesAssistantHost(commands, factory, scope()) { epoch }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        // A real accepted-root change retires the observation; the run itself
        // is NOT cancelled by the App stream adapter.
        epoch = 8L
        wire.live("""{"answerDelta":{"text":"late"}}""")
        val settled = withTimeoutOrNull(6_000) { turn.await(); true } ?: false
        assertTrue("an epoch change must settle the UI", settled)
        val failed = events.filterIsInstance<NotesAssistantEvent.Failed>().single()
        assertEquals("superseded", failed.failure.detail)
        assertTrue(events.none { it is NotesAssistantEvent.Cancelled })
        assertTrue(wire.commandsOf("run.cancel").isEmpty())
        assertEquals(0, factory.trackedRunCount())
    }

    @Test
    fun localDetachIsNotATerminalAndDoesNotCancel() = runBlocking {
        val wire = Wire()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val failures = CopyOnWriteArrayList<String>()
        val frames = CopyOnWriteArrayList<JsonObject>()
        val detach = factory.open(
            taskID = conversationID,
            runID = runID,
            onFrame = { frames.add(it) },
            onFailure = { failures.add(it) },
        )
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })
        val waiting = async(Dispatchers.Default) {
            // Start awaiting BEFORE detaching; the deferred must stay pending.
            factory.awaitTerminal(runID)
            true
        }
        delay(60)
        detach()
        val returned = withTimeoutOrNull(250) { waiting.await() }
        assertNull("a local detach is not a terminal/drain", returned)
        assertTrue(failures.isEmpty())
        assertTrue(frames.none {
            (it["kind"] as? JsonPrimitive)?.content == "terminal"
        })
        assertTrue(wire.commandsOf("run.cancel").isEmpty())
        assertTrue(wire.commandsOf("assistant.cancel").isEmpty())
        waiting.cancel()
    }

    @Test
    fun terminalSnapshotSettlesWithoutADurableTerminalFrame() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        // Fast run: the window detaches before a durable terminal frame; the
        // live hint's authoritative snapshot reports the real terminal.
        wire.queueSnapshot(terminalPage(answerText = "FLOE_G02_OK"))
        wire.live("""{"answerDelta":{"text":"_OK"}}""")
        val settled = withTimeoutOrNull(6_000) { turn.await(); true } ?: false
        assertTrue("a terminal snapshot must settle the turn", settled)
        val finished = events.filterIsInstance<NotesAssistantEvent.Finished>().single()
        assertEquals("FLOE_G02_OK", finished.finalText)
        assertTrue(events.none { it is NotesAssistantEvent.Failed })
        assertEquals(0, factory.trackedRunCount())
    }

    @Test
    fun authoritativeReplacementIsASnapshotEventNotAnAppend() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(request()) { events.add(it) } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        wire.queueSnapshot(nonTerminalPage(answerText = "FLOE_G02_OK", watermark = 1L))
        wire.live("""{"answerDelta":{"text":"x"}}""")
        assertTrue(awaitCondition {
            subject.activeTurn(conversationID)?.text == "FLOE_G02_OK"
        })
        // A retry/rollback resets the native step: the snapshot is shorter but
        // fresher (same durable watermark). It REPLACES the tail instead of
        // appending a second copy.
        wire.queueSnapshot(nonTerminalPage(answerText = "FLOE_", watermark = 1L))
        wire.live("""{"answerDelta":{"text":"y"}}""")
        val replaced = awaitCondition {
            events.filterIsInstance<NotesAssistantEvent.Snapshot>().any { it.text == "FLOE_" }
        }
        assertTrue("a shorter authoritative tail must be a Snapshot replace", replaced)
        assertEquals("FLOE_", subject.activeTurn(conversationID)?.text)

        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
        assertEquals("FLOE_",
            events.filterIsInstance<NotesAssistantEvent.Finished>().single().finalText)
    }

    @Test
    fun durableResyncReadsTheCanonicalSnapshotWithoutALiveFrame() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val turn = async(Dispatchers.Default) { subject.send(request()) { } }
        assertTrue(awaitCondition { wire.eventPollCursors().isNotEmpty() })

        wire.queueSnapshot(nonTerminalPage(answerText = "RESYNC_OK", watermark = 1L))
        wire.resyncRequired = true
        assertTrue("the typed resync signal must reconcile by snapshot",
            awaitCondition { subject.activeTurn(conversationID)?.text == "RESYNC_OK" })
        wire.resyncRequired = false
        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
        assertEquals("RESYNC_OK", subject.activeTurn(conversationID)?.text)
        assertEquals(0, factory.trackedRunCount())
    }

    @Test
    fun sendCarriesTheRealConversationRevisionAndEditorFocus() = runBlocking {
        val wire = Wire()
        val pageID = "44444444-4444-4444-8444-444444444444"
        val nodeID = "55555555-5555-4555-8555-555555555555"
        val element1 = "66666666-6666-4666-8666-666666666666"
        val element2 = "77777777-7777-4777-8777-777777777777"
        val resource = "88888888-8888-4888-8888-888888888888"
        val startPayloads = CopyOnWriteArrayList<JsonObject>()
        val commands = object : NotesAssistantCommandPort {
            override suspend fun command(action: String, payload: JsonObject): JsonObject =
                when (action) {
                    "assistant.open" -> JsonObject(mapOf(
                        "ok" to JsonPrimitive(true),
                        "conversationID" to JsonPrimitive(conversationID),
                        "revision" to JsonPrimitive("conv-rev-9"),
                        "created" to JsonPrimitive(false),
                    ))
                    "assistant.start" -> {
                        startPayloads.add(payload)
                        JsonObject(mapOf(
                            "ok" to JsonPrimitive(true),
                            "runID" to JsonPrimitive(runID),
                        ))
                    }
                    else -> JsonObject(mapOf("ok" to JsonPrimitive(true)))
                }
        }
        val factory = HostNotesAssistantRunStreamFactory(client(wire), scope(), epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, scope()) { 7L }
        val turn = async(Dispatchers.Default) {
            subject.send(NotesAssistantSendRequest(
                conversationID = conversationID,
                documentID = documentID,
                revision = 4,
                text = "Summarise the selection",
                context = NotesAssistantContext(
                    documentID = documentID,
                    revision = 4,
                    pageID = pageID,
                    pageNumber = 3,
                    nodeID = nodeID,
                    selectedElementIDs = listOf(element1, element2),
                    selectedText = "The selected paragraph",
                    attachmentResourceIDs = listOf(resource),
                ),
            )) { }
        }
        assertTrue("the launch must be sent", awaitCondition { startPayloads.isNotEmpty() })
        val payload = startPayloads.single()
        // The native start CAS is the CONVERSATION revision, never the
        // document revision the editor context carries.
        assertEquals("conv-rev-9", payload.string("revision"))
        assertEquals(4L, (payload["documentRevision"] as? JsonPrimitive)?.content?.toLong())
        assertEquals(pageID, payload.string("pageID"))
        assertEquals(3L, (payload["pageNumber"] as? JsonPrimitive)?.content?.toLong())
        assertEquals(nodeID, payload.string("nodeID"))
        assertEquals(listOf(element1, element2),
            (payload["selectedElementIDs"] as? kotlinx.serialization.json.JsonArray)
                ?.map { (it as? JsonPrimitive)?.content })
        assertEquals("The selected paragraph", payload.string("selectedText"))
        assertEquals(listOf(resource),
            (payload["attachmentResourceIDs"] as? kotlinx.serialization.json.JsonArray)
                ?.map { (it as? JsonPrimitive)?.content })
        wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
        turn.await()
    }

    @Test
    fun repeatedTurnsLeaveNoTrackedStreamOrPump() = runBlocking {
        val wire = Wire()
        val commands = Commands()
        val hostScope = scope()
        val commandClient = client(wire)
        val factory = HostNotesAssistantRunStreamFactory(commandClient, hostScope, epochProvider = { 7L })
        val subject = NotesAssistantHost(commands, factory, hostScope) { 7L }
        repeat(5) { index ->
            wire.queueEvent("terminal", """{"stopReason":"endTurn"}""")
            val events = CopyOnWriteArrayList<NotesAssistantEvent>()
            subject.send(request()) { events.add(it) }
            assertEquals(1, events.filterIsInstance<NotesAssistantEvent.Finished>().size)
            assertEquals("turn ${index + 1} detaches its record",
                0, factory.trackedRunCount())
        }
        assertEquals(0, commandClient.activePumpCounts().first)
        assertEquals(0, commandClient.activePumpCounts().second)
    }
}
