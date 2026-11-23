// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingtranscription

import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import com.floe.android.host.voice.C03VoiceTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * The page decoder is the last boundary before a transcript can be committed.
 * Every malformed, dropped or truncated page must be a typed failure, never a
 * partial success.
 */
class MeetingTranscriptionBridgeParsingTest {
    private val meetingId = UUID.randomUUID().toString()
    private val materialId = UUID.randomUUID().toString()

    private fun backend(response: String): Pair<SwiftMeetingTranscriptionBackend, MutableList<String>> {
        val requests = mutableListOf<String>()
        val transport = C03VoiceTransport { request ->
            requests += request
            response
        }
        return SwiftMeetingTranscriptionBackend(
            transport = transport,
            ioDispatcher = Dispatchers.Unconfined,
        ) to requests
    }

    private fun parse(
        response: String,
        offset: Int = 0,
        limit: Int = 200,
    ): MeetingTranscriptionPage = runBlocking {
        val (backend, _) = backend(response)
        backend.page(meetingId, materialId, "operation-1", offset, limit)
    }

    private fun expectInvalid(
        response: String,
        reason: String,
        offset: Int = 0,
        limit: Int = 200,
    ) {
        val failure = assertThrows(C03VoiceFailure::class.java) {
            runBlocking {
                val (backend, _) = backend(response)
                backend.page(meetingId, materialId, "operation-1", offset, limit)
            }
        }
        assertEquals(C03VoiceErrorCode.INVALID_RESPONSE, failure.code)
        assertEquals(reason, failure.reason)
    }

    @Test
    fun `valid page keeps every segment and the reported total`() {
        val page = parse(
            """
            {"ok":true,"segments":[
              {"start":0.5,"end":1.5,"text":"  First   part  "},
              {"start":2.0,"end":3.0,"text":"Second"}
            ],"nextOffset":2,"total":7}
            """.trimIndent(),
        )
        assertEquals(7, page.total)
        assertEquals(2, page.segments.size)
        assertEquals("First part", page.segments[0].text)
        assertEquals(0.5, page.segments[0].start, 0.0)
        assertEquals("Second", page.segments[1].text)
    }

    @Test
    fun `terminal empty page at the reported total is valid`() {
        val page = parse(
            """{"ok":true,"segments":[],"nextOffset":0,"total":0}""",
        )
        assertTrue(page.segments.isEmpty())
        assertEquals(0, page.total)
    }

    @Test
    fun `missing or wrong-typed envelope fields are refused`() {
        expectInvalid("""{"ok":true,"total":1,"nextOffset":0}""", "missingSegments")
        expectInvalid("""{"ok":true,"segments":[],"nextOffset":0}""", "missingTotal")
        expectInvalid(
            """{"ok":true,"segments":[],"total":0}""",
            "missingNextOffset",
        )
        expectInvalid(
            """{"ok":true,"segments":[],"total":"0","nextOffset":0}""",
            "missingTotal",
        )
        expectInvalid(
            """{"ok":true,"segments":[],"total":0,"nextOffset":"0"}""",
            "missingNextOffset",
        )
        expectInvalid(
            """{"ok":true,"segments":[],"total":-1,"nextOffset":0}""",
            "invalidPageBounds",
        )
    }

