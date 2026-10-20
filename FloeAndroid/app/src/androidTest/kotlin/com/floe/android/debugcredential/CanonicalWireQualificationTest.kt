// SPDX-License-Identifier: MPL-2.0
//
// Product-UID canonical Bridge V3 wire qualification (READ-ONLY config/event;
// one marked synthetic QA conversation that is deleted when the trusted
// deletion lifecycle is bound, otherwise reported for Main cleanup).
//
// Everything below goes through the PRODUCT process's actual JNI bridge
// (`SwiftCore.exchange`) and the actual `RuntimeHostCommandClient` — never a
// fake exchange, never a second database, never a fabricated success. The
// negative cases send the EXACT wrong shapes the frozen validator must refuse
// (old bare envelope, wrong schema, wrong scope, correlation mismatch, owner
// cursor mismatch).
package com.floe.android.debugcredential

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CanonicalWireQualificationTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val json = Json { ignoreUnknownKeys = true; isLenient = false }

    private class RecordingExchange : com.floe.android.host.HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        val responses = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            val response = com.floe.android.bridge.SwiftCore.exchange(request)
            responses.add(response)
            return response
        }
    }

    private data class Outcome(
        val submit: com.floe.android.host.HostSubmitResult,
        val terminal: com.floe.android.host.HostEffectTerminal? = null,
        val failure: com.floe.android.host.HostPumpFailure? = null,
    )

    private fun client(exchange: com.floe.android.host.HostBridgeExchange) =
        com.floe.android.host.RuntimeHostCommandClient(
            exchange = exchange,
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        )

    private fun readiness(): JsonObject {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            val raw = runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness()
            }.getOrNull()
            if (raw != null) {
                val root = json.parseToJsonElement(raw) as JsonObject
                val epoch = (root["epoch"] as? JsonPrimitive)?.longOrNull ?: 0L
                val nativeEpoch = (root["nativeRootEpoch"] as? JsonPrimitive)?.longOrNull ?: 0L
                if (epoch > 0 && nativeEpoch == epoch) {
                    val info = context.packageManager.getApplicationInfo(context.packageName, 0)
                    assertEquals("must run in the product App UID",
                        info.uid, android.os.Process.myUid())
                    val domains = (root["domains"] as? JsonArray) ?: JsonArray(emptyList())
                    val states = domains.mapNotNull { element ->
                        val obj = element as? JsonObject ?: return@mapNotNull null
                        val name = (obj["domain"] as? JsonPrimitive)?.contentOrNull
                        val state = (obj["state"] as? JsonPrimitive)?.contentOrNull
                        if (name == null || state == null) null else name to state
                    }.toMap()
                    assertEquals("provider domain ready",
                        "ready", states["providerConfigurationDomain"])
                    assertEquals("conversation domain ready",
                        "ready", states["conversationDomain"])
                    return root
                }
            }
            Thread.sleep(250)
        }
        throw AssertionError("accepted runtime generation not observed")
    }

    private suspend fun execute(
        client: com.floe.android.host.RuntimeHostCommandClient,
        request: com.floe.android.host.HostCommandRequest,
        timeoutMillis: Long = 25_000,
    ): Outcome {
        val submitted = client.submit(request)
        if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) {
            return Outcome(submitted)
        }
        client.closeCorrelation(request.correlationID)
        val done = CompletableDeferred<Outcome>()
        val handle = client.openEffectStream(
            operationReceiptID = submitted.operationReceiptID,
            configurationScope = request.configurationScope ?: "system",
            onFrame = { },
            onTerminal = { terminal ->
                if (!done.isCompleted) done.complete(Outcome(submitted, terminal = terminal))
            },
            onFailure = { failure ->
                if (!done.isCompleted) done.complete(Outcome(submitted, failure = failure))
            },
        )
        val outcome = try {
            withTimeout(timeoutMillis) { done.await() }
        } finally {
            handle.close()
        }
        return outcome
    }

    private fun completedValue(outcome: Outcome, label: String): JsonElement {
        assertTrue("$label submit rejected/failed: ${outcome.submit}",
            outcome.submit is com.floe.android.host.HostSubmitResult.Accepted)
        assertNotNull("$label pump failure: ${outcome.failure}", outcome.terminal)
        val terminal = outcome.terminal
        assertTrue("$label terminal was not Completed: $terminal",
            terminal is com.floe.android.host.HostEffectTerminal.Completed)
        val value = (terminal as com.floe.android.host.HostEffectTerminal.Completed).value
        assertNotNull("$label completed without a typed value", value)
        return value!!
    }

    private fun raw(request: String): JsonObject =
        json.parseToJsonElement(com.floe.android.bridge.SwiftCore.exchange(request)) as JsonObject

    @Test
    fun providersListUsesCanonicalV3AndReturnsTheRealEffectValue(): Unit = runBlocking {
        val readiness = readiness()
        val epoch = (readiness["epoch"] as JsonPrimitive).longOrNull ?: 0L
        val exchange = RecordingExchange()
        val client = client(exchange)
        val correlation = "canonical-providers-${System.nanoTime()}"
        val outcome = execute(
            client,
            com.floe.android.host.HostCommandRequest(
                command = "config.providers.list",
                scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = correlation,
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        )
        val value = completedValue(outcome, "config.providers.list")
        // Main decision 2026-10-20: the frozen OBJECT-only carrier delivers
        // the ConfigPageComposer list as the explicit {"rows":[...]} object
        // composed at the G02 domain-to-carrier binder boundary. A bare
        // top-level array must NOT reach the App (the carrier refuses it);
        // asserting this exact shape is what pins the repair on-device.
        assertTrue("providers list value must be the {rows} OBJECT carrier: $value",
            value is JsonObject)
        val rows = (value as JsonObject)["rows"] as? JsonArray
            ?: throw AssertionError("providers list object carries no rows array: $value")
        for (element in rows) {
            val obj = element as? JsonObject ?: throw AssertionError("non-object provider row")
            val id = (obj["id"] as? JsonPrimitive)?.contentOrNull
            assertNotNull("provider row id missing", id)
            UUID.fromString(id!!) // canonical UUID identity; throws on malformed rows
            assertTrue("provider row syncRevision missing: $obj",
                obj["syncRevision"] is JsonPrimitive)
            assertTrue("provider row secret status missing: $obj",
                obj["secret"] is JsonObject)
        }
        // The exact first request/response bytes are retained (public
        // metadata only; no secret value is ever read by this command).
        val evidence = buildString {
            append("EPOCH\n").append(epoch).append("\n")
            append("REQUEST\n").append(exchange.requests.first()).append("\n")
            append("RESPONSE\n").append(exchange.responses.first()).append("\n")
            append("ROWS\n").append(rows.size).append("\n")
            for (element in rows) {
                val obj = element as JsonObject
                append("ROW\n").append(obj.toString()).append("\n")
            }
        }
        val out = File(context.filesDir, "floe-canonical-providers.txt")
        out.writeText(evidence)
        Log.i(TAG, "FLOE_CANONICAL_PROVIDERS ok epoch=$epoch rows=${rows.size} " +
            "file=${out.absolutePath}")
    }

    @Test
    fun conversationCreateGetAndMessagePageThroughRealJni(): Unit = runBlocking {
        val readiness = readiness()
        val epoch = (readiness["epoch"] as JsonPrimitive).longOrNull ?: 0L
        val client = client(RecordingExchange())
        val title = "wire-qa-${System.currentTimeMillis()}"
        val created = completedValue(
            execute(
                client,
                com.floe.android.host.HostCommandRequest(
                    command = "conversation.create",
                    scope = com.floe.android.host.HostScope.LaunchNewIdentity,
                    stateful = true,
                    correlationID = "canonical-create-${System.nanoTime()}",
                    createIntent = true,
                    payload = JsonObject(mapOf("title" to JsonPrimitive(title))),
                ),
            ),
            "conversation.create",
        ) as? JsonObject ?: throw AssertionError("create value is not an object")
        val createdConversationID = (created["conversationID"] as? JsonPrimitive)?.contentOrNull
        val createdResourceID = (created["resourceID"] as? JsonPrimitive)?.contentOrNull
        val createdRevision = (created["revision"] as? JsonPrimitive)?.contentOrNull
        val createdTitle = (created["title"] as? JsonPrimitive)?.contentOrNull
        assertNotNull("create conversationID missing: $created", createdConversationID)
        assertNotNull("create resourceID missing: $created", createdResourceID)
        assertNotNull("create revision missing: $created", createdRevision)
        val conversationID = createdConversationID!!
        val resourceID = createdResourceID!!
        val revision = createdRevision!!
        UUID.fromString(conversationID)
        assertEquals("conversation.$conversationID", resourceID)
        assertEquals(title, createdTitle)

        val fetched = completedValue(
            execute(
                client,
                com.floe.android.host.HostCommandRequest(
                    command = "conversation.get",
                    scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                    stateful = false,
                    correlationID = "canonical-get-${System.nanoTime()}",
                ),
            ),
            "conversation.get",
        ) as? JsonObject ?: throw AssertionError("get value is not an object")
        assertEquals(conversationID,
            (fetched["conversationID"] as? JsonPrimitive)?.contentOrNull)
        assertEquals(title, (fetched["title"] as? JsonPrimitive)?.contentOrNull)
        assertEquals(resourceID, (fetched["resourceID"] as? JsonPrimitive)?.contentOrNull)
        assertEquals(revision, (fetched["revision"] as? JsonPrimitive)?.contentOrNull)
        // Fresh (unarchived) get: the projection carries an EXPLICIT JSON
        // null for archivedAt (never an omitted field, never a stringified
        // "null"; the boxed Optional.none previously poisoned the strict
        // binder and settled frameBudgetExceeded on this exact read).
        assertTrue("fresh conversation.get must carry the archivedAt member",
            fetched.containsKey("archivedAt"))
        assertEquals("fresh conversation.get archivedAt must be JSON null",
            JsonNull, fetched["archivedAt"])
        // Run/pending snapshots of a fresh conversation are real empty
        // arrays with numeric counts (not nulls, not omissions).
        assertTrue("fresh conversation.get runs must be an array",
            fetched["runs"] is JsonArray)
        assertTrue("fresh conversation.get pendingInputs must be an array",
            fetched["pendingInputs"] is JsonArray)
        val messageRows = (fetched["firstScreen"] as? JsonObject)
            ?.get("rows") as? JsonArray
            ?: throw AssertionError("fresh get firstScreen rows missing")
        assertEquals("fresh conversation has no persisted messages", 0, messageRows.size)

        val page = completedValue(
            execute(
                client,
                com.floe.android.host.HostCommandRequest(
                    command = "conversation.messagePage",
                    scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                    stateful = false,
                    correlationID = "canonical-page-${System.nanoTime()}",
                    payload = JsonObject(mapOf("limit" to JsonPrimitive(20))),
                ),
            ),
            "conversation.messagePage",
        ) as? JsonObject ?: throw AssertionError("message page value is not an object")
        val rows = page["rows"] as? JsonArray ?: throw AssertionError("message rows missing")
        assertEquals("fresh conversation has no persisted messages", 0, rows.size)
        assertFalse("fresh conversation hasEarlier must be false",
            (page["hasEarlier"] as? JsonPrimitive)?.content?.toBoolean() ?: false)

        // Keep the device clean when the trusted deletion lifecycle is bound;
        // otherwise record the exact owned synthetic id for Main cleanup.
        val deleteOutcome = execute(
            client,
            com.floe.android.host.HostCommandRequest(
                command = "conversation.delete",
                scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                stateful = true,
                correlationID = "canonical-delete-${System.nanoTime()}",
                revision = com.floe.android.host.HostRevision(resourceID!!, revision!!),
            ),
        )
        val deleted = deleteOutcome.terminal is com.floe.android.host.HostEffectTerminal.Completed
        val deleteCode = (deleteOutcome.terminal
            as? com.floe.android.host.HostEffectTerminal.Rejected)?.code
        val cleanup = if (deleted) "deleted" else "retained:${deleteCode ?: "unconfirmed"}"
        val out = File(context.filesDir, "floe-canonical-conversation.json")
        out.writeText(
            "{\"epoch\":$epoch,\"conversationID\":\"$conversationID\"," +
                "\"resourceID\":\"$resourceID\",\"revision\":\"$revision\"," +
                "\"title\":\"$title\",\"messageRows\":${rows.size}," +
                "\"cleanup\":\"$cleanup\"}",
        )
        Log.i(TAG, "FLOE_CANONICAL_CONVERSATION ok epoch=$epoch id=$conversationID " +
            "rows=${rows.size} cleanup=$cleanup file=${out.absolutePath}")
    }

    @Test
    fun eventPollRoutesCanonicallyAndReportsTheActualWindowOutcome(): Unit = runBlocking {
        readiness()
        val runID = UUID.randomUUID().toString()
        val taskID = UUID.randomUUID().toString()
        val correlation = "canonical-event-${System.nanoTime()}"
        val request = """{"version":3,"operation":"event.poll","requestID":"$correlation",""" +
            """"envelope":{"schema":"floe.event-cursor/3","scope":"taskExecution",""" +
            """"owner":{"taskID":"$taskID","runID":"$runID"},""" +
            """"command":"event.poll","stateful":false,""" +
            """"cursor":{"runID":"$runID","sequence":0},""" +
            """"correlationID":"$correlation"}}"""
        val response = raw(request)
        assertEquals(true, (response["ok"] as JsonPrimitive).content.toBoolean())
        assertEquals(3L, (response["version"] as JsonPrimitive).content.toLong())
        assertEquals(correlation, (response["requestID"] as JsonPrimitive).content)
        assertEquals("floe.event-cursor/3",
            (response["schema"] as JsonPrimitive).content)
        val durable = response["durable"] as? JsonObject
            ?: throw AssertionError("durable window missing: $response")
        // Precise known outcome for a run that has no attached durable window
        // or live consumer: honest notAttached/noConsumer, never synthesized
        // events and never a fabricated success list.
        assertEquals("notAttached", (durable["windowState"] as JsonPrimitive).content)
        assertEquals(0, (durable["events"] as JsonArray).size)
        assertEquals(false, (durable["hasMore"] as JsonPrimitive).content.toBoolean())
        val live = response["live"] as? JsonObject ?: throw AssertionError("live missing")
        assertEquals("noConsumer", (live["liveState"] as JsonPrimitive).content)

        // The ACTUAL client pump sends the same canonical request and stays
        // healthy on this honest empty outcome.
        val exchange = RecordingExchange()
        val client = client(exchange)
        val frames = CopyOnWriteArrayList<com.floe.android.host.HostRunEventFrame>()
        val failures = CopyOnWriteArrayList<com.floe.android.host.HostPumpFailure>()
        val handle = client.openRunEventStream(
            taskID = taskID, runID = runID, environmentID = null, jobID = null,
            onEvent = { frames.add(it) },
            onLiveHint = { },
            onFailure = { failures.add(it) },
        )
        Thread.sleep(300)
        handle.close()
        assertTrue("event pump never sent a request", exchange.requests.isNotEmpty())
        assertTrue("event pump reported a failure: $failures", failures.isEmpty())
        assertTrue("no durable event exists for a random run", frames.isEmpty())
        val pumpRequest = json.parseToJsonElement(exchange.requests.first()) as JsonObject
        assertEquals("event.poll", (pumpRequest["operation"] as JsonPrimitive).content)
        assertEquals("taskExecution",
            ((pumpRequest["envelope"] as JsonObject)["scope"] as JsonPrimitive).content)
    }

    @Test
    fun wrongVersionSchemaScopeCorrelationOwnerAndCursorStayRefused() {
        readiness()
        val taskID = UUID.randomUUID().toString()
        val runID = UUID.randomUUID().toString()
        fun envelope(
            schema: String = "floe.event-cursor/3",
            scope: String = "taskExecution",
            requestID: String = "neg-1",
            correlation: String? = null,
            ownerRun: String = runID,
            cursorRun: String = runID,
            operation: String = "event.poll",
        ): String {
            val corr = correlation ?: requestID
            return """{"version":3,"operation":"$operation","requestID":"$requestID",""" +
                """"envelope":{"schema":"$schema","scope":"$scope",""" +
                """"owner":{"taskID":"$taskID","runID":"$ownerRun"},""" +
                """"command":"event.poll","stateful":false,""" +
                """"cursor":{"runID":"$cursorRun","sequence":0},""" +
                """"correlationID":"$corr"}}"""
        }
        fun reason(request: String): String {
            val response = raw(request)
            assertEquals("expected invalidEnvelope: $response",
                "invalidEnvelope", (response["error"] as JsonPrimitive).content)
            return (response["reason"] as JsonPrimitive).content
        }

        // 1) The pre-fix bare inner command document has no outer operation:
        //    the frozen dispatcher answers unsupportedOperation.
        val bare = raw(
            """{"schema":"floe.command-envelope/3","version":3,""" +
                """"command":"config.providers.list",""" +
                """"scope":{"kind":"applicationConfiguration","configurationScope":"providers"},""" +
                """"stateful":false,"correlationID":"neg-bare"}""",
        )
        assertEquals("unsupportedOperation", (bare["error"] as JsonPrimitive).content)

        // 2) Wrong schema on the event channel.
        assertEquals("schemaRoleMismatch",
            reason(envelope(schema = "floe.command-envelope/3")))

        // 3) Wrong scope for an event poll.
        assertEquals("eventPollRequiresTaskScope",
            reason(envelope(scope = "applicationConfiguration")))

        // 4) Correlation must equal the request identity.
        assertEquals("correlationMismatch",
            reason(envelope(requestID = "neg-corr", correlation = "foreign")))

        // 5) The cursor run must equal the owner run.
        assertEquals("cursorRunMismatch",
            reason(envelope(ownerRun = runID,
                cursorRun = UUID.randomUUID().toString())))

        // 6) A command envelope with wrong schema is a role mismatch too.
        val wrongSchemaCommand = raw(
            """{"version":3,"operation":"command.submit","requestID":"neg-cmd",""" +
                """"envelope":{"schema":"floe.event-cursor/3","scope":"applicationConfiguration",""" +
                """"configurationScope":"providers","command":"config.providers.list",""" +
                """"stateful":false,"correlationID":"neg-cmd"}}""",
        )
        assertEquals("invalidEnvelope", (wrongSchemaCommand["error"] as JsonPrimitive).content)
        assertEquals("schemaRoleMismatch",
            (wrongSchemaCommand["reason"] as JsonPrimitive).content)

        // 7) Configuration scope must never carry an execution owner.
        val ownerOnConfig = raw(
            """{"version":3,"operation":"command.submit","requestID":"neg-owner",""" +
                """"envelope":{"schema":"floe.command-envelope/3",""" +
                """"scope":"applicationConfiguration","configurationScope":"providers",""" +
                """"owner":{"taskID":"$taskID"},"command":"config.providers.list",""" +
                """"stateful":false,"correlationID":"neg-owner"}}""",
        )
        assertEquals("invalidEnvelope", (ownerOnConfig["error"] as JsonPrimitive).content)
        assertEquals("configurationScopeMustNotCarryOwner",
            (ownerOnConfig["reason"] as JsonPrimitive).content)

        // 8) Task execution requires a real owner.
        val missingOwner = raw(
            """{"version":3,"operation":"command.submit","requestID":"neg-noowner",""" +
                """"envelope":{"schema":"floe.command-envelope/3","scope":"taskExecution",""" +
                """"command":"run.cancel","stateful":true,""" +
                """"revision":{"resourceID":"run.$runID","version":"v"},""" +
                """"correlationID":"neg-noowner"}}""",
        )
        assertEquals("invalidEnvelope", (missingOwner["error"] as JsonPrimitive).content)
        assertEquals("missingExecutionOwner",
            (missingOwner["reason"] as JsonPrimitive).content)

        // 9) An effect-only identity on the event channel is refused.
        val effectOnEvent = raw(
            """{"version":3,"operation":"event.poll","requestID":"neg-effect",""" +
                """"envelope":{"schema":"floe.event-cursor/3","scope":"taskExecution",""" +
                """"owner":{"taskID":"$taskID","runID":"$runID"},""" +
                """"command":"event.poll","stateful":false,""" +
                """"cursor":{"runID":"$runID","sequence":0},""" +
                """"effect":{"operationReceiptID":"op:v1:x","sequence":0},""" +
                """"correlationID":"neg-effect"}}""",
        )
        assertEquals("invalidEnvelope", (effectOnEvent["error"] as JsonPrimitive).content)
        assertEquals("effectIdentityNotAllowed",
            (effectOnEvent["reason"] as JsonPrimitive).content)
        Log.i(TAG, "FLOE_CANONICAL_NEGATIVES ok 9/9 refused")
    }

    /**
     * DIAGNOSTIC ONLY (not an acceptance gate): records the EXACT terminal
     * for every ordinary reply shape so a host-side carrier defect can be
     * separated from a wire-shape defect without guessing.
     */
    @Test
    fun carrierDiagnostics(): Unit = runBlocking {
        readiness()
        val client = client(RecordingExchange())
        val created = execute(
            client,
            com.floe.android.host.HostCommandRequest(
                command = "conversation.create",
                scope = com.floe.android.host.HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = "diag-create-${System.nanoTime()}",
                createIntent = true,
                payload = JsonObject(mapOf("title" to JsonPrimitive("wire-diag-${System.currentTimeMillis()}"))),
            ),
        )
        val createdValue = created.terminal
        val createdObject = (createdValue as? com.floe.android.host.HostEffectTerminal.Completed)
            ?.value as? JsonObject
        val conversationID = (createdObject?.get("conversationID") as? JsonPrimitive)
            ?.contentOrNull
        val createdResourceID = (createdObject?.get("resourceID") as? JsonPrimitive)
            ?.contentOrNull
        val createdRevision = (createdObject?.get("revision") as? JsonPrimitive)
            ?.contentOrNull
        val lines = StringBuilder()
        fun record(label: String, outcome: Outcome) {
            val terminal = outcome.terminal
            val value = (terminal as? com.floe.android.host.HostEffectTerminal.Completed)?.value
            lines.append(label).append(" submit=").append(outcome.submit)
                .append(" terminal=").append(terminal?.javaClass?.simpleName)
                .append(" valueType=").append(value?.javaClass?.simpleName)
                .append(" terminalDetail=").append(
                    when (terminal) {
                        is com.floe.android.host.HostEffectTerminal.Completed -> "value=${value?.toString()?.take(160)}"
                        is com.floe.android.host.HostEffectTerminal.Rejected ->
                            "code=${terminal.code} reason=${terminal.reason} detail=${terminal.detail}"
                        is com.floe.android.host.HostEffectTerminal.Failed ->
                            "code=${terminal.code} reason=${terminal.reason} detail=${terminal.detail}"
                        is com.floe.android.host.HostEffectTerminal.Cancelled -> "cancelled"
                        is com.floe.android.host.HostEffectTerminal.Closed -> "closed"
                        is com.floe.android.host.HostEffectTerminal.Replaced -> "replaced"
                        null -> "none"
                    },
                )
                .append(" failure=").append(outcome.failure).append("\n")
        }
        record("conversation.create", created)
        if (conversationID != null) {
            record("conversation.get", execute(client, com.floe.android.host.HostCommandRequest(
                command = "conversation.get",
                scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                stateful = false,
                correlationID = "diag-get-${System.nanoTime()}",
            )))
            record("conversation.messagePage", execute(client, com.floe.android.host.HostCommandRequest(
                command = "conversation.messagePage",
                scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                stateful = false,
                correlationID = "diag-page-${System.nanoTime()}",
                payload = JsonObject(mapOf("limit" to JsonPrimitive(20))),
            )))
        }
        if (conversationID != null && createdResourceID != null && createdRevision != null) {
            // A pinned archivedAt is a real String, so this isolates the
            // Optional.none carrier member from every numeric/bool member.
            record("conversation.archive", execute(client, com.floe.android.host.HostCommandRequest(
                command = "conversation.archive",
                scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                stateful = true,
                correlationID = "diag-archive-${System.nanoTime()}",
                revision = com.floe.android.host.HostRevision(createdResourceID, createdRevision),
                payload = JsonObject(mapOf("archived" to JsonPrimitive(true))),
            )))
            record("conversation.get(archived)", execute(client, com.floe.android.host.HostCommandRequest(
                command = "conversation.get",
                scope = com.floe.android.host.HostScope.ConversationLifecycle(conversationID),
                stateful = false,
                correlationID = "diag-get-archived-${System.nanoTime()}",
            )))
        }
        record("conversation.list", execute(client, com.floe.android.host.HostCommandRequest(
            command = "conversation.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("conversations"),
            stateful = false,
            correlationID = "diag-list-${System.nanoTime()}",
        )))
        record("conversation.search", execute(client, com.floe.android.host.HostCommandRequest(
            command = "conversation.search",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("conversations"),
            stateful = false,
            correlationID = "diag-search-${System.nanoTime()}",
            payload = JsonObject(mapOf("query" to JsonPrimitive("wire"))),
        )))
        record("config.providers.list", execute(client, com.floe.android.host.HostCommandRequest(
            command = "config.providers.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
            stateful = false,
            correlationID = "diag-providers-${System.nanoTime()}",
            payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
        )))
        record("config.models.list", execute(client, com.floe.android.host.HostCommandRequest(
            command = "config.models.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("models"),
            stateful = false,
            correlationID = "diag-models-${System.nanoTime()}",
        )))
        record("system.lifecycle", execute(client, com.floe.android.host.HostCommandRequest(
            command = "system.lifecycle",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("system"),
            stateful = false,
            correlationID = "diag-lifecycle-${System.nanoTime()}",
        )))
        val out = File(context.filesDir, "floe-carrier-diagnostics.txt")
        out.writeText(lines.toString())
        Log.i(TAG, "FLOE_CARRIER_DIAGNOSTICS file=${out.absolutePath} bytes=${out.length()}")
    }

    /** Records every owned synthetic QA conversation id for Main cleanup
     *  (the trusted deletion lifecycle is not bound in this generation, so
     *  the harness cannot delete them itself). Diagnostic only. */
    @Test
    fun recordSyntheticConversations(): Unit = runBlocking {
        readiness()
        val client = client(RecordingExchange())
        val outcome = execute(
            client,
            com.floe.android.host.HostCommandRequest(
                command = "conversation.list",
                scope = com.floe.android.host.HostScope.ApplicationConfiguration("conversations"),
                stateful = false,
                correlationID = "diag-convlist-${System.nanoTime()}",
                payload = JsonObject(mapOf(
                    "includeArchived" to JsonPrimitive(true),
                    "limit" to JsonPrimitive(50),
                    "includeRevision" to JsonPrimitive(true),
                )),
            ),
        )
        val value = completedValue(outcome, "conversation.list(cleanup)") as? JsonObject
            ?: throw AssertionError("conversation.list value not an object")
        val rows = (value["rows"] as? JsonArray) ?: JsonArray(emptyList())
        val synthetic = rows.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val id = (obj["conversationID"] as? JsonPrimitive)?.contentOrNull
            val title = (obj["title"] as? JsonPrimitive)?.contentOrNull
            if (id != null && title != null && title.startsWith("wire-")) {
                JsonObject(mapOf(
                    "conversationID" to JsonPrimitive(id),
                    "title" to JsonPrimitive(title),
                ))
            } else null
        }
        val out = File(context.filesDir, "floe-synthetic-conversations.json")
        out.writeText(JsonArray(synthetic).toString())
        Log.i(TAG, "FLOE_SYNTHETIC_CONVERSATIONS count=${synthetic.size} " +
            "file=${out.absolutePath}")
    }

    private companion object {
        const val TAG = "FloeCanonicalWire"
    }
}
