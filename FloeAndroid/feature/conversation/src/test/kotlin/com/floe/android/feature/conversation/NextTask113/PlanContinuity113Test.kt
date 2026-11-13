// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation.NextTask113

import com.floe.android.contracts.Revision
import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.ChecklistPresentationRules
import com.floe.android.feature.conversation.ChecklistStepStatusUi
import com.floe.android.feature.conversation.ChecklistStepUi
import com.floe.android.feature.conversation.ChecklistUi
import com.floe.android.feature.conversation.PlanExecutionHandoffRules
import com.floe.android.feature.conversation.PlanPresentationRules
import com.floe.android.feature.conversation.PlanUi
import com.floe.android.feature.conversation.RunRowUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlanContinuity113Test {
    private val planID = "2a9bb479-f614-473c-b8e4-008e2dfe8222"
    private val plan = PlanUi(
        id = planID,
        title = "Review first",
        statusRaw = "ready",
        isDecisionComplete = true,
        executionRecommendation = null,
        recommendationReason = null,
        revisionNumber = 4,
        revision = Revision("plan.$planID", "4"),
        digest = "digest-4",
    )
    private val marker = "$planID:4"

    private fun run(
        id: String,
        state: String,
        mode: String?,
    ) = RunRowUi(id, state, null, "", mode)

    @Test fun freshPlanPresentsOnceThenAgentAndKeepsExplicitPlan() {
        val fresh = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = null, lastPresentedPlanRevision = null,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.AGENT, fresh.mode)
        assertEquals(marker, fresh.acknowledgement)
        assertTrue(fresh.shouldPersist)
        assertFalse(fresh.needsRepairNotice)

        // Same revision, explicit Plan: later snapshots/reopen keep Plan.
        val explicit = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "plan", lastPresentedPlanRevision = marker,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.PLAN, explicit.mode)
        assertFalse(explicit.shouldPersist)

        val explicitAgain = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "agent", lastPresentedPlanRevision = marker,
            currentMode = AgentExecutionModeUi.PLAN, hasResolvedPreferredMode = true,
        )
        assertEquals(AgentExecutionModeUi.PLAN, explicitAgain.mode)
        assertFalse(explicitAgain.shouldPersist)
    }

    @Test fun newerPlanRevisionIsANewPresentationAndOldRevisionIsNot() {
        val revisited = PlanPresentationRules.decide(
            plan = plan.copy(revisionNumber = 5, revision = Revision("plan.$planID", "5")),
            storedModeRaw = "plan", lastPresentedPlanRevision = marker,
            currentMode = AgentExecutionModeUi.PLAN, hasResolvedPreferredMode = true,
        )
        assertEquals(AgentExecutionModeUi.AGENT, revisited.mode)
        assertEquals("$planID:5", revisited.acknowledgement)

        val same = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "plan", lastPresentedPlanRevision = marker,
            currentMode = AgentExecutionModeUi.PLAN, hasResolvedPreferredMode = true,
        )
        assertEquals(AgentExecutionModeUi.PLAN, same.mode)
        assertFalse(same.shouldPersist)
    }

    @Test fun planPresentationNeverPromotesChatGoalOrCorruptMode() {
        val chat = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "chat", lastPresentedPlanRevision = null,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.CHAT, chat.mode)
        assertEquals(marker, chat.acknowledgement)

        val goal = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "goal", lastPresentedPlanRevision = null,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.GOAL, goal.mode)

        val corrupt = PlanPresentationRules.decide(
            plan = plan, storedModeRaw = "unrecognized-mode", lastPresentedPlanRevision = null,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.CHAT, corrupt.mode)
        assertTrue(corrupt.needsRepairNotice)
        assertTrue(corrupt.shouldPersist)
    }

    @Test fun legacyAbsentModeKeepsAgentAndAcknowledgesPlanWithoutExecutingIt() {
        val decision = PlanPresentationRules.decide(
            plan = null, storedModeRaw = null, lastPresentedPlanRevision = marker,
            currentMode = AgentExecutionModeUi.AGENT, hasResolvedPreferredMode = false,
        )
        assertEquals(AgentExecutionModeUi.AGENT, decision.mode)
        assertEquals(marker, decision.acknowledgement)
        assertFalse(decision.shouldPersist)
        assertNull(PlanPresentationRules.presentedPlanKey(
            plan?.copy(statusRaw = "accepted")))
    }

    @Test fun explicitSelectionPinsOnlyTheCurrentPresentedRevision() {
        assertEquals(marker, PlanPresentationRules.explicitSelectionAcknowledgement(plan, null))
        assertEquals("old",
            PlanPresentationRules.explicitSelectionAcknowledgement(null, "old"))
    }

    @Test fun checklistStripBelongsToTheSelectedActiveRoundOnly() {
        val checklist = ChecklistUi(
            title = "Work", currentStepTitle = "one", progressSummary = "0/2",
            steps = listOf(ChecklistStepUi("a", "one", ChecklistStepStatusUi.IN_PROGRESS, emptyList())),
            runId = "run-a", revision = 1,
        )
        assertTrue(ChecklistPresentationRules.shouldPresent(checklist, "run-a", "streamingModel"))
        assertFalse(ChecklistPresentationRules.shouldPresent(checklist, "run-b", "streamingModel"))
        assertFalse(ChecklistPresentationRules.shouldPresent(checklist, "run-a", "completed"))
        assertFalse(ChecklistPresentationRules.shouldPresent(checklist, "run-a", "failed"))
        assertFalse(ChecklistPresentationRules.shouldPresent(
            checklist.copy(isFinished = true), "run-a", "streamingModel"))
        assertFalse(ChecklistPresentationRules.shouldPresent(
            checklist.copy(wasReset = true), "run-a", "streamingModel"))
    }

    @Test fun handoffStopsOnlyLivePlanOwnersAndRefusesOtherLiveWork() {
        assertTrue(PlanExecutionHandoffRules.decide(emptyList()) is
            PlanExecutionHandoffRules.Decision.Proceed)
        val terminalOldPlan = PlanExecutionHandoffRules.decide(listOf(
            run("old", "completed", "plan"),
            run("failed-old", "failed", "plan"),
        ))
        assertTrue(terminalOldPlan is PlanExecutionHandoffRules.Decision.Proceed)

        val livePlan = PlanExecutionHandoffRules.decide(listOf(
            run("live-plan", "streamingModel", "plan"),
            run("old", "completed", "plan"),
        ))
        assertEquals(
            listOf("live-plan"),
            (livePlan as PlanExecutionHandoffRules.Decision.Quiesce).planRunIDs)

        assertTrue(PlanExecutionHandoffRules.decide(listOf(
            run("agent", "streamingModel", "agent"))) is
            PlanExecutionHandoffRules.Decision.RefuseBusy)
        assertTrue(PlanExecutionHandoffRules.decide(listOf(
            run("goal", "executingTool", "goal"))) is
            PlanExecutionHandoffRules.Decision.RefuseBusy)
        assertTrue(PlanExecutionHandoffRules.decide(listOf(
            run("legacy", "preparing", null))) is
            PlanExecutionHandoffRules.Decision.RefuseBusy)
        assertTrue(PlanExecutionHandoffRules.decide(listOf(
            run("plan", "streamingModel", "plan"),
            run("agent", "preparing", "agent"))) is
            PlanExecutionHandoffRules.Decision.RefuseBusy)
    }

    @Test fun acceptRequiresTheExactPresentedIdentityAndDigest() {
        assertTrue(PlanExecutionHandoffRules.matchesPresentedPlan(
            plan, planID, 4, "ready", "digest-4"))
        assertFalse(PlanExecutionHandoffRules.matchesPresentedPlan(
            plan, planID, 5, "ready", "digest-4"))
        assertFalse(PlanExecutionHandoffRules.matchesPresentedPlan(
            plan, planID, 4, "ready", "digest-other"))
        assertFalse(PlanExecutionHandoffRules.matchesPresentedPlan(
            plan, planID, 4, "accepted", "digest-4"))
        assertFalse(PlanExecutionHandoffRules.matchesPresentedPlan(
            plan.copy(digest = null), planID, 4, "ready", "digest-4"))
    }

    @Test fun settlementRequiresEveryPlanOwnerToBecomeTerminal() {
        val rows = listOf(
            run("one", "completed", "plan"),
            run("two", "cancelling", "plan"),
        )
        assertFalse(PlanExecutionHandoffRules.allSettled(rows, listOf("one", "two")))
        assertTrue(PlanExecutionHandoffRules.allSettled(
            listOf(run("one", "completed", "plan"), run("two", "cancelled", "plan")),
            listOf("one", "two")))
        // An unknown id is not settlement proof.
        assertFalse(PlanExecutionHandoffRules.allSettled(rows, listOf("missing")))
    }
}
