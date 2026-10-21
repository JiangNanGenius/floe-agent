// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import java.security.MessageDigest
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/**
 * DEFERRED App tests for the reusable full-row model reader
 * (job-7d4d4e41017f4391). AUTHORED ONLY: NOT compiled, NOT executed by
 * this task — Main batches these with the goal/Root coherent cohort.
 *
 * The scripted exchange implements the native chunk PROTOCOL faithfully
 * (id/digest/offset/next/total/text over the exact row bytes with a
 * SHA-256 read digest), so these tests exercise the REAL command client +
 * REAL RuntimeHost operation lifecycle through ModelPageReadController —
 * no native/device/network.
 */
class ModelPageReadControllerTest {

    private class ChunkedExchange(
        val rowBytes: ByteArray,
        val rowID: String,
        private val chunkSize: Int = 18_000,
        private val totalOverride: Long? = null,
        private val digestOverride: String? = null,
        private val repeatFirstChunk: Boolean = false,
        private val dropMarkerAfterFirstChunk: Boolean = false,
        private val firstRowCursor: String = "0",
        private val finalNextCursor: String? = "1",
        private val finalHasMore: Boolean = true,
    ) : HostBridgeExchange {
        val payloads = java.util.concurrent.CopyOnWriteArrayList<JsonObject>()
        private val pages = java.util.concurrent.ConcurrentHashMap<String, String>()
        private var sequence = 0
        var onFirstPageServed: (() -> Unit)? = null

        /** The read digest over the ACTUAL served row bytes. */
        val rowDigest: String = sha256Hex(rowBytes)

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val page = pages.getValue(receipt)
                return """{"version":3,"requestID":"$correlation","ok":true,""" +
                    """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                    """"cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                    """"effects":[{"sequence":1,"kind":"accepted","page":$page}],""" +
                    """"hasMore":false,"resyncRequired":false}"""
            }
            val envelope = Json.parseToJsonElement(request).jsonObject["envelope"]!!.jsonObject
            val command = envelope["command"]!!.jsonPrimitive.content
            check(command == "config.models.list") { "reader uses the same command" }
            val payload = (envelope["payload"] as? JsonObject) ?: JsonObject(emptyMap())
            payloads.add(payload)
            val modelRead = payload["modelRead"]?.jsonObject
                ?: error("the reader must opt in with the closed modelRead member")
            val offset: Long = if (modelRead.isEmpty()) {
                0L
            } else {
                assertEquals(setOf("id", "digest", "offset"), modelRead.keys)
                assertEquals(rowID, modelRead.stringOrNull("id"))
                assertEquals(digestOverride ?: rowDigest, modelRead.stringOrNull("digest"))
                val claimed = modelRead.stringOrNull("offset")!!.toLong()
                if (repeatFirstChunk) 0L else claimed
            }
            val start = offset.toInt()
            val end = minOf(start + chunkSize, rowBytes.size)
            val text = String(rowBytes.copyOfRange(start, end), Charsets.UTF_8)
            val advancing = end == rowBytes.size
            val marker = buildJsonObject {
                put("modelChunk", buildJsonObject {
                    put("id", rowID)
                    put("digest", digestOverride ?: rowDigest)
                    put("offset", start.toString())
                    put("next", if (advancing) null else end.toString())
                    put("total", (totalOverride ?: rowBytes.size.toLong()).toString())
                    put("text", text)
                })
            }
            val page = buildJsonObject {
                put("rows", if (dropMarkerAfterFirstChunk && start > 0) JsonArray(emptyList())
                    else JsonArray(listOf(marker)))
                if (advancing) {
                    // Final chunk: the row cursor advances only now.
                    finalNextCursor?.let { put("nextCursor", it) }
                    put("hasMore", finalHasMore)
                } else {
                    put("nextCursor", firstRowCursor)
                    put("hasMore", true)
                }
            }.toString()
            val receipt = "op:v1:chunked${++sequence}"
            pages[receipt] = page
            if (start == 0 && payloads.size == 1) onFirstPageServed?.invoke()
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"$receipt"}"""
        }
    }

    /** Plain (non-oversized) page exchange for the pass-through cases. */
    private class PlainExchange(private val pageJson: String) : HostBridgeExchange {
        var dispatched = 0
        private val pages = java.util.concurrent.ConcurrentHashMap<String, String>()
        private var sequence = 0
        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                return """{"version":3,"requestID":"$correlation","ok":true,""" +
                    """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                    """"cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                    """"effects":[{"sequence":1,"kind":"accepted","page":${pages.getValue(receipt)}}],""" +
                    """"hasMore":false,"resyncRequired":false}"""
            }
            dispatched++
            val receipt = "op:v1:plain${++sequence}"
            pages[receipt] = pageJson
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"$receipt"}"""
        }
    }

    private companion object {
        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
    }

    private suspend fun withHost(exchange: HostBridgeExchange, block: suspend (RuntimeHost) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        // Bootstrap legitimately reads provider/preferences too. They are
        // outside this model-reader fixture and receive typed refusals.
        val selectedExchange = object : HostBridgeExchange {
          override fun exchange(request: String): String {
            val root = Json.parseToJsonElement(request).jsonObject
            val envelope = root["envelope"] as? JsonObject
            return if (root["operation"]?.jsonPrimitive?.content != "effect.poll" &&
                envelope != null && envelope["command"]?.jsonPrimitive?.content != "config.models.list") {
                buildJsonObject {
                    put("version", 3); put("ok", false)
                    put("correlationID", correlationOf(request)); put("error", "fixture_not_selected")
                }.toString()
            } else exchange.exchange(request)
          }
        }
        val client = RuntimeHostCommandClient(
            exchange = selectedExchange, scope = scope, ioDispatcher = Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1))
        val host = RuntimeHost(
            commandClient = client,
            gatewayCapability = MutableStateFlow(SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(RuntimeBootstrapCapability.Idle),
            scope = scope, ioDispatcher = Dispatchers.Default)
        try {
            host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
            block(host)
        } finally {
            host.stop()
            scope.cancel()
        }
    }

    private val provider = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val denseID = "22222222-2222-2222-2222-222222222222"

    /** A LEGAL dense original row above the 49_152 page-item budget with
     *  the native revision member present (the exact page shape). */
    private fun denseBytes(providerId: String = provider, withRevision: Boolean = true,
                           paddingChar: Char = 'x'): ByteArray {
        val padding = paddingChar.toString().repeat(56_000)
        val revision = if (withRevision)
            ""","revision":{"resourceID":"model.$denseID","version":"${"ab".repeat(32)}"}"""
        else ""
        return ("""{"capabilities":3,"displayName":"$padding","id":"$denseID",""" +
            """"isEnabled":true,"limits":{"contextTokens":4096,"maxOutputTokens":1024},""" +
            """"providerID":"$providerId","remoteModelID":"dense-row"$revision}""")
            .toByteArray(Charsets.UTF_8)
    }

    private suspend fun readOnce(
        host: RuntimeHost,
        exchange: ChunkedExchange,
        providerFilter: String = provider,
        isCurrent: () -> Boolean = { true },
    ): HostOperationOutcome = withTimeout(10_000) {
        var captured: HostOperationOutcome? = null
        ModelPageReadController(host)
            .readPage(providerID = providerFilter, cursor = null,
                      correlationTag = "testmlist", isCurrent = isCurrent) { captured = it }
        while (captured == null) { delay(5) }
        captured!!
    }

    @Test fun hostHelperKeepsIndependentConsumerReadsAlive() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(), denseID)
        withHost(exchange) { host ->
            val first = CompletableDeferred<HostOperationOutcome>()
            val second = CompletableDeferred<HostOperationOutcome>()
            // Start a second consumer while the first request is being
            // served, before its first terminal callback can settle.
            exchange.onFirstPageServed = {
                host.readModelPage(provider, null, "independent-b") { second.complete(it) }
            }
            host.readModelPage(provider, null, "independent-a") { first.complete(it) }
            val outcomes = withTimeout(10_000) { listOf(first.await(), second.await()) }
            outcomes.forEach { assertTrue(it is HostOperationOutcome.Completed) }
            val pages = outcomes.map { (it as HostOperationOutcome.Completed).value }
            assertEquals(pages[0], pages[1])
            assertTrue(exchange.payloads.count { it["modelRead"]?.jsonObject?.isEmpty() == true } == 2)
        }
    }

    @Test fun ordinaryPageCannotReplaceAnIncompleteChunkedRow() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(), denseID, dropMarkerAfterFirstChunk = true)
        withHost(exchange) { host ->
            val outcome = readOnce(host, exchange)
            assertTrue(outcome is HostOperationOutcome.Failed)
            assertEquals("model_read_sequence", (outcome as HostOperationOutcome.Failed).code)
            assertEquals(2, exchange.payloads.size)
        }
    }

    @Test fun reconstructsTheFullOversizedRowAndDeliversALogicalPage() = runBlocking {
        val bytes = denseBytes()
        val exchange = ChunkedExchange(bytes, denseID)
        withHost(exchange) { host ->
            val outcome = readOnce(host, exchange)
            val completed = outcome as HostOperationOutcome.Completed
            val page = completed.value as JsonObject
            val rows = page["rows"] as JsonArray
            assertEquals(1, rows.size)
            val row = rows[0].jsonObject
            assertNull(row["modelChunk"])
            // The FULL original row equals the source (digest-checked
            // inside the reader; content + fidelity here).
            assertEquals(denseID, row.stringOrNull("id"))
            assertEquals(provider, row.stringOrNull("providerID"))
            assertEquals("dense-row", row.stringOrNull("remoteModelID"))
            assertEquals(56_000, row.stringOrNull("displayName")?.length)
            val revision = row["revision"] as? JsonObject
            assertNotNull(revision)
            assertEquals("model.$denseID", revision!!.stringOrNull("resourceID"))
            // Original numeric page metadata preserved and truthful.
            assertEquals("1", page.stringOrNull("nextCursor"))
            assertEquals(true, (page["hasMore"] as JsonPrimitive).booleanOrNull)
            // begin + continuations on the SAME command/filter; the row
            // index cursor rode the continuation requests.
            assertEquals((bytes.size + 17_999) / 18_000, exchange.payloads.size)
            assertEquals(setOf("providerID", "modelRead"), exchange.payloads[0].keys)
            assertEquals(JsonObject(emptyMap()), exchange.payloads[0]["modelRead"])
            assertEquals(provider, exchange.payloads[1].stringOrNull("providerID"))
            assertEquals("0", exchange.payloads[1].stringOrNull("cursor"))
            assertEquals(setOf("id", "digest", "offset"),
                exchange.payloads[1]["modelRead"]!!.jsonObject.keys)
            assertEquals(exchange.rowDigest,
                exchange.payloads[1]["modelRead"]!!.jsonObject.stringOrNull("digest"))
        }
    }

    @Test fun normalPagesPassThroughTheRealValueUnchanged() = runBlocking {
        val pageJson = """{"rows":[{"id":"row-1","providerID":"$provider",""" +
            """"remoteModelID":"m","displayName":"D","capabilities":1,"isEnabled":true,""" +
            """"revision":{"resourceID":"model.row-1","version":"v"}}],"nextCursor":"4","hasMore":true}"""
        val exchange = PlainExchange(pageJson)
        withHost(exchange) { host ->
            val outcome = withTimeout(10_000) {
                var captured: HostOperationOutcome? = null
                ModelPageReadController(host)
                    .readPage(providerID = provider, cursor = null,
                              correlationTag = "testmlist", isCurrent = { true }) { captured = it }
                while (captured == null) { delay(5) }
                captured!!
            }
            val completed = outcome as HostOperationOutcome.Completed
            // The reader hands the consumer the ORIGINAL page document and
            // dispatches exactly ONE command (no continuation chain).
            assertEquals("4", completed.value!!.jsonObject.stringOrNull("nextCursor"))
            assertEquals(true,
                (completed.value!!.jsonObject["hasMore"] as JsonPrimitive).booleanOrNull)
            assertEquals("row-1",
                (completed.value!!.jsonObject["rows"] as JsonArray)[0]
                    .jsonObject.stringOrNull("id"))
            assertEquals(1, exchange.dispatched)
        }
    }

    @Test fun digestMismatchRefusesWithoutPublication() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(), denseID,
                                       digestOverride = "0".repeat(64))
        withHost(exchange) { host ->
            val failed = readOnce(host, exchange) as HostOperationOutcome.Failed
            assertEquals("model_read_digest_mismatch", failed.code)
        }
    }

    @Test fun replayedOffsetRefusesAsSequence() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(), denseID, repeatFirstChunk = true)
        withHost(exchange) { host ->
            val failed = readOnce(host, exchange) as HostOperationOutcome.Failed
            assertEquals("model_read_sequence", failed.code)
        }
    }

    @Test fun wrongTotalRefusesAtEofWithoutPublishing() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(), denseID,
                                       totalOverride = denseBytes().size + 7L)
        withHost(exchange) { host ->
            assertTrue(readOnce(host, exchange) is HostOperationOutcome.Failed)
        }
    }

    @Test fun missingRevisionRefusesTheReconstructedRow() = runBlocking {
        val exchange = ChunkedExchange(denseBytes(withRevision = false), denseID)
        withHost(exchange) { host ->
            val failed = readOnce(host, exchange) as HostOperationOutcome.Failed
            assertEquals("model_read_row_revision", failed.code)
        }
    }

    @Test fun foreignProviderRowRefusesReconstruction() = runBlocking {
        val foreign = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        val exchange = ChunkedExchange(denseBytes(providerId = foreign), denseID)
        withHost(exchange) { host ->
            // The digest matches the served bytes, but the reconstructed
            // row's provider member is foreign to the filter: typed
            // refusal, never a published row.
            val failed = readOnce(host, exchange) as HostOperationOutcome.Failed
            assertEquals("model_read_row_provider", failed.code)
        }
    }

    @Test fun nonAdvancingFinalCursorRefusesTheLogicalPage() = runBlocking {
        // The EOF chunk claims hasMore=true while its row cursor did NOT
        // advance past the reconstructed row: sequence lie → refusal.
        val exchange = ChunkedExchange(denseBytes(), denseID,
                                       finalNextCursor = "0", finalHasMore = true)
        withHost(exchange) { host ->
            val failed = readOnce(host, exchange) as HostOperationOutcome.Failed
            assertEquals("model_read_page_meta", failed.code)
        }
    }

    @Test fun cancellationStopsBeforeAnyContinuationDispatch() = runBlocking {
        var current = true
        val exchange = ChunkedExchange(denseBytes(), denseID)
        exchange.onFirstPageServed = { current = false }
        withHost(exchange) { host ->
            val outcome = withTimeout(10_000) {
                var captured: HostOperationOutcome? = null
                ModelPageReadController(host)
                    .readPage(providerID = provider, cursor = null,
                              correlationTag = "testmlist",
                              isCurrent = { current }) { captured = it }
                while (captured == null) { delay(5) }
                captured!!
            }
            assertTrue("stale terminal after cancel",
                outcome is HostOperationOutcome.Superseded)
            assertEquals("no continuation dispatched after cancel", 1, exchange.payloads.size)
        }
    }

    @Test fun restartFencesTheOldCallAndKeepsOnePartialPerReader() = runBlocking {
        val bytes = denseBytes()
        val exchange = ChunkedExchange(bytes, denseID)
        withHost(exchange) { host ->
            val reader = ModelPageReadController(host)
            var oldCaptured: HostOperationOutcome? = null
            var newCaptured: HostOperationOutcome? = null
            var oldCurrent = true
            reader.readPage(providerID = provider, cursor = null,
                            correlationTag = "testmlist-a",
                            isCurrent = { oldCurrent }) { oldCaptured = it }
            withTimeout(10_000) { while (exchange.payloads.isEmpty()) delay(5) }
            // RESTART while the old call holds a bounded partial row: the
            // old call is retired and its partial bytes destroyed; only
            // the new call may publish.
            oldCurrent = false
            reader.readPage(providerID = provider, cursor = null,
                            correlationTag = "testmlist-b",
                            isCurrent = { true }) { newCaptured = it }
            withTimeout(10_000) {
                while (oldCaptured == null || newCaptured == null) { delay(5) }
            }
            assertTrue(oldCaptured is HostOperationOutcome.Superseded ||
                oldCaptured is HostOperationOutcome.Failed)
            assertTrue(newCaptured is HostOperationOutcome.Completed)
            // No cross-publication: exactly one Completed page reached a
            // consumer for this row.
            assertEquals(1, listOf(oldCaptured, newCaptured)
                .count { it is HostOperationOutcome.Completed })
        }
    }

    @Test fun malformedMarkerRowFailsClosedNeverSkipped() = runBlocking {
        // A rows document carrying a marker WITHOUT its text member is a
        // protocol lie (a silently skipped saved row would otherwise
        // follow): typed failure, no partial publish, no continuation.
        val pageJson = """{"rows":[{"modelChunk":{"id":"$denseID",""" +
            """"digest":"${"0".repeat(64)}","offset":"0","next":"100","total":"200"}}],""" +
            """"nextCursor":"0","hasMore":true}"""
        val exchange = PlainExchange(pageJson)
        withHost(exchange) { host ->
            val failed = withTimeout(10_000) {
                var captured: HostOperationOutcome? = null
                ModelPageReadController(host)
                    .readPage(providerID = provider, cursor = null,
                              correlationTag = "testmlist", isCurrent = { true }) { captured = it }
                while (captured == null) { delay(5) }
                captured!!
            } as HostOperationOutcome.Failed
            assertEquals("model_read_marker_shape", failed.code)
            assertEquals(1, exchange.dispatched)
        }
    }

    @Test fun oversizedPageConsumerStillSeesOnlyCompleteRowsThroughDecode() {
        // ProviderWire-level fidelity guard: a page that STILL carries an
        // unprocessed marker never decodes into a silently-short row set.
        val pageJson = """{"rows":[{"modelChunk":{"id":"x","digest":"y",""" +
            """"offset":"0","next":"1","total":"2","text":"{}"}}]}"""
        val value = Json.parseToJsonElement(pageJson)
        assertNull(ProviderWire.decodeModelRows(value))
        val clean = Json.parseToJsonElement(
            """{"rows":[{"id":"00000000-0000-0000-0000-000000000001","providerID":"$provider",""" +
                """"remoteModelID":"m","displayName":"D","capabilities":1,"isEnabled":true}]}""")
        assertNotNull(ProviderWire.decodeModelRows(clean))
    }
}
