// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationHistorySearchWireTest {
    @Test fun nativeMessageHitsCarryTheirActualSnippetAndConversationPin() {
        val reply = Json.parseToJsonElement("""{"rows":[
            {"conversationID":"c1","messageID":"m1","conversationTitle":"Report","snippet":"body needle","createdAt":"2026-11-08T00:00:00Z","pinned":true},
            {"conversationID":"c1","messageID":"m2","conversationTitle":"Report","snippet":"second needle","createdAt":"2026-11-08T00:00:01Z","pinned":true}
        ]}""")
        val rows = ConversationWire.decodeSearch(reply)
        assertEquals(1, rows.size)
        assertEquals("c1", rows.single().id)
        assertTrue(rows.single().isPinned)
        assertEquals(mapOf("c1" to "second needle"), ConversationWire.decodeSearchSnippets(reply))
    }

    @Test fun malformedHitsCannotInventASnippetForAnotherConversation() {
        val reply = Json.parseToJsonElement("""{"rows":[
            {"snippet":"no owner"},{"conversationID":"missingSnippet"},
            {"conversationID":"real","snippet":"actual preview"}
        ]}""")
        assertEquals(mapOf("real" to "actual preview"), ConversationWire.decodeSearchSnippets(reply))
    }
}
