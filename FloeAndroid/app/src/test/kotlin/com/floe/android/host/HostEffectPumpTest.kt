// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Authored NOTRUN. Scripted transport double; bounded, typed frames only. */
class HostEffectPumpTest {

    @Test
    fun nativeDomainFailureKeepsWireCodeAndAdmissionFailureStaysIntact() = runBlocking {
        for ((wire, expected) in listOf(
            "staleRevision" to "staleRevision",
            "" to "ordinaryRuntimeBlocked",
            "not a code" to "ordinaryRuntimeBlocked",
        )) {
            val client = client { raw ->
                val correlation = correlationOf(raw)
                """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:domain-error","sequence":1},"effects":[{"sequence":1,"kind":"failed","code":"ordinaryRuntimeBlocked","detail":[{"key":"wire","value":"$wire"}],"value":{"errorCode":"$wire","reason":"revisionResourceMismatch"}}],"hasMore":false,"resyncRequired":false}"""
            }
            val captured = Captured()
            val handle = client.openEffectStream(
                operationReceiptID = "op:v1:domain-error",
                configurationScope = "providers",
                onFrame = captured.frames::add,
                onTerminal = captured.terminals::add,
                onFailure = captured.failures::add,
            )
            repeat(50) { if (captured.terminals.isEmpty()) delay(10) }
            handle.close()
            assertTrue(captured.failures.isEmpty())
            val failure = captured.terminals.single() as HostEffectTerminal.Failed
            assertEquals(expected, failure.code)
            assertEquals("revisionResourceMismatch", failure.reason)
        }
    }

    private class ScriptedExchange(
        private val script: (String) -> String,
    ) : HostBridgeExchange {
        override fun exchange(request: String): String = script(request)
    }

    private data class Captured(
        val frames: MutableList<HostEffectFrame> = CopyOnWriteArrayList(),
        val terminals: MutableList<HostEffectTerminal> = CopyOnWriteArrayList(),
        val failures: MutableList<HostPumpFailure> = CopyOnWriteArrayList(),
    )

    // Two overloads so BOTH call styles bind the lambda to `script`
    // unambiguously: trailing form `client { raw -> ... }` and explicit
    // first-position form `client({ raw -> ... }, budgets = ...)`.
    private fun client(script: (String) -> String): RuntimeHostCommandClient =
        client(script, HostWireBudgets(effectPollIntervalMillis = 1))

    private fun client(
        script: (String) -> String,
        budgets: HostWireBudgets,
    ): RuntimeHostCommandClient = RuntimeHostCommandClient(
        exchange = ScriptedExchange(script),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = budgets,
    )



