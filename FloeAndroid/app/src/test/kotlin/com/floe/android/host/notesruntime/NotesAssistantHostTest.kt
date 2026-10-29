// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesruntime

import com.floe.android.feature.notes.ui.api.NotesAssistantAvailability
import com.floe.android.feature.notes.ui.api.NotesAssistantConversationRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantEvent
import com.floe.android.feature.notes.ui.api.NotesAssistantRestartRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantRunOutcome
import com.floe.android.feature.notes.ui.api.NotesAssistantSendRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptRole
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Notes assistant host regressions.
 *
 * The fake command port returns EXACT `floe.notes/4` reply shapes and the fake
 * run stream replays the ORIGINAL durable run-event vocabulary
 * (`assistantText`/`terminal`/`status`). No test here claims App/device
 * acceptance: these prove the DTO/state/lifecycle mapping.
 */
class NotesAssistantHostTest {
    private val documentID = "11111111-1111-4111-8111-111111111111"
    private val conversationID = "22222222-2222-4222-8222-222222222222"
    private val runID = "33333333-3333-4333-8333-333333333333"

    private class ScriptedCommands(
        var handler: suspend (String, JsonObject) -> JsonObject,
    ) : NotesAssistantCommandPort {
        val actions = CopyOnWriteArrayList<String>()
        val payloads = CopyOnWriteArrayList<JsonObject>()

        override suspend fun command(action: String, payload: JsonObject): JsonObject {
            actions.add(action)
            payloads.add(payload)
            return handler(action, payload)
        }
    }

    private class FakeRuns(private val runID: String) : NotesAssistantRunStreamFactory {
        val opened = CopyOnWriteArrayList<Pair<String, String>>()
        val detaches = AtomicInteger(0)
        var onFrame: ((JsonObject) -> Unit)? = null
        var onFailure: ((String) -> Unit)? = null
        private val terminal = CompletableDeferred<Unit>()

        override fun open(
            taskID: String,
            runID: String,
            onFrame: (JsonObject) -> Unit,
            onFailure: (String) -> Unit,
        ): () -> Unit {
            opened.add(taskID to runID)
            this.onFrame = onFrame
            this.onFailure = onFailure
            return { detaches.incrementAndGet() }
        }

        override suspend fun awaitTerminal(runID: String) {
            terminal.await()
        }

        fun emit(kind: String, payload: JsonObject? = null) {
            onFrame?.invoke(buildJsonObject {
                put("runID", runID)
                put("sequence", 1)
                put("kind", kind)
                if (payload != null) put("payload", payload)
            })
        }

        fun fail(code: String) { onFailure?.invoke(code) }
        fun finish() { terminal.complete(Unit) }
    }

    private fun ok(vararg pairs: Pair<String, kotlinx.serialization.json.JsonElement>) =
        JsonObject(mapOf("ok" to JsonPrimitive(true)) + pairs.toMap())

    private fun host(
        commands: ScriptedCommands,
        runs: FakeRuns? = null,
        epoch: Long = 7L,
        scope: CoroutineScope = CoroutineScope(Dispatchers.Default),
    ) = NotesAssistantHost(
        commands = commands,
        runs = runs ?: FakeRuns(runID),
        scope = scope,
        epochProvider = { epoch },
    )

    private fun sendRequest(text: String = "Summarise this page") = NotesAssistantSendRequest(
        conversationID = conversationID,
        documentID = documentID,
        revision = 4,
        text = text,
        context = com.floe.android.feature.notes.ui.api.NotesAssistantContext(
            documentID = documentID,
            revision = 4,
            pageID = "44444444-4444-4444-8444-444444444444",
        ),
    )

    // ---------------------------------------------------------------- status

    @Test
    fun statusMapsTheClosedAvailabilityVocabulary() = runBlocking {
        val commands = ScriptedCommands { _, _ ->
            ok("availability" to JsonPrimitive("ready"),
                "modelLabel" to JsonPrimitive("Fixture"))
        }
        val status = host(commands).status()
        assertEquals(NotesAssistantAvailability.READY, status.availability)
        assertEquals("Fixture", status.modelLabel)

        val notConfigured = host(ScriptedCommands { _, _ ->
            ok("availability" to JsonPrimitive("notConfigured"),
                "reason" to JsonPrimitive("modelUnavailable"))
        }).status()
        assertEquals(NotesAssistantAvailability.NOT_CONFIGURED, notConfigured.availability)

        val unavailable = host(ScriptedCommands { _, _ ->
            ok("availability" to JsonPrimitive("unavailable"),
                "reason" to JsonPrimitive("rootStopping"))
        }).status()
        assertEquals(NotesAssistantAvailability.UNSUPPORTED, unavailable.availability)
    }

