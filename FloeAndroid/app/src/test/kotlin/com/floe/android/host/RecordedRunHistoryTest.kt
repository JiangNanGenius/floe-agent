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
}
