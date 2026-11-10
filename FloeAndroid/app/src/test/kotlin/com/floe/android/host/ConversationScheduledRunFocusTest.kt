// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.design.SidebarSelection
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
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

/**
 * N03 exact scheduled-run navigation regressions using a scripted v3
 * transport double only; no JNI, device, store or network.
 *
 * Pins the ConversationHostController run-focus contract:
 *  * a history/notification target with BOTH real ids opens the owning task
 *    and presents THAT recorded run (cold entry via the `conversation.get`
 *    settle, and the same-task live fast path);
 *  * the bounded session page (native SQL LIMIT 160) and a stale cached page
 *    are WINDOWS, never deletion proof: a valid recorded run absent from the
 *    page is decided by ONE authoritative `run.snapshot` read and presented
 *    with its own distinct recorded receipt (run.events), and later session
 *    refreshes retain the target instead of silently jumping to the newest
 *    run;
 *  * a deleted / task-foreign run id (typed notFound/runMissing refusal, or
 *    even an accepted page owned by another task) NEVER presents: the task
 *    stays at its ordinary newest selection and the typed failure is
 *    surfaced — never a fabricated row, never a silent latest-run selection;
 *  * reading history NEVER creates/starts/continues a run or touches a
 *    provider (no `run.start` leaves the host);
 *  * a null run id keeps the honest task-only fallback;
 *  * any newer plain open / new-task request supersedes an unconsumed focus,
 *    and a late authoritative reply for a superseded focus cannot steal the
 *    later navigation;
 *  * a refused request (runtime not admitted) publishes nothing.
 */
class ConversationScheduledRunFocusTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val otherConversationId = "55555555-5555-4555-8555-555555555555"
    private val newestRunId = "33333333-3333-4333-8333-333333333333"
    private val recordedRunId = "ABCDEFAB-2222-4222-8222-222222222222"
    private val missingRunId = "99999999-9999-4999-8999-999999999999"
    private val foreignRunId = "66666666-6666-4666-8666-666666666666"
    private val hostileRunId = "77777777-7777-4777-8777-777777777777"

    // ------------------------------------------------------------------ wire

    private class ScriptedExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        val replies = CopyOnWriteArrayList<String>()
        /** Optional `conversation.get` reply override: a bounded native page
         * WITHOUT the targeted run (the 160-row window dropped it). */
        @Volatile var conversationPageJson: String? = null
        /** When set, every `run.snapshot` effect answer blocks until released
         * (deterministic superseded-late-reply control). */
        @Volatile var snapshotGate: java.util.concurrent.CountDownLatch? = null

        lateinit var script: (String) -> String

        override fun exchange(request: String): String {
            requests.add(request)
            return script(request).also(replies::add)
        }

        fun commandsOf(command: String): List<kotlinx.serialization.json.JsonObject> =
            requests.mapNotNull { raw ->
                val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                    ?: return@mapNotNull null
                if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") {
                    return@mapNotNull null
                }
                val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
                if ((envelope["command"]?.jsonPrimitive?.content) != command) {
                    return@mapNotNull null
                }
                envelope
            }
    }

    private fun ownerRunIdOf(raw: String): String? = runCatching {
        val root = Json.parseToJsonElement(raw).jsonObject
        ((root["envelope"] as? kotlinx.serialization.json.JsonObject)
            ?.get("owner") as? kotlinx.serialization.json.JsonObject)
            ?.get("runID")?.jsonPrimitive?.content
    }.getOrNull()

    private fun receipt(correlation: String, receiptTag: String): String =
        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
            """"operationReceiptID":"op:v1:$receiptTag"}"""

    private fun effectPage(
        correlation: String,
        receiptTag: String,
        effectsJson: String,
    ): String {
        val receiptId = if (receiptTag.startsWith("op:v1:")) receiptTag else "op:v1:$receiptTag"
        return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receiptId",""" +
            """"sequence":1},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""
    }

    private fun accepted(valueJson: String): String =
        """{"sequence":1,"kind":"accepted","value":$valueJson}"""

    /** A typed authoritative refusal, exactly like the native run domain:
     *  rejected(notFound, runMissing) for a deleted/foreign run id. */
    private fun rejected(code: String, reason: String): String =
        """{"sequence":1,"kind":"rejected","code":"$code","""+
            """"detail":[{"key":"reason","value":"$reason"}]}"""

    /** Two completed runs, NEWEST-FIRST, exactly like the native page. */
    private fun twoRunConversationPage(): String =
        """{"conversationID":"$conversationId","title":"Scheduled task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}","version":"digest-9"},""" +
            """"runs":[""" +
            """{"runID":"$newestRunId","state":"completed","modelName":"DeepSeek Cloud QA",""" +
            """"startedAt":"2026-11-10T02:00:00.000Z"},""" +
            """{"runID":"$recordedRunId","state":"completed","modelName":"DeepSeek Cloud QA",""" +
            """"startedAt":"2026-11-10T01:00:00.000Z"}],""" +
            """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

    /** The bounded native window carrying ONLY [runId] — every older recorded
     *  run fell off the 160-row page (absence is a window, not a deletion). */
    private fun singleRunConversationPage(runId: String): String =
        """{"conversationID":"$conversationId","title":"Scheduled task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}","version":"digest-9"},""" +
            """"runs":[""" +
            """{"runID":"$runId","state":"completed","modelName":"DeepSeek Cloud QA",""" +
            """"startedAt":"2026-11-10T02:00:00.000Z"}],""" +
            """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

    private fun runSnapshotValue(runId: String, owner: String = conversationId): String =
        """{"schema":"floe.command-envelope/3","conversationID":"$owner",""" +
            """"runID":"$runId","durableState":"completed",""" +
            """"revision":{"resourceID":"run.${runId.uppercase()}","version":"completed"},""" +
            """"isTerminal":true,"liveOwner":false,"pendingApproval":null,"approvalRevision":null,""" +
            """"pendingInputs":[],"queueRevision":null,"durableWatermark":2}"""

    /** A DISTINCT recorded receipt per run: the readable result must come
     *  from THIS run's own journal, never the newest run's replayed. */
    private fun runEventsPage(runId: String, answer: String): String =
        """{"taskID":"$conversationId","runID":"$runId","events":[""" +
            """{"sequence":1,"kind":"assistantText",""" +
            """"payload":"{\"text\":\"$answer\"}"},""" +
            """{"sequence":2,"kind":"terminal",""" +
            """"payload":"{\"terminal\":\"completed\"}"}],""" +
            """"hasEarlier":false,"firstSequence":1}"""

    private fun recordedAnswer(runId: String): String = when (runId) {
        newestRunId -> "newest-run-answer"
        recordedRunId -> "recorded-run-answer"
        else -> "run-$runId-answer"
    }

    private fun buildExchange(): ScriptedExchange {
        // Fail at the fixture boundary rather than turning malformed JSON
        // into misleading asynchronous session/snapshot timeouts.
        listOf(
            twoRunConversationPage(), singleRunConversationPage(newestRunId),
            runSnapshotValue(recordedRunId), runEventsPage(recordedRunId, "recorded-run-answer"),
        ).forEach { Json.parseToJsonElement(it) }
        val exchange = ScriptedExchange()
        exchange.script = { raw ->
            val correlation = correlationOf(raw)
            when {
                raw.contains("\"operation\":\"effect.poll\"") -> {
                    val tag = receiptOf(raw)
                    when {
                        tag == "op:v1:cget" ->
                            effectPage(
                                correlation, "cget",
                                accepted(exchange.conversationPageJson ?: twoRunConversationPage()),
                            )
                        tag == "op:v1:msgpage" ->
                            effectPage(
                                correlation, "msgpage",
                                accepted("""{"rows":[],"hasEarlier":false,"earlierCursor":null}"""),
                            )
                        tag == "op:v1:question" ->
                            effectPage(
                                correlation, "question",
                                accepted(
                                    """{"schema":"floe.question.v1","conversationID":"$conversationId","requests":[]}""",
                                ),
                            )
                        tag == "op:v1:cchildlist" ->
                            effectPage(
                                correlation, "cchildlist",
                                accepted("""{"children":[]}"""),
                            )
                        tag.startsWith("op:v1:rsnap:") -> {
                            exchange.snapshotGate?.await(5, java.util.concurrent.TimeUnit.SECONDS)
                            val runId = tag.removePrefix("op:v1:rsnap:").uppercase()
                            when (runId) {
                                // The REAL native contract: a deleted or
                                // task-foreign run id is a typed refusal —
                                // the fixture no longer succeeds for ANY id.
                                missingRunId, foreignRunId ->
                                    effectPage(correlation, tag, rejected("notFound", "runMissing"))
                                // A hostile carrier answering `accepted` with
                                // a page owned by ANOTHER task: the App-side
                                // ownership proof must refuse presentation.
                                hostileRunId ->
                                    effectPage(
                                        correlation, tag,
                                        accepted(runSnapshotValue(hostileRunId, otherConversationId)),
                                    )
                                else -> effectPage(correlation, tag, accepted(runSnapshotValue(runId)))
                            }
                        }
                        tag.startsWith("op:v1:rhistory:") -> {
                            val runId = tag.removePrefix("op:v1:rhistory:").uppercase()
                            effectPage(correlation, tag, accepted(runEventsPage(runId, recordedAnswer(runId))))
                        }
                        else -> effectPage(correlation, tag, accepted("null"))
                    }
                }
                raw.contains("\"command\":\"conversation.get\"") ->
                    receipt(correlation, "cget")
                raw.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "rsnap:${ownerRunIdOf(raw) ?: newestRunId}")
                raw.contains("\"command\":\"run.events\"") ->
                    receipt(correlation, "rhistory:${ownerRunIdOf(raw) ?: newestRunId}")
                raw.contains("\"command\":\"conversation.messagePage\"") ->
                    receipt(correlation, "msgpage")
                raw.contains("\"command\":\"question.pending\"") ->
                    receipt(correlation, "question")
                raw.contains("\"command\":\"child.list\"") ->
                    receipt(correlation, "cchildlist")
                else -> receipt(correlation, "other")
            }
        }
        return exchange
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

    private fun readyHost(exchange: HostBridgeExchange): RuntimeHost {
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        return host
    }

    private suspend fun awaitCondition(timeoutMillis: Long = 3_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    private suspend fun loadAndAwait(host: RuntimeHost):
        com.floe.android.feature.conversation.ConversationFlowHolder {
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(holder.session)
        assertTrue(
            awaitCondition { holder.snapshot.value?.hasLoaded == true },
        )
        return holder
    }

    // ----------------------------------------------------------------- tests

    /** Cold entry: focus staged before the holder exists; the settle applies it. */
    @Test
    fun coldOpenPresentsTheRecordedRunFromTheSessionSettle() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            assertEquals(
                SidebarSelection.Conversation(conversationId),
                host.conversations.navigationRequest.value,
            )
            val holder = loadAndAwait(host)
            // The recorded (OLDER) run is presented, not the newest row.
            assertEquals(recordedRunId, holder.snapshot.value?.selectedRunId)
            assertEquals(
                recordedRunId,
                host.conversations.entryFor(conversationId)?.builder?.selectedRunId,
            )
            assertEquals(recordedRunId, holder.selectedRunId.value)
            // The selected run's authoritative snapshot was re-read.
            assertTrue(
                "the recorded run snapshot must be refreshed",
                awaitCondition {
                    host.conversations.entryFor(conversationId)
                        ?.builder?.runStateName(recordedRunId) == "completed"
                },
            )
        } finally {
            host.stop()
        }
    }

    /** Same-task live tap: a loaded surface switches selection immediately. */
    @Test
    fun liveSameTaskTapSelectsTheRecordedRunImmediately() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            val holder = loadAndAwait(host)
            // Ordinary cold selection is the newest run.
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            assertEquals(
                SidebarSelection.Conversation(conversationId),
                host.conversations.navigationRequest.value,
            )
            assertEquals(recordedRunId, holder.snapshot.value?.selectedRunId)
            assertEquals(recordedRunId, holder.selectedRunId.value)
        } finally {
            host.stop()
        }
    }

    /** An invalid supplied run id must NOT silently select the latest run.
     *  The page lacks it, the authoritative read refuses typed
     *  notFound/runMissing — the task still opens at the ordinary newest
     *  selection and the typed failure is surfaced asynchronously. */
    @Test
    fun missingRecordedRunOpensTheTaskWithAnHonestFailure() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(null, conversationId, missingRunId),
            )
            val holder = loadAndAwait(host)
            // The task still opened (ordinary newest selection)...
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            // ...and the authoritative refusal is surfaced, not swallowed.
            assertTrue(
                awaitCondition { holder.actionError == "scheduledRunUnavailable" },
            )
        } finally {
            host.stop()
        }
    }

    /** A newer plain open supersedes an unconsumed run focus. */
    @Test
    fun plainOpenSupersedesAnUnconsumedRunFocus() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            // The user navigates plainly before the target ever settles.
            assertTrue(host.conversations.requestOpenConversation(null, conversationId))
            val holder = loadAndAwait(host)
            // No stale exact-run selection survives the newer navigation.
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertNull(holder.actionError)
        } finally {
            host.stop()
        }
    }

    /** New Task also retires a pending focus (no later steal). */
    @Test
    fun newTaskSupersedesAnUnconsumedRunFocus() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            assertTrue(host.conversations.requestNewTask(null))
            val holder = loadAndAwait(host)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertNull(holder.actionError)
        } finally {
            host.stop()
        }
    }

    /** Null run id keeps the honest task-only fallback (plain open). */
    @Test
    fun nullRunIdKeepsTheTaskOnlyFallback() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(host.conversations.requestOpenConversationRun(null, conversationId, null))
            assertEquals(
                SidebarSelection.Conversation(conversationId),
                host.conversations.navigationRequest.value,
            )
            val holder = loadAndAwait(host)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertNull(holder.actionError)
        } finally {
            host.stop()
        }
    }

    /** A blank run id is the same honest task-only fallback. */
    @Test
    fun blankRunIdKeepsTheTaskOnlyFallback() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(host.conversations.requestOpenConversationRun(null, conversationId, "  "))
            val holder = loadAndAwait(host)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertNull(holder.actionError)
        } finally {
            host.stop()
        }
    }

    /** Runtime not admitted: refused, nothing published. */
    @Test
    fun notAdmittedRefusesWithoutPublishing() = runBlocking {
        val host = testHost(buildExchange())
        try {
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            // conversationDomain stays unavailable.
            assertFalse(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            assertNull(host.conversations.navigationRequest.value)
        } finally {
            host.stop()
        }
    }

    /** The focus is one-shot: a second load keeps the user's own selection. */
    @Test
    fun consumedFocusDoesNotReplayOnLaterLoads() = runBlocking {
        val host = readyHost(buildExchange())
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            val holder = loadAndAwait(host)
            assertEquals(recordedRunId, holder.snapshot.value?.selectedRunId)
            // A later plain reload (e.g. recomposition) must not re-apply:
            // the focus was consumed exactly once.
            host.conversations.loadThread(holder.session)
            assertTrue(awaitCondition {
                holder.snapshot.value?.hasLoaded == true &&
                    holder.snapshot.value?.selectedRunId == recordedRunId
            })
            // An explicit user selection of the newest run survives reloads.
            val entry = host.conversations.entryFor(conversationId)
            assertNotNull(entry)
            entry!!.builder.selectedRunId = newestRunId
            host.conversations.loadThread(holder.session)
            assertTrue(awaitCondition {
                holder.snapshot.value?.selectedRunId == newestRunId
            })
        } finally {
            host.stop()
        }
    }

    /** A valid recorded run OUTSIDE the native 160-row page stays readable:
     *  bounded-page absence triggers ONE authoritative `run.snapshot` read;
     *  the run is presented, its own distinct recorded receipt is projected
     *  through the real `run.events` read, later refreshes retain the target,
     *  and no run is ever created/continued. */
    @Test
    fun runBeyondTheBoundedPagePresentsThroughTheAuthoritativeRead() = runBlocking {
        val exchange = buildExchange()
        // The native bounded window now carries ONLY the newest run.
        exchange.conversationPageJson = singleRunConversationPage(newestRunId)
        val host = readyHost(exchange)
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            val holder = loadAndAwait(host)
            val selected = awaitCondition { holder.snapshot.value?.selectedRunId == recordedRunId }
            assertTrue(
                "the beyond-page recorded run must become the selection; " +
                    "selected=${holder.snapshot.value?.selectedRunId}; error=${holder.actionError}; " +
                    "requests=${exchange.requests}; replies=${exchange.replies}",
                selected,
            )
            assertEquals(recordedRunId, holder.selectedRunId.value)
            assertEquals(
                "completed",
                host.conversations.entryFor(conversationId)
                    ?.builder?.runStateName(recordedRunId),
            )
            // The old run's DISTINCT receipt is read through the REAL
            // recorded-history service for THIS run id...
            assertTrue(
                "the recorded run's own event journal must be read",
                awaitCondition {
                    exchange.commandsOf("run.events").any {
                        it["owner"]?.jsonObject?.get("runID")
                            ?.jsonPrimitive?.content == recordedRunId
                    }
                },
            )
            // ...and projected as its OWN timeline row (never the newest
            // run's answer replayed as the target's).
            assertTrue(
                "the recorded run's distinct answer must be projected",
                awaitCondition {
                    holder.snapshot.value?.rows?.any {
                        it.id == "assistant.recorded:$recordedRunId:1" &&
                            (it as? com.floe.android.feature.conversation.TimelineRowUi.AssistantMessage)?.text == "recorded-run-answer"
                    } == true
                },
            )
            // Reading history NEVER creates/continues a run or calls a
            // provider: the only commands are reads.
            assertTrue(exchange.commandsOf("run.start").isEmpty())
            // A later session refresh (same bounded page, target still
            // absent from it) RETAINS the presented target — no silent
            // fallback to the newest run.
            host.conversations.loadThread(holder.session)
            assertTrue(
                "later refreshes must not fall back to the newest run",
                awaitCondition {
                    holder.snapshot.value?.hasLoaded == true &&
                        holder.snapshot.value?.selectedRunId == recordedRunId
                },
            )
        } finally {
            host.stop()
        }
    }

    @Test
    fun lowercaseNotificationTargetUsesNativeUUIDIdentityAndOwnReceipt() = runBlocking {
        val exchange = buildExchange()
        exchange.conversationPageJson = singleRunConversationPage(newestRunId)
        val host = readyHost(exchange)
        try {
            assertTrue(host.conversations.requestOpenConversationRun(
                null, conversationId, recordedRunId.lowercase(),
            ))
            val holder = loadAndAwait(host)
            assertTrue(awaitCondition {
                holder.snapshot.value?.selectedRunId == recordedRunId &&
                    holder.snapshot.value?.rows?.any {
                        it.id == "assistant.recorded:$recordedRunId:1" &&
                            (it as? com.floe.android.feature.conversation.TimelineRowUi.AssistantMessage)
                                ?.text == "recorded-run-answer"
                    } == true
            })
            assertEquals(recordedRunId, holder.selectedRunId.value)
            assertTrue(exchange.commandsOf("run.snapshot").any {
                it["owner"]?.jsonObject?.get("runID")?.jsonPrimitive?.content == recordedRunId.lowercase()
            })
            assertTrue(exchange.commandsOf("run.events").any {
                it["owner"]?.jsonObject?.get("runID")?.jsonPrimitive?.content == recordedRunId
            })
            assertTrue(exchange.commandsOf("run.start").isEmpty())
        } finally {
            host.stop()
        }
    }

    /** A LIVE holder whose cached page is stale (recorded before a newer run
     *  existed) presents that newer run through the authoritative read —
     *  cached absence is not proof of absence either. */
    @Test
    fun staleCachedPagePresentsNewerRunThroughTheAuthoritativeRead() = runBlocking {
        val exchange = buildExchange()
        exchange.conversationPageJson = singleRunConversationPage(recordedRunId)
        val host = readyHost(exchange)
        try {
            val holder = loadAndAwait(host)
            // The stale cached page selected its only row.
            assertEquals(recordedRunId, holder.snapshot.value?.selectedRunId)
            // A history/notification target names the NEWER run, absent from
            // the stale cache: the fast path must consult the authority.
            assertTrue(
                host.conversations.requestOpenConversationRun(null, conversationId, newestRunId),
            )
            assertTrue(
                awaitCondition { holder.snapshot.value?.selectedRunId == newestRunId },
            )
            assertEquals(newestRunId, holder.selectedRunId.value)
            assertEquals(
                "completed",
                host.conversations.entryFor(conversationId)
                    ?.builder?.runStateName(newestRunId),
            )
            assertTrue(
                awaitCondition {
                    holder.snapshot.value?.rows?.any {
                        it.id == "assistant.recorded:$newestRunId:1"
                    } == true
                },
            )
            assertNull(holder.actionError)
        } finally {
            host.stop()
        }
    }

    /** A run foreign to this task (authoritative typed notFound/runMissing)
     *  fails honestly: the task stays at its ordinary selection, the typed
     *  failure is surfaced, and nothing is fabricated for the foreign run. */
    @Test
    fun foreignRunTargetFailsHonestlyThroughTheAuthoritativeRead() = runBlocking {
        val exchange = buildExchange()
        val host = readyHost(exchange)
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(null, conversationId, foreignRunId),
            )
            val holder = loadAndAwait(host)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertTrue(
                awaitCondition { holder.actionError == "scheduledRunUnavailable" },
            )
            assertNull(
                host.conversations.entryFor(conversationId)
                    ?.builder?.runStateName(foreignRunId),
            )
            assertTrue(exchange.commandsOf("run.start").isEmpty())
        } finally {
            host.stop()
        }
    }

    /** Even a carrier answering `accepted` with a page owned by ANOTHER task
     *  is refused by the App-side ownership proof: no presentation, honest
     *  failure, no foreign state projected into the builder. */
    @Test
    fun foreignOwnedSnapshotPageRefusedByTheOwnershipProof() = runBlocking {
        val exchange = buildExchange()
        val host = readyHost(exchange)
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(null, conversationId, hostileRunId),
            )
            val holder = loadAndAwait(host)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertTrue(
                awaitCondition { holder.actionError == "scheduledRunUnavailable" },
            )
            assertNull(
                host.conversations.entryFor(conversationId)
                    ?.builder?.runStateName(hostileRunId),
            )
            assertTrue(exchange.commandsOf("run.start").isEmpty())
        } finally {
            host.stop()
        }
    }

    /** A late authoritative reply for a focus the user already superseded can
     *  never steal the later navigation: the focus-generation fence drops it
     *  untouched — selection and error surface stay with the user. */
    @Test
    fun supersededLateAuthoritativeReplyCannotStealSelection() = runBlocking {
        val exchange = buildExchange()
        exchange.conversationPageJson = singleRunConversationPage(newestRunId)
        exchange.snapshotGate = java.util.concurrent.CountDownLatch(1)
        val host = readyHost(exchange)
        try {
            assertTrue(
                host.conversations.requestOpenConversationRun(
                    null, conversationId, recordedRunId),
            )
            val holder = loadAndAwait(host)
            // The authoritative read for the beyond-page target was issued...
            assertTrue(
                awaitCondition {
                    exchange.commandsOf("run.snapshot").any {
                        it["owner"]?.jsonObject?.get("runID")
                            ?.jsonPrimitive?.content == recordedRunId
                    }
                },
            )
            // ...but the user superseded it BEFORE the reply could land.
            assertTrue(host.conversations.requestOpenConversation(null, conversationId))
            exchange.snapshotGate!!.countDown()
            // Let the late reply land: it must be dropped by the generation
            // fence — no selection steal, no error from the stale focus.
            delay(200)
            assertEquals(newestRunId, holder.snapshot.value?.selectedRunId)
            assertNull(holder.actionError)
            assertNull(
                host.conversations.entryFor(conversationId)
                    ?.builder?.runStateName(recordedRunId),
            )
        } finally {
            exchange.snapshotGate!!.countDown()
            host.stop()
        }
    }
}
