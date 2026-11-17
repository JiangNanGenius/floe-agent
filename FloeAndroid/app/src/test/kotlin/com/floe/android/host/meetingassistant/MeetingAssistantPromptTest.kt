// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingassistant

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure prompt policy for the meeting assistant. These tests never read a
 * meeting store, start a run or call a provider.
 */
class MeetingAssistantPromptTest {
    private val meetingId = UUID.randomUUID().toString()

    @Test
    fun `no notes and no transcript never builds a goal`() {
        val detail = detail(notes = "", segments = emptyList())
        assertEquals(
            MeetingAssistantPromptResult.NoContext,
            MeetingAssistantPromptBuilder.build(detail, MeetingAssistantAction.ASK, "What?"),
        )
        assertEquals(
            MeetingAssistantPromptResult.NoContext,
            MeetingAssistantPromptBuilder.build(detail, MeetingAssistantAction.MINUTES, ""),
        )
    }

    @Test
    fun `ask needs a real question`() {
        val detail = detail(notes = "Budget approved")
        assertEquals(
            MeetingAssistantPromptResult.InvalidQuestion,
            MeetingAssistantPromptBuilder.build(detail, MeetingAssistantAction.ASK, "   "),
        )
        val tooLong = "x".repeat(MeetingAssistantPromptBuilder.MAX_QUESTION_BYTES + 1)
        assertEquals(
            MeetingAssistantPromptResult.InvalidQuestion,
            MeetingAssistantPromptBuilder.build(detail, MeetingAssistantAction.ASK, tooLong),
        )
    }

    @Test
    fun `ask prompt carries the current meeting evidence and both revisions`() {
        val detail = detail(
            notes = "Only this meeting's notes",
            segments = listOf(segment(1_000, "Alpha", "We agreed on the budget.")),
            notesRevision = 7,
            transcriptRevision = 4,
        )
        val built = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.ASK,
            "What did we agree?",
        ) as MeetingAssistantPromptResult.Built

