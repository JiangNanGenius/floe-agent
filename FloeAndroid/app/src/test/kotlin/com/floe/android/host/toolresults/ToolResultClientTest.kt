// SPDX-License-Identifier: MPL-2.0
//
// C02 client tests. The fake transport returns canned `floe.results/20` JSON;
// no native bridge, file or tool execution is invoked.
package com.floe.android.host.toolresults

import com.floe.android.feature.toolresults.ToolResultDetailException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ToolResultClientTest {
    private val json = Json { ignoreUnknownKeys = true }

    private class Recorder(
        private val responder: (String) -> String,
    ) : ToolResultTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests += request
            return responder(request)
        }
    }

    private fun pageReply(
        text: String = "abc中文",
        offset: Int = 0,
        end: Int = text.toByteArray(Charsets.UTF_8).size,
        next: Int? = null,
        total: Int = end,
        sha: String = "a".repeat(64),
    ): String {
        val nextField = next?.let { "\"nextOffset\":$it," } ?: ""
        return """
        {"ok":true,"schema":"floe.results/20","ref":"tr_${"b".repeat(24)}",
         "runID":"11111111-1111-1111-1111-111111111111",
         "callID":"call-1","toolName":"exec.shell","status":"ok",
         "offset":$offset,"endOffset":$end,"totalBytes":$total,$nextField
         "text":"$text","sha256":"$sha","executionReportedTruncation":false,
         "retentionTruncated":false,"durability":"durable","restoredFromDisk":false,
         "evictedCopies":0,"capturedAt":"2026-11-02T00:00:00Z"}
        """.trimIndent()
    }

    @Test
    fun pageSendsClosedWireAndUsesActualNextOffset() {
        val recorder = Recorder { pageReply(next = 9, total = 12) }
        val client = ToolResultClient(recorder)
        val page = client.page(
            taskId = "22222222-2222-2222-2222-222222222222",
            runId = "11111111-1111-1111-1111-111111111111",
            callId = "call-1",
            ref = null,
            offset = 0,
            maxBytes = 9,
            expectedSHA256 = "a".repeat(64),
        )
        assertEquals("abc中文", page.text)
        assertEquals(0, page.offset)
        assertEquals(9, page.endOffset)
        assertEquals(9, page.nextOffset)
        assertEquals(12, page.totalBytes)
        assertEquals("durable", page.durability)
        assertFalse(page.isLastPage)

        val request = json.parseToJsonElement(recorder.requests.single()).jsonObject
        assertEquals(20, request["version"]!!.jsonPrimitive.content.toInt())
        assertEquals("floe.results/20", request["schema"]!!.jsonPrimitive.content)
        assertEquals("c02.results.page", request["operation"]!!.jsonPrimitive.content)
        assertEquals("22222222-2222-2222-2222-222222222222", request["taskID"]!!.jsonPrimitive.content)
        assertEquals("11111111-1111-1111-1111-111111111111", request["runID"]!!.jsonPrimitive.content)
        assertEquals("call-1", request["callID"]!!.jsonPrimitive.content)
        assertEquals(0, request["offset"]!!.jsonPrimitive.content.toInt())
        assertEquals(9, request["length"]!!.jsonPrimitive.content.toInt())
        assertEquals("a".repeat(64), request["expectedSHA256"]!!.jsonPrimitive.content)
        assertTrue(request["exactRun"]!!.jsonPrimitive.content.toBoolean())
        assertFalse(recorder.requests.single().contains("/data/"))
        assertFalse(recorder.requests.single().contains("Bearer"))
    }

    @Test
    fun declaredWindowMustMatchDeliveredBytes() {
        val recorder = Recorder { pageReply(text = "😀", end = 7) }
        try {
            ToolResultClient(recorder).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "call-1",
                ref = null,
                offset = 0,
                maxBytes = 12_000,
            )
            fail("malformed window accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("malformedResponse", expected.code)
        }
    }

    @Test
    fun nextOffsetMustEqualEndOffset() {
        val recorder = Recorder { pageReply(text = "abc", end = 3, next = 9, total = 9) }
        try {
            ToolResultClient(recorder).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "call-1",
                ref = null,
                offset = 0,
            )
            fail("cursor skip accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("malformedResponse", expected.code)
        }
    }

    @Test
    fun temporaryReadsAreRefusedBeforeAnyTransportCall() {
        val recorder = Recorder { error("transport must not be called") }
        try {
            ToolResultClient(recorder).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "call-1",
                ref = null,
                offset = 0,
                temporary = true,
            )
            fail("temporary read accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("temporaryTaskRefused", expected.code)
        }
        assertTrue(recorder.requests.isEmpty())
    }

    @Test
    fun missingAndChangedStayTypedForTheUi() {
        val missing = Recorder {
            """{"ok":false,"schema":"floe.results/20","code":"missing","message":"not retained","retryable":false}"""
        }
        try {
            ToolResultClient(missing).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "gone", ref = null, offset = 0,
            )
            fail("missing accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("missing", expected.code)
            assertFalse(expected.retryable)
        }

        val changed = Recorder {
            """{"ok":false,"schema":"floe.results/20","code":"changed","message":"changed","retryable":true}"""
        }
        try {
            ToolResultClient(changed).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "c", ref = null, offset = 0,
            )
            fail("changed accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("changed", expected.code)
            assertTrue(expected.retryable)
        }
    }

    @Test
    fun indexAndSearchParseOnlyClosedFields() {
        val index = Recorder {
            """
            {"ok":true,"schema":"floe.results/20","evicted":1,"rows":[
              {"ref":"tr_${"c".repeat(24)}","runID":"11111111-1111-1111-1111-111111111111",
               "callID":"c1","toolName":"exec.shell","totalBytes":42,
               "executionReportedTruncation":true,"retentionTruncated":false,
               "capturedAt":"2026-11-02T00:00:00Z","durability":"durable",
               "sha256":"${"d".repeat(64)}"}]}
            """.trimIndent()
        }
        val client = ToolResultClient(index)
        val rows = client.index("22222222-2222-2222-2222-222222222222")
        assertEquals(1, rows.evicted)
        assertEquals("c1", rows.rows.single().callId)
        assertTrue(rows.rows.single().executionReportedTruncation)

        val search = Recorder {
            """
            {"ok":true,"schema":"floe.results/20","searchedCaptures":1,"searchedBytes":20,
             "truncated":false,"hits":[{"ref":"tr_${"e".repeat(24)}",
             "runID":"11111111-1111-1111-1111-111111111111","callID":"c1",
             "toolName":"exec.shell","totalBytes":20,"matchOffset":6,
             "excerpt":"alpha needle omega","hasAdditionalMatches":false,
             "sha256":"${"f".repeat(64)}"}]}
            """.trimIndent()
        }
        val hits = ToolResultClient(search).search(
            "22222222-2222-2222-2222-222222222222", "needle")
        assertEquals(6, hits.hits.single().matchOffset)
        assertEquals(20, hits.searchedBytes)
        assertFalse(hits.truncated)
    }

    @Test
    fun malformedEnvelopeFailsClosedWithoutInventingAPage() {
        val recorder = Recorder { "<html>not json</html>" }
        try {
            ToolResultClient(recorder).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "c", ref = null, offset = 0,
            )
            fail("malformed envelope accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("malformedResponse", expected.code)
        }
        try {
            ToolResultClient(recorder).page(
                taskId = "22222222-2222-2222-2222-222222222222",
                callId = "c", ref = "not-a-ref", offset = 0,
            )
            fail("invalid ref accepted")
        } catch (expected: ToolResultDetailException) {
            assertEquals("invalidRequest:invalidRef", expected.code)
        }
    }
}
