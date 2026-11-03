// SPDX-License-Identifier: MPL-2.0
//
// C02 continuity wire tests. Fake transport only: no native, Android, disk,
// network, provider or device call participates.
package com.floe.android.host.taskcontinuity

import com.floe.android.feature.taskcontinuity.TaskContinuityStorageConditionUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskContinuityClientTest {

    private class RecordingTransport(
        var response: String,
    ) : TaskContinuityTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests += request
            return response
        }
    }

    @Test
    fun snapshotRequestUsesReservedChannelAndParsesCanonicalWaits() {
        val transport = RecordingTransport(
            """
            {"ok":true,"schema":"floe.continuity/21","taskID":"11111111-1111-1111-1111-111111111111",
             "runID":"22222222-2222-2222-2222-222222222222","rootEpoch":7,
             "rootFingerprint":"${"a".repeat(64)}",
             "storage":{"condition":"volumeFull","isReady":false,"checkedAt":"2026-11-02T00:00:00.000Z"},
             "pause":null,"waits":[
               {"waitID":"tw_1","kind":"question","rootEpoch":7,
                "taskID":"11111111-1111-1111-1111-111111111111",
                "runID":"22222222-2222-2222-2222-222222222222",
                "toolCallID":"call-1","requestID":"uq_1","itemID":"uq_1.q1","revision":2,
                "prompt":"Pick one","promptTruncated":false,"waitPolicy":"required",
                "answerableNow":false,"requiresResume":true,"createdAt":"2026-11-02T00:00:00.000Z",
                "updatedAt":"2026-11-02T00:00:00.000Z","deadlineAt":null,
                "requestDigest":"${"b".repeat(64)}","answerNonce":"nonce",
                "approvalVersion":null,"runState":"executingTool"}
             ],"waitsTruncated":false,"waitsUnavailable":false,"unknownOutcomeCount":0,
             "generatedAt":"2026-11-02T00:00:00.000Z","modelTools":false}
            """.trimIndent(),
        )
        val client = TaskContinuityClient(transport)
        val reply = client.snapshot(
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        )
        assertTrue(transport.requests.single().contains("\"version\":21"))
        assertTrue(transport.requests.single().contains("\"operation\":\"continuity.snapshot\""))
        assertEquals(7L, reply.state.rootEpoch)
        assertEquals(1, reply.state.waits.size)
        assertEquals("uq_1.q1", reply.state.waits.single().itemID)
        assertTrue(reply.state.waits.single().requiresResume)
        assertEquals(TaskContinuityStorageConditionUi.VOLUME_FULL, reply.state.storage.condition)
    }

    @Test
    fun resumeCarriesExplicitUserActionAndExactIdentity() {
        val transport = RecordingTransport(
            """{"ok":true,"accepted":true,"resumed":true,"requiresReconciliation":false,"marker":null}""",
        )
        val client = TaskContinuityClient(transport)
        val reply = client.resume(
            taskID = "11111111-1111-1111-1111-111111111111",
            runID = "22222222-2222-2222-2222-222222222222",
            markerID = "marker-1",
            expectedRootEpoch = 7,
            expectedTargetRevision = 3,
        )
        assertTrue(reply.accepted)
        assertTrue(reply.resumed)
        val request = transport.requests.single()
        assertTrue(request.contains("\"operation\":\"continuity.resume\""))
        assertTrue(request.contains("\"markerID\":\"marker-1\""))
        assertTrue(request.contains("\"expectedRootEpoch\":7"))
        assertTrue(request.contains("\"expectedTargetRevision\":3"))
        assertTrue(request.contains("\"explicitUserAction\":true"))
    }

    @Test
    fun refusalKeepsTypedCodeAndDoesNotClaimResume() {
        val transport = RecordingTransport(
            """{"ok":false,"accepted":false,"code":"storageStillUnavailable:volumeFull",
                "message":"Storage is still unavailable.","retryable":true}""",
        )
        val client = TaskContinuityClient(transport)
        val failure = runCatching {
            client.resume(
                taskID = "11111111-1111-1111-1111-111111111111",
                runID = "22222222-2222-2222-2222-222222222222",
                markerID = "marker-1",
                expectedRootEpoch = 7,
                expectedTargetRevision = null,
            )
        }.exceptionOrNull()
        assertTrue(failure is TaskContinuityFailure)
        assertEquals("storageStillUnavailable:volumeFull", (failure as TaskContinuityFailure).code)
        assertTrue(failure.retryable)
    }

    @Test
    fun pauseReplyIsParsedFromItsOwnNestedMarker() {
        val transport = RecordingTransport(
            """
            {"ok":true,"pause":{"markerID":"m-1","taskID":"t-1","runID":"r-1","rootEpoch":7,
             "reason":"volumeMissing","state":"awaitingStorageRecovery","durability":"recoveryMetadata",
             "detectedAt":"2026-11-02T00:00:00.000Z","updatedAt":"2026-11-02T00:00:00.000Z",
             "resumeAttempt":0,"runCheckpointed":false,"unknownOutcomeCount":0,
             "explicitResumeOnly":true,"targetRevision":null},
             "storage":{"condition":"volumeMissing","isReady":false},
             "runCheckpointed":false}
            """.trimIndent(),
        )
        val client = TaskContinuityClient(transport)
        val reply = client.pause("t-1", "r-1", "volumeMissing")
        assertEquals("m-1", reply.pause.markerID)
        assertFalse(reply.storage.isReady)
        assertFalse(reply.runCheckpointed)
    }
}
