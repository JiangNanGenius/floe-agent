// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Actual App-shaped consumer for the changed oversize-message path:
 * a producer `conversation.messagePage` row with `content:null` and an
 * owned `chunk:v1:` handle, then real `content.read` slice documents whose
 * chunks contain UTF-8 (Chinese + emoji) and are appended in order.
 *
 * The host's `fetchContentSlice` re-checks `ownCurrentEntry` before every
 * append (source-fenced), and the builder keys the append by the exact
 * message id: a late chunk for another holder or another message is a
 * no-op here, never a cross-session mutation.
 */
class ConversationContentHandleConsumerTest {
    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val otherConversationId = "55555555-5555-4555-8555-555555555555"
    private val messageId = "22222222-2222-4222-8222-222222222222"
    private val otherMessageId = "33333333-3333-4333-8333-333333333333"
    private val handle = "chunk:v1:0123456789abcdef0123456789abcdef"

    private fun pageJson(
        conversation: String,
        id: String,
        textIsHandle: Boolean,
    ): kotlinx.serialization.json.JsonObject =
        Json.parseToJsonElement(
            """{"rows":[{"id":"$id","role":"assistant",""" +
                """"createdAt":"2026-10-20T01:02:03.456Z","totalBytes":14,"partCount":1,""" +
                """"content":${if (textIsHandle) "null" else "\"\""},""" +
                """"contentHandle":"$handle","contentInlineComplete":false,"runID":null}],""" +
                """"hasEarlier":false,"earlierCursor":null}""",
        ).jsonObject

    private fun sliceJson(
        conversation: String,
        id: String,
        chunk: String,
        done: Boolean,
        nextOffset: Int?,
    ): kotlinx.serialization.json.JsonObject =
        Json.parseToJsonElement(
            """{"handle":"$handle","chunk":"$chunk","totalBytes":14,"done":$done,""" +
                """"nextOffset":${nextOffset ?: "null"},""" +
                """"conversationID":"$conversation","messageID":"$id","contentDigest":"d"}""",
        ).jsonObject

    @Test
    fun handlePageAndUtf8ChunksAppendExactlyInOrder() {
        val page = ConversationWire.decodeMessagePage(
            pageJson(conversationId, messageId, textIsHandle = true),
            conversationId,
        )
        assertNotNull(page)
        val handles = ConversationWire.contentHandles(
            pageJson(conversationId, messageId, textIsHandle = true),
        )
        assertEquals(listOf(messageId to handle), handles)
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applyMessagePage(page!!, earlier = false)

        val first = ConversationWire.decodeContentSlice(
            sliceJson(conversationId, messageId, "中文🙂", done = false, nextOffset = 10),
        )
        val second = ConversationWire.decodeContentSlice(
            sliceJson(conversationId, messageId, "tail", done = true, nextOffset = 14),
        )
        assertNotNull(first)
        assertNotNull(second)
        builder.appendMessageContent(messageId, first!!.chunk)
        builder.appendMessageContent(messageId, second!!.chunk)

        val assistant = builder.build().rows
            .filterIsInstance<TimelineRowUi.AssistantMessage>()
            .firstOrNull { it.attachedMessageId == messageId }
        assertNotNull(assistant)
        assertEquals("中文🙂tail", assistant!!.text)
    }

    @Test
    fun lateChunkCannotMutateAnotherHolderOrAnotherMessage() {
        val firstPage = ConversationWire.decodeMessagePage(
            pageJson(conversationId, messageId, textIsHandle = true),
            conversationId,
        )!!
        val otherPage = ConversationWire.decodeMessagePage(
            pageJson(otherConversationId, otherMessageId, textIsHandle = true),
            otherConversationId,
        )!!
        val first = ThreadProjectionBuilder(conversationId)
        val other = ThreadProjectionBuilder(otherConversationId)
        first.applyMessagePage(firstPage, earlier = false)
        other.applyMessagePage(otherPage, earlier = false)

        // The real first chunk lands on the owning holder only.
        first.appendMessageContent(messageId, "owned")
        // A late chunk for the OTHER holder's message id is a no-op here.
        first.appendMessageContent(otherMessageId, "leak")
        // A late chunk for a retired/different conversation is a no-op.
        other.appendMessageContent(messageId, "late")
        // The other holder only accepts its own message id.
        other.appendMessageContent(otherMessageId, "own")

        val firstAssistant = first.build().rows
            .filterIsInstance<TimelineRowUi.AssistantMessage>()
            .firstOrNull { it.attachedMessageId == messageId }
        val otherAssistant = other.build().rows
            .filterIsInstance<TimelineRowUi.AssistantMessage>()
            .firstOrNull { it.attachedMessageId == otherMessageId }
        assertNotNull(firstAssistant)
        assertNotNull(otherAssistant)
        assertEquals("owned", firstAssistant!!.text)
        assertEquals("own", otherAssistant!!.text)
    }
}
