// SPDX-License-Identifier: MPL-2.0
//
// PROPOSED regression source (authored, NOT compiled or run — Main batches
// all checks per the G04R2 source-first policy).
//
// C04 queue-body cold-load stranding regressions (job-2813761c4a0045d2).
//
// ACTUAL defect (device-proven stranding, entry/C04_QUEUE_LOADING_ACTUAL
// .json + entry/C04_BODY_READONLY_REOPEN_RESULT.json): on the exact
// candidate04 cold upgrade session the queue editor opened on the durable
// 224-char row rendered "Loading the full message…" indefinitely
// (byte-identical dumps at open/+60s/+90s, crash buffer 0, no typed
// failure), while the SAME process/root hydrated the SAME row's full body
// in ~2s once warm, and the warm CAS save/read pipeline later proved
// 224->235 end to end (entry/C04_QUEUE_EDIT235_ACTUAL.json). Source proof
// closed the stranding to exactly three silent holes in the bounded
// `conversation.get.detail{kind:"pendingInput"}` lane: one all-or-nothing
// callback fence (`generation && entry && rootEpoch`) that SILENTLY dropped
// EVERY terminal — including typed refusals — whenever any fence component
// moved between the request-time epoch capture and the callback;
// `Cancelled/Superseded -> Unit`; and guard early-returns that left a null
// slot the sheet rendered as the loading promise. WHICH hole fired live is
// INFERRED (the release build exposes no epoch/readiness telemetry), so
// these tests pin the repaired contract for the whole proven hole class —
// the owned slot can never strand again, and the full body still never
// publishes across a moved entry/root (fences unrelaxed; the entry fence
// on failure publication is defensive — release/replace always bump the
// generation — and kept explicit for clarity and regression).
//
// These tests pin the repaired contract at the REAL host-controller level
// (RuntimeHost + RuntimeHostCommandClient + scripted v3 transport, the
// ConversationOrdinaryPathTest idiom):
//   * a stable-root cold read hydrates the EXACT full body and a proven
//     row never re-dispatches;
//   * a root-epoch move during an owned read re-issues the read EXACTLY
//     once against the current root and lands the full body (the actual
//     cold case now self-heals instead of stranding);
//   * a second move surfaces the typed actionable failure — and the
//     ordinary re-open then recovers the full body (the original full-body
//     edit path works after transient instability);
//   * typed refusals (Rejected/Failed) publish their real codes;
//   * a mailbox replaced/cancelled terminal publishes a typed failure —
//     never a silent endless Loading;
//   * a superseded generation's late terminal can never publish into the
//     newer read's slot (stale-callback fences stay strict — a body is
//     NEVER published across a moved entry/root);
//   * admission loss and temporary-session refusals publish typed
//     failures with no dispatch;
//   * an ownership release strands nothing and keeps late terminals silent.
// Synthetic wire only; no provider, database, network or device involved.

package com.floe.android.host

