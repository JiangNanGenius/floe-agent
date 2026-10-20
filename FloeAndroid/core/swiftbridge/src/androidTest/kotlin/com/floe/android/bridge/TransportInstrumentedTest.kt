// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Installed-device proof for the G02-P3 incremental Android transport.
 *
 * Each test runs the REAL libFloeAndroidCore Swift code on Android
 * FoundationNetworking — the original OpenAI Chat Completions / OpenAI
 * Responses / Anthropic Messages adapters, the original SSEParser pipeline
 * and the original MCP Streamable-HTTP client — against an
 * instrumentation-owned synthetic loopback fixture. The two-way barrier
 * (server withholds its tail + EOF until the Swift CONSUMER performs a
 * separate GET) makes "first event before end-of-response" structural
 * rather than a timing margin; the same barrier cannot be opened by a
 * buffered client, and that negative control runs in this class too.
 *
 * Synthetic loopback HTTP only: this is NOT real cloud/TLS certificate or
 * hostname trust proof, NOT App/UI acceptance, and grants no permissions.
 * The test APK is debug/test-only; Main runs it on the assigned devices.
 */
@RunWith(AndroidJUnit4::class)
class TransportInstrumentedTest {
    private companion object {
        const val TAG = "FloeQualification"
    }

    private lateinit var fixture: TransportLoopbackFixture
    private var tagCounter = 0

    @Before
    fun setUp() {
        fixture = TransportLoopbackFixture()
        fixture.start()
    }

    @After
    fun tearDown() {
        fixture.close()
    }

    private fun baseUrl(): String = "http://127.0.0.1:${fixture.port}"

    private fun nextTag(prefix: String): String = "$prefix-${tagCounter++}"

