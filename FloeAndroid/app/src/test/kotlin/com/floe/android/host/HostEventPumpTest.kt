// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Run-event pump wire tests. The request fixture is the EXACT outer
 * `event.poll` operation + frozen `floe.event-cursor/3` document the native
 * BridgeEnvelopeV3 validator accepts; the response fixtures are the EXACT
 * shape emitted by the native event-pump handler (`durable` window with
 * `windowState`/`events`/`nextSequence` and a JSON-STRING `payload`).
 */
class HostEventPumpTest {

    private val taskID = "11111111-1111-4111-8111-111111111111"
    private val runID = "22222222-2222-4222-8222-222222222222"

    private class ScriptedExchange(
        private val script: (String) -> String,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return script(request)
        }
    }

    private fun client(exchange: HostBridgeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 1),
    )

    private fun page(
        correlation: String,
        windowState: String,
        nextSequence: Long,
        events: String = "[]",
        hasMore: Boolean = false,
    ): String = """{"version":3,"requestID":"$correlation","ok":true,""" +
        """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
        """"cursor":{"runID":"$runID","sequence":$nextSequence},""" +
        """"durable":{"windowState":"$windowState","events":$events,""" +
        """"hasMore":$hasMore,"resyncRequired":false,"nextSequence":$nextSequence},""" +
        """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
        """"resyncRequired":false}"""

    @Test
    fun requestIsCanonicalEventPoll() = runBlocking {
        val exchange = ScriptedExchange { raw ->
            page(correlationOf(raw), "notAttached", 0)
        }
        val client = client(exchange)
        val frames = CopyOnWriteArrayList<HostRunEventFrame>()
        val failures = CopyOnWriteArrayList<HostPumpFailure>()
        val handle = client.openRunEventStream(
            taskID = taskID,
            runID = runID,
            environmentID = null,
            jobID = null,
            onEvent = frames::add,
            onLiveHint = { },
            onFailure = failures::add,
        )
        delay(40)
        handle.close()
        val root = Json.parseToJsonElement(exchange.requests.first()) as JsonObject
        assertEquals(3L, (root["version"] as JsonPrimitive).content.toLong())
        assertEquals("event.poll", (root["operation"] as JsonPrimitive).content)
        val correlation = (root["requestID"] as JsonPrimitive).content
        val envelope = root["envelope"] as JsonObject
        assertEquals("floe.event-cursor/3", (envelope["schema"] as JsonPrimitive).content)
        assertEquals("taskExecution", (envelope["scope"] as JsonPrimitive).content)
        assertEquals(correlation, (envelope["correlationID"] as JsonPrimitive).content)
        val owner = envelope["owner"] as JsonObject
        assertEquals(taskID, (owner["taskID"] as JsonPrimitive).content)
        assertEquals(runID, (owner["runID"] as JsonPrimitive).content)
        val cursor = envelope["cursor"] as JsonObject
        assertEquals(runID, (cursor["runID"] as JsonPrimitive).content)
        assertEquals(0L, (cursor["sequence"] as JsonPrimitive).content.toLong())
        assertFalse(envelope.containsKey("event"))
        assertFalse(envelope.containsKey("version"))
        assertTrue(frames.isEmpty())
        assertTrue(failures.isEmpty())
    }

    @Test
    fun notAttachedWindowIsAnHonestPositiveOutcome() = runBlocking {
        val exchange = ScriptedExchange { raw -> page(correlationOf(raw), "notAttached", 0) }
        val client = client(exchange)
        val frames = CopyOnWriteArrayList<HostRunEventFrame>()
        val failures = CopyOnWriteArrayList<HostPumpFailure>()
        val handle = client.openRunEventStream(taskID, runID, null, null,
            onEvent = frames::add, onLiveHint = { }, onFailure = failures::add)
        delay(40)
        handle.close()
        assertTrue(exchange.requests.isNotEmpty())
        assertTrue(frames.isEmpty())
        assertTrue("notAttached must not be treated as a protocol failure: $failures",
            failures.isEmpty())
    }

    @Test
    fun durableEventPayloadStringIsParsedIntoTheTypedFrame() = runBlocking {
        val polls = java.util.concurrent.atomic.AtomicInteger(0)
        val exchange = ScriptedExchange { raw ->
            val correlation = correlationOf(raw)
            if (polls.incrementAndGet() == 1) {
                page(
                    correlation, "attached", 1,
                    events = """[{"sequence":1,"kind":"assistantText","createdAt":123,""" +
                        """"payload":"{\"text\":\"hello\"}"}]""",
                )
            } else {
                page(correlation, "attached", 1)
            }
        }
        val client = client(exchange)
        val frames = CopyOnWriteArrayList<HostRunEventFrame>()
        val failures = CopyOnWriteArrayList<HostPumpFailure>()
        val handle = client.openRunEventStream(taskID, runID, null, null,
            onEvent = frames::add, onLiveHint = { }, onFailure = failures::add)
        delay(80)
        handle.close()
        val frame = frames.singleOrNull()
        assertTrue("expected exactly one decoded durable frame, got $frames", frame != null)
        assertEquals(1L, frame!!.sequence)
        assertEquals("assistantText", frame.kind)
        assertEquals("hello", (frame.payload?.get("text") as JsonPrimitive).content)
        assertTrue(failures.isEmpty())
    }

    @Test
    fun cursorRunMismatchIsProtocolBreak() = runBlocking {
        val exchange = ScriptedExchange { raw ->
            val correlation = correlationOf(raw)
            val wrong = "33333333-3333-4333-8333-333333333333"
            """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.event-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"runID":"$wrong","sequence":0},""" +
                """"durable":{"windowState":"notAttached","events":[],"hasMore":false,""" +
                """"resyncRequired":false,"nextSequence":0},""" +
                """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
                """"resyncRequired":false}"""
        }
        val client = client(exchange)
        val failures = CopyOnWriteArrayList<HostPumpFailure>()
        val handle = client.openRunEventStream(taskID, runID, null, null,
            onEvent = {}, onLiveHint = { }, onFailure = failures::add)
        delay(60)
        handle.close()
        assertTrue(failures.any {
            it is HostPumpFailure.Recoverable && it.code == "eventProtocolMismatch"
        })
    }

}
