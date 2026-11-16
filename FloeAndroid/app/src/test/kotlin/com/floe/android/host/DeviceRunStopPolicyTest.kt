// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for device-stop settlement classification. It goes
// through the REAL run.snapshot decoder; no host, native code or device state.
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the reported takeover defect boundary:
 *  - a dispatched cancel is never "settled";
 *  - a live run with a pending approval is still stopping;
 *  - an unowned parked run's null approval does not prove revocation;
 *  - only an explicit durable terminal or a current, verified typed stop
 *    proof settles, and the latter never declares the entire run terminal.
 */
class DeviceRunStopPolicyTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val callId = "call_device_1"

    private fun page(
        state: String = "executingTool",
        terminal: Boolean = false,
        liveOwner: Boolean? = true,
        pendingApproval: Boolean = false,
        checkpointReason: String? = null,
        durableTerminal: Boolean? = null,
        terminalDisposition: String? = null,
        rawLiveOwner: String? = null,
        stopSettlement: String? = null,
        includeApproval: Boolean = true,
        watermarkRaw: String? = "9",
        schema: String = "floe.command-envelope/3",
        task: String = conversationId,
        run: String = runId,
        ownerPhaseRaw: String? = "\"none\"",
        liveProducerRaw: String? = "false",
    ): ConversationWire.SnapshotPage {
        val approval = if (pendingApproval) {
            """{"callID":"$callId","tool":"device.act","reason":"Needs approval",""" +
                """"requestedAt":"2026-11-16T10:00:00.000Z",""" +
                """"generation":"55555555-5555-4555-8555-555555555555"}"""
        } else {
            "null"
        }
        val approvalRevision = if (pendingApproval) {
            """{"resourceID":"approval.$callId",""" +
                """"version":"generation:55555555-5555-4555-8555-555555555555"}"""
        } else {
            "null"
        }
        val reason = checkpointReason?.let { ""","checkpointReason":"$it"""" } ?: ""
        val durable = durableTerminal?.let { ""","durableTerminal":$it""" } ?: ""
        val disposition = terminalDisposition?.let { ""","terminalDisposition":"$it"""" } ?: ""
        val owner = rawLiveOwner?.let { ""","liveOwner":$it""" }
            ?: liveOwner?.let { ""","liveOwner":$it""" } ?: ""
        val approvalMember = if (includeApproval) ""","pendingApproval":$approval""" else ""
        val watermark = watermarkRaw?.let { ""","durableWatermark":$it""" } ?: ""
        val proof = stopSettlement?.let { ""","stopSettlement":$it""" } ?: ""
        val ownerPhase = ownerPhaseRaw?.let { ""","currentOwnerPhase":$it""" } ?: ""
        val liveProducer = liveProducerRaw?.let { ""","currentLiveProducer":$it""" } ?: ""
        val json =
            """{"schema":"$schema","conversationID":"$task",""" +
                """"runID":"$run","durableState":"$state",""" +
                """"revision":{"resourceID":"run.${run.uppercase()}","version":"$state"},""" +
                """"isTerminal":$terminal,"conversationMode":"chat","goal":"hi",""" +
                """"approvalRevision":$approvalRevision,"pendingInputs":[]""" +
                "$approvalMember$watermark$proof$reason$durable$disposition$owner$ownerPhase$liveProducer}"
        return ConversationWire.decodeSnapshotPage(Json.parseToJsonElement(json))!!
    }

    /** Fixed native-format digest independently calculated from the Swift
     * settlement v1 basis for the test task/run and values below. */
    private fun validProof(): JsonObject = Json.parseToJsonElement(
        """{"schema":"floe.run-stop-settlement/1","settled":true,"currentIncarnation":true,
           "durableState":"checkpointed","currentOwnerPhase":"none","currentLiveProducer":false,
           "settlementID":"33333333-3333-4333-8333-333333333333",
           "settledAt":"2026-11-16T10:00:00.000Z","path":"liveCancel",
           "reasonKey":"runtime.agent_runtime.the_task_was_stopped_by_you",
           "expectedState":"checkpointed","ownerAbsent":true,"incarnation":"${"a".repeat(64)}",
           "incarnationSource":"activation","incarnationEventID":"44444444-4444-4444-8444-444444444444",
           "incarnationSequence":5,
           "settlementDigest":"ab4f7a84d79c82498d2bd539f9959accab81d8a584927f5f82ceeca430c0c079"}"""
    ).jsonObject

    private fun stoppedPage(proof: JsonObject, liveOwner: Boolean? = false,
                            includeApproval: Boolean = true, watermark: String? = "9") =
        page(state = "checkpointed", terminal = true, liveOwner = liveOwner,
            durableTerminal = true, terminalDisposition = "suspended",
            stopSettlement = proof.toString(), includeApproval = includeApproval,
            watermarkRaw = watermark)

    @Test
    fun exactCurrentTypedStopProofSettlesOnlyTheRunControl() {
        assertEquals(DeviceRunStopReceipt.Settled(terminal = false),
            DeviceRunStopPolicy.classify(stoppedPage(validProof()), awaitingBackgroundJobs = false))
        val parkedProof = JsonObject(validProof().toMutableMap().apply {
            put("path", JsonPrimitive("parkedDependency"))
            put("settlementDigest", JsonPrimitive("9bd6d6ce6f716470a9654ec473e84eb8fbb858086467a94dd92cb389b301eb07"))
        })
        assertEquals(DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(stoppedPage(parkedProof), awaitingBackgroundJobs = false))
        assertEquals(DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(stoppedPage(validProof()), awaitingBackgroundJobs = true))
        assertEquals(DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(stoppedPage(parkedProof), awaitingBackgroundJobs = true))
    }

    @Test
    fun typedStopProofRequiresCurrentOwnerIncarnationAndEveryField() {
        val valid = validProof()
        for (key in listOf("schema", "settled", "currentIncarnation", "durableState",
            "currentOwnerPhase", "currentLiveProducer", "settlementID", "settledAt", "path",
            "reasonKey", "expectedState", "ownerAbsent", "incarnation", "incarnationSource",
            "incarnationEventID", "incarnationSequence", "settlementDigest")) {
            val missing = JsonObject(valid.filterKeys { it != key })
            assertEquals("missing $key", DeviceRunStopReceipt.StillStopping,
                DeviceRunStopPolicy.classify(stoppedPage(missing), false))
        }
        for ((key, value) in listOf(
            "settled" to JsonPrimitive(false), "currentIncarnation" to JsonPrimitive(false),
            "currentOwnerPhase" to JsonPrimitive("admitting"),
            "currentLiveProducer" to JsonPrimitive(true), "ownerAbsent" to JsonPrimitive(false),
            "currentLiveProducer" to JsonPrimitive("false"),
            "settled" to JsonPrimitive("true"), "currentIncarnation" to JsonPrimitive("true"),
            "incarnationSequence" to JsonPrimitive("5"),
            "incarnationSequence" to JsonPrimitive(10), "path" to JsonPrimitive("unknown"),
            "incarnationEventID" to JsonPrimitive("not-a-uuid"),
            "reasonKey" to JsonPrimitive("unknown"), "settledAt" to JsonPrimitive("unknown"),
            "settlementDigest" to JsonPrimitive("b".repeat(64)),
            "reason" to JsonPrimitive("historicalIncarnation"),
        )) {
            val altered = JsonObject(valid.toMutableMap().apply { put(key, value) })
            assertEquals("invalid $key", DeviceRunStopReceipt.StillStopping,
                DeviceRunStopPolicy.classify(stoppedPage(altered), false))
        }
    }

    @Test
    fun missingOwnerOrApprovalOrWatermarkNeverProvesStopped() {
        val proof = validProof()
        for (page in listOf(stoppedPage(proof, liveOwner = null),
            stoppedPage(proof, liveOwner = true), stoppedPage(proof, includeApproval = false),
            stoppedPage(proof, watermark = null), stoppedPage(proof, watermark = "\"9\""))) {
            assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(page, false))
        }
    }

    @Test
    fun proofDigestBindsOuterTaskAndRunIdentity() {
        val original = stoppedPage(validProof())
        val legacy = page(state = "checkpointed", terminal = true, liveOwner = false,
            durableTerminal = true, terminalDisposition = "suspended",
            stopSettlement = validProof().toString(), schema = "legacy")
        assertEquals(DeviceRunStopReceipt.Settled(terminal = false), DeviceRunStopPolicy.classify(original, false))
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(legacy, false))
        for ((task, run) in listOf(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" to runId,
            conversationId to "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        )) {
            val foreign = page(state = "checkpointed", terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = "suspended",
                stopSettlement = validProof().toString(), task = task, run = run)
            assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(foreign, false))
        }
    }

    @Test
    fun liveRunWithPendingApprovalIsStillStopping() {
        assertEquals(
            DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(page(liveOwner = true, pendingApproval = true), false),
        )
        assertEquals(
            DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(page(liveOwner = true, pendingApproval = false), false),
        )
    }

    @Test
    fun parkedRunStillOwningAnApprovalIsStillStopping() {
        assertEquals(
            DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(page(liveOwner = false, pendingApproval = true), false),
        )
    }

    @Test
    fun realTerminalRunSettlesAsTerminal() {
        assertEquals(
            DeviceRunStopReceipt.Settled(terminal = true),
            DeviceRunStopPolicy.classify(page(state = "cancelled", terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = "cancelled"), false),
        )
    }

    @Test
    fun finiteJobCheckpointDoesNotProveApprovalWasRevoked() {
        val parked = page(
            state = "awaitingDependency", terminal = false, liveOwner = false,
            pendingApproval = false, checkpointReason = "awaiting.finite.job",
        )
        assertEquals(
            DeviceRunStopReceipt.StillStopping,
            DeviceRunStopPolicy.classify(parked, awaitingBackgroundJobs = true),
        )
    }

    @Test
    fun awaitingJobsTerminalPageIsStillNotClaimedAsATerminalRun() {
        val receipt = DeviceRunStopPolicy.classify(
            page(state = "completed", terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = "completed"),
            awaitingBackgroundJobs = true,
        )
        assertEquals(DeviceRunStopReceipt.StillStopping, receipt)
    }

    @Test
    fun liveOwnerWinsEvenWhenDurableRowLooksTerminal() {
        for (state in listOf("completed", "failed", "cancelled")) {
            val live = page(state = state, terminal = true, liveOwner = true,
                durableTerminal = true, terminalDisposition = state)
            assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(live, false))
        }
    }

    @Test
    fun authoritativeCurrentOwnerIsRequiredForEachTerminalState() {
        for (state in listOf("completed", "failed", "cancelled")) {
            for ((phase, producer) in listOf(
                "\"admitting\"" to "false",
                "\"prepared\"" to "false",
                "\"terminating\"" to "false",
                "\"none\"" to "true",
                null to "false",
                "\"none\"" to null,
                "\"none\"" to "\"false\"",
                "false" to "false",
            )) {
                val result = page(state = state, terminal = true, liveOwner = false,
                    durableTerminal = true, terminalDisposition = state,
                    ownerPhaseRaw = phase, liveProducerRaw = producer)
                assertEquals("$state / $phase / $producer", DeviceRunStopReceipt.StillStopping,
                    DeviceRunStopPolicy.classify(result, false))
            }
        }
    }

    @Test
    fun typedProofCannotOverrideMissingOrActiveOuterOwnership() {
        for ((phase, producer) in listOf(
            null to "false", "\"none\"" to null, "\"admitting\"" to "false",
            "\"none\"" to "true", "\"none\"" to "\"false\"",
        )) {
            val result = page(state = "checkpointed", terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = "suspended",
                stopSettlement = validProof().toString(),
                ownerPhaseRaw = phase, liveProducerRaw = producer)
            assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(result, false))
        }
    }

    @Test
    fun missingLiveOwnerIsUnknownEvenWithExplicitTerminalDisposition() {
        val missing = page(state = "completed", terminal = true, liveOwner = null,
            durableTerminal = true, terminalDisposition = "completed")
        assertEquals(false, missing.liveOwnerPresent)
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(missing, false))
        val stringValue = page(state = "completed", terminal = true, liveOwner = null,
            durableTerminal = true, terminalDisposition = "completed", rawLiveOwner = "\"false\"")
        assertEquals(false, stringValue.liveOwnerPresent)
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(stringValue, false))
        val explicit = page(state = "completed", terminal = true, liveOwner = false,
            durableTerminal = true, terminalDisposition = "completed")
        assertEquals(true, explicit.liveOwnerPresent)
        assertEquals(DeviceRunStopReceipt.Settled(terminal = true), DeviceRunStopPolicy.classify(explicit, false))
    }

    @Test
    fun parkedOrUnknownSnapshotNeverSettlesFromNullApproval() {
        for (state in listOf("checkpointed", "interrupted", "idle", "waitingApproval")) {
            val parked = page(state = state, terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = "suspended")
            assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(parked, false))
        }
        val legacy = page(state = "completed", terminal = true, liveOwner = false)
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(legacy, false))
    }

    @Test
    fun conflictingDispositionOrPendingApprovalDoesNotSettle() {
        val mismatch = page(state = "failed", terminal = true, liveOwner = false,
            durableTerminal = true, terminalDisposition = "completed")
        val pending = page(state = "failed", terminal = true, liveOwner = false,
            pendingApproval = true, durableTerminal = true, terminalDisposition = "failed")
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(mismatch, false))
        assertEquals(DeviceRunStopReceipt.StillStopping, DeviceRunStopPolicy.classify(pending, false))
    }

    @Test
    fun explicitFinishedDispositionsSettleWhenUnowned() {
        for (state in listOf("completed", "failed", "cancelled")) {
            val finished = page(state = state, terminal = true, liveOwner = false,
                durableTerminal = true, terminalDisposition = state)
            assertEquals(DeviceRunStopReceipt.Settled(terminal = true), DeviceRunStopPolicy.classify(finished, false))
        }
    }

    @Test
    fun failureCodesAreBoundedAndNeverEchoFreeText() {
        assertEquals("stale_revision", DeviceRunStopPolicy.safeCode("stale_revision"))
        assertEquals("unknown", DeviceRunStopPolicy.safeCode("bad value with spaces"))
        assertEquals("unknown", DeviceRunStopPolicy.safeCode(null))
        assertTrue(DeviceRunStopPolicy.safeCode("x".repeat(200)).length <= 64)
    }
}
