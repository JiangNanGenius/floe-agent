// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingassistant

import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Durable assistant history policy. The store must never touch the meeting
 * record, must keep meetings isolated and must preserve a corrupt file rather
 * than deleting it.
 */
class MeetingAssistantStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun store(clock: () -> Long = { 1_700_000_000_000L }): MeetingAssistantStore =
        MeetingAssistantStore.forTest(temporary.root, clock)

    @Test
    fun `a completed turn round-trips with its real identities`() {
        val store = store()
        val meetingId = UUID.randomUUID().toString()
        val conversationId = UUID.randomUUID().toString()
        val runId = UUID.randomUUID().toString()
        val entry = entry(
            meetingId = meetingId,
            conversationId = conversationId,
            runId = runId,
            status = MeetingAssistantEntryStatus.PENDING,
        )

        assertTrue(store.recordPending(meetingId, entry))
        assertTrue(
            store.complete(
                meetingId,
                entry.copy(
                    status = MeetingAssistantEntryStatus.ANSWERED,
                    answer = "The budget was approved.",
                    assistantMessageId = UUID.randomUUID().toString(),
                ),
            ),
        )

        val loaded = store.load(meetingId)
        assertEquals(conversationId, loaded.conversationId)
        assertEquals(1, loaded.entries.size)
        val saved = loaded.entries.single()
        assertEquals(MeetingAssistantEntryStatus.ANSWERED, saved.status)
        assertEquals("The budget was approved.", saved.answer)
        assertEquals(runId, saved.runId)
        assertNotNull(saved.assistantMessageId)
    }

    @Test
    fun `a late pending write cannot downgrade a settled entry`() {
        val store = store()
        val meetingId = UUID.randomUUID().toString()
        val entry = entry(meetingId = meetingId, status = MeetingAssistantEntryStatus.PENDING)

        assertTrue(store.recordPending(meetingId, entry))
        assertTrue(
            store.complete(
                meetingId,
                entry.copy(status = MeetingAssistantEntryStatus.ANSWERED, answer = "Done"),
            ),
        )
        assertTrue(store.recordPending(meetingId, entry))

        val saved = store.load(meetingId).entries.single()
        assertEquals(MeetingAssistantEntryStatus.ANSWERED, saved.status)
        assertEquals("Done", saved.answer)
    }

    @Test
    fun `meetings never share entries or bindings`() {
        val store = store()
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val firstEntry = entry(meetingId = first, status = MeetingAssistantEntryStatus.ANSWERED)
        val secondEntry = entry(meetingId = second, status = MeetingAssistantEntryStatus.ANSWERED)

        assertTrue(store.recordPending(first, firstEntry.copy(status = MeetingAssistantEntryStatus.PENDING)))
        assertTrue(store.complete(first, firstEntry))
        assertTrue(store.recordPending(second, secondEntry.copy(status = MeetingAssistantEntryStatus.PENDING)))
        assertTrue(store.complete(second, secondEntry))
        assertTrue(store.bindConversation(first, UUID.randomUUID().toString()))

        assertEquals(listOf(firstEntry.id), store.load(first).entries.map { it.id })
        assertEquals(listOf(secondEntry.id), store.load(second).entries.map { it.id })
        assertNotNull(store.conversationId(first))
        assertEquals(secondEntry.conversationId, store.conversationId(second))
    }

    @Test
    fun `an entry with another meeting prefix is refused`() {
        val store = store()
        val meetingId = UUID.randomUUID().toString()
        val foreign = entry(meetingId = UUID.randomUUID().toString())
        assertFalse(store.recordPending(meetingId, foreign))
        assertFalse(store.complete(meetingId, foreign))
        assertTrue(store.load(meetingId).entries.isEmpty())
    }

    @Test
    fun `a corrupt history file is preserved and reported`() {
        val store = store(clock = { 42L })
        val target = File(temporary.root, "meeting-assistant-history.json")
        target.writeText("{not-json", Charsets.UTF_8)
        val meetingId = UUID.randomUUID().toString()

        val loaded = store.load(meetingId)

        assertTrue(loaded.unreadable)
        assertTrue(loaded.entries.isEmpty())
        assertFalse(target.exists())
        assertTrue(File(temporary.root, "meeting-assistant-history.json.corrupt-42").exists())
    }

    @Test
    fun `an invalid meeting id never creates history`() {
        val store = store()
        assertTrue(store.load("not-a-meeting").entries.isEmpty())
        assertFalse(
            store.recordPending(
                "not-a-meeting",
                entry(meetingId = UUID.randomUUID().toString()),
            ),
        )
        assertFalse(File(temporary.root, "meeting-assistant-history.json").exists())
    }

    @Test
    fun `a very long answer is bounded and marked truncated`() {
        val store = store()
        val meetingId = UUID.randomUUID().toString()
        val entry = entry(
            meetingId = meetingId,
            status = MeetingAssistantEntryStatus.ANSWERED,
            answer = "A".repeat(30_000),
        )
        assertTrue(store.recordPending(meetingId, entry.copy(status = MeetingAssistantEntryStatus.PENDING)))
        assertTrue(store.complete(meetingId, entry))

        val saved = store.load(meetingId).entries.single()
        assertTrue(saved.answerTruncated)
        assertNotNull(saved.answer)
        assertTrue(saved.answer!!.toByteArray(Charsets.UTF_8).size <= 24_100)
        assertTrue(saved.answer!!.endsWith("[truncated]"))
    }

    @Test
    fun `clearing a conversation keeps the recorded answers`() {
        val store = store()
        val meetingId = UUID.randomUUID().toString()
        val conversationId = UUID.randomUUID().toString()
        val entry = entry(meetingId = meetingId, status = MeetingAssistantEntryStatus.ANSWERED)
        assertTrue(store.bindConversation(meetingId, conversationId))
        assertTrue(store.complete(meetingId, entry))

        assertTrue(store.clearConversation(meetingId))

        assertNull(store.conversationId(meetingId))
        assertEquals(1, store.load(meetingId).entries.size)
    }

    @Test
    fun `clearing one meeting keeps the other meeting history`() {
        val store = store()
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        assertTrue(store.complete(first, entry(meetingId = first, status = MeetingAssistantEntryStatus.ANSWERED)))
        assertTrue(store.complete(second, entry(meetingId = second, status = MeetingAssistantEntryStatus.ANSWERED)))

        assertTrue(store.clearMeeting(first))

        assertTrue(store.load(first).entries.isEmpty())
        assertEquals(1, store.load(second).entries.size)
    }

    @Test
    fun `assistant history never rewrites the meeting record`() {
        val store = store()
        val meetingRecord = File(temporary.root, "meeting.json")
        meetingRecord.writeText("{\"notes\":\"original\"}", Charsets.UTF_8)
        val meetingId = UUID.randomUUID().toString()

        assertTrue(store.complete(meetingId, entry(meetingId = meetingId, status = MeetingAssistantEntryStatus.ANSWERED)))

        assertEquals("{\"notes\":\"original\"}", meetingRecord.readText(Charsets.UTF_8))
    }

    private fun entry(
        meetingId: String,
        conversationId: String = UUID.randomUUID().toString(),
        runId: String = UUID.randomUUID().toString(),
        status: MeetingAssistantEntryStatus = MeetingAssistantEntryStatus.ANSWERED,
        answer: String? = if (status == MeetingAssistantEntryStatus.ANSWERED) "Answer" else null,
    ): MeetingAssistantEntry = MeetingAssistantEntry(
        id = newMeetingAssistantEntryId(meetingId),
        action = MeetingAssistantAction.ASK,
        question = "What happened?",
        status = status,
        answer = answer,
        createdAtMillis = 1_700_000_000_000L,
        notesRevision = 3L,
        transcriptRevision = 2L,
        conversationId = conversationId,
        runId = runId,
        failure = null,
        assistantMessageId = if (status == MeetingAssistantEntryStatus.ANSWERED) {
            UUID.randomUUID().toString()
        } else {
            null
        },
    )
}
