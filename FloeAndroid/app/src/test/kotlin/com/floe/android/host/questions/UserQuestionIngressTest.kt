// SPDX-License-Identifier: MPL-2.0
//
// App-side ingress regressions for the additive G07.3A interaction commands.
//
// The actual parked-question and in-thread-search features never reached the
// native handlers because `HostCommandValidator` consults the frozen Kotlin
// `BridgeV3CommandMatrix` BEFORE `SwiftCore.exchange`. That projection was
// still the pre-additive 90-tuple table, so every question/search command was
// rejected locally as `unknownCommandInScope` and only an invisible holder
// error remained. These tests pin the actual App command gate (not a wire
// decoder fixture) and the stateless envelope rule for answer/cancel.
package com.floe.android.host.questions

import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostCommandValidator
import com.floe.android.host.HostScope
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UserQuestionIngressTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"

    private fun request(command: String, stateful: Boolean) = HostCommandRequest(
        command = command,
        scope = HostScope.ConversationLifecycle(conversationId),
        stateful = stateful,
        correlationID = "ingress-$command",
        payload = if (command == "question.pending") null else JsonObject(emptyMap()),
    )

    /**
     * The five additive conversationLifecycle tuples must be admitted by the
     * SAME matrix the production submit path uses. This is the regression
     * that failed for the actual A19 parked question and thread search.
     */
    @Test
    fun additiveQuestionAndSearchCommandsAreAdmittedByAppMatrix() {
        for (command in listOf(
            "conversation.messageSearch",
            "conversation.messageWindow",
            "question.pending",
        )) {
            assertNull(
                "$command must pass the App bridge matrix before reaching Core",
                HostCommandValidator.validate(request(command, stateful = false)),
            )
        }
        for (command in listOf("question.answer", "question.cancel")) {
            assertNull(
                "$command must pass the App bridge matrix with the frozen " +
                    "stateless envelope",
                HostCommandValidator.validate(request(command, stateful = false)),
            )
        }
    }

    /**
     * `stateful` is the envelope revision flag. The frozen matrix declares
     * question.answer/question.cancel revisionRequired=false (identity/CAS
     * travel in the payload), so a true flag is a typed statefulMismatch and
     * can never reach the handler.
     */
    @Test
    fun answerAndCancelRejectTheRevisionStatefulFlag() {
        for (command in listOf("question.answer", "question.cancel")) {
            assertEquals(
                "$command must refuse a revision-stateful envelope",
                "statefulMismatch",
                HostCommandValidator.validate(request(command, stateful = true)),
            )
        }
    }
}
