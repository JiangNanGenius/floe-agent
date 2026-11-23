// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationSharedHistoryProjectionTest {
    @Test
    fun receivedToolResultsAreDisplayOnlyAndAttachmentKeepsItsExactMessageLink() {
        val reply = Json.parseToJsonElement("""
            {"rows":[{"id":"message","role":"assistant","content":"Read the document.",
            "attachments":[{"id":"part","attachmentId":"attachment","displayName":"demo.txt","kind":"file"}],
            "sharedToolResults":[{"name":"workspace.readFile","summary":"13 bytes","status":"ok"}],
            "sharedToolResultCount":2}]}
        """.trimIndent())
        val page = requireNotNull(ConversationWire.decodeMessagePage(reply, "conversation"))
        val row = page.rows.single()
        assertEquals("message", row.id)
        assertEquals("conversation", row.conversationId)
        assertNull(row.runId)
        assertEquals("attachment", row.attachmentChips.single().attachmentId)
        assertEquals("demo.txt", row.attachmentChips.single().name)
        assertEquals("workspace.readFile", row.sharedToolResults.single().name)
        assertEquals("13 bytes", row.sharedToolResults.single().summary)
        assertEquals("ok", row.sharedToolResults.single().status)
        assertEquals(2, row.sharedToolResultCount)
        val builder = ThreadProjectionBuilder("conversation")
        builder.applyMessagePage(page, earlier = false)
        val timeline = builder.build().rows.filterIsInstance<TimelineRowUi.AssistantMessage>().single()
        assertEquals("message", timeline.attachedMessageId)
        assertEquals(row.sharedToolResults, timeline.sharedToolResults)
        assertEquals(row.attachmentChips, timeline.attachmentChips)
    }

    @Test
    fun legacyRowsStillDecodeWithoutTheOptionalHistoryFields() {
        val reply = Json.parseToJsonElement("""{"rows":[{"id":"legacy","content":"Hello"}]}""")
        val row = requireNotNull(ConversationWire.decodeMessagePage(reply)).rows.single()
        assertEquals("Hello", row.text)
        assertTrue(row.attachmentChips.isEmpty())
        assertTrue(row.sharedToolResults.isEmpty())
    }
}
