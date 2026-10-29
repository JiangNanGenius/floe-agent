// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.ApprovalModeUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Cold-open task-policy projection regression (policy-reopen129, 2026-10-29).
 *
 * Device evidence: after the first human Full access gesture on an existing
 * five-run task persisted `approval_mode=fullAccess` in the real
 * `task_policies` row, a force-stop + cold reopen showed "Ask first" in the
 * composer permission chip and the permissions pane while the DB row and its
 * `updated_at` stamp were intact. The fresh `conversation.get` page carries
 * the persisted `taskPolicy`; the decoder compared the Kotlin enum NAME
 * (`FULL_ACCESS`) with the native wire rawValue (`fullAccess`), so the mode
 * decoded to null and the fresh builder kept its Ask default. `updatedAt`
 * decoded correctly (the sheet had a CAS revision and the later policy
 * update worked), which isolates the failure to the enum mapping.
 *
 * These tests drive the REAL `ConversationWire` decoder and the REAL
 * `ThreadProjectionBuilder` — the same page -> projection -> holder path the
 * cold-open UI uses. The permission chip is the task policy for the NEXT
 * run (the pane states this); the selected run's frozen policy is a separate
 * native run record and must not be projected here. A terminal
 * `run.snapshot` may refresh the CAS stamp but must never replace the
 * persisted task mode with the old run's frozen choice.
 *
 * AUTHORED, NOTRUN — Main runs the focused JVM cohort after integration.
 */
class ConversationColdOpenTaskPolicyProjectionTest {

    private val conversationId = "087720D9-D69F-472D-8906-A8F93F6F812D"
    private val stamp = "2026-10-29T10:18:55.628Z"
    private val snapshotStamp = "2026-10-29T10:21:00.000Z"

    /** Five terminal runs, newest-first, as the native page orders them. */
    private val runIds = listOf(
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
        "44444444-4444-4444-8444-444444444444",
        "55555555-5555-4555-8555-555555555555",
    )

    private fun terminalRuns(): String = runIds.mapIndexed { index, runId ->
        """{"runID":"$runId","state":"completed",""" +
            """"modelName":"floe-c15-exec",""" +
            """"startedAt":"2026-10-29T09:5${index}:00.000Z"}"""
    }.joinToString(",")

    /**
     * A REAL-shaped `conversation.get` reply: the newest run is the latest
     * terminal round. The run-summary wire carries NO approval mode, so the
     * chip can only come from the durable taskPolicy row, which says Full
     * access. The row stamp is the actual device value.
     */
    private fun coldOpenPage(
        resolvedMode: String? = "fullAccess",
        includePolicy: Boolean = true,
    ): String {
        val policy = if (!includePolicy) {
            ""
        } else {
            """"taskPolicy":{"approvalMode":${if (resolvedMode == null) "null" else "\"$resolvedMode\""},""" +
                """"resolvedApprovalMode":${if (resolvedMode == null) "null" else "\"$resolvedMode\""},""" +
                """"recoveryPolicy":"safePoint","notificationPolicy":"stages",""" +
                """"updatedAt":"$stamp"},"""
        }
        return """{"conversationID":"$conversationId","title":"Untitled",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-cold-open"},""" +
            """"runs":[${terminalRuns()}],""" +
            """"pendingInputs":[],"pendingInputsTotalCount":0,""" +
            """"pendingInputsTruncated":false,$policy""" +
            """"archivedAt":null}"""
    }

    /** A terminal `run.snapshot` for the selected run: no mode member; its
     * only policy content is the durable CAS identity. */
    private fun terminalSnapshot(): String {
        val runId = runIds.first()
        return """{"conversationID":"$conversationId","runID":"$runId",""" +
            """"durableState":"completed",""" +
            """"revision":{"resourceID":"run.${runId.uppercase()}",""" +
            """"version":"completed"},""" +
            """"isTerminal":true,"conversationMode":"chat","liveOwner":false,""" +
            """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
            """"queueRevision":null,"durableWatermark":42,""" +
            """"policyRevision":{"resourceID":"taskPolicy.${conversationId.uppercase()}",""" +
            """"version":"$snapshotStamp"}}"""
    }

    private fun decode(json: String) = requireNotNull(
        ConversationWire.decodeSessionReply(
            Json.parseToJsonElement(json).jsonObject,
        ),
    ) { "fixture must decode through the real session decoder" }

    @Test
    fun coldReopenProjectsPersistedFullAccessOverTheDefaultAsk() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(coldOpenPage("fullAccess")))
        val state = builder.build()
        assertEquals(ApprovalModeUi.FULL_ACCESS, state.approvalMode)
        assertEquals(stamp, state.taskPolicyRevision?.version)
        // The newest durable run is selected; none of these terminal rows
        // contributes a mode, so the chip value comes ONLY from the row.
        assertEquals(runIds.first(), builder.selectedRunId)
    }

    @Test
    fun everyNativeWireApprovalModeDecodesExactly() {
        assertEquals(ApprovalModeUi.ASK, decode(coldOpenPage("ask")).approvalMode)
        assertEquals(
            ApprovalModeUi.AUTOMATIC,
            decode(coldOpenPage("automatic")).approvalMode,
        )
        assertEquals(
            ApprovalModeUi.FULL_ACCESS,
            decode(coldOpenPage("fullAccess")).approvalMode,
        )
    }

    @Test
    fun absentOrUnknownResolvedModeIsHonestAbsence() {
        val absent = decode(coldOpenPage(includePolicy = false))
        assertNull(absent.approvalMode)
        assertNull(absent.policyRevision)

        // A policy row with an unproven resolved vocabulary still proves its
        // CAS identity from updatedAt; the MODE is not guessed as Ask.
        val unknown = decode(coldOpenPage("futureMode"))
        assertNull(unknown.approvalMode)
        assertEquals(stamp, unknown.policyRevision?.version)
    }

    @Test
    fun legacyPageWithoutTaskPolicyDoesNotResetAProvenMode() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(coldOpenPage("fullAccess")))
        builder.applySession(decode(coldOpenPage(includePolicy = false)))
        val state = builder.build()
        assertEquals(ApprovalModeUi.FULL_ACCESS, state.approvalMode)
        assertEquals(stamp, state.taskPolicyRevision?.version)
    }

    @Test
    fun terminalRunSnapshotKeepsTaskModeAndOnlyRefreshesCas() {
        val builder = ThreadProjectionBuilder(conversationId)
        builder.applySession(decode(coldOpenPage("fullAccess")))
        val snapshot = requireNotNull(
            ConversationWire.decodeSnapshotPage(
                Json.parseToJsonElement(terminalSnapshot()),
            ),
        ) { "fixture must decode through the real snapshot decoder" }
        builder.applySnapshot(snapshot)
        val state = builder.build()
        assertEquals(ApprovalModeUi.FULL_ACCESS, state.approvalMode)
        assertEquals(snapshotStamp, state.taskPolicyRevision?.version)
        assertEquals("completed", state.liveStateName)
        assertEquals(runIds.first(), builder.selectedRunId)
    }
}
