// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class ConversationDetailAssemblerTest {
    private val body = "{\"id\":\"row\",\"objective\":\"原始😀\\\"目标\"}"
    private fun digest(text: String) = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun page(
        text: String = body, offset: Long = 0,
        total: Long = body.toByteArray().size.toLong(), id: String = "row",
        digest: String = digest(body), truncated: Boolean = offset + text.toByteArray().size < total,
        kind: String = "goal",
    ): ConversationWire.DetailPage {
        val wire = buildJsonObject {
            put("detail", buildJsonObject {
                put("kind", kind); put("id", id); put("status", "active"); put("revision", 2)
                put("digest", digest); put("encoding", "json-utf8")
                put("offset", offset); put("nextOffset", offset + text.toByteArray().size)
                put("totalBytes", total); put("truncated", truncated); put("content", text)
            })
        }
        return requireNotNull(ConversationWire.decodeDetailPage(wire))
    }

    @Test fun originalUnicodeChunksReconstructExactlyOnce() {
        val split = body.indexOf("😀") + 2 // Whole Unicode scalar in first fragment.
        val left = body.substring(0, split)
        val right = body.substring(split)
        val assembler = ConversationDetailAssembler("goal", 1_048_576)
        assertEquals(ConversationDetailAssembler.Result.Continue, assembler.accept(page(text = left)))
        val completed = assembler.accept(page(text = right, offset = left.toByteArray().size.toLong()))
        assertEquals(body, (completed as ConversationDetailAssembler.Result.Complete).content)
        assertTrue(assembler.accept(page()) is ConversationDetailAssembler.Result.Failed)
    }

    @Test fun changedIdentityDigestAndTotalNeverPublishMixedRows() {
        for (field in listOf("id", "digest", "total")) {
            val assembler = ConversationDetailAssembler("goal", 1_048_576)
            assertEquals(ConversationDetailAssembler.Result.Continue, assembler.accept(page(text = body.take(1))))
            val changed = page(
                text = body.drop(1), offset = 1,
                id = if (field == "id") "other" else "row",
                digest = if (field == "digest") "a".repeat(64) else digest(body),
                total = body.toByteArray().size.toLong() + if (field == "total") 1 else 0,
            )
            val result = assembler.accept(changed) as ConversationDetailAssembler.Result.Failed
            assertEquals(field, "detailIdentityMismatch", result.code)
        }
    }

    @Test fun zeroProgressAndReplayedOffsetsFailBeforeAnotherRequest() {
        val empty = ConversationDetailAssembler("goal", 1_048_576)
        assertEquals("detailBytesMismatch",
            (empty.accept(page(text = "")) as ConversationDetailAssembler.Result.Failed).code)
        val replay = ConversationDetailAssembler("goal", 1_048_576)
        replay.accept(page(text = body.take(1)))
        assertTrue(replay.accept(page(text = body.take(1))) is ConversationDetailAssembler.Result.Failed)
    }

    @Test fun falseEndMarkerAndCompleteDigestMismatchFailClosed() {
        val falseEnd = ConversationDetailAssembler("goal", 1_048_576)
        assertEquals("detailBytesMismatch",
            (falseEnd.accept(page(text = body.take(1), truncated = false)) as
                ConversationDetailAssembler.Result.Failed).code)
        val badDigest = ConversationDetailAssembler("goal", 1_048_576)
        assertEquals("detailDigestMismatch",
            (badDigest.accept(page(digest = "a".repeat(64))) as
                ConversationDetailAssembler.Result.Failed).code)
    }

    @Test fun existingRowSizeCeilingAndRequestedKindRemainEnforced() {
        val small = ConversationDetailAssembler("goal", 8)
        assertEquals("detailTooLarge", (small.accept(page()) as
            ConversationDetailAssembler.Result.Failed).code)
        val otherKind = ConversationDetailAssembler("plan", 1_048_576)
        assertEquals("detailKindMismatch", (otherKind.accept(page()) as
            ConversationDetailAssembler.Result.Failed).code)
    }

    @Test fun malformedDigestCannotBecomeAnAbsentDetail() {
        val value = Json.parseToJsonElement("""{"detail":{"kind":"goal","id":"row",
            "digest":"${"z".repeat(64)}","encoding":"json-utf8","offset":0,
            "nextOffset":2,"totalBytes":2,"truncated":false,"content":"{}"}}""")
        assertNull(ConversationWire.decodeDetailPage(value))
    }
}