        assertTrue(built.prompt.goal.contains("Only this meeting's notes"))
        assertTrue(built.prompt.goal.contains("We agreed on the budget."))
        assertTrue(built.prompt.goal.contains("What did we agree?"))
        assertTrue(built.prompt.goal.contains("Notes revision: 7"))
        assertTrue(built.prompt.goal.contains("Transcript revision: 4"))
        assertEquals(7L, built.prompt.notesRevision)
        assertEquals(4L, built.prompt.transcriptRevision)
        assertEquals(1, built.prompt.transcriptSegmentCount)
        assertFalse(built.prompt.notesTruncated)
        assertFalse(built.prompt.transcriptTruncated)
        assertTrue(built.prompt.goal.toByteArray(Charsets.UTF_8).size <=
            MeetingAssistantPromptBuilder.MAX_GOAL_BYTES)
    }

    @Test
    fun `minutes and to-dos do not require a question`() {
        val detail = detail(notes = "Decision: ship on Friday")
        val minutes = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.MINUTES,
            "",
        ) as MeetingAssistantPromptResult.Built
        val todos = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.TODOS,
            "",
        ) as MeetingAssistantPromptResult.Built
        assertTrue(minutes.prompt.goal.contains("Summary, Decisions"))
        assertTrue(todos.prompt.goal.contains("Extract action items"))
    }

    @Test
    fun `a long transcript keeps the newest segments and marks the omission`() {
        val segments = (0 until 400).map { index ->
            segment(
                startMillis = index * 1_000L,
                speaker = if (index % 2 == 0) "Alpha" else "Beta",
                text = "Transcript line $index with enough text to consume the budget.",
            )
        }
        val detail = detail(notes = "", segments = segments)
        val built = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.MINUTES,
            "",
        ) as MeetingAssistantPromptResult.Built

        assertTrue(built.prompt.transcriptTruncated)
        assertTrue(built.prompt.goal.contains("Transcript line 399"))
        assertFalse(built.prompt.goal.contains("Transcript line 0 with"))
        assertTrue(built.prompt.goal.contains("[earlier transcript omitted]"))
        assertTrue(built.prompt.goal.toByteArray(Charsets.UTF_8).size <=
            MeetingAssistantPromptBuilder.MAX_GOAL_BYTES)
    }

    @Test
    fun `long notes are bounded with an explicit marker`() {
        val detail = detail(notes = "N".repeat(20_000))
        val built = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.MINUTES,
            "",
        ) as MeetingAssistantPromptResult.Built

        assertTrue(built.prompt.notesTruncated)
        assertTrue(built.prompt.goal.contains("[notes truncated]"))
        assertTrue(built.prompt.goal.toByteArray(Charsets.UTF_8).size <=
            MeetingAssistantPromptBuilder.MAX_GOAL_BYTES)
    }

    @Test
    fun `the largest legal meeting still fits the native goal bound`() {
        val segments = (0 until 600).map { index ->
            segment(
                startMillis = index * 1_000L,
                speaker = "Speaker $index",
                text = "条".repeat(80) + " segment $index",
            )
        }
        val detail = detail(
            notes = "说明".repeat(4_000),
            segments = segments,
        )
        val built = MeetingAssistantPromptBuilder.build(
            detail,
            MeetingAssistantAction.ASK,
            "请总结".repeat(100),
        ) as MeetingAssistantPromptResult.Built
        assertTrue(built.prompt.goal.toByteArray(Charsets.UTF_8).size <=
            MeetingAssistantPromptBuilder.MAX_GOAL_BYTES)
    }

    @Test
    fun `conversation title is bounded and keeps the assistant prefix`() {
        val short = MeetingAssistantPromptBuilder.conversationTitle("Weekly sync")
        assertTrue(short.startsWith("Meeting assistant"))
        val long = MeetingAssistantPromptBuilder.conversationTitle("会".repeat(300))
        assertTrue(long.toByteArray(Charsets.UTF_8).size <=
            MeetingAssistantPromptBuilder.MAX_TITLE_BYTES)
        assertEquals("Meeting assistant", MeetingAssistantPromptBuilder.conversationTitle(""))
    }

    @Test
    fun `utf8 truncation never splits a code point`() {
        val text = "会议助手"
        val cut = boundedUtf8(text, 4)
        assertEquals("会", cut)
        assertEquals(3, cut.toByteArray(Charsets.UTF_8).size)
        assertEquals("", boundedUtf8(text, 0))
        assertEquals("", boundedUtf8(text, -1))
        assertEquals(text, boundedUtf8(text, 12))
    }

    @Test
    fun `a different meeting is never part of this goal`() {
        val first = detail(notes = "First meeting secret")
        val second = detail(notes = "Second meeting secret")
        val built = MeetingAssistantPromptBuilder.build(
            first,
            MeetingAssistantAction.ASK,
            "Summarize",
        ) as MeetingAssistantPromptResult.Built
        assertTrue(built.prompt.goal.contains("First meeting secret"))
        assertFalse(built.prompt.goal.contains("Second meeting secret"))
        assertFalse(built.prompt.goal.contains(second.id))
    }

    private fun detail(
        notes: String,
        segments: List<MeetingTranscriptSegment> = emptyList(),
        notesRevision: Long = 1L,
        transcriptRevision: Long = 1L,
    ): MeetingDetail = MeetingDetail(
        id = meetingId,
        title = "Weekly sync",
        createdAtMillis = 1_700_000_000_000L,
        updatedAtMillis = 1_700_000_100_000L,
        notes = notes,
        notesRevision = notesRevision,
        revision = 3L,
        transcription = MeetingTranscription(
            revision = transcriptRevision,
            materialId = if (segments.isEmpty()) null else UUID.randomUUID().toString(),
            segments = segments,
        ),
        materials = emptyList(),
        recordings = emptyList(),
        imports = emptyList(),
    )

    private fun segment(startMillis: Long, speaker: String, text: String) =
        MeetingTranscriptSegment(
            id = UUID.randomUUID().toString(),
            startMillis = startMillis,
            endMillis = startMillis + 1_000L,
            text = text,
            speaker = speaker,
        )
}
