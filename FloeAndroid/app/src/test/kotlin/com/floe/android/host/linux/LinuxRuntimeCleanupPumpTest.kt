// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.runtimeipc.RuntimePeerProof
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/**
 * G03-R3 (job-7e9db10b801940c2): the REAL `LinuxRuntimeCleanupPump` state
 * machine against fake lane/Binder EDGES only — the production claim,
 * scope validation, dispatch, peer-proof, receipt stamping and settlement
 * logic under test is the shipped code. Filesystem semantics are covered by
 * the shipped `WorkspaceCopyWiper` engine tests.
 */
class LinuxRuntimeCleanupPumpTest {
    private companion object {
        const val CONVERSATION = "0F66A2F0-6CFA-4B6E-9E5F-3E9D2B5C7A11"
        const val PROJECT = "5AA3F1C2-1D2E-4A6B-8C9D-0E1F2A3B4C5D"
        const val CORE_REQUEST_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val TARGET_EPOCH = 5L
        const val BOUND_EPOCH = 99L

        val proof = RuntimePeerProof(
            peerPackage = "com.floe.agent.runtime",
            peerUid = 10123,
            packageVersion = "0.3/42",
            certificateDigest = "cd".repeat(32),
            binderIdentity = "runtime-binder:u10123:x2:g1",
        )

        fun payloadJson(truncated: Boolean = false, keys: List<String> = listOf("0".repeat(32))): String =
            "{\"conversationID\":\"$CONVERSATION\",\"deletionSet\":\"targetProjectScope\"," +
                "\"evidenceSessionKeys\":[${keys.joinToString(",") { "\"$it\"" }}]," +
                "\"evidenceTruncated\":$truncated,\"operation\":\"runtimeWorkspaceCopies.clear\"," +
                "\"projectID\":\"$PROJECT\",\"provenTotal\":${maxOf(keys.size, 1)}," +
                "\"targetEpoch\":$TARGET_EPOCH,\"workspaceRelativePath\":\"PrivateTasks/$CONVERSATION\"}"

        val describeJson: String =
            "{\"ok\":true,\"requestID\":\"$CORE_REQUEST_ID\",\"operation\":\"runtimeWorkspaceCopies.clear\"," +
                "\"targetEpoch\":$TARGET_EPOCH,\"boundEpoch\":$BOUND_EPOCH}"

        val clearedResult: String =
            "{\"requestID\":\"$CORE_REQUEST_ID\",\"state\":\"completed\",\"result\":{" +
                "\"operation\":\"runtimeWorkspaceCopies.clear\",\"requestID\":\"$CORE_REQUEST_ID\"," +
                "\"conversationID\":\"$CONVERSATION\",\"projectID\":\"$PROJECT\",\"targetEpoch\":$TARGET_EPOCH," +
                "\"outcome\":\"cleared\",\"executorUid\":10123,\"pathsRemoved\":9,\"bytesFreed\":4096," +
                "\"executorProofDigest\":\"${"ef".repeat(32)}\"}}"

        fun statusCompleted(bodyJson: String): String =
            "{\"version\":1,\"id\":\"${UUID.randomUUID()}\",\"ok\":true,\"result\":$bodyJson}"

        val refusedBusyResult: String =
            "{\"requestID\":\"$CORE_REQUEST_ID\",\"state\":\"completed\",\"result\":{" +
                "\"operation\":\"runtimeWorkspaceCopies.clear\",\"requestID\":\"$CORE_REQUEST_ID\"," +
                "\"conversationID\":\"$CONVERSATION\",\"projectID\":\"$PROJECT\",\"targetEpoch\":$TARGET_EPOCH," +
                "\"outcome\":\"refused\",\"reason\":\"ownedWorkActive\"}}"

        val refusedAttributionResult: String = refusedBusyResult.replace("ownedWorkActive", "attributionIncomplete")
    }

    /** Scripted lane edge: capture delivered receipts; claims/stats scripted. */
    private class FakeQueue(
        val claims: java.util.concurrent.ConcurrentLinkedDeque<Long> = java.util.concurrent.ConcurrentLinkedDeque(),
        val liveClaims: MutableSet<Long> = mutableSetOf(),
        var describeSample: String = "{\"ok\":false}",
        var payloadSample: String = "{}",
        var statsJson: String = "{\"queued\":0,\"claimed\":0}",
        var bindResult: Int = 0,
    ) : RuntimeCleanupQueue {
        val delivered = mutableListOf<JsonObject>()
        val bindEpochs = mutableListOf<Long>()
        override fun bind(epoch: Long): Int { bindEpochs += epoch; return bindResult }
        override fun next(timeoutMillis: Int): Long = claims.pollFirst() ?: 0L
        override fun describe(claim: Long): ByteArray = describeSample.toByteArray()
        override fun payload(claim: Long): ByteArray = payloadSample.toByteArray()
        override fun isLive(claim: Long): Boolean = claim in liveClaims
        override fun complete(claim: Long, receipt: ByteArray): ByteArray? {
            val text = String(receipt, Charsets.UTF_8)
            delivered += Json.parseToJsonElement(text) as JsonObject
            val outcome = text.contains("\"outcome\":\"cleared\"")
            liveClaims.remove(claim)
            return if (outcome) {
                ("{\"ok\":true,\"state\":\"cleared\",\"receiptDigest\":\"" + "d".repeat(16) + "\"}")
                    .toByteArray()
            } else {
                "{\"ok\":true,\"state\":\"retrying\",\"reason\":\"retained\"}".toByteArray()
            }
        }
        override fun status(requestID: String): ByteArray? = null
        override fun stats(): ByteArray = statsJson.toByteArray()
    }

    /** Scripted signed distinct-UID channel edge. */
    private class FakeChannel(
        var dispatchScript: (control: JsonObject, wireID: String) -> String = { _, id ->
            "{\"version\":1,\"id\":\"$id\",\"ok\":true," +
                "\"result\":{\"requestID\":\"$id\",\"state\":\"queued\"}}"
        },
        var statusScript: (queriedWireID: String, pollIndex: Int) -> String = { _, _ -> statusCompleted(clearedResult) },
        var exchangeThrowsFirst: Boolean = false,
        var proofSequence: List<RuntimePeerProof?> = listOf(proof, proof),
    ) : RuntimeCleanupChannel {
        var openThrows = false
        val dispatchWireIDs = mutableListOf<String>()
        val statusQueries = mutableListOf<String>()
        private var exchanges = 0
        private var proofReads = 0
        override fun open() { if (openThrows) throw IllegalStateException("runtime not installed") }
        override fun exchange(operation: String, control: JsonObject, requestID: String): String {
            exchanges += 1
            if (operation == "runtimeWorkspaceCopies.clear") {
                // the wire id IS recorded even when the accepted dispatch
                // died mid-flight (the pump must still poll the ORIGINAL id)
                dispatchWireIDs += requestID
                if (exchangeThrowsFirst && exchanges == 1) throw IllegalStateException("binder died after accept")
                return dispatchScript(control, requestID)
            }
            val queried = ((control["requestID"] as? JsonPrimitive)?.content) ?: ""
            statusQueries += queried
            return statusScript(queried, statusQueries.size)
        }
        override fun peerProof(): RuntimePeerProof? =
            proofSequence.getOrElse(proofReads.also { proofReads += 1 }) { proofSequence.last() }
        override fun ownUid(): Int = 10001
        override fun close() {}
    }

    private var scope: CoroutineScope = CoroutineScope(Job() + Dispatchers.Unconfined)

    private fun pumpWith(queue: FakeQueue, channel: FakeChannel): LinuxRuntimeCleanupPump =
        LinuxRuntimeCleanupPump(
            queue,
            RuntimeCleanupChannelFactory { channel },
            scope,
            settleBudgetMillis = 2_000,
            drainBudgetMillis = 400,
            backoffBaseMillis = 10,
            maxBackoffMillis = 20,
        )

    private fun armedQueue(vararg claims: Long): FakeQueue = FakeQueue(
        liveClaims = claims.toMutableSet(),
    ).also {
        it.describeSample = describeJson
        it.payloadSample = payloadJson()
    }

    private fun finish(pump: LinuxRuntimeCleanupPump) {
        // stop the reader deterministically after each direct call
        scope.coroutineContext[Job]?.cancel()
        scope = CoroutineScope(Job() + Dispatchers.Unconfined)
    }

    @Test fun clearedReceiptUsesMeasuredPeerValuesNotTheBodyEcho() = runBlocking {
        val queue = armedQueue(1L)
        val channel = FakeChannel()
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertTrue(pump.settleOne(1L, BOUND_EPOCH))
            val receipt = queue.delivered.single()
            assertEquals("cleared", receipt["outcome"]!!.jsonPrimitive.content)
            assertEquals(CORE_REQUEST_ID, receipt["requestID"]!!.jsonPrimitive.content)
            assertEquals(CONVERSATION, receipt["conversationID"]!!.jsonPrimitive.content)
            assertEquals(PROJECT, receipt["projectID"]!!.jsonPrimitive.content)
            assertEquals(TARGET_EPOCH, receipt["targetEpoch"]!!.jsonPrimitive.content.toLong())
            // identity fields come from the HOST-MEASURED peer proof only
            assertEquals(10123L, receipt["runtimeUID"]!!.jsonPrimitive.content.toLong())
            assertEquals("cd".repeat(32), receipt["certificateDigest"]!!.jsonPrimitive.content)
            assertEquals("0.3/42", receipt["packageVersion"]!!.jsonPrimitive.content)
            assertEquals("runtime-binder:u10123:x2:g1", receipt["binderIdentity"]!!.jsonPrimitive.content)
            // effect numbers come from the verified scoped execution result
            assertEquals(9L, receipt["pathsRemoved"]!!.jsonPrimitive.content.toLong())
            assertEquals(4096L, receipt["bytesFreed"]!!.jsonPrimitive.content.toLong())
            assertEquals("ef".repeat(32), receipt["executorProofDigest"]!!.jsonPrimitive.content)
            assertEquals(1L, pump.settledCleared.get())
        } finally { finish(pump) }
    }

    @Test fun busyRuntimeDeliversRefusedRetentionAndNeverCancels() = runBlocking {
        val queue = armedQueue(1L)
        var statusOps = 0
        val channel = FakeChannel(
            statusScript = { _, _ -> statusCompleted(refusedBusyResult).also { statusOps += 1 } },
        )
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            val receipt = queue.delivered.single()
            assertEquals("refused", receipt["outcome"]!!.jsonPrimitive.content)
            assertEquals("runtime:ownedWorkActive", receipt["reason"]!!.jsonPrimitive.content)
            assertEquals(0, pump.settledCleared.get())
            // the pump never dispatches any cancel/shell operation to stop A
            assertTrue(channel.dispatchWireIDs.single().isNotEmpty())
        } finally { finish(pump) }
    }

    @Test fun noReceiptIsDeliveredForADeadClaimOrStaleGeneration() = runBlocking {
        val queue = armedQueue(1L, 2L)
        queue.liveClaims.remove(1L)
        val channel = FakeChannel()
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH)) // isLive false
            assertFalse(pump.settleOne(2L, BOUND_EPOCH + 1)) // different generation
            assertTrue(queue.delivered.isEmpty())
        } finally { finish(pump) }
    }

    @Test fun peerChangeAfterExecutionNeverClears() = runBlocking {
        val queue = armedQueue(1L)
        val changed = proof.copy(binderIdentity = "runtime-binder:u10123:x9:g2")
        val channel = FakeChannel(proofSequence = listOf(proof, changed))
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            val receipt = queue.delivered.single()
            assertEquals("refused", receipt["outcome"]!!.jsonPrimitive.content)
            assertEquals("peerChanged", receipt["reason"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun executorUidMismatchIsNeverTrusted() = runBlocking {
        val queue = armedQueue(1L)
        val spoofed = clearedResult.replace("\"executorUid\":10123", "\"executorUid\":10999")
        val channel = FakeChannel(statusScript = { _, _ -> statusCompleted(spoofed) })
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            assertEquals("peerChanged", queue.delivered.single()["reason"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun resultStringAloneNeverClearsWhenDigestMalformed() = runBlocking {
        val queue = armedQueue(1L)
        val badProof = clearedResult.replace("ef".repeat(32), "not-a-digest")
        val channel = FakeChannel(statusScript = { _, _ -> statusCompleted(badProof) })
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            assertEquals("resultUnverified", queue.delivered.single()["reason"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun transportTimeoutAfterAcceptedDispatchPollsTheOriginalControlID() = runBlocking {
        val queue = armedQueue(1L)
        val channel = FakeChannel(exchangeThrowsFirst = true)
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertTrue(pump.settleOne(1L, BOUND_EPOCH))
            // the ORIGINAL accepted control id was polled; NO blind replay
            assertEquals(channel.dispatchWireIDs.single(), channel.statusQueries.single())
            assertEquals(1, channel.dispatchWireIDs.size)
            assertEquals("cleared", queue.delivered.single()["outcome"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun unknownControlAfterStatusAllowsNewWireIdContinuationSameScope() = runBlocking {
        val queue = armedQueue(1L)
        val channel = FakeChannel(
            statusScript = { _, pollIndex ->
                if (pollIndex == 1) {
                    "{\"version\":1,\"id\":\"${UUID.randomUUID()}\",\"ok\":true," +
                        "\"result\":{\"state\":\"unknown\"}}"
                } else statusCompleted(clearedResult)
            },
        )
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertTrue(pump.settleOne(1L, BOUND_EPOCH))
            assertEquals(2, channel.dispatchWireIDs.size)
            assertNotEquals(channel.dispatchWireIDs[0], channel.dispatchWireIDs[1]) // NEW wire id
            assertEquals(2, channel.dispatchWireIDs.map { UUID.fromString(it).toString() }.toSet().size)
            val receipt = queue.delivered.single() // retained partial NOT cached forever
            assertEquals("cleared", receipt["outcome"]!!.jsonPrimitive.content)
            // the scope across both dispatches was the SAME Core request
            assertEquals(CORE_REQUEST_ID, receipt["requestID"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun oldTargetEpochFromLedgerSettlesAgainstNewerBoundEpoch() = runBlocking {
        // describe.targetEpoch (stable ledger identity, OLDER) vs
        // describe.boundEpoch (current generation): the receipt must echo
        // the scope's stable targetEpoch, never the bound epoch.
        val queue = armedQueue(1L)
        val channel = FakeChannel()
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertTrue(pump.settleOne(1L, BOUND_EPOCH))
            val receipt = queue.delivered.single()
            assertEquals(TARGET_EPOCH, receipt["targetEpoch"]!!.jsonPrimitive.content.toLong())
            assertNotEquals(BOUND_EPOCH, receipt["targetEpoch"]!!.jsonPrimitive.content.toLong())
        } finally { finish(pump) }
    }

    @Test fun truncatedEvidenceRetainsUntilAttributionCompletes() = runBlocking {
        val queue = armedQueue(1L)
        queue.payloadSample = payloadJson(truncated = true, keys = (0 until 16).map { "%032x".format(it) })
        val channel = FakeChannel(statusScript = { _, _ -> statusCompleted(refusedAttributionResult) })
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            assertEquals("runtime:attributionIncomplete",
                queue.delivered.single()["reason"]!!.jsonPrimitive.content)
        } finally { finish(pump) }
    }

    @Test fun runtimeNotInstalledRefusesAndOrdinaryNonLinuxPathsStayUntouched() = runBlocking {
        val queue = armedQueue(1L)
        val channel = FakeChannel().also { it.openThrows = true }
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            assertEquals("peerUnauthenticated", queue.delivered.single()["reason"]!!.jsonPrimitive.content)
            // ordinary never-Linux chat deletion never enqueues this lane at
            // all (Core-side rule preserved by this lane): a bound-but-empty
            // lane just idles and drains quiescent without fabricating
            // receipts.
            assertTrue(pump.drainAndStop(BOUND_EPOCH, budgetMillis = 200))
            assertEquals(1, queue.delivered.size) // only the explicit refusal above
        } finally { finish(pump) }
    }

    @Test fun drainQuiescenceClosesOnlyWhenTheLaneReportsNoLiveObligations() = runBlocking {
        val queue = armedQueue(1L)
        queue.statsJson = "{\"queued\":1,\"claimed\":1}"
        val channel = FakeChannel()
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        queue.claims.add(1L)
        try {
            // NOT quiescent: the cleanup channel must NOT be closed (root
            // retirement stays honest and retryable)
            assertFalse(pump.drainAndStop(BOUND_EPOCH, budgetMillis = 200))
            assertEquals(BOUND_EPOCH, pump.boundNativeEpoch)
            // quiescent lane -> real completion, channel retires itself
            queue.statsJson = "{\"queued\":0,\"claimed\":0}"
            assertTrue(pump.drainAndStop(BOUND_EPOCH, budgetMillis = 200))
            assertEquals(0L, pump.boundNativeEpoch)
            // after retirement the lane is never re-pollable without a
            // strictly-newer rebind attempt
            assertFalse(pump.drainAndStop(BOUND_EPOCH, budgetMillis = 50))
        } finally { finish(pump) }
    }

    @Test fun malformedLaneScopeNeverDispatches() = runBlocking {
        val queue = armedQueue(1L)
        queue.payloadSample = queue.payloadSample.replace(PROJECT, "not-a-uuid")
        val channel = FakeChannel()
        val pump = pumpWith(queue, channel)
        pump.start(BOUND_EPOCH)
        try {
            assertFalse(pump.settleOne(1L, BOUND_EPOCH))
            assertTrue(queue.delivered.isEmpty()) // no receipt without a provable scope
            assertTrue(channel.dispatchWireIDs.isEmpty()) // nothing crossed Binder
        } finally { finish(pump) }
    }

    @Test fun laneRefusesEqualRebindAndPumpBindsOnlyTheAcceptedEpoch() = runBlocking {
        val queue = armedQueue()
        queue.bindResult = -105
        val pump = pumpWith(queue, FakeChannel())
        try {
            assertThrows(IllegalStateException::class.java) {
                runBlocking { pump.start(0L) }
            }
            assertThrows(IllegalStateException::class.java) {
                runBlocking { pump.start(BOUND_EPOCH) } // lane refused the epoch
            }
            assertEquals(listOf(BOUND_EPOCH), queue.bindEpochs)
            assertEquals(0L, pump.boundNativeEpoch) // never "guessed 0 as live"
        } finally { finish(pump) }
    }
}
