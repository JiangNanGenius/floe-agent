// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation-rule tests extracted from the original sources
// (RunStateLocalizer, TokenUnitFormatter, ToolCallCardView statuses,
// StepGroupView pairing, ThreadRunScopedResolution, ApprovalGrantMapping,
// PendingInputQueueView, LatestMessageFollowState, PlanModeReconciler,
// TaskBulk* rules, CredentialMessagePart). No Compose, no device.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationPresentationLogicTest {

    /* ------------------------------- run state ------------------------------- */

    @Test
    fun runStateMappingKeepsTheFrozenTable() {
        assertEquals("state_streaming", FloeRunStateLocalizer.titleKey("streamingModel"))
        assertEquals("state_round_ended", FloeRunStateLocalizer.titleKey("completed"))
        assertEquals("state_stopped", FloeRunStateLocalizer.titleKey("cancelled"))
        assertEquals("state_unknown", FloeRunStateLocalizer.titleKey("someFutureState"))
        assertEquals(FloeStateColorRole.SUCCESS, FloeRunStateLocalizer.colorRole("completed"))
        assertEquals(FloeStateColorRole.DESTRUCTIVE, FloeRunStateLocalizer.colorRole("failed"))
        assertEquals(FloeStateColorRole.PENDING, FloeRunStateLocalizer.colorRole("waitingApproval"))
        assertEquals(FloeStateColorRole.UNKNOWN, FloeRunStateLocalizer.colorRole("mystery"))
    }

    @Test
    fun errorEndsLoadingImmediatelyAndCheckpointedIsTerminal() {
        assertTrue(FloeRunStateLocalizer.isLoading("streamingModel", hasError = false))
        assertFalse(FloeRunStateLocalizer.isLoading("streamingModel", hasError = true))
        assertFalse(FloeRunStateLocalizer.isLoading("waitingApproval", hasError = false))
        assertTrue(FloeRunStateLocalizer.isTerminal("checkpointed"))
        assertTrue(FloeRunStateLocalizer.isTerminal("completed"))
        assertFalse(FloeRunStateLocalizer.isTerminal("executingTool"))
        assertEquals("attention_warning", FloeRunStateLocalizer.attentionSymbolKey("checkpointed"))
        assertNull(FloeRunStateLocalizer.attentionSymbolKey("streamingModel"))
        assertEquals("state_round_ended", FloeRunStateLocalizer.terminalTitleKey("endTurn"))
        assertEquals("state_truncated", FloeRunStateLocalizer.terminalTitleKey("maxTokens"))
        assertEquals("state_unknown", FloeRunStateLocalizer.terminalTitleKey("wireOnlyName"))
    }

    /* --------------------------------- tokens -------------------------------- */

    @Test
    fun tokenFormatterScalesWithoutTrailingZeroes() {
        assertEquals("999", TokenUnitFormatter.format(999))
        assertEquals("1K", TokenUnitFormatter.format(1_000))
        assertEquals("1.5K", TokenUnitFormatter.format(1_500))
        assertEquals("1M", TokenUnitFormatter.format(1_000_000))
        assertEquals("1.2M", TokenUnitFormatter.format(1_240_000))
        assertEquals("2B", TokenUnitFormatter.format(2_000_000_000))
    }

    @Test
    fun usageComputedValuesClampAndReportHonestly() {
        val usage = UsageUi(
            inputTokens = 100,
            outputTokens = 50,
            contextTokens = 90,
            contextWindowTokens = 100,
            isEstimatedLive = true,
            cacheReadTokens = 50,
        )
        assertEquals(200, usage.totalTokens)
        assertEquals(0.9, usage.contextFraction, 0.0001)
        assertEquals(50.0 / 150.0, usage.cacheHitRate!!, 0.0001)
        val empty = UsageUi(0, 0, 0, 0, isEstimatedLive = false)
        assertEquals(0.0, empty.contextFraction, 0.0)
        assertNull(empty.cacheHitRate)
    }

    /* ------------------------------ tool statuses ----------------------------- */

    @Test
    fun toolStatusMappingMatchesToolCallCardView() {
        assertEquals("tool_status_succeeded", FloeToolStatusPresentation.forStatus("ok").titleKey)
        assertEquals("tool_status_needs_user", FloeToolStatusPresentation.forStatus("needsUser").titleKey)
        assertEquals(FloeStateColorRole.DESTRUCTIVE, FloeToolStatusPresentation.forStatus("denied").colorRole)
        assertEquals("tool_status_unknown", FloeToolStatusPresentation.forStatus("whatever").titleKey)
        assertTrue(FloeToolStatusPresentation.shouldAutoExpand("failed"))
        assertTrue(FloeToolStatusPresentation.shouldAutoExpand("expired"))
        assertFalse(FloeToolStatusPresentation.shouldAutoExpand("ok"))
    }

    /* ---------------------------- step-group pairing ---------------------------- */

    private fun toolEvent(
        id: String,
        kind: RunEventKindUi,
        callId: String,
        status: String = "ok",
        approvalSummary: String? = null,
        harnessSuppressed: Boolean = false,
    ) = RunEventUi(
        id = id,
        runId = "run-1",
        sequence = 1,
        kind = kind,
        timeLabel = "10:00",
        tool = ToolEventProjectionUi(
            callId = callId,
            toolName = "workspace.readFile",
            statusRaw = status,
            resultSummary = "content",
            approvalSummary = approvalSummary,
            harnessSuppressed = harnessSuppressed,
        ),
    )

    @Test
    fun pairingFoldsResultsAndDetachedApprovalsIntoTheRequestCard() {
        val request = toolEvent("e1", RunEventKindUi.TOOL_REQUEST, "call-1")
        val result = toolEvent("e2", RunEventKindUi.TOOL_RESULT, "call-1")
        val approval = toolEvent("e3", RunEventKindUi.APPROVAL, "call-1", approvalSummary = "allowed once")
        val events = listOf(request, result, approval)

        assertEquals(setOf("call-1"), StepGroupPairing.requestCallIds(events))
        assertTrue(StepGroupPairing.isPairedResult(result, setOf("call-1")))
        assertEquals("ok", StepGroupPairing.requestStatus(request, StepGroupPairing.resultsByCall(events), false, isLive = true))
        val displayed = StepGroupPairing.displayedEvents(events)
        assertEquals(listOf("e1"), displayed.map { it.id })
        assertEquals(mapOf("call-1" to "allowed once"), StepGroupPairing.approvalSummariesByCall(events))
    }

    @Test
    fun standaloneResultWithoutRequestStaysVisible() {
        val result = toolEvent("e2", RunEventKindUi.TOOL_RESULT, "call-9")
        assertEquals(listOf("e2"), StepGroupPairing.displayedEvents(listOf(result)).map { it.id })
        assertEquals("failed", StepGroupPairing.requestStatus(toolEvent("e1", RunEventKindUi.TOOL_REQUEST, "call-1"), emptyMap(), false, isLive = false))
    }

    @Test
    fun groupStatePrioritiesApprovalThenReviewThenRunning() {
        assertEquals("group_waiting_confirmation", StepGroupPairing.groupStateKey(2, 2, 1, true))
        assertEquals(FloeStateColorRole.PENDING, StepGroupPairing.groupStateColorRole(2, 2, 1))
        assertEquals("group_one_needs_review", StepGroupPairing.groupStateKey(1, 1, 0, true))
        assertEquals("group_items_running", StepGroupPairing.groupStateKey(0, 2, 0, true))
        assertEquals("group_view_run_records", StepGroupPairing.groupStateKey(0, 0, 0, false))
    }

    @Test
    fun disclosureSeedsOnlyOncePerGroup() {
        assertTrue(StepGroupDisclosurePolicy.initiallyExpanded(isLatest = true, isLive = false, hasError = false, hasPendingApproval = false))
        assertFalse(StepGroupDisclosurePolicy.initiallyExpanded(isLatest = false, isLive = false, hasError = false, hasPendingApproval = false))
        assertTrue(StepGroupDisclosurePolicy.initiallyExpanded(isLatest = false, isLive = false, hasError = true, hasPendingApproval = false))
    }

    /* ------------------------ run-scoped child/decision ------------------------ */

    @Test
    fun childAndDecisionResolutionIsScopedToTheRun() {
        val children = listOf(
            ChildRunUi("child-a", "run-1", "call-1", "working", "Working", false, "A", null, "10:00"),
            ChildRunUi("child-b", "run-2", "call-1", "done", "Done", true, "B", null, "10:01"),
        )
        assertEquals("child-a", ThreadRunScopedResolution.child("call-1", "run-1", children)?.id)
        assertEquals("child-b", ThreadRunScopedResolution.child("call-1", "run-2", children)?.id)
        assertNull(ThreadRunScopedResolution.child("", "run-1", children))

        val decisions = listOf(
            ToolDecisionUi("d1", "call-1", "run-1", "proposal-1", "applied", "Applied in run 1"),
            ToolDecisionUi("d2", "call-1", "run-2", "proposal-2", "rejected", "Rejected in run 2"),
            ToolDecisionUi("legacy", "call-1", null, "proposal-3", "applied", "Legacy note"),
        )
        assertEquals(listOf("Applied in run 1"), ThreadRunScopedResolution.decisionSummaries("call-1", "run-1", decisions))
        assertEquals(listOf("Rejected in run 2"), ThreadRunScopedResolution.decisionSummaries("call-1", "run-2", decisions))
        assertEquals(listOf("Legacy note"), ThreadRunScopedResolution.decisionSummaries("call-1", "run-9", decisions))
    }

    /* ------------------------------ approval tiers ---------------------------- */

    @Test
    fun grantTiersNarrowOnlyWhatAnAllowRemembers() {
        val local = ApprovalTargetUi.Local
        val hostPath = ApprovalTargetUi.HostPath("host-1", "/srv/data")
        assertEquals(
            ApprovalGrantUi("t", null, emptyList(), singleUse = true),
            ApprovalGrantMapping.grant("t", local, "local", ApprovalScopeChoiceUi.ONCE),
        )
        assertEquals(
            ApprovalGrantUi("t", null, listOf("local"), singleUse = false),
            ApprovalGrantMapping.grant("t", local, "local", ApprovalScopeChoiceUi.PROJECT),
        )
        assertEquals(
            ApprovalGrantUi("t", "host-1", emptyList(), singleUse = false),
            ApprovalGrantMapping.grant("t", hostPath, "host-1 · /srv/data", ApprovalScopeChoiceUi.HOST),
        )
        assertEquals(
            ApprovalGrantUi("t", "host-1", listOf("/srv/data"), singleUse = false),
            ApprovalGrantMapping.grant("t", hostPath, "host-1 · /srv/data", ApprovalScopeChoiceUi.TASK),
        )
        assertTrue(ApprovalGrantMapping.isGateStopped("catastrophic gate stop"))
        assertFalse(ApprovalGrantMapping.isGateStopped("ordinary approval"))
        assertTrue(ApprovalGrantMapping.requiresEvidence(true, setOf("writesFiles")))
        assertTrue(ApprovalGrantMapping.requiresEvidence(false, setOf("executesRemoteCommand")))
        assertFalse(ApprovalGrantMapping.requiresEvidence(true, setOf("readsFiles")))
        assertEquals("risk_writes_files", ApprovalGrantMapping.riskLabelKey("writesFiles"))
        assertEquals("", ApprovalGrantMapping.riskLabelKey("unknownLabel"))
        assertTrue(ApprovalGrantMapping.isSkillCreation("skill.create"))
    }

    /* ------------------------------- pending queue ---------------------------- */

    @Test
    fun queueReorderOnlyTouchesTheQueuedSliceAndEnforcesBounds() {
        val inputs = listOf(
            pendingInput(id = "a", status = PendingInputStatusUi.QUEUED),
            pendingInput(id = "b", status = PendingInputStatusUi.PROMOTING),
            pendingInput(id = "c", status = PendingInputStatusUi.QUEUED),
        )
        assertEquals(listOf("c", "a"), PendingInputQueueLogic.reorderQueued(inputs, "a", 1))
        assertNull(PendingInputQueueLogic.reorderQueued(inputs, "a", -1))
        assertNull(PendingInputQueueLogic.reorderQueued(inputs, "b", 1))
        assertTrue(PendingInputQueueLogic.canPromoteToSteer(true, PendingInputStatusUi.QUEUED))
        assertFalse(PendingInputQueueLogic.canPromoteToSteer(false, PendingInputStatusUi.QUEUED))
        assertFalse(PendingInputQueueLogic.canPromoteToSteer(true, PendingInputStatusUi.STEER_PENDING))
    }

    @Test
    fun queueDisplayPrefersTrustedSummaryThenVerbatim() {
        val trusted = pendingInput().copy(trustedSummary = "Decision recorded")
        assertEquals("Decision recorded", PendingInputQueueLogic.displayText(trusted))
        assertEquals("follow up", PendingInputQueueLogic.displayText(pendingInput()))
        assertEquals("queue_status_sent", PendingInputQueueLogic.statusTitleKey(PendingInputStatusUi.CONSUMED))
    }

    /* ------------------------------- plan mode -------------------------------- */

    @Test
    fun planModeRestoresOnlyWhileTheSameRevisionAwaitsReview() {
        val plan = PlanUi(
            id = "plan-1",
            title = "Plan",
            statusRaw = "ready",
            isDecisionComplete = true,
            executionRecommendation = PlanRecommendationUi.NORMAL,
            recommendationReason = null,
            revisionNumber = 4,
            revision = com.floe.android.contracts.Revision("plan-1", "digest-4"),
        )
        assertEquals(AgentExecutionModeUi.PLAN, PlanModeReconciler.reconcile(plan, null, AgentExecutionModeUi.AGENT))
        // An explicit choice at the same revision is respected.
        assertEquals(AgentExecutionModeUi.CHAT, PlanModeReconciler.reconcile(plan, 4, AgentExecutionModeUi.CHAT))
        assertEquals(4, PlanModeReconciler.onExplicitModeSwitch(plan))
        assertEquals(null, PlanModeReconciler.activePlanRevision(plan.copy(statusRaw = "accepted")))
    }

    /* ------------------------------ model identity ---------------------------- */

    @Test
    fun modelIdentityFieldsStayDistinct() {
        val model = ModelOptionUi("uuid-1", "wire/gpt-5", "GPT-5", "provider-1", "Provider", true)
        assertEquals("uuid-1", model.modelId)
        assertEquals("wire/gpt-5", model.remoteModelId)
        assertEquals("GPT-5", model.displayName)
        assertTrue(model.modelId != model.remoteModelId)
    }

    /* -------------------------------- send gate -------------------------------- */

    @Test
    fun sendPolicyGatesBlankMissingProviderAndTemporaryMode() {
        assertFalse(ThreadSendPolicy.canSend(false, true, "   "))
        assertFalse(ThreadSendPolicy.canSend(true, true, "hi"))
        assertFalse(ThreadSendPolicy.canSend(false, false, "hi"))
        assertTrue(ThreadSendPolicy.canSend(false, true, "hi"))
        assertEquals(AgentExecutionModeUi.AGENT, ThreadSendPolicy.effectiveAgentMode(true, AgentExecutionModeUi.PLAN))
        assertEquals(AgentExecutionModeUi.PLAN, ThreadSendPolicy.effectiveAgentMode(false, AgentExecutionModeUi.PLAN))
        val staged = listOf(stagedAttachment())
        assertTrue(ThreadSendPolicy.launchAttachments(true, staged).isEmpty())
        assertEquals(staged, ThreadSendPolicy.launchAttachments(false, staged))
    }

    @Test
    fun sendOriginGateOnlyAllowsTheExactIncarnationOrItsPromotion() {
        assertTrue(TemporarySendOriginGate.allowsDraftMutation(null, "x", true, "conv-1", null))
        assertTrue(TemporarySendOriginGate.allowsDraftMutation("inc-1", "inc-1", true, "conv-1", null))
        assertFalse(TemporarySendOriginGate.allowsDraftMutation("inc-1", "inc-2", true, "conv-1", null))
        assertFalse(TemporarySendOriginGate.allowsDraftMutation("inc-1", null, true, "conv-1", "other"))
        assertTrue(TemporarySendOriginGate.allowsDraftMutation("inc-1", null, false, "conv-1", "conv-1"))
    }

    /* ------------------------------- send commit ------------------------------ */

    @Test
    fun sendCommitClearsOnlyTheConsumedGeneration() {
        val staged = listOf(stagedAttachment(id = "a1"), stagedAttachment(id = "a2"))
        val commit = ComposerSendCommit(
            conversationId = "conv-1",
            sentText = "A",
            sentAttachments = listOf(staged[0]),
            editorGeneration = 7,
            temporaryIncarnationId = null,
        )
        assertEquals("", commit.draftAfterSuccess("A", 7))
        // A → B → A: generation changed, so a new A is never erased.
        assertEquals("A", commit.draftAfterSuccess("A", 9))
        // Only the sent ref is consumed; a mid-flight file survives.
        assertEquals(listOf("a2"), commit.attachmentsAfterSuccess(staged).map { it.id })
        assertTrue(commit.editorStillConsumed(7))
        assertFalse(commit.editorStillConsumed(8))
    }

    /* ------------------------------- scroll follow ---------------------------- */

    @Test
    fun followIntentDistinguishesContentGrowthFromUserScrollAway() {
        val follow = ConversationFollowState()
        follow.observe(offset = 0.0, bottomDistance = 0.0, userScrolling = false)
        assertTrue(follow.followsLatest)

        // User scrolls up away from the bottom: stops following.
        follow.observe(offset = 100.0, bottomDistance = 0.0, userScrolling = false)
        follow.observe(offset = 50.0, bottomDistance = 300.0, userScrolling = true)
        assertFalse(follow.followsLatest)
        assertTrue(follow.isAwayFromLatest)

        // Returning to the bottom re-enables following.
        follow.observe(offset = 80.0, bottomDistance = 0.0, userScrolling = true)
        assertTrue(follow.followsLatest)
        assertFalse(follow.isAwayFromLatest)

        // Content growth alone (no scroll) never breaks follow intent.
        follow.observe(offset = 80.0, bottomDistance = 0.0, userScrolling = false)
        assertTrue(follow.followsLatest)
        follow.returnToLatest()
        assertTrue(follow.followsLatest)
    }

    /* --------------------------------- search --------------------------------- */

    @Test
    fun titleSearchIsLocalAndContentHitsComeFromTheHost() {
        assertTrue(ConversationSearchRules.titleMatches("Grocery List", "grocery"))
        assertFalse(ConversationSearchRules.titleMatches("Grocery List", "milk"))
        val item = ConversationListItemUi("c1", "项目计划", "10:00", null, false, null)
        assertTrue(ConversationSearchRules.isVisible(item, false, "计划", emptyMap()))
        assertTrue(ConversationSearchRules.isVisible(item, false, "nothing", mapOf("c1" to "片段")))
        assertFalse(ConversationSearchRules.isVisible(item, true, "", emptyMap()))
        assertTrue(ConversationSearchRules.acceptsSearchPage(3, 3))
        assertFalse(ConversationSearchRules.acceptsSearchPage(3, 2))
    }

    /* ------------------------------- bulk rules ------------------------------- */

    @Test
    fun bulkOutcomeResolutionMatchesTheSwiftTable() {
        assertTrue(BulkItemOutcomeUi.Archived.isResolved)
        assertTrue(BulkItemOutcomeUi.Deleted.isResolved)
        assertTrue(BulkItemOutcomeUi.Skipped(BulkSkipReasonUi.NOT_MANAGED_HERE).isResolved)
        assertFalse(BulkItemOutcomeUi.Failed("x").isResolved)
        assertFalse(BulkItemOutcomeUi.Unverified("x").isResolved)
        assertFalse(BulkItemOutcomeUi.NotAttempted.isResolved)
        assertEquals("x", BulkItemOutcomeUi.Unverified("x").issueText)
        assertNull(BulkItemOutcomeUi.Archived.issueText)
    }

    @Test
    fun bulkSelectionRulesAreSymmetricAndVisibleScoped() {
        assertEquals(setOf("a"), TaskBulkSelectionRules.toggled(emptySet(), "a"))
        assertEquals(emptySet<String>(), TaskBulkSelectionRules.toggled(setOf("a"), "a"))
        assertEquals(setOf("a", "b"), TaskBulkSelectionRules.selectionAfterSelectAllToggle(setOf("a"), setOf("a", "b")))
        // Deselect happens over the VISIBLE SLICE only: selection {a,b} with
        // visible {a} toggles "a" off and keeps the off-screen selection {b}.
        assertEquals(setOf("b"), TaskBulkSelectionRules.selectionAfterSelectAllToggle(setOf("a", "b"), setOf("a")))
        assertEquals(emptySet<String>(), TaskBulkSelectionRules.selectionAfterSelectAllToggle(setOf("a", "b"), setOf("a", "b")))
        assertEquals(setOf("a"), TaskBulkSelectionRules.pruned(setOf("a", "b"), setOf("a", "c")))
        assertTrue(TaskBulkSelectionRules.allVisibleSelected(setOf("a"), setOf("a")))
        assertFalse(TaskBulkSelectionRules.allVisibleSelected(emptySet(), emptySet()))
    }

    /* --------------------------- credentials & preview ------------------------- */

    @Test
    fun credentialMarkersParseIntoCardSegments() {
        val token = "123e4567-e89b-12d3-a456-426614174000"
        val parts = CredentialTextParser.parse("Use \u27e8credential:$token\u27e9 now")
        assertEquals(3, parts.size)
        assertFalse(parts[0].isCredential)
        assertEquals("Use ", parts[0].value)
        assertTrue(parts[1].isCredential)
        // The tail keeps its leading space VERBATIM: segment splitting must
        // never drop or trim user content.
        assertEquals(" now", parts[2].value)

        val malformed = CredentialTextParser.parse("\u27e8credential:not-a-uuid\u27e9")
        assertEquals(1, malformed.size)
        assertFalse(malformed[0].isCredential)
    }

    @Test
    fun reasoningPreviewKeepsTwoRenderedLines() {
        assertEquals("first second", preview("first\n\nsecond\nthird"))
        assertEquals("", preview("\n \n"))
    }

    @Test
    fun goalLineSplittingTrimsAndDropsEmpties() {
        assertEquals(listOf("a", "b"), splitGoalLines("a\n\n  b  \n"))
    }
}
