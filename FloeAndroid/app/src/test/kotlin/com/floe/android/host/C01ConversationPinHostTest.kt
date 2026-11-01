// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * C01 conversation pin host projection (schema v50).
 *
 * Authored NOTRUN — source-authored only; Main runs the focused JVM filter.
 *
 * Pins travel through the EXISTING frozen `conversation.archive` metadata
 * envelope with a closed `{"pinned": Bool}` discriminator. This suite pins
 * the exact command/payload the host sends, the durable `pinned` flag read
 * from both the list page and the search page, and the fact that the native
 * pinned-first row ORDER is preserved rather than re-sorted in the UI.
 */
class C01ConversationPinHostTest {

    @Test
    fun pinMutationUsesTheExistingArchiveEnvelopeAndAClosedBooleanPayload() {
        assertEquals("conversation.archive", ConversationPinProjection.COMMAND)

        val pin = ConversationPinProjection.payload(true)
        assertEquals(setOf("pinned"), pin.keys)
        assertTrue(pin["pinned"]!!.jsonPrimitive.boolean)

        val unpin = ConversationPinProjection.payload(false)
        assertEquals(setOf("pinned"), unpin.keys)
        assertFalse(unpin["pinned"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun pinnedIdsCoverBothListAndSearchRowsAndIgnoreMalformedRows() {
        val listPage = Json.parseToJsonElement(
            """
            {"rows":[
              {"conversationID":"A","title":"pinned","pinned":true},
              {"conversationID":"B","title":"normal","pinned":false},
              {"conversationID":"C","title":"missing"},
              {"title":"no id","pinned":true}
            ],"nextCursor":null,"hasMore":false}
            """.trimIndent(),
        )
        assertEquals(setOf("A"), ConversationPinProjection.pinnedConversationIDs(listPage))

        val searchPage = Json.parseToJsonElement(
            """
            {"rows":[
              {"conversationID":"A","messageID":"m1","pinned":true},
              {"conversationID":"D","messageID":"m2","pinned":true}
            ],"truncatedTail":0}
            """.trimIndent(),
        )
        assertEquals(setOf("A", "D"), ConversationPinProjection.pinnedConversationIDs(searchPage))
        assertEquals(emptySet<String>(), ConversationPinProjection.pinnedConversationIDs(null))
        assertEquals(emptySet<String>(),
            ConversationPinProjection.pinnedConversationIDs(Json.parseToJsonElement("{}")))
    }

    @Test
    fun decodedRowsKeepTheNativePinnedFirstOrderAndCarryTheDurableFlag() {
        val page = Json.parseToJsonElement(
            """
            {"rows":[
              {"conversationID":"PINNED-OLD","title":"Pinned old","updatedAt":"2025-01-01T00:00:00.000Z","archived":false,"pinned":true},
              {"conversationID":"FRESH","title":"Fresh","updatedAt":"2025-02-01T00:00:00.000Z","archived":false,"pinned":false}
            ],"nextCursor":null,"hasMore":false}
            """.trimIndent(),
        )
        val decoded = ConversationWire.decodeConversationList(page)
        val rows = checkNotNull(decoded).active
        assertEquals(listOf("PINNED-OLD", "FRESH"), rows.map { it.id })

        val pinned = ConversationPinProjection.pinnedConversationIDs(page)
        val projected = rows.map { it.copy(isPinned = it.id in pinned) }
        assertTrue(projected.first().isPinned)
        assertFalse(projected.last().isPinned)
        assertEquals(listOf("PINNED-OLD", "FRESH"), projected.map { it.id })
    }

    @Test
    fun archivedRowsAreExcludedFromTheNormalListButStillCarryTheirPin() {
        val page = Json.parseToJsonElement(
            """
            {"rows":[
              {"conversationID":"PINNED-ARCHIVED","title":"Archived","updatedAt":"2025-01-01T00:00:00.000Z","archived":true,"pinned":true},
              {"conversationID":"ACTIVE","title":"Active","updatedAt":"2025-02-01T00:00:00.000Z","archived":false,"pinned":false}
            ],"nextCursor":null,"hasMore":false}
            """.trimIndent(),
        )
        val decoded = checkNotNull(ConversationWire.decodeConversationList(page))
        assertEquals(listOf("ACTIVE"), decoded.active.map { it.id })
        val pinned = ConversationPinProjection.pinnedConversationIDs(page)
        val archived = decoded.archived.map { it.copy(isPinned = it.id in pinned) }
        assertEquals(listOf("PINNED-ARCHIVED"), archived.map { it.id })
        assertTrue(archived.single().isPinned)
    }
}
