// SPDX-License-Identifier: MPL-2.0
//
// Focused pure-JVM tests for durable question presentation/state.
//
// Native once-only/CAS settlement is tested by the Swift store tests in the
// private shared patch. These tests prove the App never invents a settlement:
// it dispatches at most one answer per in-flight request, keeps the selected
// draft across unchanged snapshots, clears only on the native receipt/absent
// snapshot, and refuses submission without a complete answer.
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationUserQuestionTest {

    private val session = ConversationSessionToken("conv-1", 0L)

    private fun question(
        id: String = "q1",
        options: List<UserQuestionOptionUi> = listOf(
            UserQuestionOptionUi("yes", "Yes"),
            UserQuestionOptionUi("no", "No"),
        ),
        mode: UserQuestionSelectionModeUi = UserQuestionSelectionModeUi.SINGLE,
        allowsFreeText: Boolean = false,
        status: UserQuestionStatusUi = UserQuestionStatusUi.PENDING,
        revision: Int = 3,
    ) = UserQuestionPromptUi(
        questionId = "uq_$id.$id",
        requestId = "uq_$id",
        runId = "run-1",
        text = "Proceed?",
        options = options,
        selectionMode = mode,
        allowsFreeText = allowsFreeText,
        waitPolicy = UserQuestionWaitPolicyUi.REQUIRED,
        deadlineLabel = null,
        status = status,
        revision = revision,
        answerNonce = "nonce-$revision",
        requestDigest = "a".repeat(64),
    )

    private fun snapshot(vararg questions: UserQuestionPromptUi) = UserQuestionSnapshotUi(
        requestId = questions.first().requestId,
        requestDigest = questions.first().requestDigest,
        conversationId = "conv-1",
        runId = "run-1",
        stateRaw = "awaitingAnswer",
        isEphemeral = false,
        questions = questions.toList(),
        currentQuestionId = questions.firstOrNull { it.isPending }?.questionId,
    )

    @Test
    fun snapshotOpensSheetAndPreservesDraftAcrossSameQuestion() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        val q = question()
        holder.applyUserQuestionSnapshot(session, snapshot(q))
        assertTrue(holder.showingUserQuestion)
        holder.selectUserQuestionOption("yes")
        assertEquals(setOf("yes"), holder.userQuestionDraft?.selectedOptionIds)

        holder.applyUserQuestionSnapshot(session, snapshot(q.copy(revision = 3)))
        assertEquals(setOf("yes"), holder.userQuestionDraft?.selectedOptionIds)
    }

    @Test
    fun newQuestionResetsSelection() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.applyUserQuestionSnapshot(session, snapshot(question("q1")))
        holder.selectUserQuestionOption("yes")
        holder.applyUserQuestionSnapshot(session, snapshot(question("q2")))
        assertTrue(holder.userQuestionDraft?.selectedOptionIds.isNullOrEmpty())
    }

    @Test
    fun submitDispatchesExactlyOneExactIdentityAndBlocksDuplicateTap() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        val q = question(revision = 7)
        holder.applyUserQuestionSnapshot(session, snapshot(q))
        holder.selectUserQuestionOption("yes")
        assertTrue(holder.canSubmitUserQuestion())

        val first = holder.submitUserQuestion()
        assertEquals(ConversationFlowResult.Accepted, first)
        assertEquals(1, host.count("answerUserQuestion"))
        val request = host.lastArgs("answerUserQuestion")?.get(1) as UserQuestionAnswerRequestUi
        assertEquals("uq_q1", request.requestId)
        assertEquals("uq_q1.q1", request.questionId)
        assertEquals(7, request.expectedRevision)
        assertEquals("nonce-7", request.answerNonce)
        assertEquals(listOf("yes"), request.selectedOptionIds)

        val duplicate = holder.submitUserQuestion()
        assertTrue(duplicate is ConversationFlowResult.Rejected)
        assertEquals(1, host.count("answerUserQuestion"))
    }

    @Test
    fun incompleteSingleSelectNeverDispatches() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.applyUserQuestionSnapshot(session, snapshot(question()))
        assertFalse(holder.canSubmitUserQuestion())
        val result = holder.submitUserQuestion()
        assertTrue(result is ConversationFlowResult.Rejected)
        assertEquals(0, host.count("answerUserQuestion"))
    }

    @Test
    fun textOnlyQuestionRequiresTextAndIgnoresOptions() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.applyUserQuestionSnapshot(
            session,
            snapshot(question(options = emptyList(), allowsFreeText = true)),
        )
        assertFalse(holder.canSubmitUserQuestion())
        holder.setUserQuestionFreeText("Ship it")
        assertTrue(holder.canSubmitUserQuestion())
        holder.submitUserQuestion()
        val request = host.lastArgs("answerUserQuestion")?.get(1) as UserQuestionAnswerRequestUi
        assertEquals("Ship it", request.freeText)
        assertTrue(request.selectedOptionIds.isEmpty())
    }

    @Test
    fun settledSnapshotClearsSheetAndFailureRestoresControls() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.applyUserQuestionSnapshot(session, snapshot(question()))
        holder.selectUserQuestionOption("no")
        holder.submitUserQuestion()
        holder.applyUserQuestionFailure("staleRevision")
        assertFalse(holder.userQuestionSubmitting)
        assertEquals("staleRevision", holder.userQuestionError)

        holder.applyUserQuestionSnapshot(session, null)
        assertFalse(holder.showingUserQuestion)
        assertEquals(null, holder.userQuestionDraft)
    }

    @Test
    fun multiSelectTogglesAndFreeTextGate() {
        assertTrue(
            UserQuestionDraftPolicy.canSubmit(
                question(mode = UserQuestionSelectionModeUi.MULTIPLE),
                setOf("yes", "no"),
                "",
            ),
        )
        assertEquals(
            setOf("yes", "no"),
            UserQuestionDraftPolicy.toggle(setOf("yes"), "no",
                UserQuestionSelectionModeUi.MULTIPLE, setOf("yes", "no")),
        )
        assertEquals(
            setOf("no"),
            UserQuestionDraftPolicy.toggle(setOf("yes"), "no",
                UserQuestionSelectionModeUi.SINGLE, setOf("yes", "no")),
        )
        assertFalse(
            UserQuestionDraftPolicy.canSubmit(
                question(allowsFreeText = false),
                setOf("yes"),
                "a note",
            ),
        )
    }

    @Test
    fun cancelDispatchesOnceAndUsesRequestIdentity() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.applyUserQuestionSnapshot(session, snapshot(question()))
        val result = holder.cancelUserQuestion()
        assertEquals(ConversationFlowResult.Accepted, result)
        assertEquals(1, host.count("cancelUserQuestion"))
        assertEquals("uq_q1", host.lastArgs("cancelUserQuestion")?.get(1))
    }
}