    @Test
    fun `a malformed element never becomes a partial page`() {
        expectInvalid(
            """{"ok":true,"segments":[42],"total":1,"nextOffset":1}""",
            "invalidSegment",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"ok"},{"start":1.0,"end":2.0}],"total":2,"nextOffset":2}""",
            "invalidSegmentText",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"ok"},null],"total":2,"nextOffset":2}""",
            "invalidSegment",
        )
    }

    @Test
    fun `invalid timestamps and text are refused`() {
        expectInvalid(
            """{"ok":true,"segments":[{"start":"0.5","end":1.5,"text":"text"}],"total":1,"nextOffset":1}""",
            "invalidSegmentTiming",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"end":1.5,"text":"text"}],"total":1,"nextOffset":1}""",
            "invalidSegmentTiming",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":-0.1,"end":1.5,"text":"text"}],"total":1,"nextOffset":1}""",
            "invalidSegment",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":2.0,"end":2.0,"text":"text"}],"total":1,"nextOffset":1}""",
            "invalidSegment",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"   "}],"total":1,"nextOffset":1}""",
            "invalidSegment",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":7}],"total":1,"nextOffset":1}""",
            "invalidSegmentText",
        )
    }

    @Test
    fun `inconsistent cursor count and total are refused`() {
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"}],"total":1,"nextOffset":2}""",
            "invalidNextOffset",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"}],"total":1,"nextOffset":0}""",
            "invalidNextOffset",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"}],"total":5,"nextOffset":3}""",
            "invalidNextOffset",
            1,
            10,
        )
        expectInvalid(
            """{"ok":true,"segments":[],"total":4,"nextOffset":0}""",
            "invalidPageBounds",
            5,
            10,
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"},{"start":1.0,"end":2.0,"text":"two"}],"total":1,"nextOffset":2}""",
            "invalidNextOffset",
        )
        expectInvalid(
            """{"ok":true,"segments":[],"total":3,"nextOffset":0}""",
            "emptyPageBeforeTotal",
        )
        expectInvalid(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"},{"start":1.0,"end":2.0,"text":"two"}],"total":2,"nextOffset":2}""",
            "pageTooLarge",
            limit = 1,
        )
    }

    @Test
    fun `invalid request bounds are refused before the wire call`() {
        for (offset in listOf(-1)) {
            val (backend, requests) = backend(
                """{"ok":true,"segments":[],"total":4,"nextOffset":0}""",
            )
            val failure = assertThrows(C03VoiceFailure::class.java) {
                runBlocking { backend.page(meetingId, materialId, "operation-1", offset, 10) }
            }
            assertEquals(C03VoiceErrorCode.INVALID_SELECTION, failure.code)
            assertEquals("invalidPageBounds", failure.reason)
            assertTrue(requests.isEmpty())
        }
        for (limit in listOf(0, 201)) {
            val (backend, requests) = backend(
                """{"ok":true,"segments":[],"total":0,"nextOffset":0}""",
            )
            val failure = assertThrows(C03VoiceFailure::class.java) {
                runBlocking { backend.page(meetingId, materialId, "operation-1", 0, limit) }
            }
            assertEquals(C03VoiceErrorCode.INVALID_SELECTION, failure.code)
            assertEquals("invalidPageBounds", failure.reason)
            assertTrue(requests.isEmpty())
        }
    }

    @Test
    fun `request carries the exact offset and limit`() {
        val (backend, requests) = backend(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one"},{"start":1.0,"end":2.0,"text":"two"}],"total":5,"nextOffset":2}""",
        )
        val page = runBlocking {
            backend.page(meetingId, materialId, "operation-1", 0, 2)
        }
        assertEquals(5, page.total)
        assertEquals(2, page.segments.size)
        val request = requests.single()
        assertTrue(request.contains("\"offset\":0"))
        assertTrue(request.contains("\"limit\":2"))
    }

    @Test
    fun `speaker label is preserved when the provider supplies it`() {
        val page = parse(
            """
            {"ok":true,"segments":[
              {"start":0.5,"end":1.5,"text":"Hello","speaker":"Alice"},
              {"start":1.5,"end":2.5,"text":"Hi","speaker":"  Bob  "},
              {"start":2.5,"end":3.5,"text":"No speaker here"}
            ],"nextOffset":3,"total":3}
            """.trimIndent(),
        )
        assertEquals(3, page.segments.size)
        assertEquals("Alice", page.segments[0].speaker)
        assertEquals("Bob", page.segments[1].speaker)
        assertEquals(null, page.segments[2].speaker)
    }

    @Test
    fun `overlong speaker label is bounded and empty becomes absent`() {
        val longSpeaker = "s".repeat(200)
        val page = parse(
            """
            {"ok":true,"segments":[
              {"start":0.5,"end":1.5,"text":"Hello","speaker":"$longSpeaker"},
              {"start":1.5,"end":2.5,"text":"Hi","speaker":"   "}
            ],"nextOffset":2,"total":2}
            """.trimIndent(),
        )
        assertEquals(120, page.segments[0].speaker!!.length)
        assertEquals(null, page.segments[1].speaker)
    }

    @Test
    fun `malformed optional speaker label is dropped but the segment is kept`() {
        // Numeric / object / bool speaker labels come from providers that
        // half-diarize; the optional label must never cost the segment its
        // required timing and text, and must never be coerced into a string.
        val page = parse(
            """
            {"ok":true,"segments":[
              {"start":0.0,"end":1.0,"text":"one","speaker":7},
              {"start":1.0,"end":2.0,"text":"two","speaker":{"name":"A"}},
              {"start":2.0,"end":3.0,"text":"three","speaker":true},
              {"start":3.0,"end":4.0,"text":"four","speaker":"Ada"}
            ],"nextOffset":4,"total":4}
            """.trimIndent(),
        )
        assertEquals(4, page.segments.size)
        assertEquals(listOf("one", "two", "three", "four"), page.segments.map { it.text })
        assertEquals(null, page.segments[0].speaker)
        assertEquals(null, page.segments[1].speaker)
        assertEquals(null, page.segments[2].speaker)
        assertEquals("Ada", page.segments[3].speaker)
    }

    @Test
    fun `json null speaker is treated as not supplied`() {
        val page = parse(
            """{"ok":true,"segments":[{"start":0.0,"end":1.0,"text":"one","speaker":null}],"total":1,"nextOffset":1}""",
        )
        assertEquals(1, page.segments.size)
        assertEquals(null, page.segments[0].speaker)
    }
}
