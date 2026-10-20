// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.MessagePageCursorUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Native message-page keyset cursor codec (`ConversationCursorCodec`):
 * `k1.` + base64url(JSON `{"createdAt","id"}`). The App must send the opaque
 * string back, not the authored `{createdAt,id}` object the frozen validator
 * refuses.
 */
class ConversationWireCursorTest {

    private val createdAt = "2026-10-19T22:08:16.917Z"
    private val messageId = "DA11F2B1-652C-4F05-AFD6-1401E68A3943"

    @Test
    fun decodesNativeOpaqueCursorIntoRealIdentity() {
        val document = """{"createdAt":"$createdAt","id":"$messageId"}"""
        val encoded = java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString(document.toByteArray(Charsets.UTF_8))
        val cursor = ConversationWire.decodeOpaqueMessageCursor("k1.$encoded")
        assertEquals(createdAt, cursor?.createdAtLabel)
        assertEquals(messageId, cursor?.messageId)
    }

    @Test
    fun reencodesTheExactIdentityAsAK1Cursor() {
        val cursor = MessagePageCursorUi(createdAtLabel = createdAt, messageId = messageId)
        val encoded = ConversationWire.encodeOpaqueMessageCursor(cursor)
        assertTrue("expected a k1. cursor, got $encoded", encoded!!.startsWith("k1."))
        val roundTrip = ConversationWire.decodeOpaqueMessageCursor(encoded)
        assertEquals(createdAt, roundTrip?.createdAtLabel)
        assertEquals(messageId, roundTrip?.messageId)
        // The native decoder requires exactly these two JSON keys.
        val payload = String(
            java.util.Base64.getUrlDecoder().decode(encoded.removePrefix("k1.")),
            Charsets.UTF_8,
        )
        assertTrue(payload.contains("\"createdAt\":\"$createdAt\""))
        assertTrue(payload.contains("\"id\":\"$messageId\""))
    }

    @Test
    fun malformedOrForeignCursorsAreAbsenceNotAGuess() {
        assertNull(ConversationWire.decodeOpaqueMessageCursor("k2.abcd"))
        assertNull(ConversationWire.decodeOpaqueMessageCursor("k1.!!!"))
        assertNull(ConversationWire.decodeOpaqueMessageCursor(
            "k1." + java.util.Base64.getUrlEncoder().withoutPadding()
                .encodeToString("""{"createdAt":"$createdAt","id":"not-a-uuid"}""".toByteArray()),
        ))
        assertNull(ConversationWire.encodeOpaqueMessageCursor(
            MessagePageCursorUi(createdAtLabel = "", messageId = messageId)))
    }
}