    @Test
    fun decodesTypedPageAndTerminalOnce() = runBlocking {
        val client = client { raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:abc","sequence":3},"effects":[{"sequence":1,"kind":"prepared","detail":[{"key":"runID","value":"r1"}],"page":{"runID":"r1"}},{"sequence":2,"kind":"started"},{"sequence":3,"kind":"accepted","page":{"launched":true}}],"hasMore":false,"resyncRequired":false}"""
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(200)
        handle.close()
        assertEquals(3, captured.frames.size)
        assertEquals("r1", captured.frames[0].page?.get("runID")?.toString()?.trim('"'))
        assertTrue(captured.terminals.single() is HostEffectTerminal.Completed)
        assertTrue(captured.failures.isEmpty())
    }

    @Test
    fun failedDecodeDoesNotAdvanceCursorAndRecovers() = runBlocking {
        var pollCount = 0
        val client = client { raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    pollCount += 1
                    if (pollCount == 1) {
                        // Sequence regression: server replayed an old frame.
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:abc","sequence":1},"effects":[{"sequence":0,"kind":"started"}],"hasMore":true,"resyncRequired":false}"""
                    } else {
                        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:abc","sequence":1},"effects":[{"sequence":1,"kind":"accepted"}],"hasMore":false,"resyncRequired":false}"""
                    }
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(300)
        handle.close()
        // A sequence regression is a HARD protocol break under the frozen
        // carrier contract: the page is never acked (no frame delivered, the
        // cursor does not advance) and the pump reports the typed failure
        // instead of silently trusting the replayed frame.
        assertTrue(captured.frames.isEmpty())
        assertTrue(captured.terminals.isEmpty())
        assertTrue(captured.failures.any {
            it is HostPumpFailure.Recoverable && it.code == "effectProtocolMismatch"
        })
        // Recovery is a FRESH stream over the same receipt (never a silent
        // continuation of the poisoned cursor): the good page is delivered.
        val recovered = Captured()
        val second = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = recovered.frames::add,
            onTerminal = recovered.terminals::add,
            onFailure = recovered.failures::add,
        )
        delay(150)
        second.close()
        assertTrue(recovered.terminals.singleOrNull() is HostEffectTerminal.Completed)
        assertEquals(1, recovered.frames.size)
    }

    @Test
    fun overBudgetPageSurfacesTypedFailureWithoutAck() = runBlocking {
        val client = client({ raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    val big = "x".repeat(49 * 1024)
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:abc","sequence":1},"effects":[{"sequence":1,"kind":"accepted","page":{"blob":"$big"}}],"hasMore":false,"resyncRequired":false}"""
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }, budgets = HostWireBudgets(effectPollIntervalMillis = 1, maxPageBytes = 48 * 1024))
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(200)
        handle.close()
        val failure = captured.failures.singleOrNull()
        assertTrue(failure is HostPumpFailure.Recoverable)
        assertEquals("frameBudgetExceeded", (failure as HostPumpFailure.Recoverable).code)
        assertTrue(captured.terminals.isEmpty())
    }

    @Test
    fun generationBumpDisposesPumpAsSuperseded() = runBlocking {
        val client = client { raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:abc","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(60)
        client.bumpGeneration()
        delay(120)
        assertTrue(captured.failures.any { it == HostPumpFailure.Superseded })
        assertTrue(handle.job == null || handle.job?.isActive == false)
    }

    @Test
    fun acceptsArrayValueFromRealListPage() = runBlocking {
        val valueJson = """[{"id":"11111111-1111-4111-8111-111111111111",""" +
            """"syncRevision":2,"secret":{"configured":false}}]"""
        val valueBytes = valueJson.toByteArray(Charsets.UTF_8).size
        val client = client { raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    """{"version":3,"requestID":"$correlation","ok":true,""" +
                        """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                        """"cursor":{"operationReceiptID":"op:v1:abc","sequence":1},""" +
                        """"effects":[{"sequence":1,"kind":"accepted","value":$valueJson,""" +
                        """"valueBytes":$valueBytes}],"hasMore":false,"resyncRequired":false}"""
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(60)
        handle.close()
        val terminal = captured.terminals.singleOrNull()
        assertTrue("expected one terminal, got $terminal", terminal is HostEffectTerminal.Completed)
        val value = (terminal as HostEffectTerminal.Completed).value
        assertTrue("array list value must survive the typed carrier: $value",
            value is kotlinx.serialization.json.JsonArray)
        assertEquals(
            "11111111-1111-4111-8111-111111111111",
            ((value as kotlinx.serialization.json.JsonArray)[0]
                as kotlinx.serialization.json.JsonObject)["id"].
                let { (it as kotlinx.serialization.json.JsonPrimitive).content },
        )
        assertTrue(captured.failures.isEmpty())
    }

    @Test
    fun receiptReceiptMismatchIsProtocolBreak() = runBlocking {
        val client = client { raw ->
            when {
                raw.contains("\"command\":\"effect.poll\"") -> {
                    val correlation = correlationOf(raw)
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:FOREIGN","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                }
                else -> """{"version":3,"ok":true,"queued":true,"correlationID":"${correlationOf(raw)}","operationReceiptID":"op:v1:abc"}"""
            }
        }
        val captured = Captured()
        val handle = client.openEffectStream(
            operationReceiptID = "op:v1:abc",
            configurationScope = "providers",
            onFrame = captured.frames::add,
            onTerminal = captured.terminals::add,
            onFailure = captured.failures::add,
        )
        delay(150)
        handle.close()
        assertTrue(captured.failures.any {
            it is HostPumpFailure.Recoverable && it.code == "effectProtocolMismatch"
        })
    }
}
