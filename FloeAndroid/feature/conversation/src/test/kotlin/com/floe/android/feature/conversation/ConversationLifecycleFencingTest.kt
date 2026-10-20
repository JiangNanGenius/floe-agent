// SPDX-License-Identifier: MPL-2.0
//
// Retained-holder lifecycle and effect-fencing source tests (no device, no
// Android runtime). These pin the contracts Main required:
//  - a VIEW DETACH (recreation/background/lock/onDisappear-equivalent) is NOT
//    a navigation: temporary RAM state and in-flight Keep survive it;
//  - a GENUINE navigation retires the holder so late Keep/end/send echoes
//    can never emit global navigation or mutate the new route;
//  - navigation effects carry the source session token the host revalidates;
//  - one important-file tap emits EXACTLY ONE real file intent and never a
//    dummy/placeholder open;
//  - stale/foreign sessions are rejected without effects.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationLifecycleFencingTest {

    private fun tempHolder(host: RecordingHost): ConversationFlowHolder {
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(
            threadState(holder.session, isTemporary = true, temporaryIncarnationId = "inc-1")
        )
        return holder
    }

    private fun ref(holder: ConversationFlowHolder, incarnation: String = "inc-1") =
        TemporarySessionRef(holder.conversationId, holder.session.sessionEpoch, incarnation)

    /* ------------------- detach is not navigation (TMP retention) ------------------- */

    @Test
    fun viewDetachKeepsTemporaryStateAndInFlightKeep() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())
        assertEquals(TemporaryKeepStateUi.Saving, holder.temporaryKeepState)

        holder.detach()

        assertFalse("a view detach must never retire the session", holder.retired)
        assertTrue(host.names().contains("threadViewDetached"))
        // The in-flight Keep still settles: projection confirms promotion.
        holder.applyHostSnapshot(
            threadState(holder.session, isTemporary = false, promotedConversationId = "conv-1")
        )
        holder.applyTemporaryKeepOutcome(ref(holder), TemporaryKeepOutcomeUi.Promoted)
        assertEquals(TemporaryKeepStateUi.Idle, holder.temporaryKeepState)
        assertFalse(holder.temporaryDraftHandoffPending)
    }

    @Test
    fun detachKeepsTemporaryDraftAndStagedContent() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        holder.onDraftChange(androidx.compose.ui.text.input.TextFieldValue("ephemeral draft"))
        val before = holder.draft.value.text

        holder.detach()

        assertEquals(before, holder.draft.value.text)
        assertTrue(holder.snapshot.value?.isTemporary == true)
    }

    /* ---------------------- genuine navigation retires the session ---------------------- */

    @Test
    fun retireForNavigationBlocksLateEndEchoNavigation() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        assertEquals(ConversationFlowResult.Accepted, holder.endTemporaryChat())
        val bound = ref(holder)
        val effectsBefore = host.count("requestOpenConversation")

        holder.retireForNavigation()
        assertTrue(holder.retired)
        assertNull(holder.snapshot.value)

        // Even a ref constructed with the POST-retirement epoch (the exact
        // equality a stale object could still compute) must do nothing: the
        // retired flag is checked before any epoch comparison.
        holder.applyTemporaryEndOutcome(
            TemporarySessionRef(holder.conversationId, holder.session.sessionEpoch, bound.incarnationId),
            TemporaryEndTargetUi.OpenConversation("ordinary-1"),
        )
        assertEquals(effectsBefore, host.count("requestOpenConversation"))
        assertEquals(0, host.count("requestNewTask"))
    }

    @Test
    fun retireForNavigationRejectsLateSnapshotsAndEffects() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        holder.retireForNavigation()
        val events = host.effects.size

        // A late projection for the old epoch cannot resurrect the session.
        holder.applyHostSnapshot(threadState(ConversationSessionToken("conv-1", 0)))
        assertNull(holder.snapshot.value)
        // Effects that require a bound projection are rejected without I/O.
        val result = holder.send()
        assertTrue(result is ConversationFlowResult.Rejected)
        assertEquals(events, host.effects.size)
    }

    @Test
    fun navigationEchoUsesSourceTokenAndOnlyClearsOnHostAcceptance() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        assertEquals(ConversationFlowResult.Accepted, holder.endTemporaryChat())
        val bound = ref(holder)

        host.openConversationAccepted = false
        holder.applyTemporaryEndOutcome(bound, TemporaryEndTargetUi.OpenConversation("ordinary-1"))
        assertEquals(1, host.count("requestOpenConversation"))
        // Rejected by host revalidation: no local state is pretended away.
        assertEquals(TemporaryKeepStateUi.Idle, holder.temporaryKeepState)
        val call = host.lastArgs("requestOpenConversation")!!
        assertEquals(holder.session, call[0])
        assertEquals("ordinary-1", call[1])

        host.openConversationAccepted = true
        holder.applyTemporaryEndOutcome(bound, TemporaryEndTargetUi.OpenNewTask)
        assertEquals(1, host.count("requestNewTask"))
        assertEquals(holder.session, host.lastArgs("requestNewTask")!![0])
    }

    @Test
    fun staleKeepEchoFromReplacedIncarnationIsIgnored() {
        val host = RecordingHost()
        val holder = tempHolder(host)
        holder.keepTemporaryChat()
        // A replacement session projects a different incarnation.
        holder.applyHostSnapshot(
            threadState(holder.session, isTemporary = true, temporaryIncarnationId = "inc-2")
        )
        holder.applyTemporaryKeepOutcome(
            TemporarySessionRef("conv-1", holder.session.sessionEpoch, "inc-1"),
            TemporaryKeepOutcomeUi.TailPending,
        )
        // The echo belongs to the destroyed generation: the control is not
        // flipped to partial-retry for the new session.
        assertEquals(TemporaryKeepStateUi.Saving, holder.temporaryKeepState)
    }

    /* ------------------------- important file: one exact effect ------------------------- */

    @Test
    fun importantFileTapEmitsExactlyOneRealFileIntent() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        val file = ImportantFileUi("src/Main.kt", "Edited")
        holder.applyHostSnapshot(threadState(holder.session, importantFiles = listOf(file)))

        val result = holder.openImportantFile(file)

        assertEquals(ConversationFlowResult.Accepted, result)
        assertEquals(1, host.count("openWorkspaceFile"))
        assertEquals(0, host.count("openMessageAttachment"))
        val args = host.lastArgs("openWorkspaceFile")!!
        assertEquals(holder.session, args[0])
        assertEquals("src/Main.kt", args[1])
    }

    @Test
    fun unknownOrForeignFileIsRejectedWithoutEffects() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(holder.session, importantFiles = listOf(ImportantFileUi("a.txt", "Viewed"))))

        // Not in the projected working set.
        assertEquals(
            ConversationFlowResult.Stale,
            holder.openImportantFile(ImportantFileUi("other.txt", "Viewed")),
        )
        assertEquals(0, host.count("openWorkspaceFile"))

        // A FOREIGN-epoch projection is IGNORED: it can neither overwrite the
        // current working set nor add a file the host never projected here.
        // The contract under test is that the stale page is dropped, so the
        // retained snapshot STILL governs (a.txt valid) and the foreign-only
        // file (foreign.txt) is not present -> Stale, zero effects.
        val foreignEpoch = holder.session.sessionEpoch + 3
        holder.applyHostSnapshot(
            threadState(
                ConversationSessionToken("conv-1", foreignEpoch),
                importantFiles = listOf(ImportantFileUi("foreign.txt", "Viewed")),
            ),
        )
        // The foreign page never replaced the live projection.
        assertEquals(
            ConversationFlowResult.Stale,
            holder.openImportantFile(ImportantFileUi("foreign.txt", "Viewed")),
        )
        assertEquals(0, host.count("openWorkspaceFile"))
        // The live a.txt projection is intact and still opens (proving the
        // foreign snapshot was dropped, NOT that state was cleared).
        assertEquals(
            ConversationFlowResult.Accepted,
            holder.openImportantFile(ImportantFileUi("a.txt", "Viewed")),
        )
        assertEquals(1, host.count("openWorkspaceFile"))
    }

    @Test
    fun afterRebindTheOldConversationFileIntentIsStale() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        val file = ImportantFileUi("src/Main.kt", "Edited")
        holder.applyHostSnapshot(threadState(holder.session, importantFiles = listOf(file)))

        holder.rebind("conv-2")
        val result = holder.openImportantFile(file)

        assertTrue(result is ConversationFlowResult.Rejected)
        assertEquals(0, host.count("openWorkspaceFile"))
        assertEquals("conv-2", holder.conversationId)
    }
}
