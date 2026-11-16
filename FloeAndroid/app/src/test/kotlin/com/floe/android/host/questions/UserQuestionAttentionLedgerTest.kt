// SPDX-License-Identifier: MPL-2.0
//
// Focused regressions for the durable App-owned question attention signal.
//
// These tests are pure JVM: they pin the exact identity/fencing and
// settlement rules the coordinator will run later. They do not instantiate
// Android notifications or the native bridge.
//
// The original App only posted a question reminder from a live holder's
// bounded `question.pending` discovery window. A background/scheduled run, a
// released holder, or a question registered after that window therefore had
// no reminder at all. The new ledger/record path must survive holder loss,
// re-read authoritative state, and withdraw only the exact request/run it
// posted.
package com.floe.android.host.questions

import com.floe.android.feature.conversation.UserQuestionOptionUi
import com.floe.android.feature.conversation.UserQuestionPromptUi
import com.floe.android.feature.conversation.UserQuestionSelectionModeUi
import com.floe.android.feature.conversation.UserQuestionSnapshotUi
import com.floe.android.feature.conversation.UserQuestionStatusUi
import com.floe.android.feature.conversation.UserQuestionWaitPolicyUi
import com.floe.android.host.HostCommandValidator
import com.floe.android.host.HostScope
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UserQuestionAttentionLedgerTest {

    private val conversation = "11111111-1111-4111-8111-111111111111"
    private val otherConversation = "33333333-3333-4333-8333-333333333333"
    private val run = "22222222-2222-4222-8222-222222222222"
    private val otherRun = "44444444-4444-4444-8444-444444444444"
    private val request = "uq_" + "a".repeat(32)
    private val question = "$request.q1"
    private val digest = "b".repeat(64)

    @Test
    fun removingOldRecordDoesNotRemoveItsReplacement() {
        val ledger = UserQuestionAttentionLedger()
        val old = UserQuestionAttentionRecord(1L, conversation, request, run, question)
        val replacementRequest = "uq_" + "c".repeat(32)
        val replacement = UserQuestionAttentionRecord(
            1L, conversation, replacementRequest, run, "$replacementRequest.q1")
        assertTrue(ledger.record(old))
        assertTrue(ledger.record(replacement))
        assertFalse(ledger.remove(old))
        assertEquals(replacement, ledger.recordFor(conversation))
        assertTrue(ledger.remove(replacement))
        assertNull(ledger.recordFor(conversation))
    }

    private fun snapshot(
        status: UserQuestionStatusUi = UserQuestionStatusUi.PENDING,
        ephemeral: Boolean = false,
        questions: List<UserQuestionPromptUi>? = null,
        conversationId: String = conversation,
        runId: String = run,
    ): UserQuestionSnapshotUi = UserQuestionSnapshotUi(
        requestId = request,
        requestDigest = digest,
        conversationId = conversationId,
        runId = runId,
        stateRaw = if (status == UserQuestionStatusUi.PENDING) "awaitingAnswer" else "settled",
        isEphemeral = ephemeral,
        questions = questions ?: listOf(
            UserQuestionPromptUi(
                questionId = question,
                requestId = request,
                runId = runId,
                text = "A private presence question",
                options = emptyList<UserQuestionOptionUi>(),
                selectionMode = UserQuestionSelectionModeUi.SINGLE,
                allowsFreeText = true,
                waitPolicy = UserQuestionWaitPolicyUi.REQUIRED,
                deadlineLabel = null,
                status = status,
                revision = 3,
                answerNonce = "nonce-3",
                requestDigest = digest,
            ),
        ),
        currentQuestionId = question,
    )

    @Test
    fun noHolderPendingReadUsesTheExistingAdmittedCommand() {
        val request = UserQuestionPendingCommand.build(
            conversationId = conversation,
            requestId = null,
            correlationID = "qwatch-1",
        )!!
        assertEquals("question.pending", request.command)
        assertEquals(HostScope.ConversationLifecycle(conversation), request.scope)
        assertEquals(false, request.stateful)
        assertNull(request.payload)
        assertNull(
            "the App command gate must admit the no-holder authoritative read",
            HostCommandValidator.validate(request),
        )
    }

    @Test
    fun exactRequestReadCarriesOnlyTheQuestionRequestIdentity() {
        val command = UserQuestionPendingCommand.build(
            conversationId = conversation,
            requestId = request,
            correlationID = "qwatch-2",
        )!!
        assertEquals(setOf("requestID"), command.payload!!.keys)
        assertEquals(
            JsonPrimitive(request).toString(),
            command.payload!!["requestID"].toString(),
        )
        assertNull(HostCommandValidator.validate(command))
    }

    @Test
    fun candidateGenerationIsStableUntilTheExactCandidateIsDropped() {
        val ledger = UserQuestionAttentionLedger()
        val first = ledger.ensureCandidate(conversation, 1L)
        assertNotNull(first)
        assertEquals(first, ledger.ensureCandidate(conversation, 2L))

        assertTrue(ledger.dropCandidate(conversation))
        val replacement = ledger.ensureCandidate(conversation, 3L)
        assertNotNull(replacement)
        assertNotEquals(first, replacement)
        assertFalse(
            "a read from the removed candidate must not apply to its replacement",
            UserQuestionAttentionRules.isCurrentCandidate(
                expectedGeneration = first!!,
                currentGeneration = replacement,
            ),
        )
        assertTrue(
            UserQuestionAttentionRules.isCurrentCandidate(
                expectedGeneration = replacement!!,
                currentGeneration = ledger.candidateGeneration(conversation),
            ),
        )
    }

    @Test
    fun presentedQuestionProjectsIdentifierOnlyRecord() {
        val record = UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 47L)!!
        assertEquals(47L, record.rootEpoch)
        assertEquals(conversation, record.conversationId)
        assertEquals(request, record.requestId)
        assertEquals(run, record.runId)
        assertEquals(question, record.questionId)
        val encoded = UserQuestionAttentionCodec.encode(record)
        assertNotNull(encoded)
        assertFalse(
            "the persisted reminder must never contain question text",
            encoded!!.contains("presence question"),
        )
        assertEquals(record, UserQuestionAttentionCodec.decode(encoded!!))
    }

    @Test
    fun persistedIdentityIsCanonicalAndCannotAliasAnotherRoot() {
        val record = UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 47L)!!
            .copy(
                conversationId = conversation.uppercase(),
                runId = run.uppercase(),
            )
        val encoded = UserQuestionAttentionCodec.encode(record)!!
        val decoded = UserQuestionAttentionCodec.decode(encoded)!!
        assertEquals(conversation, decoded.conversationId)
        assertEquals(run, decoded.runId)
        assertEquals(47L, decoded.rootEpoch)
        assertTrue(encoded.contains("|47|"))
    }

    @Test
    fun ephemeralOrSettledSnapshotsNeverBecomeDurableReminders() {
        assertNull(
            UserQuestionAttentionRules.recordFor(
                snapshot(ephemeral = true), rootEpoch = 1L),
        )
        assertNull(
            UserQuestionAttentionRules.recordFor(
                snapshot(status = UserQuestionStatusUi.ANSWERED), rootEpoch = 1L),
        )
        assertFalse(
            UserQuestionAttentionRules.canPost(
                snapshot(ephemeral = true), notificationsAllowed = true),
        )
        assertFalse(
            UserQuestionAttentionRules.canPost(
                snapshot(status = UserQuestionStatusUi.CANCELLED),
                notificationsAllowed = true,
            ),
        )
        assertFalse(
            UserQuestionAttentionRules.canPost(
                snapshot(), notificationsAllowed = false),
        )
        assertTrue(
            UserQuestionAttentionRules.canPost(
                snapshot(), notificationsAllowed = true),
        )
    }

    @Test
    fun settlementRequiresTheExactRequestAndQuestionIdentity() {
        val ledger = UserQuestionAttentionLedger()
        val record = UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 9L)!!
        ledger.record(record)

        assertNull(
            "another request in the same conversation cannot settle this one",
            ledger.settle(conversation, "uq_" + "c".repeat(32), question),
        )
        assertNull(
            "another question of the same request cannot settle this one",
            ledger.settle(conversation, request, "$request.q2"),
        )
        assertEquals(record, ledger.recordFor(conversation))

        assertEquals(record, ledger.settle(conversation, request, question))
        assertNull(ledger.recordFor(conversation))
    }

    @Test
    fun terminalRunOnlyWithdrawsItsOwnReminder() {
        val ledger = UserQuestionAttentionLedger()
        ledger.record(UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 9L)!!)

        assertNull(
            "a different run's terminal must not withdraw this question",
            ledger.settleForRun(conversation, otherRun),
        )
        assertNotNull(ledger.recordFor(conversation))

        assertNotNull(ledger.settleForRun(conversation, run))
        assertNull(ledger.recordFor(conversation))
    }

    @Test
    fun anotherConversationsReminderIsNeverTouched() {
        val ledger = UserQuestionAttentionLedger()
        val first = UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 9L)!!
        val second = UserQuestionAttentionRules.recordFor(
            snapshot(conversationId = otherConversation), rootEpoch = 9L)!!
        ledger.record(first)
        ledger.record(second)

        assertNull(
            "another request identity cannot settle the other conversation's reminder",
            ledger.settle(otherConversation, "uq_" + "c".repeat(32), question),
        )
        assertEquals(second, ledger.recordFor(otherConversation))
        assertEquals(first, ledger.recordFor(conversation))
    }

    @Test
    fun malformedOrTamperedRecordIsRejected() {
        assertNull(UserQuestionAttentionCodec.decode(""))
        assertNull(UserQuestionAttentionCodec.decode("v1|9|not-a-uuid|$request|$run|$question"))
        assertNull(
            UserQuestionAttentionCodec.decode(
                "v1|9|$conversation|uq_bad|$run|uq_bad.q1"),
        )
        assertNull(
            UserQuestionAttentionCodec.decode(
                "v1|9|$conversation|$request|$run|$request.q1|extra"),
        )
        assertNull(
            UserQuestionAttentionCodec.decode(
                "v2|9|$conversation|$request|$run|$question"),
        )
    }

    @Test
    fun authoritativeReadSelectsPostWithdrawOrKeepWithoutGuessing() {
        val record = UserQuestionAttentionRules.recordFor(snapshot(), rootEpoch = 9L)!!
        val pending = snapshot()
        assertTrue(
            UserQuestionAttentionRules.actionFor(
                UserQuestionPendingRead.Snapshot(pending), record,
            ) is UserQuestionAttentionAction.Post,
        )
        assertTrue(
            "an authoritative empty read retires the exact reminder",
            UserQuestionAttentionRules.actionFor(
                UserQuestionPendingRead.Empty, record,
            ) is UserQuestionAttentionAction.Withdraw,
        )
        assertEquals(
            "a transient read failure must never pretend the question ended",
            UserQuestionAttentionAction.Keep,
            UserQuestionAttentionRules.actionFor(
                UserQuestionPendingRead.Failure("timeout"), record),
        )
        val settled = snapshot(status = UserQuestionStatusUi.ANSWERED)
        assertTrue(
            UserQuestionAttentionRules.actionFor(
                UserQuestionPendingRead.Snapshot(settled), record,
            ) is UserQuestionAttentionAction.Withdraw,
        )
    }

    @Test
    fun candidateCapacityIsBoundedWithoutCrossConversationCollision() {
        val ledger = UserQuestionAttentionLedger(maximumCandidates = 2)
        val a = "10000000-0000-4000-8000-000000000001"
        val b = "10000000-0000-4000-8000-000000000002"
        val c = "10000000-0000-4000-8000-000000000003"
        assertNotNull(ledger.ensureCandidate(a, 1L))
        assertNotNull(ledger.ensureCandidate(b, 2L))
        assertNotNull(ledger.ensureCandidate(c, 3L))
        assertEquals(2, ledger.candidateIds().size)
        assertFalse(ledger.candidateIds().contains(a))
        assertTrue(ledger.candidateIds().contains(b))
        assertTrue(ledger.candidateIds().contains(c))
    }
}
