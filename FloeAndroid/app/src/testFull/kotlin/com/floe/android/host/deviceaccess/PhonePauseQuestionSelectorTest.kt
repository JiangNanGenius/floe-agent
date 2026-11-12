// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class PhonePauseQuestionSelectorTest {
    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())
    private val pause = PhoneAutomationPause.Snapshot(owner, 100, UUID.randomUUID(), setOf("phone-call"))
    private fun wire(call: String = "phone-call", local: String = "phone-control-paused-${pause.id}",
        run: String = owner.runID.toString(), text: String = "Phone control is paused. Allow this task to continue?") = Json.parseToJsonElement("""
        {"schema":"floe.question.v1","requests":[{"requestID":"request-1","requestDigest":"${"a".repeat(64)}",
        "conversationID":"${owner.taskID}","runID":"$run","toolCallID":"$call","state":"waiting",
        "isEphemeral":false,"questions":[{"questionID":"request-1.native-qualified-id","localID":"$local",
        "text":"$text","status":"pending","revision":1,"answerNonce":"nonce-1","selectionMode":"single",
        "allowsFreeText":false,"waitPolicy":"required","options":[{"id":"allow","label":"Continue"},
        {"id":"keep-control","label":"Keep control"}]}]}]}
        """)

    @Test fun localLabelResolvesTheActualQualifiedNativeQuestion() {
        val question = PhonePauseQuestionSelector.select(wire(), pause).single()
        assertEquals("request-1.native-qualified-id", question.questionId)
        assertEquals("request-1", question.requestId)
        assertEquals("nonce-1", question.answerNonce)
    }

    @Test fun canonicalDevicePauseCopyStillResolvesTheQuestion() {
        // The current mailbox emits "Device control is paused..."; older
        // persisted questions use the exact legacy spelling. Both are
        // accepted, but only with the exact options/label shape.
        val question = PhonePauseQuestionSelector.select(
            wire(text = "Device control is paused. Allow this task to continue?"), pause).single()
        assertEquals("request-1.native-qualified-id", question.questionId)
    }

    @Test fun unrelatedModelQuestionOrOldPauseCannotBeAnswered() {
        assertTrue(PhonePauseQuestionSelector.select(wire(call = "model-ask"), pause).isEmpty())
        assertTrue(PhonePauseQuestionSelector.select(wire(local = "phone-control-paused-${UUID.randomUUID()}"), pause).isEmpty())
        assertTrue(PhonePauseQuestionSelector.select(wire(run = UUID.randomUUID().toString()), pause).isEmpty())
        assertTrue(PhonePauseQuestionSelector.select(wire(text = "Send a payment?"), pause).isEmpty())
    }
}
