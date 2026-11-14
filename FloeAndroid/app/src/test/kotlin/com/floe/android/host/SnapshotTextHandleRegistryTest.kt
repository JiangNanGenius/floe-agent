// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Snapshot-text continuation handle lifecycle. The native snapshot builder
 * restages the FULL live text behind a NEW `chunk:v1:` handle on every
 * oversized snapshot, so the App must retain exactly the newest handle for
 * its paged reader, acknowledge only superseded handles, and never release
 * the handle it is currently reading.
 */
class SnapshotTextHandleRegistryTest {
    private val task = "11111111-1111-1111-1111-111111111111"
    private val run = "22222222-2222-2222-2222-222222222222"
    private fun handle(n: Int) = "chunk:v1:" + n.toString(16).padStart(32, '0')
    private fun request(runID: String = run, metadata: Boolean = false) = HostCommandRequest(
        "run.snapshot", HostScope.TaskExecution(task, runID), false, "test",
        payload = if (metadata) buildJsonObject { put("metadataOnly", true) } else null,
    )
    private fun result(
        n: Int? = null,
        owner: String = run,
        terminal: Boolean = false,
        complete: Boolean = false,
        inline: String? = null,
        revision: Long? = null,
    ) = HostOperationOutcome.Completed(buildJsonObject {
        put("conversationID", task)
        put("runID", owner)
        put("isTerminal", terminal)
        put("answerComplete", complete)
        inline?.let { put("answerText", it) }
        revision?.let { put("textRevision", it) }
        n?.let { put("answerContinuationHandle", handle(it)) }
    })
    private fun returned(t: SnapshotTextHandleRegistry.Ticket) =
        (t.request.payload?.get("releaseTextHandles") as? JsonArray).orEmpty()
            .map { it.jsonPrimitive.content }.toSet()

    @Test
    fun ninetySixSnapshotsAcknowledgeOnlySupersededHandles() {
        val registry = SnapshotTextHandleRegistry()
        for (n in 1..96) {
            val ticket = registry.prepare(request(), 7)
            // The newest handle stays readable for the paged reader; the
            // previous page's handle is acknowledged only after the newer
            // page has adopted its replacement.
            val expected = when {
                n <= 2 -> emptySet()
                else -> setOf(handle(n - 2))
            }
            assertEquals("snapshot $n", expected, returned(ticket))
            registry.settle(ticket, result(n))
        }
        // The newest handle is still retained (never released while it is
        // the reader's only carrier); native run retirement owns it after.
        val tail = returned(registry.prepare(request(), 7))
        assertFalse("the in-use newest handle is never acknowledged", handle(96) in tail)
        assertTrue("only superseded handles are acknowledged", tail.size <= 1)
    }

    @Test
    fun concurrentCompletionsKeepTheNewestHandleAndAcknowledgeTheStaleBlob() {
        val registry = SnapshotTextHandleRegistry()
        val a = registry.prepare(request(), 7) // order 1
        val b = registry.prepare(request(), 7) // order 2
        registry.settle(b, result(2))
        registry.settle(a, result(1))
        // The newer page wins; the late page's blob is acknowledged because
        // the retained handle contains the same full current text.
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
        registry.settle(registry.prepare(request(), 7), result(3))
        assertEquals(setOf(handle(2)), returned(registry.prepare(request(), 7)))
    }

    @Test
    fun metadataProofDoesNotConsumeOrReleaseDisplayHandles() {
        val registry = SnapshotTextHandleRegistry()
        registry.settle(registry.prepare(request(), 7), result(1))
        val proof = registry.prepare(request(metadata = true), 7)
        assertNull(proof.key)
        assertFalse(proof.request.payload!!.containsKey("releaseTextHandles"))
        // The retained handle is the reader's carrier: metadata reads never
        // acknowledge it.
        assertEquals(emptySet<String>(), returned(registry.prepare(request(), 7)))
    }

    @Test
    fun otherOwnerAndLateOldGenerationCannotAdoptOrReleaseNewHandles() {
        val registry = SnapshotTextHandleRegistry()
        val old = registry.prepare(request(), 7)
        registry.settle(old, result(1, owner = "foreign"))
        assertTrue(returned(registry.prepare(request(), 7)).isEmpty())
        val fresh = registry.prepare(request(), 8)
        registry.settle(fresh, result(2))
        registry.settle(old, result(1))
        // A dead-generation page neither replaces the retained handle nor
        // acknowledges it.
        assertEquals(emptySet<String>(), returned(registry.prepare(request(), 8)))
        val next = registry.prepare(request(), 8)
        registry.settle(next, result(3))
        assertEquals(setOf(handle(2)), returned(registry.prepare(request(), 8)))
        assertTrue(returned(registry.prepare(request("33333333-3333-3333-3333-333333333333"), 8)).isEmpty())
    }

    @Test
    fun terminalOrInlineCompleteProofRetiresTheCurrentHandle() {
        val registry = SnapshotTextHandleRegistry()
        registry.settle(registry.prepare(request(), 7), result(1))
        // Inline non-null text without a handle is the WHOLE current step.
        val inline = registry.prepare(request(), 7)
        assertEquals(emptySet<String>(), returned(inline))
        registry.settle(inline, result(complete = true, inline = "complete inline"))
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }

    @Test
    fun failureKeepsPendingAcknowledgementsForTheNextRead() {
        val registry = SnapshotTextHandleRegistry()
        registry.settle(registry.prepare(request(), 7), result(1))
        registry.settle(registry.prepare(request(), 7), result(2))
        val failed = registry.prepare(request(), 7)
        assertEquals(setOf(handle(1)), returned(failed))
        registry.settle(failed, HostOperationOutcome.Failed("unavailable", "test"))
        // The acknowledgement was not confirmed by a Completed page: resend.
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }

    @Test
    fun outOfOrderRevisionNeverRegressesTheNewestPage() {
        val registry = SnapshotTextHandleRegistry()
        val first = registry.prepare(request(), 7)
        val second = registry.prepare(request(), 7)
        registry.settle(second, result(2, revision = 10))
        registry.settle(first, result(1, revision = 9))
        // The lower-revision page is stale and its blob is acknowledged once.
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }

    @Test
    fun equalRevisionLatePageCannotReleaseTheNewerReadersHandle() {
        val registry = SnapshotTextHandleRegistry()
        val first = registry.prepare(request(), 7)
        val second = registry.prepare(request(), 7)
        registry.settle(second, result(2, revision = 10))
        registry.settle(first, result(1, revision = 10))
        assertEquals(setOf(handle(1)), returned(registry.prepare(request(), 7)))
    }
}
