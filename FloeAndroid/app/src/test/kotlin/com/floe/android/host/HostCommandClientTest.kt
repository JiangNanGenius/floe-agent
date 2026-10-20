// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN (no JVM/Gradle execution in the source phase). Controlled
 * transport double only — these tests never touch the real bridge.
 */
class HostCommandClientTest {

    private class FakeExchange(
        private val responder: (String) -> String = { raw ->
            val correlation = correlationOf(raw)
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:abc123"}"""
        },
    ) : HostBridgeExchange {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return responder(request)
        }

        companion object {
            fun correlationOf(raw: String): String {
                val marker = "\"correlationID\":\""
                val start = raw.indexOf(marker)
                if (start < 0) return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return raw.substring(from, end)
            }
        }
    }

    private fun client(exchange: FakeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.IO,
    )

    @Test
    fun submitBuildsClosedEnvelopeAndParsesReceipt() = runBlocking {
        val fake = FakeExchange()
        val client = client(fake)
        val result = client.submit(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = "test-1",
                payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
            ),
        )
        assertTrue(result is HostSubmitResult.Accepted)
        assertEquals("op:v1:abc123", (result as HostSubmitResult.Accepted).operationReceiptID)
        // EXACT canonical v3 command.submit request (outer operation envelope
        // + frozen floe.command-envelope/3 inner document with a STRING scope
        // and the configuration label as a sibling). This fixture is the
        // shape the native BridgeEnvelopeV3 validator accepts; the bare inner
        // object is a different (unsupportedOperation) request.
        val expected = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"version":3,"operation":"command.submit","requestID":"test-1","envelope":{""" +
                """"schema":"floe.command-envelope/3","scope":"applicationConfiguration",""" +
                """"configurationScope":"providers","command":"config.providers.list",""" +
                """"stateful":false,"correlationID":"test-1",""" +
                """"payload":{"operation":"snapshot"}}}""",
        )
        assertEquals(expected, kotlinx.serialization.json.Json.parseToJsonElement(fake.requests.single()))
        assertTrue(client.ownsCorrelation("test-1"))
    }

    @Test
    fun matrixRejectsUnknownCommandInScope() = runBlocking {
        val client = client(FakeExchange())
        val result = client.submit(
            HostCommandRequest(
                command = "memory.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = "test-2",
            ),
        )
        assertEquals(HostSubmitResult.Rejected("unknownCommandInScope"), result)
    }

    @Test
    fun matrixRejectsStatefulMismatchAndRevisionRules() = runBlocking {
        val client = client(FakeExchange())
        val noRevision = client.submit(
            HostCommandRequest(
                command = "config.provider.save",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = "test-3",
            ),
        )
        assertEquals(HostSubmitResult.Rejected("revisionRequired"), noRevision)
        val wrongStateful = client.submit(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = true,
                correlationID = "test-4",
            ),
        )
        assertEquals(HostSubmitResult.Rejected("statefulMismatch"), wrongStateful)
    }

    @Test
    fun foreignCorrelationReceiptIsMalformed() = runBlocking {
        val fake = FakeExchange { raw ->
            val ignored = HostCommandClientTest.FakeExchange.correlationOf(raw)
            """{"version":3,"ok":true,"queued":true,"correlationID":"foreign-$ignored","operationReceiptID":"op:v1:abc123"}"""
        }
        val client = client(fake)
        val result = client.submit(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = "test-5",
            ),
        )
        assertEquals(HostSubmitResult.Rejected("queueReceiptMalformed"), result)
        assertFalse(client.ownsCorrelation("test-5"))
    }


    @Test
    fun conversationAndExecutionScopesCarryCanonicalOwnerRoles() = runBlocking {
        val fake = FakeExchange()
        val client = client(fake)
        val lifecycle = client.submit(
            HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle("11111111-1111-4111-8111-111111111111"),
                stateful = false,
                correlationID = "test-owner-1",
            ),
        )
        assertTrue(lifecycle is HostSubmitResult.Accepted)
        val launch = client.submit(
            HostCommandRequest(
                command = "run.start",
                scope = HostScope.LaunchExisting("11111111-1111-4111-8111-111111111111"),
                stateful = true,
                correlationID = "test-owner-2",
                revision = HostRevision("conversation.11111111-1111-4111-8111-111111111111", "digest"),
            ),
        )
        assertTrue(launch is HostSubmitResult.Accepted)
        val execution = client.submit(
            HostCommandRequest(
                command = "run.cancel",
                scope = HostScope.TaskExecution(
                    taskID = "11111111-1111-4111-8111-111111111111",
                    runID = "22222222-2222-4222-8222-222222222222",
                    environmentID = "33333333-3333-4333-8333-333333333333",
                ),
                stateful = true,
                correlationID = "test-owner-3",
                revision = HostRevision("run.22222222-2222-4222-8222-222222222222", "digest"),
            ),
        )
        assertTrue(execution is HostSubmitResult.Accepted)
        val parsed = fake.requests.map { kotlinx.serialization.json.Json.parseToJsonElement(it) as JsonObject }
        val lifecycleEnvelope = (parsed[0]["envelope"] as JsonObject)
        assertEquals("conversationLifecycle", lifecycleEnvelope["scope"]?.let { (it as JsonPrimitive).content })
        assertEquals(
            setOf("taskID"),
            (lifecycleEnvelope["owner"] as JsonObject).keys,
        )
        val launchEnvelope = (parsed[1]["envelope"] as JsonObject)
        assertEquals("launch", launchEnvelope["scope"]?.let { (it as JsonPrimitive).content })
        assertEquals(
            "11111111-1111-4111-8111-111111111111",
            ((launchEnvelope["owner"] as JsonObject)["taskID"] as JsonPrimitive).content,
        )
        val executionEnvelope = (parsed[2]["envelope"] as JsonObject)
        assertEquals("taskExecution", executionEnvelope["scope"]?.let { (it as JsonPrimitive).content })
        val owner = executionEnvelope["owner"] as JsonObject
        assertEquals(
            "22222222-2222-4222-8222-222222222222",
            (owner["runID"] as JsonPrimitive).content,
        )
        assertEquals(
            "33333333-3333-4333-8333-333333333333",
            (owner["environmentID"] as JsonPrimitive).content,
        )
        // No inner document may carry the outer-only `version` member.
        assertTrue(parsed.all { !(it["envelope"] as JsonObject).containsKey("version") })
        assertTrue(parsed.all { it["operation"]?.let { op -> (op as JsonPrimitive).content } == "command.submit" })
    }

    @Test
    fun launchNewIdentityCarriesNoOwnerAndExplicitCreateIntent() = runBlocking {
        val fake = FakeExchange()
        val client = client(fake)
        val result = client.submit(
            HostCommandRequest(
                command = "conversation.create",
                scope = HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = "test-new-1",
                createIntent = true,
                payload = JsonObject(mapOf("title" to JsonPrimitive("wire qa"))),
            ),
        )
        assertTrue(result is HostSubmitResult.Accepted)
        val root = kotlinx.serialization.json.Json.parseToJsonElement(fake.requests.single()) as JsonObject
        val envelope = root["envelope"] as JsonObject
        assertEquals("launch", (envelope["scope"] as JsonPrimitive).content)
        assertFalse(envelope.containsKey("owner"))
        assertEquals(true, (envelope["createIntent"] as JsonPrimitive).content.toBoolean())
        assertFalse(envelope.containsKey("revision"))
    }

    @Test
    fun launchNewIdentityRequiresCreateIntent() = runBlocking {
        val client = client(FakeExchange())
        val result = client.submit(
            HostCommandRequest(
                command = "conversation.create",
                scope = HostScope.LaunchNewIdentity,
                stateful = true,
                correlationID = "test-6",
            ),
        )
        assertEquals(HostSubmitResult.Rejected("newIdentityRequiresCreateIntent"), result)
    }
}
