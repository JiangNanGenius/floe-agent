// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TimelineRowUi
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationChronologyTest {
    private fun rows(vararg records: Triple<String, String, String>): List<String> {
        val data = records.joinToString(",") { (id, role, date) ->
            """{"id":"$id","role":"$role","content":"$id","createdAt":"$date"}"""
        }
        val page = ConversationWire.decodeMessagePage(Json.parseToJsonElement(
            """{"rows":[$data],"hasEarlier":false}"""), "conversation")!!
        val builder = ThreadProjectionBuilder("conversation")
        builder.applyMessagePage(page, earlier = false)
        return builder.build().rows.mapNotNull {
            when (it) {
                is TimelineRowUi.UserMessage -> it.message.id
                is TimelineRowUi.AssistantMessage -> it.attachedMessageId
                else -> null
            }
        }
    }

    @Test fun midnightFollowupStaysAfterPreviousDayMessages() {
        assertEquals(listOf("old-user", "old-answer", "new-user", "new-answer"), rows(
            Triple("old-user", "user", "2026-11-01T23:58:00.000Z"),
            Triple("old-answer", "assistant", "2026-11-01T23:59:00.000Z"),
            Triple("new-user", "user", "2026-11-02T00:01:00.000Z"),
            Triple("new-answer", "assistant", "2026-11-02T00:02:00.000Z")))
    }

    @Test fun sameMinuteTurnsKeepRealSecondsAndNativeIdentityTiebreak() {
        assertEquals(listOf("a", "b", "c"), rows(
            Triple("c", "assistant", "2026-11-02T12:00:02.001Z"),
            Triple("b", "user", "2026-11-02T12:00:01.000Z"),
            Triple("a", "assistant", "2026-11-02T12:00:01.000Z")))
    }

    @Test fun equivalentOffsetDatesCompareAsInstants() {
        assertEquals(listOf("early", "late"), rows(
            Triple("late", "user", "2026-11-02T12:00:01+01:00"),
            Triple("early", "assistant", "2026-11-02T11:00:00Z")))
    }
}