    /**
     * Bounded OWNED test wait for a peer-side observation: after the Swift
     * call returns, the fixture thread still has to hit its next write and
     * record the IOException. Polling with a hard deadline (and FAILING when
     * never observed) makes the abort assertion deterministic without
     * sleeping-as-proof or weakening it.
     */
    private fun awaitAbort(path: String, timeoutMillis: Long = 4_000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (fixture.aborted(path)) return true
            Thread.sleep(10)
        }
        return fixture.aborted(path)
    }

    private fun assertAbortedBeforeCompletion(path: String) {
        assertTrue(
            "server must observe the owned-task abort (fixture: ${fixture.summary()})",
            awaitAbort(path),
        )
        assertFalse(
            "the scripted body must NOT have completed normally (fixture: ${fixture.summary()})",
            fixture.completedNormally(path),
        )
    }

    private fun smoke(
        scenario: String,
        tag: String,
        extra: JSONObject.() -> Unit = {},
    ): JSONObject {
        val spec = JSONObject()
            .put("base", baseUrl())
            .put("scenario", scenario)
            .put("tag", tag)
        spec.extra()
        val raw = QualificationNative.nativeTransportSmoke(spec.toString())
        val report = JSONObject(raw)
        Log.i(TAG, "transport-smoke $scenario: $raw")
        return report
    }

    // MARK: - wire events (exact original wire shapes)

    private fun chatEvent(text: String) =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"$text\"}}]}\n\n"

    private fun responsesEvent(text: String) =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"$text\"}\n\n"

    private fun anthropicEvent(text: String) =
        "data: {\"type\":\"content_block_delta\",\"index\":0," +
            "\"delta\":{\"type\":\"text_delta\",\"text\":\"$text\"}}\n\n"

    private val doneEvent = "data: [DONE]\n\n"

    /**
     * Scripted two-way barrier: the first event is written, then the fixture
     * BLOCKS (bounded 4 s owned test deadline) until the Swift consumer's
     * separate /open?tag= GET proves it parsed an event while the response
     * was still open. Only then are the tail event, terminal marker and EOF
     * written. A buffered client can never satisfy this.
     */
    private fun barrierScript(
        path: String,
        tag: String,
        firstEvent: String,
        secondEvent: String,
        terminal: String = doneEvent,
    ) {
        fixture.register(path) { exchange ->
            exchange.head(
                200,
                listOf("content-type" to "text/event-stream"),
                chunked = true,
            )
            exchange.chunk(firstEvent.toByteArray(Charsets.UTF_8))
            var opened = false
            val deadline = System.currentTimeMillis() + 4_000
            while (System.currentTimeMillis() < deadline) {
                if (fixture.opened(tag)) {
                    opened = true
                    break
                }
                exchange.sleep(10)
            }
            fixture.recordBarrier(tag, opened)
            if (exchange.clientGone) return@register
            exchange.chunk(secondEvent.toByteArray(Charsets.UTF_8))
            exchange.chunk(terminal.toByteArray(Charsets.UTF_8))
            exchange.finishChunked()
            fixture.markCompleted(path)
        }
    }

    // MARK: - original three-wire providers over real Android FoundationNetworking

    @Test
    fun providerChatStreamsFirstEventBeforeEOFThroughAndroidTransport() {
        val tag = nextTag("chat-barrier")
        barrierScript(
            "/wire-chat/chat/completions", tag,
            chatEvent("one"), chatEvent("two"),
        )
        val report = smoke("providerBarrier", tag) {
            put("wire", "chat")
            put("ephemeral", true)
        }
        assertTrue("chat barrier report: $report", report.getBoolean("ok"))
        assertEquals("onetwo", report.getString("text"))
        assertTrue(
            "first parsed event must precede end-of-response in monotonic time",
            report.getLong("firstEventUs") < report.getLong("endUs"),
        )
        assertEquals(
            "the fixture must have observed the client parsing event 1 before writing the tail",
            true, fixture.barrier(tag),
        )
        assertEquals(
            "the original adapter's bearer credential must reach the real request",
            "Bearer synthetic-local-fixture",
            fixture.headers("/wire-chat/chat/completions")?.get("authorization"),
        )
    }

    @Test
    fun providerResponsesAndAnthropicStreamBeforeEOF() {
        val responsesTag = nextTag("responses-barrier")
        barrierScript(
            "/wire-responses/responses", responsesTag,
            responsesEvent("one"), responsesEvent("two"),
        )
        val responsesReport = smoke("providerBarrier", responsesTag) {
            put("wire", "responses")
            put("ephemeral", false)
        }
        assertTrue("responses report: $responsesReport", responsesReport.getBoolean("ok"))
        assertEquals("onetwo", responsesReport.getString("text"))
        assertEquals(true, fixture.barrier(responsesTag))

        val anthropicTag = nextTag("anthropic-barrier")
        barrierScript(
            "/wire-anthropic/v1/messages", anthropicTag,
            anthropicEvent("one"), anthropicEvent("two"),
        )
        val anthropicReport = smoke("providerBarrier", anthropicTag) {
            put("wire", "anthropic")
            put("ephemeral", false)
        }
        assertTrue("anthropic report: $anthropicReport", anthropicReport.getBoolean("ok"))
        assertEquals("onetwo", anthropicReport.getString("text"))
        assertEquals(true, fixture.barrier(anthropicTag))
    }

    @Test
    fun cancellationStopsOwnedRequestAndSecondUnrelatedRequestSucceeds() {
        fixture.register("/chat-cancel/chat/completions") { exchange ->
            exchange.head(
                200, listOf("content-type" to "text/event-stream"), chunked = true,
            )
            repeat(200) {
                exchange.chunk(chatEvent("x").toByteArray(Charsets.UTF_8))
                if (exchange.clientGone) return@register
                exchange.sleep(20)
            }
            exchange.finishChunked()
            fixture.markCompleted("/chat-cancel/chat/completions")
        }
        fixture.register("/chat-second/chat/completions") { exchange ->
            exchange.head(
                200, listOf("content-type" to "text/event-stream"), chunked = true,
            )
            exchange.chunk(chatEvent("second-complete").toByteArray(Charsets.UTF_8))
            exchange.chunk(doneEvent.toByteArray(Charsets.UTF_8))
            exchange.finishChunked()
            fixture.markCompleted("/chat-second/chat/completions")
        }
        val report = smoke("providerCancel", nextTag("cancel"))
        assertTrue("cancel report: $report", report.getBoolean("ok"))
        assertTrue(report.getBoolean("sawFirstEvent"))
        assertEquals("second-complete", report.getString("secondText"))
        assertAbortedBeforeCompletion("/chat-cancel/chat/completions")
    }

    // MARK: - early cap, bounded pipeline, parser semantics

    @Test
    fun nonStreamCapCancelsTheOwnedRequestEarly() {
        fixture.register("/huge") { exchange ->
            exchange.head(
                200, listOf("content-type" to "application/json"), chunked = true,
            )
            repeat(40) {
                exchange.chunk(ByteArray(8_192) { 0x41 })
                if (exchange.clientGone) return@register
                exchange.sleep(10)
            }
            exchange.finishChunked()
            fixture.markCompleted("/huge")
        }
        val report = smoke("capEarly", nextTag("cap")) { put("cap", 16_384) }
        assertTrue("cap report: $report", report.getBoolean("ok"))
        assertEquals("responseTooLarge", report.getString("errorLabel"))
        assertAbortedBeforeCompletion("/huge")
    }

    @Test
    fun slowConsumerSaturatesWithExplicitRecoverableError() {
        fixture.register("/sse/flood") { exchange ->
            exchange.head(
                200, listOf("content-type" to "text/event-stream"), chunked = true,
            )
            repeat(64) { index ->
                val payload = "data: ev$index-" + "x".repeat(128) + "\n\n"
                exchange.chunk(payload.toByteArray(Charsets.UTF_8))
                if (exchange.clientGone) return@register
                exchange.sleep(10)
            }
            exchange.finishChunked()
            fixture.markCompleted("/sse/flood")
        }
        val report = smoke("saturation", nextTag("saturation"))
        assertTrue("saturation report: $report", report.getBoolean("ok"))
        assertEquals("pendingBufferSaturated", report.getString("errorLabel"))
        assertTrue(report.getInt("committedEvents") > 0)
        assertAbortedBeforeCompletion("/sse/flood")
    }

    @Test
    fun splitUnicodeBomCrlfStayExactThroughTheOriginalParser() {
        val emoji = "😀".toByteArray(Charsets.UTF_8)
        fixture.register("/sse/mixed") { exchange ->
            exchange.head(
                200, listOf("content-type" to "text/event-stream"), chunked = true,
            )
            exchange.chunk(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()))
            exchange.chunk("data: first\r\n\r\n".toByteArray(Charsets.UTF_8))
            exchange.chunk("data: ".toByteArray(Charsets.UTF_8) + emoji.copyOfRange(0, 2))
            exchange.sleep(25)
            exchange.chunk(emoji.copyOfRange(2, 4) + "tail\r".toByteArray(Charsets.UTF_8))
            exchange.sleep(25)
            exchange.chunk("\n\r\n".toByteArray(Charsets.UTF_8))
            exchange.chunk("data: end\r\n\r\n".toByteArray(Charsets.UTF_8))
            exchange.finishChunked()
            fixture.markCompleted("/sse/mixed")
        }
        val report = smoke("mixedUnicode", nextTag("unicode"))
        assertTrue("unicode report: $report", report.getBoolean("ok"))
        val events = report.getJSONArray("events")
        assertEquals(3, events.length())
        assertEquals("first", events.getString(0))
        assertEquals("😀tail", events.getString(1))
        assertEquals("end", events.getString(2))
    }

    // MARK: - MCP Streamable HTTP on the real Android transport

    @Test
    fun mcpHandshakeUsesRealAndroidDelegateSession() {
        fixture.register("/mcp") { exchange ->
            val request = JSONObject(exchange.body)
            val id = request.opt("id") ?: 1
            val result = JSONObject().put(
                "tools",
                JSONArray().put(
                    JSONObject()
                        .put("name", "fixture_echo")
                        .put("description", "Synthetic echo tool")
                        .put("inputSchema", JSONObject().put("type", "object")),
                ),
            )
            val body = JSONObject()
                .put("jsonrpc", "2.0")
                .put("id", id)
                .put("result", result)
                .toString().toByteArray(Charsets.UTF_8)
            exchange.headWithLength(200, listOf("content-type" to "application/json"), body.size)
            exchange.raw(body)
        }
        val report = smoke("mcpHandshake", nextTag("mcp"))
        assertTrue("mcp report: $report", report.getBoolean("ok"))
        val tools = report.getJSONArray("tools")
        assertEquals(1, tools.length())
        assertEquals("fixture_echo", tools.getString(0))
    }

    @Test
    fun mcpOversizeAndRedirectFailClosed() {
        fixture.register("/mcp/oversize") { exchange ->
            exchange.head(
                200, listOf("content-type" to "application/json"), chunked = true,
            )
            repeat(320) {
                exchange.chunk(ByteArray(8_192) { 0x7B })
                if (exchange.clientGone) return@register
                exchange.sleep(2)  // keep the abort mid-script, below any full-body completion
            }
            exchange.finishChunked()
            fixture.markCompleted("/mcp/oversize")
        }
        fixture.register("/mcp/redirect") { exchange ->
            exchange.headWithLength(
                302,
                listOf("location" to "${baseUrl()}/mcp/stealer"),
                0,
            )
        }
        fixture.register("/mcp/stealer") { exchange ->
            val body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}"
                .toByteArray(Charsets.UTF_8)
            exchange.headWithLength(200, listOf("content-type" to "application/json"), body.size)
            exchange.raw(body)
        }
        val oversize = smoke("mcpOversize", nextTag("mcp-oversize"))
        assertTrue("mcp oversize report: $oversize", oversize.getBoolean("ok"))
        assertEquals("responseTooLarge", oversize.getString("errorLabel"))
        assertAbortedBeforeCompletion("/mcp/oversize")

        val redirect = smoke("mcpRedirect", nextTag("mcp-redirect"))
        assertTrue("mcp redirect report: $redirect", redirect.getBoolean("ok"))
        val redirectLabel = redirect.optString("errorLabel")
        assertTrue(
            "a refused redirect must surface as a typed failure, got $redirect",
            redirectLabel == "httpError" || redirectLabel == "urlError" || redirectLabel == "mcpError",
        )
        if (redirectLabel == "httpError") {
            assertEquals(302, redirect.getInt("status"))
        }
        assertEquals(
            "the no-redirect policy must not forward the request (or its auth) anywhere",
            0, fixture.count("/mcp/stealer"),
        )
        assertNull(fixture.headers("/mcp/stealer"))
    }

    // MARK: - ownership, isolation, terminal-once

    @Test
    fun sessionOwnershipTemporaryIsolationAndPlainSessionFailClosed() {
        val report = smoke("sessionPolicy", nextTag("sessions"))
        assertTrue("session policy report: $report", report.getBoolean("ok"))
        assertTrue(report.getBoolean("defaultStreamable"))
        assertTrue(report.getBoolean("ephemeralStreamable"))
        assertTrue(report.getBoolean("ephemeralStorageZeroed"))
        assertTrue(report.getBoolean("plainSharedFailsClosed"))
    }

    @Test
    fun terminalCallbackRaceDeliversExactlyOnce() {
        fixture.register("/sse/race") { exchange ->
            exchange.head(
                200, listOf("content-type" to "text/event-stream"), chunked = true,
            )
            exchange.chunk("data: r1\n\n".toByteArray(Charsets.UTF_8))
            exchange.sleep(30)
            exchange.finishChunked()
            fixture.markCompleted("/sse/race")
        }
        val report = smoke("terminalRace", nextTag("race"))
        assertTrue("terminal race report: $report", report.getBoolean("ok"))
        assertEquals(1, report.getInt("terminalDeliveries"))
    }

    /**
     * Negative control on the SAME two-way barrier: a buffered client (plain
     * java.net.HttpURLConnection, the platform's own non-incremental reader)
     * cannot open the pre-EOF barrier because it has no event until the body
     * is complete. The fixture records barrier=false, proving the
     * incremental assertion above is not vacuous ON DEVICE as well.
     */
    @Test
    fun bufferedClientCannotOpenPreEOFBarrier() {
        val tag = nextTag("buffered")
        barrierScript(
            "/wire-buffered/chat/completions", tag,
            chatEvent("buffered-one"), chatEvent("buffered-two"),
        )
        val connection = URL("${baseUrl()}/wire-buffered/chat/completions")
            .openConnection() as HttpURLConnection
        connection.connectTimeout = 5_000
        connection.readTimeout = 15_000
        val body = try {
            connection.inputStream.readBytes().toString(Charsets.UTF_8)
        } finally {
            connection.disconnect()
        }
        assertTrue("buffered body must contain the scripted events", body.contains("buffered-one"))
        assertTrue("buffered body must contain the tail event", body.contains("buffered-two"))
        assertEquals(
            "a buffered reader must NOT have opened the pre-EOF barrier",
            false, fixture.barrier(tag),
        )
        assertEquals(1, fixture.count("/wire-buffered/chat/completions"))
    }
}
