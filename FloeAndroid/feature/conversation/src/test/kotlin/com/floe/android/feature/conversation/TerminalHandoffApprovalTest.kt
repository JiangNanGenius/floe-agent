// SPDX-License-Identifier: MPL-2.0
//
// Explicit interactive-terminal → model handoff presentation tests
// (job-c4dd7334fa5341d2, Main ruling 2026-10-28).
//
// Contract pinned here, at the presentation/host seam only (the real close,
// join and engine-release proof are the host's and are covered by
// G04TerminalHostControllerTest):
//  * an ORDINARY allow/deny is byte-identical to before — no consent rides it;
//  * the consent to end a manual terminal rides ONLY an explicit allow, so a
//    denial can never end a terminal and no execution policy, tier or reusable
//    grant can imply one;
//  * the once-only dispatch latch still holds with a consent, and a host
//    refusal of that handoff releases the latch for exactly that card so the
//    user may decide again explicitly — it never re-dispatches on its own;
//  * a refusal for a different card, a stale session or a retired holder
//    publishes nothing;
//  * the conflict fact is host-published, session-fenced and cleared with the
//    terminal, and a card that left the projection takes its refusal with it;
//  * the typed reason token is matched EXACTLY (never by substring) and only
//    the tools that really acquire the single engine slot are gated.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalHandoffApprovalTest {

    private val consent = TerminalHandoffConsentUi(sessionToken = "term-token", nativeEpoch = 7L)

    private fun holderWithApproval(
        host: RecordingHost,
        card: ApprovalCardUi = execShellCard(),
    ): ConversationFlowHolder {
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(holder.session, pendingApprovals = listOf(card)))
        return holder
    }

    /** The reproduction's own shape: ONE `exec.shell` call escalated to a human
     * while this task's interactive terminal holds the engine slot. */
    private fun execShellCard(
        callId: String = "call-1",
        runId: String = "run-1",
        conversationId: String = "conv-1",
        reason: String = ApprovalGrantMapping.TERMINAL_HANDOFF_REASON_TOKEN,
    ) = ApprovalCardUi(
        approvalId = callId,
        runId = runId,
        conversationId = conversationId,
        workspaceId = null,
        toolName = "exec.shell",
        target = ApprovalTargetUi.Local,
        scopeDescription = "local",
        reason = reason,
        riskLabels = setOf("executesLocalCode", "readsFiles", "writesFiles", "networkAccess"),
        isSideEffecting = true,
        requestedAtLabel = "10:00",
        evidenceLines = listOf("command: pwd"),
    )

    private fun request(host: RecordingHost) =
        host.lastArgs("resolveApproval")!![0] as ApprovalDecisionRequest

    /* ------------------------- ordinary path unchanged ------------------------- */

    @Test
    fun anOrdinaryAllowCarriesNoTerminalHandoffConsent() {
        val host = RecordingHost()
        val card = approvalCard(reason = "Needs file writes")
        val holder = holderWithApproval(host, card)

        assertEquals(ConversationFlowResult.Accepted, holder.resolveApproval(card, allow = true))

        val sent = request(host)
        assertNull("an ordinary allow must stay byte-identical", sent.terminalHandoff)
        assertEquals("workspace.writeFile", sent.toolName)
        assertTrue(sent.decision is ApprovalUserDecisionUi.Allow)
    }

    @Test
    fun aDenialCanNeverCarryAConsentToEndATerminal() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffConflict(holder.session, TerminalHandoffConflictUi("term-token", 7L))

        assertEquals(ConversationFlowResult.Accepted,
            holder.resolveApproval(card, allow = false, terminalHandoff = consent))

        val sent = request(host)
        assertEquals(ApprovalUserDecisionUi.Deny, sent.decision)
        assertNull("a denial never ends a terminal", sent.terminalHandoff)
        assertNull(sent.grant)
        assertEquals(ConversationFlowHolder.DENY_REASON, sent.reason)
    }

    /* --------------------------- explicit consent --------------------------- */

    @Test
    fun explicitConsentRidesTheAllowWithTheExactCapturedIdentity() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffConflict(
            holder.session, TerminalHandoffConflictUi(consent.sessionToken, consent.nativeEpoch))

        assertEquals(ConversationFlowResult.Accepted,
            holder.resolveApproval(card, allow = true, terminalHandoff = consent))

        assertEquals(1, host.count("resolveApproval"))
        val sent = request(host)
        assertEquals(consent, sent.terminalHandoff)
        assertEquals("call-1", sent.approvalId)
        assertEquals("run-1", sent.runId)
        assertEquals("conv-1", sent.conversationId)
        assertEquals("exec.shell", sent.toolName)
        // The consent narrows nothing and widens nothing: the tier stays the
        // projected ONCE (single-use, no paths), exactly like an ordinary allow.
        val grant = sent.grant!!
        assertTrue(grant.singleUse)
        assertEquals(emptyList<String>(), grant.paths)
        assertEquals(ApprovalScopeChoiceUi.ONCE,
            (sent.decision as ApprovalUserDecisionUi.Allow).scopeChoice)
    }

    @Test
    fun theDispatchLatchStillHoldsExactlyOnceWithAConsent() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffConflict(
            holder.session, TerminalHandoffConflictUi(consent.sessionToken, consent.nativeEpoch))

        holder.resolveApproval(card, allow = true, terminalHandoff = consent)
        val second = holder.resolveApproval(card, allow = true, terminalHandoff = consent)

        assertTrue(second is ConversationFlowResult.Rejected)
        assertEquals(ConversationRejectedReason.OPERATION_IN_FLIGHT,
            (second as ConversationFlowResult.Rejected).reason)
        assertEquals("the already-proposed command is dispatched once, never twice",
            1, host.count("resolveApproval"))
    }

    /* --------------------------- host refusal --------------------------- */

    @Test
    fun aHostRefusedHandoffReleasesTheLatchForOneExplicitRetryOnly() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffConflict(
            holder.session, TerminalHandoffConflictUi(consent.sessionToken, consent.nativeEpoch))

        holder.resolveApproval(card, allow = true, terminalHandoff = consent)
        assertEquals(1, host.count("resolveApproval"))

        // The host proved the engine was NOT released: nothing was dispatched.
        holder.applyTerminalHandoffRefusal(holder.session, card.key, "engineSlotStillHeld")
        val refusal = holder.terminalHandoffRefusal.value
        assertEquals(card.key, refusal?.approvalKey)
        assertEquals("engineSlotStillHeld", refusal?.code)

        // The card stays actionable: ONE more explicit decision is allowed, and
        // only because the user made it — nothing retried by itself.
        assertEquals(ConversationFlowResult.Accepted,
            holder.resolveApproval(card, allow = true, terminalHandoff = consent))
        assertEquals(2, host.count("resolveApproval"))
        assertNull("a fresh decision supersedes the previous refusal",
            holder.terminalHandoffRefusal.value)

        // And the latch re-arms immediately.
        assertTrue(holder.resolveApproval(card, allow = true, terminalHandoff = consent)
            is ConversationFlowResult.Rejected)
        assertEquals(2, host.count("resolveApproval"))
    }

    @Test
    fun aRefusalForAnotherCardNeverReleasesThisLatch() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)

        holder.resolveApproval(card, allow = true, terminalHandoff = consent)
        holder.applyTerminalHandoffRefusal(holder.session, "run-1/call-other", "staleCapture")

        assertEquals("run-1/call-other", holder.terminalHandoffRefusal.value?.approvalKey)
        assertTrue(holder.resolveApproval(card, allow = true, terminalHandoff = consent)
            is ConversationFlowResult.Rejected)
        assertEquals(1, host.count("resolveApproval"))
    }

    @Test
    fun aRefusalForACardThatLeftTheProjectionIsDroppedWithIt() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffRefusal(holder.session, card.key, "closeNotSettled")
        assertEquals(card.key, holder.terminalHandoffRefusal.value?.approvalKey)

        // The approval resolved/expired host-side and left the projection.
        holder.applyHostSnapshot(threadState(holder.session, pendingApprovals = emptyList()))
        assertNull("a stale refusal must not survive its card",
            holder.terminalHandoffRefusal.value)
    }

    @Test
    fun dismissClearsTheRefusalWithoutAnyEffect() {
        val host = RecordingHost()
        val card = execShellCard()
        val holder = holderWithApproval(host, card)
        holder.applyTerminalHandoffRefusal(holder.session, card.key, "cancelled")
        holder.dismissTerminalHandoffRefusal()
        assertNull(holder.terminalHandoffRefusal.value)
        assertEquals(0, host.count("resolveApproval"))
    }

    /* ----------------------- publication fences ----------------------- */

    @Test
    fun aStaleSessionOrRetiredHolderPublishesNothing() {
        val host = RecordingHost()
        val holder = holderWithApproval(host, execShellCard())
        val stale = ConversationSessionToken("conv-1", holder.session.sessionEpoch + 1)
        val other = ConversationSessionToken("conv-2", holder.session.sessionEpoch)

        holder.applyTerminalHandoffConflict(stale, TerminalHandoffConflictUi("term-x", 9L))
        holder.applyTerminalHandoffConflict(other, TerminalHandoffConflictUi("term-x", 9L))
        assertNull(holder.terminalHandoffConflict.value)

        holder.applyTerminalHandoffRefusal(stale, "run-1/call-1", "engineSlotStillHeld")
        holder.applyTerminalHandoffRefusal(other, "run-1/call-1", "engineSlotStillHeld")
        assertNull(holder.terminalHandoffRefusal.value)

        holder.retireForNavigation()
        holder.applyTerminalHandoffConflict(holder.session, TerminalHandoffConflictUi("term-x", 9L))
        holder.applyTerminalHandoffRefusal(holder.session, "run-1/call-1", "engineSlotStillHeld")
        assertNull(holder.terminalHandoffConflict.value)
        assertNull(holder.terminalHandoffRefusal.value)
    }

    @Test
    fun theConflictFactIsClearedWithTheTerminalAndTakesAPendingRefusalWithIt() {
        val host = RecordingHost()
        val holder = holderWithApproval(host, execShellCard())
        holder.applyTerminalHandoffConflict(
            holder.session, TerminalHandoffConflictUi("term-token", 7L))
        assertEquals("term-token", holder.terminalHandoffConflict.value?.sessionToken)
        // Idempotent republish of the same truth.
        holder.applyTerminalHandoffConflict(
            holder.session, TerminalHandoffConflictUi("term-token", 7L))
        assertEquals("term-token", holder.terminalHandoffConflict.value?.sessionToken)

        holder.applyTerminalHandoffRefusal(holder.session, "run-1/call-1", "closeTimedOut")
        // The terminal is gone: the conflict and the refusal about ending it
        // both stop describing anything actionable.
        holder.applyTerminalHandoffConflict(holder.session, null)
        assertNull(holder.terminalHandoffConflict.value)
        assertNull(holder.terminalHandoffRefusal.value)
    }

    /* ------------------------- pure mapping ------------------------- */

    @Test
    fun theConflictTokenIsMatchedExactlyAndNeverBySubstring() {
        val token = ApprovalGrantMapping.TERMINAL_HANDOFF_REASON_TOKEN
        assertTrue(ApprovalGrantMapping.terminalHandoffConflict(token))
        for (other in listOf(
            "", "Needs file writes", "gate: catastrophic command",
            "prefix-$token", "$token-suffix", "linuxEngineSlotHeld",
            token.uppercase(), " $token",
        )) {
            assertFalse("'$other' must not be read as the typed conflict",
                ApprovalGrantMapping.terminalHandoffConflict(other))
        }
    }

    @Test
    fun onlySlotAcquiringToolsAreEverGated() {
        assertTrue(ApprovalGrantMapping.acquiresLinuxEngineSlot("exec.shell"))
        assertTrue(ApprovalGrantMapping.acquiresLinuxEngineSlot("shell.open"))
        for (name in listOf(
            "shell.exchange", "shell.close", "shell.signal", "jobs.submit",
            "workspace.writeFile", "web.fetch", "skill.create", "",
        )) {
            assertFalse(name, ApprovalGrantMapping.acquiresLinuxEngineSlot(name))
        }
    }

    @Test
    fun theTypedTokenIsNeverRenderedAsProseAndStaysOpaque() {
        // The card replaces the token with its own localized copy, so the
        // identifier must stay a single opaque token with no prose, separators
        // or user-facing punctuation.
        val token = ApprovalGrantMapping.TERMINAL_HANDOFF_REASON_TOKEN
        assertTrue(token.all { it.isLetterOrDigit() })
        assertEquals("linuxEngineSlotHeldByOwnInteractiveTerminal", token)
    }
}
