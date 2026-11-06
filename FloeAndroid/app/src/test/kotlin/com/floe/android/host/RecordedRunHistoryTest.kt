// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class RecordedRunHistoryTest {
    private val task = "11111111-1111-4111-8111-111111111111"
    private val run = "ABCDEF12-3456-4789-ABCD-EF1234567890"
    private fun page(events: String, earlier: Boolean = false, first: Int = 1): JsonElement =
        Json.parseToJsonElement("""{"taskID":"$task","runID":"${run.lowercase()}","events":$events,"hasEarlier":$earlier,"firstSequence":$first}""")
    private fun event(sequence: Int, kind: String, payload: String): String =
        """{"sequence":$sequence,"kind":"$kind","payload":${JsonPrimitive(payload)}}"""
    private fun builder() = ThreadProjectionBuilder(task).apply {
        applySession(ConversationWire.SessionReply("Saved task", null,
            listOf(ConversationWire.RunSummary(run, "checkpointed", null, "")), emptyList(), null))
    }

    @Test fun coldReplayShowsAssistantAndReasoningWithoutRevivingStateOrApproval() {
        val events = listOf(
            event(1, "status", """{"state":"running"}"""),
            event(2, "assistantText", """{"text":"Recorded assistant"}"""),
            event(3, "reasoning", """{"text":"Recorded reasoning"}"""),
            event(4, "approval", """{"callID":"old","tool":"phone.click","scope":"phone","reason":"old"}"""),
        ).joinToString(",", "[", "]")
        val decoded = RecordedRunHistory.decode(page(events), task, run, null)!!
        val b = builder()
        b.applyRecordedEvents(run, decoded.frames, false)
        b.applyRecordedEvents(run, decoded.frames, false)
        val rows = b.build().rows
        assertEquals("checkpointed", b.runStateName(run))
        assertEquals(1, rows.filterIsInstance<TimelineRowUi.AssistantMessage>().count { it.text == "Recorded assistant" })
        assertEquals(1, rows.filterIsInstance<TimelineRowUi.StepGroup>().flatMap { it.events }.count { it.reasoningExcerpt == "Recorded reasoning" })
        assertTrue(b.build().pendingApprovals.isEmpty())
        assertEquals("checkpointed", b.runRevision(run)?.version)
    }

    @Test fun foreignDuplicateOutOfOrderAndNonAdvancingPagesAreRejected() {
        val one = event(1, "notice", """{"message":"one"}""")
        assertNull(RecordedRunHistory.decode(page("[$one,$one]"), task, run, null))
        assertNull(RecordedRunHistory.decode(page("[$one]"), "22222222-2222-4222-8222-222222222222", run, null))
        assertNull(RecordedRunHistory.decode(page("[$one]"), task, run, 1))
        assertNull(RecordedRunHistory.decode(page("[]", earlier = true), task, run, null))
    }

    @Test fun earlierPagesHaveARealCursorAndDoNotDuplicateOverlappingEvents() {
        val b = builder()
        val one = event(1, "notice", """{"message":"one"}""")
        val two = event(2, "notice", """{"message":"two"}""")
        val latest = RecordedRunHistory.decode(page("[$two]", true, 2), task, run, null)!!
        b.applyRecordedEvents(run, latest.frames, latest.hasEarlier)
        assertEquals(2, b.build().rows.filterIsInstance<TimelineRowUi.EarlierEvents>().single().firstLoadedSequence)
        val old = RecordedRunHistory.decode(page("[$one]"), task, run, 2)!!
        b.applyRecordedEvents(run, old.frames, old.hasEarlier, browsingEarlier = true)
        assertTrue(b.build().rows.none { it is TimelineRowUi.EarlierEvents })
        assertEquals(listOf("one", "two"), b.build().rows.filterIsInstance<TimelineRowUi.Event>().map { it.event.message })
    }

    private fun referenced(sequence: Int, bytes: ByteArray): JsonElement {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return page("""[{"sequence":$sequence,"kind":"assistantText","payload":null,
            "payloadReference":{"sequence":$sequence,"totalBytes":${bytes.size},"sha256":"$digest"}}]""",
            earlier = true, first = sequence)
    }

    private fun slice(ref: RecordedRunHistory.PayloadReference, offset: Int, bytes: ByteArray,
        taskID: String = task, next: Int? = (offset + bytes.size).takeIf { it < ref.totalBytes }): JsonElement =
        buildJsonObject {
            put("taskID", taskID); put("runID", run)
            put("payloadSlice", buildJsonObject {
                put("sequence", ref.sequence); put("kind", ref.kind); put("sha256", ref.sha256)
                put("totalBytes", ref.totalBytes); put("offset", offset)
                put("base64", java.util.Base64.getUrlEncoder().encodeToString(bytes))
                put("nextOffset", next?.let(::JsonPrimitive) ?: JsonNull)
            })
        }

    @Test fun oversizeJournalReassemblesAcrossUtf8BoundaryBeforeDisplayOnlyReplay() {
        val text = "x".repeat(32_758) + "🙂" + "存档".repeat(9_000)
        val raw = buildJsonObject { put("text", text) }.toString().toByteArray(Charsets.UTF_8)
        val decoded = RecordedRunHistory.decode(referenced(7, raw), task, run, null)!!
        assertTrue(decoded.frames.isEmpty())
        val ref = decoded.payloadReference!!
        val output = java.io.ByteArrayOutputStream()
        var offset = 0
        while (offset < raw.size) {
            val part = raw.copyOfRange(offset, minOf(raw.size, offset + 32_768))
            val chunk = RecordedRunHistory.decodeSlice(slice(ref, offset, part), task, run, ref, offset)!!
            output.write(chunk.bytes)
            offset = chunk.nextOffset ?: raw.size
        }
        val frame = RecordedRunHistory.materialize(run, ref, output.toByteArray())!!
        val b = builder(); b.applyRecordedEvents(run, listOf(frame), decoded.hasEarlier)
        assertEquals(text, b.build().rows.filterIsInstance<TimelineRowUi.AssistantMessage>().single().text)
        assertEquals(7, b.build().rows.filterIsInstance<TimelineRowUi.EarlierEvents>().single().firstLoadedSequence)
        assertEquals("checkpointed", b.runStateName(run))
        assertTrue(b.build().pendingApprovals.isEmpty())
    }

    @Test fun payloadSlicesRejectForeignOwnerBadProgressCorruptionAndOversizeReference() {
        val raw = """{"text":"saved"}""".toByteArray()
        val ref = RecordedRunHistory.decode(referenced(3, raw), task, run, null)!!.payloadReference!!
        assertNull(RecordedRunHistory.decodeSlice(slice(ref, 0, raw,
            taskID = "22222222-2222-4222-8222-222222222222"), task, run, ref, 0))
        assertNull(RecordedRunHistory.decodeSlice(slice(ref, 0, raw, next = 0), task, run, ref, 0))
        assertNull(RecordedRunHistory.decodeSlice(slice(ref, 0, raw), task, run, ref, 1))
        assertNull(RecordedRunHistory.materialize(run, ref, raw.copyOf().apply { this[10] = 120 }))
        val over = referenced(3, raw).jsonObject
        val row = over["events"]!!.jsonArray.single().jsonObject
        val large = JsonObject(over + ("events" to JsonArray(listOf(JsonObject(row +
            ("payloadReference" to JsonObject(row["payloadReference"]!!.jsonObject +
                ("totalBytes" to JsonPrimitive(RecordedRunHistory.maximumPayloadBytes + 1)))))))))
        assertNull(RecordedRunHistory.decode(large, task, run, null))
    }

    @Test fun severalLargeEventsStayBoundedAndEvictedOlderContentRemainsPageable() {
        fun frame(sequence: Long, label: String): HostRunEventFrame {
            val payload = buildJsonObject { put("text", label + "x".repeat(2_200_000)) }
            return HostRunEventFrame(run, sequence, "assistantText", payload, payload.toString().toByteArray().size)
        }
        val first = frame(1, "older"); val second = frame(2, "newer")
        val b = builder()
        b.applyRecordedEvents(run, listOf(first), false)
        b.applyRecordedEvents(run, listOf(second), false)
        assertTrue(b.build().rows.filterIsInstance<TimelineRowUi.AssistantMessage>().single().text.startsWith("newer"))
        assertEquals(2, b.build().rows.filterIsInstance<TimelineRowUi.EarlierEvents>().single().firstLoadedSequence)
        b.applyRecordedEvents(run, listOf(first), false, browsingEarlier = true)
        assertTrue(b.build().rows.filterIsInstance<TimelineRowUi.AssistantMessage>().single().text.startsWith("older"))
        assertTrue(b.build().rows.none { it is TimelineRowUi.EarlierEvents })
        assertEquals("checkpointed", b.runStateName(run))
    }
}