import com.floe.android.feature.conversation.PendingInputBodyStateUi
import com.floe.android.feature.conversation.PendingInputBodyUi
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationPendingInputBodyLifecycleTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val inputId = "4F5E6D7C-8B9A-4012-8345-6789ABCDEF01"
    private val fullBody = "C03 queued text 0123456789abcdefghij0123456789abcdefghij" +
        "0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij" +
        "0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij" +
        "0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij" +
        "0123456789abcdefghij0123456789abcdefghij END_C03"
    private val inputVersion = "2026-10-24T21:00:00.000Z"

    // ------------------------------------------------------------ transport

    /** Held-terminal scripted v3 transport: body-read submits are accepted
     * with a per-request receipt; effect polls answer empty pages until the
     * test releases the exact terminal frame for that receipt. Unrelated
     * cold-start projection reads (providers/models/settings triggered by
     * the store-ready transition) are answered with a typed refusal so
     * their pumps settle; they never touch the body-receipt ordering. */
    private class BodyScript {
        val receipts = CopyOnWriteArrayList<String>()
        private val released = ConcurrentHashMap<String, String>()
        fun note(receipt: String) { receipts.add(receipt) }
        fun submitCount(): Int = receipts.size
        fun receipt(index: Int): String = receipts[index]
        fun release(receipt: String, frameJson: String) { released[receipt] = frameJson }
        fun frameFor(receipt: String): String? = released[receipt]
    }

    private class BodyExchange(private val script: BodyScript) : HostBridgeExchange {
        private val n = AtomicInteger()
        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"command.submit\"")) {
                val isBodyRead = request.contains("\"command\":\"conversation.get\"") &&
                    request.contains("\"detail\"")
                val tag = if (isBodyRead) "body-${n.incrementAndGet()}" else "other-${n.incrementAndGet()}"
                val receipt = "op:v1:$tag"
                if (isBodyRead) script.note(receipt)
                return """{"version":3,"ok":true,"queued":true,""" +
                    """"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
            }
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                if (!receipt.startsWith("op:v1:body-")) {
                    // Unrelated projection read: settle it typed so its pump
                    // closes; nothing in this lane consumes the outcome.
                    return """{"version":3,"requestID":"$correlation","ok":true,""" +
                        """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                        """"cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                        """"effects":[{"sequence":1,"kind":"rejected","code":"runtimeUnavailable",""" +
                        """"detail":[{"key":"reason","value":"test-harness"}]}],""" +
                        """"hasMore":false,"resyncRequired":false}"""
                }
                val frame = script.frameFor(receipt)
                val effects = frame ?: ""
                val sequence = if (frame == null) 0 else 1
                return """{"version":3,"requestID":"$correlation","ok":true,""" +
                    """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                    """"cursor":{"operationReceiptID":"$receipt","sequence":$sequence},""" +
                    """"effects":[$effects],"hasMore":false,"resyncRequired":false}"""
            }
            return """{"version":3,"ok":false,"error":"invalidEnvelope","reason":"unexpected"}"""
        }
    }

    // ------------------------------------------------------------- wire page

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    /** The canonical durable queue-row document (the native
     * PendingInputDetailProjection member set) for one body text. */
    private fun canonicalRowJson(body: String, version: String): String =
        buildJsonObject {
            put("attachmentCount", 0)
            put("consumedRunID", JsonNull)
            put("content", body)
            put("contentUTF8Bytes", body.toByteArray(Charsets.UTF_8).size)
            put("conversationID", conversationId)
            put("executionMode", "agent")
            put("id", inputId)
            put("inputVersion", version)
            put("mode", "queue")
            put("position", 1)
            put("status", "queued")
            put("targetRunID", JsonNull)
        }.toString()

    /** One COMPLETE single-page `conversation.get` reply carrying the
     * detail member for [body] — byte-exact digest/offsets exactly like the
     * real native pager produces. */
    private fun detailReplyJson(body: String, version: String): String {
        val canonical = canonicalRowJson(body, version)
        val bytes = canonical.toByteArray(Charsets.UTF_8)
        val page = buildJsonObject {
            put("kind", "pendingInput")
            put("id", inputId)
            put("status", "queued")
            put("revision", 0)
            put("digest", sha256Hex(bytes))
            put("encoding", "json-utf8")
            put("offset", 0)
            put("nextOffset", bytes.size.toLong())
            put("totalBytes", bytes.size.toLong())
            put("truncated", false)
            put("content", canonical)
            put("revisionResourceID", "pendingInput.$inputId")
            put("revisionVersion", version)
        }
        return buildJsonObject {
            put("conversationID", conversationId)
            put("title", "Task")
            put("detail", page)
        }.toString()
    }

    private fun acceptedFrame(replyJson: String): String =
        """{"sequence":1,"kind":"accepted","value":$replyJson}"""

    private fun rejectedFrame(code: String): String =
        """{"sequence":1,"kind":"rejected","code":"$code",""" +
            """"detail":[{"key":"reason","value":"$code"}]}"""

    private fun replacedFrame(): String =
        """{"sequence":1,"kind":"replaced","detail":[]}"""

    /** The session page that seeds the durable NOT_READ row exactly like a
     * cold `conversation.get` hydration (no body, no CAS version). */
    private fun sessionReplyJson(): String =
        """{"conversationID":"$conversationId","title":"Task",""" +
            """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
            """"version":"digest-1"},"runs":[],""" +
            """"pendingInputs":[{"id":"$inputId","status":"queued","mode":"queue",""" +
            """"executionMode":"agent","position":1,"contentBytes":""" +
            """${fullBody.toByteArray(Charsets.UTF_8).size}}]}"""

    // ----------------------------------------------------------------- host

    private inner class Harness(epoch: Long?, temporary: Boolean = false) {
        val script = BodyScript()
        val exchange = BodyExchange(script)
        @Volatile var epochValue: Long? = epoch
        val host: RuntimeHost
        val controller: ConversationHostController
        val holder: com.floe.android.feature.conversation.ConversationFlowHolder
        val entry: ConversationFlowHolderEntry

        init {
            val client = RuntimeHostCommandClient(
                exchange = exchange,
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            )
            host = RuntimeHost(
                commandClient = client,
                gatewayCapability = MutableStateFlow(
                    com.floe.android.SecretGatewayCapability.Loading),
                bootstrapCapability = MutableStateFlow(
                    com.floe.android.RuntimeBootstrapCapability.Idle),
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
            )
            host.nativeRootEpochReader = { epochValue }
            host.onBootstrapCapability(
                com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            host.onDomainAvailability("conversationDomain", true, emptyList())
            controller = host.conversations
            holder = controller.holderFor(
                conversationId,
                isTemporary = temporary,
                incarnationId = if (temporary) "inc-1" else null,
            )
            entry = controller.entryFor(conversationId)!!
            val reply = ConversationWire.decodeSessionReply(
                Json.parseToJsonElement(sessionReplyJson()))!!
            entry.builder.applySession(reply)
            holder.applyHostSnapshot(entry.builder.build())
        }

        fun slot(): PendingInputBodyUi? =
            holder.snapshot.value?.pendingInputBodies?.get(inputId)

        suspend fun awaitSlot(
            timeoutMillis: Long = 3_000,
            check: (PendingInputBodyUi?) -> Boolean,
        ): Boolean {
            val deadline = System.nanoTime() + timeoutMillis * 1_000_000
            while (System.nanoTime() < deadline) {
                if (check(slot())) return true
                delay(5)
            }
            return check(slot())
        }

        suspend fun awaitSubmits(count: Int, timeoutMillis: Long = 3_000): Boolean {
            val deadline = System.nanoTime() + timeoutMillis * 1_000_000
            while (System.nanoTime() < deadline) {
                if (script.submitCount() >= count) return true
                delay(5)
            }
            return script.submitCount() >= count
        }

        fun admitConversation(available: Boolean) {
            host.onDomainAvailability(
                "conversationDomain", available,
                if (available) emptyList() else listOf("blocked"))
        }
    }

    // ---------------------------------------------------------------- tests

    @Test
    fun coldReadHydratesTheExactFullBodyAndProvenRowNeverRedispatches() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            // The cold row is NOT_READ with no body and no CAS version.
            val row = h.holder.snapshot.value!!.pendingInputs.first { it.id == inputId }
            assertEquals(PendingInputBodyStateUi.NOT_READ, row.bodyState)

            val ok = h.controller.requestPendingInputBody(h.holder.session, inputId)
            assertTrue("the read must be admitted on the live surface", ok)
            // Loading is published SYNCHRONOUSLY with the dispatch.
            assertEquals(PendingInputBodyUi.Loading, h.slot())

            assertTrue(h.awaitSubmits(1))
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(fullBody, inputVersion)))

            assertTrue("the full body must hydrate under a stable root",
                h.awaitSlot { it is PendingInputBodyUi.Ready })
            val ready = h.slot() as PendingInputBodyUi.Ready
            assertEquals(fullBody, ready.text)
            assertEquals(inputVersion, ready.inputVersion)
            val after = h.holder.snapshot.value!!.pendingInputs.first { it.id == inputId }
            assertEquals(PendingInputBodyStateUi.COMPLETE, after.bodyState)
            assertEquals(fullBody, after.content)

            // A proven row never re-dispatches: re-open binds the projection.
            val again = h.controller.requestPendingInputBody(h.holder.session, inputId)
            assertTrue(again)
            delay(80)
            assertEquals(1, h.script.submitCount())
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun epochMoveDuringOwnedReadReissuesOnceAndLandsTheFullBody() = runBlocking {
        // The C04 cold stranding's inferred epoch-move sub-case (the
        // device-proven facts are the indefinite first-open Loading and the
        // ~2s warm hydration of the same row on the same root; no live
        // epoch trace exists). The old single fence dropped the terminal
        // silently (endless Loading); the repair re-issues this owned row's
        // read EXACTLY once — same holder entry only — against the current
        // root and lands the real full body: no user-visible failure.
        val h = Harness(epoch = 7L)
        try {
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            h.epochValue = 8L
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(fullBody, inputVersion)))

            assertTrue("the owned read must re-issue under the new root",
                h.awaitSubmits(2))
            assertEquals("still Loading while the re-issued read is in flight",
                PendingInputBodyUi.Loading, h.slot())
            h.script.release(
                h.script.receipt(1), acceptedFrame(detailReplyJson(fullBody, inputVersion)))

            assertTrue(h.awaitSlot { it is PendingInputBodyUi.Ready })
            assertEquals(fullBody, (h.slot() as PendingInputBodyUi.Ready).text)
            assertEquals(2, h.script.submitCount())
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun secondEpochMoveSurfacesTypedFailureAndReopenRecoversTheFullBody() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            h.epochValue = 8L
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            assertTrue(h.awaitSubmits(2))
            // The root moves AGAIN while the single re-issue is in flight:
            // the bounded retry is spent — surface the typed actionable
            // failure instead of an endless spinner.
            h.epochValue = 9L
            h.script.release(
                h.script.receipt(1), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            assertTrue(h.awaitSlot { it == PendingInputBodyUi.Failed("hostGenerationChanged") })
            delay(60)
            assertEquals("the retry is bounded to exactly one re-issue",
                2, h.script.submitCount())

            // The ordinary re-open (the user's actionable recovery) starts a
            // fresh chain under the now-stable root and lands the full body.
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(3))
            h.script.release(
                h.script.receipt(2), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            assertTrue(h.awaitSlot { it is PendingInputBodyUi.Ready })
            assertEquals(fullBody, (h.slot() as PendingInputBodyUi.Ready).text)
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun typedRefusalsPublishTheirRealCodes() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            h.script.release(h.script.receipt(0), rejectedFrame("runtimeUnavailable"))
            assertTrue(h.awaitSlot { it == PendingInputBodyUi.Failed("runtimeUnavailable") })
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun replacedMailboxTerminalPublishesTypedFailureNotEndlessLoading() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            // A mailbox retire/replacement settles the stream `replaced`
            // (Superseded). The old lane mapped it to Unit — a silent
            // stranded Loading. It must surface typed and stay retryable.
            h.script.release(h.script.receipt(0), replacedFrame())
            assertTrue(h.awaitSlot { it == PendingInputBodyUi.Failed("operationSuperseded") })
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun staleGenerationTerminalNeverPublishesIntoTheNewerRead() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            val otherBody = "a completely different durable body"
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            // The user re-opens: generation 2 owns the slot now.
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(2))

            // The FIRST chain's late terminal must be dropped whole.
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(otherBody, "v-stale")))
            delay(120)
            assertEquals("the stale chain must not touch the newer slot",
                PendingInputBodyUi.Loading, h.slot())
            val row = h.holder.snapshot.value!!.pendingInputs.first { it.id == inputId }
            assertEquals("", row.content)

            // The newer chain's own terminal lands its body.
            h.script.release(
                h.script.receipt(1), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            assertTrue(h.awaitSlot { it is PendingInputBodyUi.Ready })
            assertEquals(fullBody, (h.slot() as PendingInputBodyUi.Ready).text)
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun admissionLossRefusesTypedWithoutDispatch() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            h.admitConversation(false)
            val ok = h.controller.requestPendingInputBody(h.holder.session, inputId)
            assertFalse("an unadmitted domain must refuse the dispatch", ok)
            assertEquals(PendingInputBodyUi.Failed("hostUnavailable"), h.slot())
            delay(60)
            assertEquals("no body read may be dispatched while unadmitted",
                0, h.script.submitCount())

            // Readmission + re-open recovers the ordinary path.
            h.admitConversation(true)
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            assertTrue(h.awaitSlot { it is PendingInputBodyUi.Ready })
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun temporarySessionRefusesTypedWithoutDispatch() = runBlocking {
        val h = Harness(epoch = 7L, temporary = true)
        try {
            val ok = h.controller.requestPendingInputBody(h.holder.session, inputId)
            assertFalse(ok)
            // A RAM-only session has no durable queue row: the refusal is
            // typed on the temporary holder's own surface, never a spinner.
            assertEquals(PendingInputBodyUi.Failed("temporarySession"), h.slot())
            delay(60)
            assertEquals(0, h.script.submitCount())
        } finally {
            h.host.stop()
        }
    }

    @Test
    fun releaseDuringReadStrandsNothingAndLateTerminalStaysSilent() = runBlocking {
        val h = Harness(epoch = 7L)
        try {
            assertTrue(h.controller.requestPendingInputBody(h.holder.session, inputId))
            assertTrue(h.awaitSubmits(1))
            // Ownership release invalidates the chain (generation bump).
            h.controller.releaseHolder(conversationId)
            // The late terminal must not resurrect any surface.
            h.script.release(
                h.script.receipt(0), acceptedFrame(detailReplyJson(fullBody, inputVersion)))
            delay(120)
            assertNull(h.controller.entryFor(conversationId))
            assertEquals(1, h.script.submitCount())
        } finally {
            h.host.stop()
        }
    }
}
