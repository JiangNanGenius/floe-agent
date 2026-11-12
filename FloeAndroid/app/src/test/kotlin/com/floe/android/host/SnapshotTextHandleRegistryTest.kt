// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SnapshotTextHandleRegistryTest {
    private val task = "11111111-1111-1111-1111-111111111111"
    private val run = "22222222-2222-2222-2222-222222222222"
    private fun handle(n: Int) = "chunk:v1:" + n.toString(16).padStart(32, '0')
    private fun request(runID: String = run, metadata: Boolean = false) = HostCommandRequest(
        "run.snapshot", HostScope.TaskExecution(task, runID), false, "test",
        payload = if (metadata) buildJsonObject { put("metadataOnly", true) } else null,
    )
    private fun result(n: Int, owner: String = run) = HostOperationOutcome.Completed(buildJsonObject {
        put("conversationID", task); put("runID", owner)
        put("answerContinuationHandle", handle(n))
    })
    private fun returned(t: SnapshotTextHandleRegistry.Ticket) =
        (t.request.payload?.get("releaseTextHandles") as? JsonArray).orEmpty()
            .map { it.jsonPrimitive.content }.toSet()

    @Test fun ninetySixSnapshotsReturnPreviousImmutableHandle() {
        val registry = SnapshotTextHandleRegistry()
        for (n in 1..96) {
            val ticket = registry.prepare(request(), 7)
            assertEquals(if (n == 1) emptySet<String>() else setOf(handle(n - 1)), returned(ticket))
            registry.settle(ticket, result(n))
        }
    }

    @Test fun concurrentCompletionsKeepBothAcknowledgements() {
        val registry = SnapshotTextHandleRegistry()
        val a = registry.prepare(request(), 7)
        val b = registry.prepare(request(), 7)
        registry.settle(b, result(2)); registry.settle(a, result(1))
        assertEquals(setOf(handle(1), handle(2)), returned(registry.prepare(request(), 7)))
    }

    @Test fun metadataProofDoesNotConsumeDisplayHandles() {
        val registry = SnapshotTextHandleRegistry()
        registry.settle(registry.prepare(request(), 7), result(1))
        val proof = registry.prepare(request(metadata = true), 7)
        assertNull(proof.key)
        assertFalse(proof.request.payload!!.containsKey("releaseTextHandles"))
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }

    @Test fun otherOwnerAndLateOldGenerationCannotAdoptOrReleaseNewHandles() {
        val registry = SnapshotTextHandleRegistry()
        val old = registry.prepare(request(), 7)
        registry.settle(old, result(1, owner = "foreign"))
        assertTrue(returned(registry.prepare(request(), 7)).isEmpty())
        val fresh = registry.prepare(request(), 8)
        registry.settle(fresh, result(2)); registry.settle(old, result(1))
        assertEquals(setOf(handle(2)), returned(registry.prepare(request(), 8)))
        assertTrue(returned(registry.prepare(request("33333333-3333-3333-3333-333333333333"), 8)).isEmpty())
    }

    @Test fun failureKeepsPendingAcknowledgementsForTheNextRead() {
        val registry = SnapshotTextHandleRegistry()
        registry.settle(registry.prepare(request(), 7), result(1))
        val failed = registry.prepare(request(), 7)
        registry.settle(failed, HostOperationOutcome.Failed("unavailable", "test"))
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }
}
