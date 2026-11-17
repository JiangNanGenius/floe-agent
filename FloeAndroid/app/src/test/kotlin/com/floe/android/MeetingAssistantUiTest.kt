// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import com.floe.android.host.meetingassistant.MeetingAssistantAction
import com.floe.android.host.meetingassistant.MeetingAssistantAvailability
import com.floe.android.host.meetingassistant.MeetingAssistantFailureCode
import com.floe.android.host.meetingassistant.MeetingAssistantTurnPhase
import com.floe.android.host.meetingassistant.MeetingAssistantTurnView
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure page policy for the meeting assistant section. No Compose runtime, no
 * provider, no run and no device are involved.
 */
class MeetingAssistantUiTest {
    private val ready = MeetingAssistantAvailability.Ready(
        modelId = UUID.randomUUID().toString(),
        modelLabel = "Text model · Provider",
        models = emptyList(),
    )

    @Test
    fun `a turn starts only when the route and meeting content are real`() {
        assertTrue(meetingAssistantCanSend(ready, active = null, contextReady = true))
        assertFalse(meetingAssistantCanSend(ready, active = null, contextReady = false))
        assertFalse(
            meetingAssistantCanSend(
                ready,
                active = MeetingAssistantTurnView(
                    MeetingAssistantAction.ASK,
                    MeetingAssistantTurnPhase.RUNNING,
                ),
                contextReady = true,
            ),
        )
        assertFalse(
            meetingAssistantCanSend(
                MeetingAssistantAvailability.Checking,
                active = null,
                contextReady = true,
            ),
        )
        assertFalse(
            meetingAssistantCanSend(
                MeetingAssistantAvailability.NotConfigured(
                    MeetingAssistantFailureCode.NO_TEXT_MODEL,
                ),
                active = null,
                contextReady = true,
            ),
        )
    }

    @Test
    fun `notes are never overwritten while the editor is dirty, conflicted or saving`() {
        assertTrue(meetingAssistantCanInsertNotes(false, false, false))
        assertFalse(meetingAssistantCanInsertNotes(true, false, false))
        assertFalse(meetingAssistantCanInsertNotes(false, true, false))
        assertFalse(meetingAssistantCanInsertNotes(false, false, true))
    }

    @Test
    fun `append keeps existing notes and adds one clean block`() {
        assertEquals(
            "AI minutes\nSummary",
            meetingAssistantAppendText("", "AI minutes", "Summary"),
        )
        assertEquals(
            "Existing notes\n\nAI minutes\nSummary",
            meetingAssistantAppendText("Existing notes\n\n", "AI minutes", "Summary"),
        )
        assertEquals(
            "Summary",
            meetingAssistantAppendText("", "", "  Summary  "),
        )
        assertEquals(
            "Existing",
            meetingAssistantAppendText("Existing", "Heading", "   "),
        )
    }

    @Test
    fun `every failure code maps to distinct visible copy`() {
        val resources = MeetingAssistantFailureCode.entries.map {
            meetingAssistantFailureResource(it)
        }
        resources.forEach { assertNotEquals(0, it) }
        assertEquals(MeetingAssistantFailureCode.entries.size, resources.toSet().size)
    }

    @Test
    fun `every action has a visible kind label`() {
        MeetingAssistantAction.entries.forEach {
            assertNotEquals(0, meetingAssistantKindResource(it))
        }
        assertNotEquals(
            meetingAssistantKindResource(MeetingAssistantAction.MINUTES),
            meetingAssistantKindResource(MeetingAssistantAction.TODOS),
        )
    }

    @Test
    fun `context readiness reads the persisted notes or transcript only`() {
        assertTrue(meetingAssistantContextReady(detail(notes = "Notes", transcript = null)))
        assertTrue(meetingAssistantContextReady(detail(notes = "", transcript = "Transcript")))
        assertFalse(meetingAssistantContextReady(detail(notes = "  ", transcript = "  ")))
        assertFalse(meetingAssistantContextReady(detail(notes = "", transcript = null)))
    }

    private fun detail(notes: String, transcript: String?): MeetingDetail = MeetingDetail(
        id = UUID.randomUUID().toString(),
        title = "Sync",
        createdAtMillis = 1_700_000_000_000L,
        updatedAtMillis = 1_700_000_100_000L,
        notes = notes,
        notesRevision = 1L,
        revision = 1L,
        transcription = MeetingTranscription(
            revision = 1L,
            segments = transcript?.let {
                listOf(
                    MeetingTranscriptSegment(
                        id = UUID.randomUUID().toString(),
                        startMillis = 0L,
                        endMillis = 1_000L,
                        text = it,
                        speaker = null,
                    ),
                )
            } ?: emptyList(),
        ),
        materials = emptyList(),
        recordings = emptyList(),
        imports = emptyList(),
    )
}