    @Test
    fun statusBeforeAnAcceptedRootIsNotConfiguredWithoutACall() = runBlocking {
        val commands = ScriptedCommands { _, _ -> error("must not call native") }
        val status = host(commands, epoch = 0L).status()
        assertEquals(NotesAssistantAvailability.NOT_CONFIGURED, status.availability)
        assertEquals("runtimeUnavailable", status.message)
        assertTrue(commands.actions.isEmpty())
    }

    // ------------------------------------------------------------------ open

    @Test
    fun openReturnsTheDurableConversationIdentity() = runBlocking {
        val commands = ScriptedCommands { action, payload ->
            assertEquals("assistant.open", action)
            assertEquals(documentID, payload["documentID"]?.toString()?.trim('"'))
            ok("conversationID" to JsonPrimitive(conversationID),
                "created" to JsonPrimitive(true))
        }
        val conversation = host(commands).createConversation(
            NotesAssistantConversationRequest(documentID, "Doc", true))
        assertEquals(conversationID, conversation.id)
    }

    @Test
    fun openRefusalKeepsTheTypedCode() = runBlocking {
        val commands = ScriptedCommands { _, _ ->
            JsonObject(mapOf(
                "ok" to JsonPrimitive(false),
                "error" to JsonPrimitive("bindingRefused"),
                "reason" to JsonPrimitive("purposeNotNotes")))
        }
        val error = runCatching {
            host(commands).createConversation(
                NotesAssistantConversationRequest(documentID, "Doc", true))
        }.exceptionOrNull()
        val failure = error as? NotesPortFailureException
        assertNotNull(failure)
        assertEquals(NotesPortFailure.PERMISSION_DENIED, failure!!.failure.code)
        assertEquals("purposeNotNotes", failure.failure.detail)
    }

    // ------------------------------------------------------------------ send

