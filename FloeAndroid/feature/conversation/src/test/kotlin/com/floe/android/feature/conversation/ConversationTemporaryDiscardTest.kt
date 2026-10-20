// SPDX-License-Identifier: MPL-2.0
//
// Temporary presentation payload discard + late-echo rehydration fencing
// (Main's required repair #2): a host destroying its own temporary store
// cannot clear what this RETAINED UI holder still holds, so genuine
// navigation retirement must discard the holder's own ephemeral payloads —
// draft TextFieldValue, caret, staged attachment references, error/banner
// surfaces, secondary sheets and selections, latches and the shared edit
// history — and EVERY late echo/callback must be rejected afterwards.
// Contrasted against [detach], which is a view lifecycle event and MUST
// retain everything (backgrounding/rotation/reconstruction semantics), and
// against durable data: retirement never emits a durable draft deletion,
// clear, archive or any other store effect.

package com.floe.android.feature.conversation

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationTemporaryDiscardTest {

    private fun populatedTemporaryHolder(): Pair<RecordingHost, ConversationFlowHolder> {
        val host = RecordingHost()
        val h = ConversationFlowHolder(host, "conv-1")
        h.applyHostSnapshot(
            threadState(
                h.session,
                isTemporary = true,
                temporaryIncarnationId = "inc-1",
                pendingInputs = listOf(pendingInput()),
            ),
        )
        // Fill EVERY ephemeral presentation surface.
        h.applySendHandoff(null, listOf(stagedAttachment(id = "att-1"))) // gen 0
        h.onDraftChange(TextFieldValue("ephemeral draft", TextRange(7, 7)))
        h.applyAttachmentOutcome("att-1", AttachmentImportUi.Failed("late import"))
        h.setApprovalScope("run-1/call-1", ApprovalScopeChoiceUi.HOST)
        h.toggleGroup("group-1")
        h.toggleToolCard("event-1")
        h.toggleApprovalEvidence("run-1/call-1")
        h.toggleLiveReasoning()
        h.toggleChecklist()
        h.openGoalBuilder()
        h.openTemporaryAbout()
        h.openPendingInputEditor("input-1")
        h.openChildRun("child-1")
        h.openFullEditor()
        h.openUsageDetails(UsageUi(10, 5, 15, 1000, isEstimatedLive = false))
        h.selectRun("run-1")
        h.selectedAttachment.value = AttachmentOpenRequest("conv-1", "msg-1", "att-1")
        // Keep an in-flight keep on the holder.
        h.keepTemporaryChat()
        return host to h
    }

    /* ------------------------------ discard ------------------------------- */

    @Test
    fun genuineNavigationDiscardsEveryTemporaryPresentationPayload() {
        val (host, h) = populatedTemporaryHolder()
        // A model-persistence banner on a sibling holder (same discard code).
        val bannerHost = RecordingHost()
        bannerHost.selectModelPersisted = false
        val banner = ConversationFlowHolder(bannerHost, "conv-1")
        banner.applyHostSnapshot(threadState(banner.session))
        banner.selectModel("model-1")
        assertEquals("Model model-1", banner.modelPersistenceFailureName)

        // Sanity: the surfaces ARE populated before retirement.
        assertEquals("ephemeral draft", h.draft.value.text)
        assertTrue(h.stagedAttachments.value.isNotEmpty())
        assertEquals("late import", h.attachmentError)
        assertTrue(h.showsFullEditor && h.showingGoalBuilder && h.showsTemporaryAbout)

        val effectsBefore = host.effects.size
        h.retireForNavigation()

        // Draft: text, caret and generation are gone from the retained holder.
        assertEquals("", h.draft.value.text)
        assertEquals(TextRange(0, 0), h.draft.value.selection)
        assertEquals(0L, h.draftGeneration)
        // Staged attachment references released.
        assertTrue(h.stagedAttachments.value.isEmpty())
        // Errors/banners/surfaces all discarded.
        assertNull(h.attachmentError)
        assertNull(h.actionError)
        assertNull(h.modelPersistenceFailureName)
        assertFalse(h.showsFullEditor)
        assertFalse(h.showingGoalBuilder)
        assertFalse(h.showsTemporaryAbout)
        assertFalse(h.checklistExpanded)
        assertFalse(h.liveReasoningExpanded)
        assertNull(h.editingPendingInputId.value)
        assertNull(h.openChildRunId.value)
        assertNull(h.presentedUsage)
        assertNull(h.selectedAttachment.value)
        assertTrue(h.expandedGroups.value.isEmpty())
        assertTrue(h.expandedToolCards.value.isEmpty())
        assertTrue(h.expandedApprovalEvidence.value.isEmpty())
        assertTrue(h.approvalScopeChoices.value.isEmpty())
        assertTrue(h.editorHistorySize() == 0 && h.editorRedoSize() == 0)
        // Keep machine + latches reset (temporary RAM posture captured and
        // discarded — no in-flight Keep survives its session).
        assertEquals(TemporaryKeepStateUi.Idle, h.temporaryKeepState)
        assertFalse(h.isConsumingDraft)
        assertFalse(h.temporaryDraftHandoffPending)
        assertEquals(null, h.selectedModelId.value)
        assertEquals(null, h.selectedProjectId.value)
        assertEquals(null, h.selectedRunId.value)

        // NO durable deletion/clear/keep/end effect was emitted by the
        // discard itself: retirement only detaches and fences. (The keep
        // recorded BEFORE retirement is the earlier fixture action; the
        // discard window adds exactly one threadViewDetached.)
        val new = host.effects.drop(effectsBefore)
        assertEquals(listOf("threadViewDetached"), new.map { it.name })
        assertTrue(new.none { it.name == "clearDraftAfterSend" })
        assertTrue(new.none { it.name == "keepTemporaryChat" })
        assertTrue(new.none { it.name == "endTemporaryChat" })
        assertTrue(h.retired)
    }

    /* --------------------- late echo rehydration fencing -------------------- */

    @Test
    fun everyLateEchoAfterRetirementCannotRehydrateAnything() {
        val (host, h) = populatedTemporaryHolder()
        h.retireForNavigation()
        val postEpochSession = ConversationSessionToken("conv-1", h.session.sessionEpoch)
        val keepRef = TemporarySessionRef("conv-1", postEpochSession.sessionEpoch, "inc-1")
        val effectsAfterRetireBase = host.effects.size

        // 1. Late host projection for the retired holder's CURRENT epoch
        //    (a stale object could compute this equality!) — rejected by the
        //    retired flag first.
        h.applyHostSnapshot(
            threadState(postEpochSession, isTemporary = true, temporaryIncarnationId = "inc-1"),
        )
        assertNull(h.snapshot.value)

        // 2. Late send handoff cannot restore a draft.
        h.applySendHandoff("ghost draft", listOf(stagedAttachment(id = "ghost")))
        assertEquals("", h.draft.value.text)
        assertTrue(h.stagedAttachments.value.isEmpty())

        // 3. Late attachment outcome cannot recreate a row or banner.
        h.applyAttachmentOutcome("att-1", AttachmentImportUi.Ready)
        assertNull(h.attachmentError)

        // 4. Late keep/end echoes cannot navigate or flip the keep state.
        h.applyTemporaryKeepOutcome(keepRef, TemporaryKeepOutcomeUi.Promoted)
        h.applyTemporaryEndOutcome(keepRef, TemporaryEndTargetUi.OpenNewTask)
        assertEquals(TemporaryKeepStateUi.Idle, h.temporaryKeepState)

        // 5. Late launch echoes cannot clear a durable draft or set errors.
        h.applyLaunchPrepared(LaunchCorrelation("conv-1", postEpochSession.sessionEpoch, 1, null))
        h.applyLaunchFailure(LaunchCorrelation("conv-1", postEpochSession.sessionEpoch, 1, null), "late")
        assertNull(h.actionError)

        // 6. Late markdown echo cannot style; new scheduling is refused.
        h.ensureMarkdownParse("ghost source")
        h.applyMarkdownParseResult(postEpochSession, "ghost source", 1, listOf(MarkdownBlockUi.ThematicBreak))
        assertTrue(h.markdownState("ghost source") is MarkdownContentUi.Preparing)
        assertEquals(0, h.markdownCacheSize())

        // 7. Late load()/intents cannot re-arm the surface.
        h.load()
        h.openFullEditor()
        h.openGoalBuilder()
        h.openTemporaryAbout()
        h.onDraftChange(TextFieldValue("typed after retire"))
        assertFalse(h.showsFullEditor)
        assertFalse(h.showingGoalBuilder)
        assertFalse(h.showsTemporaryAbout)
        assertEquals("", h.draft.value.text)

        // 8. A late send keeps NOTHING alive.
        val lateSend = h.send()
        assertTrue(lateSend is ConversationFlowResult.Rejected)

        // None of the echoes above produced a NEW host effect.
        val newEffects = host.effects.drop(effectsAfterRetireBase)
        assertTrue("late echoes must emit zero host effects, got $newEffects", newEffects.isEmpty())
    }

    @Test
    fun keepInFlightThenRetireRejectsTheLatePromotionEcho() {
        val (host, h) = populatedTemporaryHolder()
        // keepTemporaryChat() is in flight (Saving) from the populated state.
        assertEquals(TemporaryKeepStateUi.Saving, h.temporaryKeepState)
        h.retireForNavigation()
        val postEpoch = ConversationSessionToken("conv-1", h.session.sessionEpoch)
        host.effects.clear()
        h.applyTemporaryKeepOutcome(
            TemporarySessionRef("conv-1", postEpoch.sessionEpoch, "inc-1"),
            TemporaryKeepOutcomeUi.Promoted,
        )
        assertEquals(TemporaryKeepStateUi.Idle, h.temporaryKeepState)
        assertTrue(host.effects.isEmpty())
    }

    /* --------------------- detach retains ordinary semantics --------------------- */

    @Test
    fun viewDetachKeepsEveryPopulatedSurface() {
        val (host, h) = populatedTemporaryHolder()
        val effectsBefore = host.effects.size

        h.detach()

        // One effect: stop live updates. NOTHING is discarded.
        assertEquals(listOf("threadViewDetached"), host.effects.drop(effectsBefore).map { it.name })
        assertFalse(h.retired)
        assertEquals("ephemeral draft", h.draft.value.text)
        assertTrue(h.stagedAttachments.value.isNotEmpty())
        assertEquals("late import", h.attachmentError)
        assertTrue(h.showsFullEditor)
        assertTrue(h.canUndoDraft)
        assertEquals(TemporaryKeepStateUi.Saving, h.temporaryKeepState)
        // The in-flight Keep still settles normally through the projection.
        h.applyHostSnapshot(
            threadState(h.session, isTemporary = false, promotedConversationId = "conv-1"),
        )
        h.applyTemporaryKeepOutcome(
            TemporarySessionRef("conv-1", h.session.sessionEpoch, "inc-1"),
            TemporaryKeepOutcomeUi.Promoted,
        )
        assertEquals(TemporaryKeepStateUi.Idle, h.temporaryKeepState)
    }

    @Test
    fun rebindDiscardsTheOldConversationPayloadThenSeedsTheNewDraft() {
        val (host, h) = populatedTemporaryHolder()
        h.rebind(
            "conv-2",
            ComposerDraftSeedUi("restored durable draft", emptyList(), 3, 2),
        )
        assertFalse(h.retired) // rebind is a live rebinding, not retirement
        assertEquals("conv-2", h.conversationId)
        assertEquals("restored durable draft", h.draft.value.text)
        // Caret/selection restored from the seed.
        assertEquals(TextRange(3, 5), h.draft.value.selection)
        // The OLD conversation's payload is gone.
        assertTrue(h.stagedAttachments.value.isEmpty())
        assertEquals(TemporaryKeepStateUi.Idle, h.temporaryKeepState)
        assertFalse(h.showsFullEditor)
        assertEquals(0, h.markdownCacheSize())
        assertTrue(host.names().contains("loadThread"))
    }
}
