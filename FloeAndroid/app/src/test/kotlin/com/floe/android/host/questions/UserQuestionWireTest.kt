// SPDX-License-Identifier: MPL-2.0
//
// Host wire decoding tests for the additive question/search carriers. They
// pin the exact identity fields the UI sends back (request digest, run id,
// revision, nonce) so a decoder change cannot silently drop a fence.
package com.floe.android.host.questions

import com.floe.android.feature.conversation.MessageRoleUi
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UserQuestionWireTest {

    private val digest = "a".repeat(64)

    @Test
    fun pendingDecodesExactQuestionGeneration() {
        val value = Json.parseToJsonElement(
            """
            {"schema":"floe.question.v1","conversationID":"11111111-1111-1111-1111-111111111111",
             "requests":[{"requestID":"uq_abc","requestDigest":"$digest",
             "conversationID":"11111111-1111-1111-1111-111111111111",
             "runID":"22222222-2222-2222-2222-222222222222","toolCallID":"call-1",
             "waitPolicy":"required","state":"awaitingAnswer","isEphemeral":false,
             "createdAt":"2026-10-30T10:00:00Z","updatedAt":"2026-10-30T10:00:00Z",
             "currentQuestionID":"uq_abc.q1",
             "questions":[{"questionID":"uq_abc.q1","ordinal":0,"localID":"q1",
             "text":"Proceed?","options":[{"id":"yes","label":"Yes","detail":"safe"}],
             "selectionMode":"single","allowsFreeText":false,"waitPolicy":"required",
             "status":"pending","revision":4,"answerNonce":"nonce-4",
             "createdAt":"2026-10-30T10:00:00Z","updatedAt":"2026-10-30T10:00:00Z",
             "deadlineAt":null,"fallback":null,"answer":null,"answerSource":null,
             "answeredAt":null}]}]}
            """.trimIndent(),
        )
        val snapshots = UserQuestionWire.decodePending(value)
        assertNotNull(snapshots)
        val snapshot = snapshots!!.single()
        assertEquals("uq_abc", snapshot.requestId)
        assertEquals(digest, snapshot.requestDigest)
        assertEquals("22222222-2222-2222-2222-222222222222", snapshot.runId)
        val question = snapshot.currentQuestion!!
        assertEquals("uq_abc.q1", question.questionId)
        assertEquals("22222222-2222-2222-2222-222222222222", question.runId)
        assertEquals(digest, question.requestDigest)
        assertEquals(4, question.revision)
        assertEquals("nonce-4", question.answerNonce)
        assertEquals("Yes", question.options.single().label)
        assertTrue(question.isPending)
    }

    @Test
    fun unknownSchemaIsRejectedNotTreatedAsEmpty() {
        val value = Json.parseToJsonElement("""{"schema":"other","requests":[]}""")
        assertNull(UserQuestionWire.decodePending(value))
    }

    @Test
    fun receiptPreservesAcceptedAndAlreadySettledTruth() {
        val value = Json.parseToJsonElement(
            """
            {"requestID":"uq_abc","questionID":"uq_abc.q1","status":"answered",
             "revision":5,"accepted":false,"alreadySettled":true,
             "requestState":"settled","answer":null}
            """.trimIndent(),
        )
        val receipt = UserQuestionWire.decodeReceipt(value)!!
        assertEquals("uq_abc.q1", receipt.questionId)
        assertEquals(5, receipt.revision)
        assertEquals(false, receipt.accepted)
        assertEquals(true, receipt.alreadySettled)
        assertTrue(receipt.settled)
    }

    @Test
    fun searchDecodesOnlyVisibleRowsAndKeepsTemporaryFlag() {
        val value = Json.parseToJsonElement(
            """
            {"schema":"floe.threadsearch.v1","conversationID":"c","query":"needle",
             "isTemporary":true,"hasMore":false,
             "rows":[{"messageID":"m1","role":"assistant","snippet":"a needle",
             "createdAt":"2026-10-30T10:00:00Z"},
             {"messageID":"m2","role":"user","snippet":"needle too",
             "createdAt":"2026-10-30T10:01:00Z"}]}
            """.trimIndent(),
        )
        val result = UserQuestionWire.decodeSearch(value)!!
        assertEquals(2, result.hits.size)
        assertEquals(MessageRoleUi.ASSISTANT, result.hits[0].role)
        assertEquals(MessageRoleUi.USER, result.hits[1].role)
        assertTrue(result.isTemporary)
        assertEquals(false, result.includesDurableHistory)
    }

    @Test
    fun freshDraftStartsWithNoSelection() {
        val draft = com.floe.android.feature.conversation.UserQuestionDraftUi(
            questionId = "uq_abc.q1")
        assertTrue(draft.selectedOptionIds.isEmpty())
        assertEquals("", draft.freeText.text)
    }
}
