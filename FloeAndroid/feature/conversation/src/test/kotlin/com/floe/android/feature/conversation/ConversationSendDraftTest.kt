// SPDX-License-Identifier: MPL-2.0
//
// Send/draft identity source tests (⇄ ThreadDetailViewModel.send,
// ComposerSendCommit, temporary text-only launch, handoff persistence gate).
// Focus: a success clears ONLY the exact generation it consumed (A → B → A is
// a new draft), a pre-accept failure restores the complete original draft,
// the queue path keeps the field until the submit lands, temporary sends
// carry no attachments, and the handoff gate defers durable persistence until
// the first real edit. No device, network or store is involved.
//
// Main's async-launch addendum (2026-10-18/19): startRun == true is an
// OWNED-PREPARATION ADMISSION, not a durable start. The matching commit is
// RETAINED until the correlated prepared echo (durable draft clear happens
// exactly once there), a correlated failure reverses the optimistic visual
// clear with the COMPLETE original draft + attachments, the pending commit
// gates duplicate fresh sends, and stale/foreign/retired echoes touch
// nothing. These are presentation fencing rules only: the real host owns
// task/run ids and this suite never mints or asserts domain ids.

package com.floe.android.feature.conversation

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationSendDraftTest {

    private fun holder(host: RecordingHost): ConversationFlowHolder {
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(holder.session))
        return holder
    }

    private fun sentText(host: RecordingHost): String =
        host.lastArgs("startRun")!![0].let { (it as RunLaunchRequest).goalText }

    /** Correlation captured from the ONE recorded startRun request. */
    private fun recordedCorrelation(host: RecordingHost): LaunchCorrelation =
        (host.lastArgs("startRun")!![0] as RunLaunchRequest).correlation()

    @Test
    fun admittedThenPreparedSendConsumesExactlyTheSentDraftOnce() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.onDraftChange(TextFieldValue("hello world"))
        val generationBeforeSend = holder.draftGeneration

        assertEquals(ConversationFlowResult.Accepted, holder.send())

        // ADMITTED: visually consumed, but the DURABLE clear has NOT
        // happened — the commit is retained until the real prepared echo.
        assertEquals(1, host.count("startRun"))
        assertEquals("hello world", sentText(host))
        assertEquals(0, host.count("clearDraftAfterSend"))
        assertEquals("", holder.draft.value.text)
        assertTrue(holder.draftGeneration > generationBeforeSend)

        val correlation = recordedCorrelation(host)
        holder.applyLaunchPrepared(correlation)

        // PREPARED: durable clear for exactly this send, exactly once.
        assertEquals(1, host.count("clearDraftAfterSend"))
        assertEquals("hello world", host.lastArgs("clearDraftAfterSend")!![1])
        assertEquals("", holder.draft.value.text)

        // A replayed prepared echo consumes nothing further.
        holder.applyLaunchPrepared(correlation)
        assertEquals(1, host.count("clearDraftAfterSend"))
    }

    @Test
    fun failureAfterQueueAcceptanceRestoresTheCompleteDraftAndAttachments() {
        val host = RecordingHost()
        val holder = holder(host)
        val staged = stagedAttachment(id = "att-keep")
        holder.applySendHandoff(null, listOf(staged)) // generation 0: the tray owns att-keep
        holder.onDraftChange(TextFieldValue("keep every\ncharacter  "))
        val text = holder.draft.value.text

        assertEquals(ConversationFlowResult.Accepted, holder.send())
        assertEquals(0, holder.stagedAttachments.value.size) // optimistically consumed
        val correlation = recordedCorrelation(host)

        // The queued acceptance later reverses (preflight rejection):
        holder.applyLaunchFailure(correlation, "provider rejected the launch")

        assertEquals(text, holder.draft.value.text) // FULL original text, untrimmed
        assertEquals(0, host.count("clearDraftAfterSend")) // durable store never touched
        assertEquals(listOf("att-keep"), holder.stagedAttachments.value.map { it.id })
        assertEquals("provider rejected the launch", holder.actionError)
        // Commit released: a fresh send is possible again.
        holder.onDraftChange(TextFieldValue("again"))
        assertEquals(ConversationFlowResult.Accepted, holder.send())
        assertEquals(2, host.count("startRun"))
    }

    @Test
    fun pendingCommitGatesADuplicateFreshSendUntilPrepared() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.onDraftChange(TextFieldValue("first"))
        assertEquals(ConversationFlowResult.Accepted, holder.send())

        // The field was consumed; the user immediately types a second prompt.
        holder.onDraftChange(TextFieldValue("second"))
        val duplicate = holder.send()
        assertTrue(duplicate is ConversationFlowResult.Rejected)
        assertEquals(
            ConversationRejectedReason.OPERATION_IN_FLIGHT,
            (duplicate as ConversationFlowResult.Rejected).reason,
        )
        assertEquals(1, host.count("startRun")) // no second launch dispatched

        holder.applyLaunchPrepared(recordedCorrelation(host))
        assertEquals(ConversationFlowResult.Accepted, holder.send())
        assertEquals(2, host.count("startRun"))
    }

    @Test
    fun lateOutcomeForRequestACannotTouchRequestB() {
        val host = RecordingHost()
        val holder = holder(host)

        // A: admitted then durably prepared.
        holder.onDraftChange(TextFieldValue("alpha"))
        assertEquals(ConversationFlowResult.Accepted, holder.send())
        val correlationA = recordedCorrelation(host)
        holder.applyLaunchPrepared(correlationA)

        // B: a NEW send is now in flight with its own correlation.
        holder.onDraftChange(TextFieldValue("beta"))
        assertEquals(ConversationFlowResult.Accepted, holder.send())
        val correlationB = recordedCorrelation(host)
        assertTrue(correlationA.launchGeneration != correlationB.launchGeneration)

        // Late failure echo for the ALREADY-CONSUMED request A: the retained
        // commit belongs to B, so A's outcome touches nothing.
        holder.applyLaunchFailure(correlationA, "stale A failure")
        assertEquals("", holder.draft.value.text) // B's consumption stands
        assertNull(holder.actionError)
        assertEquals(1, host.count("clearDraftAfterSend")) // still exactly A's

        // B then prepares normally.
        holder.applyLaunchPrepared(correlationB)
        assertEquals(2, host.count("clearDraftAfterSend"))
    }

    @Test
    fun retiredHolderRejectsLatePreparedAndFailureEchoes() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.onDraftChange(TextFieldValue("voyager"))
        assertEquals(ConversationFlowResult.Accepted, holder.send())
        val correlation = recordedCorrelation(host)

        holder.retireForNavigation()

        holder.applyLaunchPrepared(correlation)
        holder.applyLaunchFailure(correlation, "late")
        assertEquals(0, host.count("clearDraftAfterSend"))
        assertNull(holder.actionError)
    }

    @Test
    fun rejectedLaunchRestoresTheCompleteOriginalDraft() {
        val host = RecordingHost()
        host.startRunAccepted = false
        val holder = holder(host)
        val original = "keep every\ncharacter  "
        holder.onDraftChange(TextFieldValue(original))

        val result = holder.send()

        assertTrue(result is ConversationFlowResult.Rejected)
        assertEquals(original, holder.draft.value.text)
        assertEquals(0, host.count("clearDraftAfterSend"))
        assertEquals(1, host.count("startRun")) // exactly the one attempted start
    }

    @Test
    fun lateLaunchFailureNeverOverwritesAUserEdit() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.onDraftChange(TextFieldValue("first"))
        holder.send() // admitted: field cleared, generation advanced

        holder.onDraftChange(TextFieldValue("second")) // user owns a new draft
        holder.applyLaunchFailure(recordedCorrelation(host), "provider rejected the launch")

        // The reversal never clobbers the newer user draft (the durable store
        // still holds "second": the prepared echo — not the admission — owns
        // that side of reconciliation).
        assertEquals("second", holder.draft.value.text)
        assertEquals("provider rejected the launch", holder.actionError)
    }

    @Test
    fun queuePathSubmitsThenConsumesExactlyOnce() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(holder.session, isRunning = true))
        holder.onDraftChange(TextFieldValue("steer this"))

        assertEquals(ConversationFlowResult.Accepted, holder.send())

        assertEquals(1, host.count("submitRunningInput"))
        assertEquals(0, host.count("startRun"))
        assertEquals(0, host.count("clearDraftAfterSend"))
        val request = host.lastArgs("submitRunningInput")!![0] as RunningInputRequest
        assertEquals("conv-1", request.conversationId)
        assertEquals("run-1", request.expectedRunId)
        assertEquals("steer this", request.content)
        assertEquals("", holder.draft.value.text)
    }

    @Test
    fun temporarySendIsTextOnlyAndKeepsStagedAttachments() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        val staged = stagedAttachment()
        holder.applyHostSnapshot(
            threadState(holder.session, isTemporary = true, temporaryIncarnationId = "inc-1")
        )
        // Seed staged attachments through the host-restored draft path.
        holder.applySendHandoff(null, listOf(staged))
        holder.onDraftChange(TextFieldValue("temporary hello"))

        assertEquals(ConversationFlowResult.Accepted, holder.send())

        val request = host.lastArgs("startRun")!![0] as RunLaunchRequest
        assertTrue("temporary launches carry no attachments", request.attachments.isEmpty())
        assertEquals("inc-1", request.temporaryIncarnationId)
        // Staged files stay in the composer/draft, nothing is deleted.
        assertEquals(1, holder.stagedAttachments.value.size)
        assertEquals("", holder.draft.value.text)
    }

    @Test
    fun sendGatingRejectsBlankDraftAndMissingProvider() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.onDraftChange(TextFieldValue("   "))

        assertTrue(holder.send() is ConversationFlowResult.Rejected)
        assertEquals(0, host.count("startRun"))

        val noProviderHost = RecordingHost()
        val noProvider = ConversationFlowHolder(noProviderHost, "conv-1")
        noProvider.applyHostSnapshot(threadState(noProvider.session, needsProvider = true))
        noProvider.onDraftChange(TextFieldValue("hello"))
        assertTrue(noProvider.send() is ConversationFlowResult.Rejected)
        assertEquals(0, noProviderHost.count("startRun"))
    }

    @Test
    fun handoffGateDefersDurableDraftPersistenceUntilFirstEdit() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.noteTemporaryDraftHandoff(draftWasNonEmpty = true)
        assertEquals(false, holder.shouldPersistDraftEdits)
        val savesBefore = host.count("saveDraft")

        // Caret-only change while handed off: still not persisted.
        holder.onDraftChange(
            TextFieldValue(holder.draft.value.text, TextRange(0, 0))
        )
        assertEquals(savesBefore, host.count("saveDraft"))

        // First real edit re-arms and persists.
        holder.onDraftChange(TextFieldValue("edited"))
        assertEquals(true, holder.shouldPersistDraftEdits)
        assertEquals(savesBefore + 1, host.count("saveDraft"))
    }

    @Test
    fun attachmentOutcomeForRemovedRowIsDropped() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.applySendHandoff(null, listOf(stagedAttachment(id = "att-1", lifecycle = AttachmentImportUi.InProgress(null))))
        holder.cancelAttachment("att-1") // row leaves presentation first

        holder.applyAttachmentOutcome("att-1", AttachmentImportUi.Failed("late"))

        assertTrue(holder.stagedAttachments.value.none { it.id == "att-1" })
        assertEquals(null, holder.attachmentError)
    }
}