    @Test
    fun sendStreamsDeltasAndFinishesFromTheRealTerminal() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            when (action) {
                "assistant.start" -> ok("runID" to JsonPrimitive(runID),
                    "started" to JsonPrimitive(true))
                "assistant.drainDecisions" -> ok(
                    "delivered" to JsonArray(emptyList()))
                else -> ok()
            }
        }
        val subject = host(commands, runs)
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) {
            subject.send(sendRequest()) { events.add(it) }
        }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        assertEquals(conversationID to runID, runs.opened.first())
        runs.emit("assistantText", buildJsonObject { put("text", "Hello ") })
        runs.emit("assistantText", buildJsonObject { put("text", "note") })
        runs.finish()
        turn.await()

        assertEquals(listOf("Hello ", "note"),
            events.filterIsInstance<NotesAssistantEvent.Delta>().map { it.text })
        val finished = events.filterIsInstance<NotesAssistantEvent.Finished>().single()
        assertEquals("Hello note", finished.finalText)
        assertTrue(events.none { it is NotesAssistantEvent.Cancelled })
        assertEquals(1, runs.detaches.get())
        assertTrue(commands.actions.contains("assistant.drainDecisions"))
        val snapshot = subject.activeTurn(conversationID)
        assertNotNull(snapshot)
        assertFalse(snapshot!!.streaming)
        assertEquals("Hello note", snapshot.text)
    }

    @Test
    fun sendMapsACancelledTerminalToCancelledNotFinished() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            if (action == "assistant.start") ok("runID" to JsonPrimitive(runID)) else ok()
        }
        val subject = host(commands, runs)
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(sendRequest()) { events.add(it) } }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        runs.emit("assistantText", buildJsonObject { put("text", "partial") })
        runs.emit("terminal", buildJsonObject { put("stopReason", "cancelled") })
        runs.finish()
        turn.await()
        assertTrue(events.any { it is NotesAssistantEvent.Cancelled })
        assertTrue(events.none { it is NotesAssistantEvent.Finished })
        assertTrue(subject.activeTurn(conversationID)!!.cancelled)
    }

    @Test
    fun sendMapsAFailedStatusToFailed() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            if (action == "assistant.start") ok("runID" to JsonPrimitive(runID)) else ok()
        }
        val subject = host(commands, runs)
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(sendRequest()) { events.add(it) } }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        runs.emit("status", buildJsonObject { put("state", "failed") })
        runs.finish()
        turn.await()
        val failure = events.filterIsInstance<NotesAssistantEvent.Failed>().single()
        assertEquals(NotesPortFailure.FAILED, failure.failure.code)
    }

    @Test
    fun sendRefusesASecondTurnWhileOneIsLive() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            if (action == "assistant.start") ok("runID" to JsonPrimitive(runID)) else ok()
        }
        val subject = host(commands, runs)
        val first = async(Dispatchers.Default) { subject.send(sendRequest()) {} }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        val error = runCatching { subject.send(sendRequest()) {} }.exceptionOrNull()
        assertEquals(NotesPortFailure.BUSY, (error as? NotesPortFailureException)?.failure?.code)
        runs.emit("terminal", buildJsonObject { put("stopReason", "endTurn") })
        runs.finish()
        first.await()
    }

    // ---------------------------------------------------------------- cancel

    @Test
    fun cancelRequestsOnlyAndNeverSynthesizesATerminal() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            if (action == "assistant.start") ok("runID" to JsonPrimitive(runID)) else ok()
        }
        val subject = host(commands, runs)
        val events = CopyOnWriteArrayList<NotesAssistantEvent>()
        val turn = async(Dispatchers.Default) { subject.send(sendRequest()) { events.add(it) } }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        subject.cancel(conversationID)
        assertTrue(commands.actions.contains("assistant.cancel"))
        assertTrue(subject.activeTurn(conversationID)!!.streaming)
        assertTrue(events.none { it is NotesAssistantEvent.Cancelled })
        // The REAL terminal is what settles the turn.
        runs.emit("terminal", buildJsonObject { put("stopReason", "cancelled") })
        runs.finish()
        turn.await()
        assertTrue(events.any { it is NotesAssistantEvent.Cancelled })
    }

    @Test
    fun closeDetachesWithoutStoppingAnything() = runBlocking {
        val runs = FakeRuns(runID)
        val commands = ScriptedCommands { action, _ ->
            if (action == "assistant.start") ok("runID" to JsonPrimitive(runID)) else ok()
        }
        val subject = host(commands, runs)
        val turn = async(Dispatchers.Default) { subject.send(sendRequest()) {} }
        while (runs.opened.isEmpty()) kotlinx.coroutines.delay(5)
        subject.close(conversationID)
        assertTrue(commands.actions.none { it == "assistant.cancel" })
        assertTrue(subject.activeTurn(conversationID)!!.streaming)
        runs.emit("terminal", buildJsonObject { put("stopReason", "endTurn") })
        runs.finish()
        turn.await()
    }

    // ------------------------------------------------------------- lifecycle

    @Test
    fun rootStopIsDrainedOnlyWhenNativeProvesIt() = runBlocking {
        val commands = ScriptedCommands { action, _ ->
            when (action) {
                "assistant.prepareRootStop" -> ok(
                    "canRetire" to JsonPrimitive(true),
                    "fenced" to JsonPrimitive(true),
                    "pendingRunIDs" to JsonArray(emptyList()),
                    "requestedRunIDs" to JsonArray(listOf(JsonPrimitive(runID))),
                )
                else -> ok()
            }
        }
        val subject = host(commands)
        val report = subject.prepareForRootStop(7L)
        assertTrue(report.canRetire)
        assertEquals(1, report.cancelRequestedCount)
        assertEquals(0, report.pendingCount)
        // Admission is fenced for this process until a same-epoch abort.
        val error = runCatching { subject.createConversation(
            NotesAssistantConversationRequest(documentID, "Doc", true)) }
            .exceptionOrNull()
        assertEquals(NotesPortFailure.BUSY,
            (error as? NotesPortFailureException)?.failure?.code)
    }

    @Test
    fun rootStopReportsPendingAndRefusalAsNotRetirable() = runBlocking {
        val pending = host(ScriptedCommands { _, _ ->
            ok("canRetire" to JsonPrimitive(false),
                "fenced" to JsonPrimitive(true),
                "pendingRunIDs" to JsonArray(listOf(JsonPrimitive(runID))),
                "requestedRunIDs" to JsonArray(emptyList()))
        })
        val report = pending.prepareForRootStop(7L)
        assertFalse(report.canRetire)
        assertEquals(1, report.pendingCount)

        val refused = host(ScriptedCommands { _, _ -> error("native refused") })
        val refusal = refused.prepareForRootStop(7L)
        assertFalse(refusal.canRetire)
        assertTrue(refusal.pendingCount > 0)
    }

    @Test
    fun abortReArmsOnlyWhenNativeClearsTheSameEpochFence() = runBlocking {
        var abortReply = ok("fenced" to JsonPrimitive(true))
        val commands = ScriptedCommands { action, _ ->
            when (action) {
                "assistant.prepareRootStop" -> ok(
                    "canRetire" to JsonPrimitive(false),
                    "fenced" to JsonPrimitive(true),
                    "pendingRunIDs" to JsonArray(emptyList()))
                "assistant.abortRootStop" -> abortReply
                else -> ok()
            }
        }
        val subject = host(commands)
        subject.prepareForRootStop(7L)
        subject.abortRootStop(7L)
        // Native still reports fenced: the host must stay fenced.
        val stillFenced = runCatching { subject.createConversation(
            NotesAssistantConversationRequest(documentID, "Doc", true)) }
            .exceptionOrNull()
        assertEquals(NotesPortFailure.BUSY,
            (stillFenced as? NotesPortFailureException)?.failure?.code)

        abortReply = ok("fenced" to JsonPrimitive(false))
        subject.abortRootStop(7L)
        // A re-armed host reaches the native open again (this fake answers
        // with the durable conversation).
        val reopened = ScriptedCommands { action, _ ->
            when (action) {
                "assistant.abortRootStop" -> ok("fenced" to JsonPrimitive(false))
                "assistant.open" -> ok("conversationID" to JsonPrimitive(conversationID))
                else -> ok()
            }
        }
        val reopenedHost = host(reopened)
        reopenedHost.prepareForRootStop(7L)
        reopenedHost.abortRootStop(7L)
        assertEquals(conversationID, reopenedHost.createConversation(
            NotesAssistantConversationRequest(documentID, "Doc", true)).id)
    }

    // ------------------------------------------------------------ transcript

    @Test
    fun transcriptRestoresRolesOutcomesAndTheOpaqueCursor() = runBlocking {
        val commands = ScriptedCommands { action, _ ->
            assertEquals("assistant.transcript", action)
            ok(
                "entries" to buildJsonArray {
                    add(buildJsonObject {
                        put("id", "m1"); put("role", "user"); put("text", "Hi")
                        put("runID", runID); put("outcome", "COMPLETED")
                    })
                    add(buildJsonObject {
                        put("id", "m2"); put("role", "assistant"); put("text", "Hey")
                        put("runID", runID); put("outcome", "CANCELLED")
                    })
                    add(buildJsonObject {
                        put("id", "m3"); put("role", "system"); put("text", "Decision")
                        put("runID", JsonNull); put("outcome", JsonNull)
                    })
                    add(buildJsonObject {
                        put("id", "m4"); put("role", "tool"); put("text", "dropped")
                    })
                },
                "olderCursor" to JsonPrimitive("1700000000000|m0"),
                "hasOlder" to JsonPrimitive(true),
            )
        }
        val page = host(commands).transcript(conversationID, before = null, limit = 10)
        assertEquals(3, page.entries.size)
        assertEquals(listOf(
            NotesAssistantTranscriptRole.USER,
            NotesAssistantTranscriptRole.ASSISTANT,
            NotesAssistantTranscriptRole.SYSTEM,
        ), page.entries.map { it.role })
        assertEquals(NotesAssistantRunOutcome.COMPLETED, page.entries[0].outcome)
        assertEquals(NotesAssistantRunOutcome.CANCELLED, page.entries[1].outcome)
        assertNull(page.entries[2].outcome)
        assertEquals("1700000000000|m0", page.earlierCursor)
        assertTrue(page.hasEarlier)
    }

    @Test
    fun transcriptRefusalKeepsTheTypedFailure() = runBlocking {
        val commands = ScriptedCommands { _, _ ->
            JsonObject(mapOf(
                "ok" to JsonPrimitive(false),
                "error" to JsonPrimitive("runtimeUnavailable"),
                "reason" to JsonPrimitive("runDomainNotInstalled")))
        }
        val error = runCatching { host(commands).transcript(conversationID) }
            .exceptionOrNull()
        assertEquals(NotesPortFailure.UNAVAILABLE,
            (error as? NotesPortFailureException)?.failure?.code)
    }

    // -------------------------------------------------------------- proposals

    @Test
    fun proposalsAreScopedToTheExactDocumentAndPendingState() = runBlocking {
        val commands = ScriptedCommands { _, payload ->
            assertEquals(documentID, payload["documentID"]?.toString()?.trim('"'))
            ok("proposals" to buildJsonArray {
                add(buildJsonObject {
                    put("id", "p1"); put("documentID", documentID)
                    put("title", "Edit"); put("summary", "Rename title")
                    put("baseRevision", 4); put("editCount", 1)
                    put("status", "pending")
                })
                add(buildJsonObject {
                    put("id", "p2"); put("documentID",
                        "99999999-9999-4999-8999-999999999999")
                    put("title", "Foreign")
                })
            })
        }
        val list = host(commands).proposals(conversationID, documentID)
        assertEquals(1, list.size)
        assertEquals("p1", list[0].proposalID)
        assertTrue(list[0].isPending)
        assertEquals("Rename title", list[0].summary)
    }

    @Test
    fun acceptMintsTheGrantThenAppliesIt() = runBlocking {
        val commands = ScriptedCommands { action, payload ->
            when (action) {
                "proposal.issueGrant" -> {
                    assertEquals("p1", payload["proposalID"]?.toString()?.trim('"'))
                    ok("grant" to buildJsonObject {
                        put("grantID", "grant-1")
                        put("proposalID", "p1")
                        put("documentID", documentID)
                    })
                }
                "proposal.apply" -> {
                    assertEquals("grant-1", payload["grantID"]?.toString()?.trim('"'))
                    assertEquals(conversationID,
                        payload["conversationID"]?.toString()?.trim('"'))
                    ok("result" to buildJsonObject {
                        put("proposalID", "p1")
                        put("appliedRevision", 5)
                        put("status", "applied")
                    })
                }
                else -> ok()
            }
        }
        val decision = host(commands).acceptProposal(conversationID, documentID, "p1")
        assertEquals("applied", decision.decision)
        assertEquals(5, decision.appliedRevision)
        assertEquals(listOf("proposal.issueGrant", "proposal.apply"), commands.actions)
    }

    @Test
    fun rejectRecordsTheDurableRejectedDecision() = runBlocking {
        val commands = ScriptedCommands { action, payload ->
            assertEquals("proposal.resolve", action)
            assertEquals("rejected", payload["decision"]?.toString()?.trim('"'))
            ok("proposal" to buildJsonObject { put("id", "p1"); put("status", "resolved") })
        }
        val decision = host(commands).rejectProposal(conversationID, documentID, "p1")
        assertEquals("rejected", decision.decision)
    }

    // ---------------------------------------------------------------- restart

    @Test
    fun restartRefusesWhileTheOldRunIsNotDrained() = runBlocking {
        val commands = ScriptedCommands { action, _ ->
            when (action) {
                "assistant.restart" -> ok(
                    "restarted" to JsonPrimitive(false),
                    "reason" to JsonPrimitive("runNotDrained"),
                    "canRetire" to JsonPrimitive(false))
                else -> ok()
            }
        }
        val error = runCatching {
            host(commands).restartConversation(
                NotesAssistantRestartRequest(conversationID, documentID, "Doc"))
        }.exceptionOrNull()
        val failure = error as? NotesPortFailureException
        assertEquals(NotesPortFailure.BUSY, failure?.failure?.code)
        assertEquals("runNotDrained", failure?.failure?.detail)
    }
}
