// SPDX-License-Identifier: MPL-2.0
//
// Explicit execution-mode provenance on the App wire. AUTHORED, NOT RUN in
// this worker lane (no Gradle/build authority; Main batches the check).
//
// Contract pinned here:
//  * `run.start` gains ONE optional member, `executionMode`, sent ONLY for an
//    explicit CHAT selection. AGENT/PLAN/GOAL keep their original payload
//    bytes (old callers — including the meeting assistant's `run.startTask` —
//    are unchanged), so absence is honest `null` in native storage and is
//    NEVER relabelled as a user-chosen Agent.
//  * explicit CHAT no longer sends an empty `toolCeiling`: ordinary text/voice
//    Chat and Agent use the same task-authorized tool chain. Plan and the
//    separate temporary ceiling keep their own narrowing.
//  * `run.queue` already carries `executionMode`; the durable row now records
//    it as provenance for all four modes.
//  * the session reply's run summaries expose the recorded selection (null for
//    legacy rows), never a defaulted Agent.
package com.floe.android.host

import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.RunLaunchRequest
import com.floe.android.feature.conversation.RunningInputModeUi
import com.floe.android.feature.conversation.RunningInputRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationExecutionModePersistenceTest {

    private fun launch(mode: AgentExecutionModeUi,
                       temporary: String? = null): RunLaunchRequest = RunLaunchRequest(
        conversationId = "11111111-1111-4111-8111-111111111111",
        sessionEpoch = 7L,
        goalText = "probe",
        attachments = emptyList(),
        executionMode = mode,
        modelId = "22222222-2222-4222-8222-222222222222",
        workspaceId = null,
        temporaryIncarnationId = temporary,
        providerId = "33333333-3333-4333-8333-333333333333",
    )

    private fun runningInput(mode: AgentExecutionModeUi): RunningInputRequest =
        RunningInputRequest(
            conversationId = "11111111-1111-4111-8111-111111111111",
            sessionEpoch = 7L,
            expectedRunId = "44444444-4444-4444-8444-444444444444",
            content = "queued probe",
            mode = RunningInputModeUi.QUEUE,
            modelId = "22222222-2222-4222-8222-222222222222",
            workspaceId = null,
            executionMode = mode,
            attachments = emptyList(),
            temporaryIncarnationId = null,
        )

    @Test
    fun explicitChatTravelsAsProvenanceWithoutAnEmptyToolCeiling() {
        val payload = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.CHAT), emptyList())
        assertEquals("chat", payload["mode"]!!.jsonPrimitive.content)
        assertEquals("chat", payload["executionMode"]!!.jsonPrimitive.content)
        assertNull("explicit Chat must keep the task-authorized tool chain",
            payload["toolCeiling"])
        assertEquals(
            setOf("goal", "mode", "providerID", "modelID", "stagedAttachments",
                "executionMode"),
            payload.keys,
        )
    }

    @Test
    fun agentKeepsTheOriginalGrammarAndSendsNoFabricatedSelection() {
        val payload = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.AGENT), emptyList())
        assertEquals("chat", payload["mode"]!!.jsonPrimitive.content)
        assertNull("absence must stay unlabeled, not a chosen Agent",
            payload["executionMode"])
        assertNull(payload["toolCeiling"])
        assertEquals(
            setOf("goal", "mode", "providerID", "modelID", "stagedAttachments"),
            payload.keys,
        )
    }

    @Test
    fun aDurablyStoredAgentSelectionTravelsAsProvenance() {
        // `selectAgentMode` persists the same `TaskContinuityPreferences`
        // record; a real Agent choice therefore has a source to cite, while
        // the untouched default above stays absent.
        val payload = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.AGENT), emptyList(),
            persistedModeRaw = "agent")
        assertEquals("chat", payload["mode"]!!.jsonPrimitive.content)
        assertEquals("agent", payload["executionMode"]!!.jsonPrimitive.content)
    }

    @Test
    fun aStoredModeThatContradictsTheLaunchIsNeverClaimed() {
        // A stale preference can never overwrite the actual launch. The
        // untouched Agent default stays unlabeled when the stored value does
        // not match; no member is invented.
        val agent = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.AGENT), emptyList(),
            persistedModeRaw = "plan")
        assertNull(agent["executionMode"])

        // CHAT is inherently explicit (never the default), so it travels as
        // chat — never as the mismatching stored plan.
        val chat = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.CHAT), emptyList(),
            persistedModeRaw = "plan")
        assertEquals("chat", chat["executionMode"]!!.jsonPrimitive.content)
    }

    @Test
    fun planAndGoalKeepTheirExactSpellingAndNoExtraMember() {
        val plan = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.PLAN), emptyList())
        assertEquals("plan", plan["mode"]!!.jsonPrimitive.content)
        assertNull(plan["executionMode"])

        val goal = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.GOAL), emptyList())
        assertEquals("goal", goal["mode"]!!.jsonPrimitive.content)
        assertNull(goal["executionMode"])
    }

    @Test
    fun temporaryChatIsUntouchedByTheOrdinaryModeMember() {
        // A temporary send keeps its dedicated surface/ceiling: no ordinary
        // provenance member and no ordinary empty ceiling are invented here.
        val payload = ConversationWire.runStartPayload(
            launch(AgentExecutionModeUi.CHAT, temporary = "inc-1"), emptyList())
        assertNull(payload["executionMode"])
        assertNull(payload["toolCeiling"])
    }

    @Test
    fun queueKeepsTheComposerSelectionForAllFourModes() {
        for (mode in AgentExecutionModeUi.entries) {
            val payload = ConversationWire.runningInputPayload(
                runningInput(mode), emptyList())
            assertEquals(mode.swiftRaw,
                payload["executionMode"]!!.jsonPrimitive.content)
            assertEquals("queue", payload["mode"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun sessionRunsDecodeTheRecordedModeAndKeepLegacyAbsence() {
        val reply = ConversationWire.decodeSessionReply(Json.parseToJsonElement("""
            {
              "conversationID": "11111111-1111-4111-8111-111111111111",
              "runs": [
                {
                  "runID": "AAAAAAAA-1111-4111-8111-111111111111",
                  "state": "completed",
                  "startedAt": "2026-11-17T00:00:00.000Z",
                  "conversationMode": "chat",
                  "explicitExecutionMode": "chat"
                },
                {
                  "runID": "BBBBBBBB-2222-4222-8222-222222222222",
                  "state": "completed",
                  "startedAt": "2026-11-16T00:00:00.000Z",
                  "conversationMode": "chat"
                }
              ]
            }
        """.trimIndent()))
        val runs = reply!!.runs
        assertEquals(2, runs.size)
        assertEquals("chat", runs[0].explicitExecutionModeRaw)
        assertNull("a legacy reply must not be defaulted to Agent",
            runs[1].explicitExecutionModeRaw)
        assertEquals("chat", runs[1].conversationModeRaw)
    }
}
