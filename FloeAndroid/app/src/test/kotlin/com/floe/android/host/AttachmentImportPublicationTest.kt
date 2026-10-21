// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.AttachmentImportUi
import com.floe.android.feature.conversation.StagedAttachmentUi
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R8 REAL App failure regression (published Alpha6 APK
 * d12bd67e1a967d0baebe458ba53e170916c74de0c2b2a80eaa81cedc0538b8b5,
 * source 27ede2527f51280994d7f7612730956e839552f8): a real system
 * ACTION_OPEN_DOCUMENT pick (Downloads > floe-g02-r8-note.txt, 154 bytes)
 * delivered the filename and entered the stage row in BOTH the Home new-task
 * draft and an ordinary existing conversation, then the publication ALWAYS
 * failed with no useful public reason.
 *
 * Cause (traced against RuntimeFacadeAttachmentStaging.swift): the copy
 * coroutine closed the native staging route synchronously in its finally
 * right after SUBMITTING the asynchronous `attachment.stage` publication.
 * The native publish requires the ingress AND its route live (it refuses
 * `routeStale`), and the native closeRoute aborts EVERY ingress of the
 * route — explicitly including finished-but-unpublished ones. The
 * publication therefore arrived only after its ingress had been aborted.
 *
 * These tests drive the REAL controller end to end with:
 *  - a native-semantics channel double (routeOpen/begin/write/end/abort/
 *    routeClose with the REAL closeRoute abort semantics, plus a
 *    publish-retirement model for the accepted terminal), and
 *  - the scripted v3 wire double the host test suite already uses.
 *
 * Authored, NOTRUN (no JVM/Gradle execution in the source phase; Main runs
 * the composed batch together with IntegrationsRequiredActionsTest).
 *
 * Preimage failure surface: with the route closed at producer return, the
 * "route still open / ingress not aborted before the terminal" assertions
 * fail in every test; a late terminal after cancel/root-fence would also
 * resurrect rows or leak/double-close routes without the ownership fix.
 */
class AttachmentImportPublicationTest {

    // ---------------------------------------------------------- native seam

    /**
     * The staging channel with the REAL native lifecycle semantics the fix
     * is anchored to (RuntimeFacadeAttachmentStaging.swift):
     *  - `closeRoute` aborts EVERY ingress of the route — a
     *    finished-but-unpublished ingress is aborted too — then removes it;
     *  - the accepted publish retires the ingress from the live map, so a
     *    route close after the accepted terminal is a drain no-op;
     *  - writes to an aborted ingress fail loudly (never silent).
     */
    private class NativeSemanticsChannel : AttachmentImportController.StagingChannel {
        class Ingress(
            val receipt: String,
            val routeReceipt: String,
            val stagingId: String,
        ) {
            var finished = false
            var aborted = false
            val bytes = ByteArrayOutputStream()
        }

        private val sequence = AtomicInteger(0)
        private val routes = ConcurrentHashMap<String, CopyOnWriteArrayList<Ingress>>()
        private val allIngresses = ConcurrentHashMap<String, Ingress>()
        val openedRoutes = CopyOnWriteArrayList<String>()
        val closedRoutes = CopyOnWriteArrayList<String>()
        val abortedIngresses = CopyOnWriteArrayList<String>()
        val endedIngresses = CopyOnWriteArrayList<String>()

        fun ingress(receipt: String): Ingress =
            allIngresses[receipt]
                ?: throw com.floe.android.bridge.AttachmentStagingNativeException(-305)

        fun closeCount(routeReceipt: String): Int = closedRoutes.count { it == routeReceipt }

        fun openRouteCount(): Int = routes.size

        /** Models the native publish retiring the ingress from the live map
         *  (the accepted `attachment.stage` terminal IS that publish). */
        fun retireIngress(ingressReceipt: String) {
            val target = ingress(ingressReceipt)
            routes[target.routeReceipt]?.remove(target)
        }

        override fun routeOpen(
            conversationId: String?,
            incarnation: Long,
            draftRevision: Long,
            isTemporary: Boolean,
        ): String {
            require(incarnation > 0L) { "native route rejects zero incarnation" }
            val receipt = "route:${conversationId ?: "home-draft"}:$incarnation:" +
                sequence.incrementAndGet()
            routes[receipt] = CopyOnWriteArrayList()
            openedRoutes.add(receipt)
            return receipt
        }

        override fun routeClose(routeReceipt: String) {
            val live = routes.remove(routeReceipt) ?: return
            // EXACTLY the native closeRoute semantics: abort every ingress
            // of the route, finished-but-unpublished included.
            live.forEach { ingress ->
                if (!ingress.aborted) {
                    ingress.aborted = true
                    abortedIngresses.add(ingress.receipt)
                }
            }
            closedRoutes.add(routeReceipt)
        }

        override fun begin(routeReceipt: String, reusingStagingId: String?): String {
            val route = routes[routeReceipt]
                ?: throw com.floe.android.bridge.AttachmentStagingNativeException(-303)
            val ingress = Ingress(
                receipt = "ing:${sequence.incrementAndGet()}",
                routeReceipt = routeReceipt,
                stagingId = "00000000-0000-4000-8000-%012d".format(sequence.incrementAndGet()),
            )
            route.add(ingress)
            allIngresses[ingress.receipt] = ingress
            return "${ingress.receipt} ${ingress.stagingId}"
        }

        override fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int) {
            val ingress = ingress(ingressReceipt)
            check(!ingress.aborted) { "write on aborted ingress" }
            ingress.bytes.write(data, offset, length)
        }

        override fun end(ingressReceipt: String, displayNameHint: String?, mimeTypeHint: String?) {
            val ingress = ingress(ingressReceipt)
            check(!ingress.aborted) { "end on aborted ingress" }
            ingress.finished = true
            endedIngresses.add(ingressReceipt)
        }

        override fun abort(ingressReceipt: String) {
            val ingress = ingress(ingressReceipt)
            if (!ingress.aborted) {
                ingress.aborted = true
                abortedIngresses.add(ingressReceipt)
            }
        }
    }

    // --------------------------------------------------------------- wire

    /** Scripted v3 wire (same model as IntegrationsRequiredActionsTest):
     *  command.submit → queued receipt; effect.poll → open page until the
     *  test registers the terminal effects for that receipt. */
    private class StagingWire : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        private val replies = ConcurrentHashMap<String, String>()
        private val sequence = AtomicInteger(0)
        /** Receipts whose terminal page has actually been served to a poll
         *  (the controller has received the terminal). */
        val terminalsServed = CopyOnWriteArrayList<String>()

        private data class Queued(val command: String, val receipt: String, val raw: String)
        private val queued = CopyOnWriteArrayList<Queued>()

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val effects = replies[receipt]
                return if (effects != null) {
                    terminalsServed.add(receipt)
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                        """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt",""" +
                        """"sequence":1},"effects":[$effects],"hasMore":false,"resyncRequired":false}"""
                } else {
                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                        """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt",""" +
                        """"sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                }
            }
            val command = commandOf(request)
            val receipt = "op:v1:$command-${sequence.incrementAndGet()}"
            queued.add(Queued(command, receipt, request))
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"$receipt"}"""
        }

        /** Deliver the terminal effects for the queued [command] whose
         *  envelope satisfies [match]. Polls before this stay open. Returns
         *  the wire operation receipt (so a test can await the served
         *  terminal deterministically). */
        fun completeWhere(command: String, effectJson: String, match: (JsonObject) -> Boolean): String {
            val target = queued.firstOrNull { op ->
                op.command == command &&
                    (runCatching {
                        Json.parseToJsonElement(op.raw).jsonObject
                    }.getOrNull()?.get("envelope") as? JsonObject)?.let(match) == true
            } ?: error("no queued $command matching the predicate: $queued")
            replies[target.receipt] = effectJson
            return target.receipt
        }

        fun envelopes(command: String): List<JsonObject> = queued
            .filter { it.command == command }
            .mapNotNull {
                (runCatching { Json.parseToJsonElement(it.raw).jsonObject }
                    .getOrNull()?.get("envelope") as? JsonObject)
            }

        fun queuedCount(command: String): Int = queued.count { it.command == command }

        companion object {
            fun commandOf(raw: String): String {
                val marker = "\"command\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return if (end > from) raw.substring(from, end) else ""
            }
        }
    }

    private fun JsonObject.stringOf(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    // ------------------------------------------------------------- helpers

    private fun hostWith(wire: StagingWire): RuntimeHost {
        val host = RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = wire,
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            ),
            gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Ready),
            bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        )
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("hostAttachmentStaging", available = true, missing = emptyList())
        host.nativeRootEpochReader = { 31L }
        return host
    }

    /** A substituted in-memory source (the real R8 file shape: 154 bytes,
     *  text/plain, Downloads-provider-style authority). */
    private fun memorySource(name: String, bytes: ByteArray): AttachmentImportController.AttachmentSource =
        AttachmentImportController.AttachmentSource(
            uri = null,
            scheme = "content",
            authority = "com.android.providers.downloads.documents",
            displayName = name,
            mimeType = "text/plain",
            declaredSize = bytes.size.toLong(),
            openStream = { ByteArrayInputStream(bytes) },
        )

    private val r8Bytes: ByteArray = ByteArray(154) { (it * 31 % 251).toByte() }

    private fun acceptedStaging(stagingId: String, handle: String): String =
        """{"sequence":1,"kind":"accepted","detail":[{"key":"result","value":"accepted"},{"key":"stagingID","value":"$stagingId"},{"key":"stagingHandle","value":"$handle"}]}"""

    private fun rejectedStaging(code: String, reason: String): String =
        """{"sequence":1,"kind":"accepted","detail":[{"key":"result","value":"refused"},{"key":"code","value":"$reason"}]}"""

    private fun stagedFull(row: StagedAttachmentUi?, bytes: ByteArray): Boolean =
        row != null && row.byteCount == bytes.size.toLong() &&
            row.import.let { it is AttachmentImportUi.InProgress && it.fraction == 1f }

    private suspend fun waitUntil(timeoutMillis: Long = 4_000, predicate: () -> Boolean) {
        withTimeout(timeoutMillis) {
            while (!predicate()) delay(5)
        }
    }

    // -------------------------------------------------------------- tests

    /**
     * The core regression: the native route survives the whole asynchronous
     * publication and closes exactly once AT the accepted terminal; Ready is
     * published only with the real accepted handle. On the preimage the
     * route was closed (and the finished ingress aborted) the moment the
     * copy returned, so this test fails before the fix.
     */
    @Test
    fun `route survives asynchronous publication and closes at the accepted terminal`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val (nonce, generation) = host.conversations.rootWorkspace.currentDraftOwner()

        host.attachments.stageSubstitutedSource(
            null, nonce, generation, memorySource("floe-g02-r8-note.txt", r8Bytes))

        // The copy fully settled (real bytes, full digest) and publication
        // is in flight. THIS is the instant the old code had already closed
        // the route — aborting the very ingress the publish reads.
        waitUntil {
            stagedFull(
                host.conversations.rootWorkspace.draftAttachments.value.singleOrNull(),
                r8Bytes)
        }
        val rowId = host.conversations.rootWorkspace.draftAttachments.value.single().id
        val ingress = channel.ingress(channel.endedIngresses.single())
        // FAILS ON PREIMAGE: the route is still open and the finished
        // ingress has NOT been aborted before the terminal.
        assertEquals("route must stay open while publication is pending", 1, channel.openRouteCount())
        assertTrue("finished ingress must not abort before the terminal",
            channel.abortedIngresses.isEmpty())

        // The real publication envelope rides the exact native ingress.
        waitUntil { wire.queuedCount("attachment.stage") == 1 }
        val stageEnv = wire.envelopes("attachment.stage").single()
        assertEquals(ingress.receipt,
            (stageEnv["payload"] as JsonObject).stringOf("ingressReceipt"))
        // No auto-send ever leaves the host.
        assertEquals(0, wire.queuedCount("run.start"))

        // The DELAYED native terminal accepts with the real handle (this
        // models the native publish retiring the ingress).
        channel.retireIngress(ingress.receipt)
        wire.completeWhere("attachment.stage", acceptedStaging(rowId, "stag:v1:handle-r8")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ingress.receipt
        }
        waitUntil {
            host.conversations.rootWorkspace.draftAttachments.value
                .singleOrNull()?.import is AttachmentImportUi.Ready
        }
        assertEquals("stag:v1:handle-r8", host.attachments.draftHandle(rowId))

        // Exactly-once route close, happening only after the terminal.
        waitUntil { channel.closedRoutes.size == 1 }
        assertEquals(1, channel.closeCount(ingress.routeReceipt))
        assertEquals(0, channel.openRouteCount())
        assertTrue("accepted publish retired the ingress before the close",
            channel.abortedIngresses.isEmpty())
        assertEquals(0, wire.queuedCount("run.start"))

        val rows = host.conversations.rootWorkspace.takeSendableForLaunch()
        val holder = host.conversations.holderFor(
            "22222222-2222-4222-8222-222222222222", false, null)
        assertTrue(host.attachments.handoffDraftToSession(nonce, holder.session, rows.map { it.id }))
        host.conversations.rootWorkspace.clearHandedOff(nonce)
        host.conversations.rootWorkspace.onHomeReplaced(generation + 1)
        host.attachments.drainDraft(nonce)
        val sessionRows = holder.stagedAttachments.value
        assertEquals(holder.session.conversationId, sessionRows.single().ownerConversationId)
        val handles = host.attachments.launchHandles(holder.session, sessionRows)
        assertEquals(listOf("stag:v1:handle-r8"), handles)
        val request = com.floe.android.feature.conversation.RunLaunchRequest(
            holder.session.conversationId, holder.session.sessionEpoch, "local input", sessionRows,
            com.floe.android.feature.conversation.AgentExecutionModeUi.AGENT, null, null, null)
        val payload = ConversationWire.runStartPayload(request, handles!!)
        assertEquals("stag:v1:handle-r8", payload["stagedAttachments"]!!.jsonArray.single().jsonPrimitive.content)
        assertNull(host.attachments.launchHandles(holder.session,
            listOf(sessionRows.single().copy(id = "unknown-row"))))
        assertNull(host.attachments.launchHandles(holder.session, sessionRows + sessionRows))
        assertEquals(0, wire.queuedCount("attachment.staging.discard"))
        // A prepared/queue commit releases only host ownership; subsequent
        // session cleanup must not discard native message-owned bytes.
        host.attachments.consumeSessionRows(holder.session, rows.map { it.id })
        host.attachments.drainSession(holder.session)
        assertEquals(0, wire.queuedCount("attachment.staging.discard"))
    }

    /**
     * A user cancel while publication is pending removes the row and
     * releases ONLY its own route; a late accepted terminal for the removed
     * row cannot resurrect it and cannot touch the sibling row's live
     * route, bytes or publication.
     */
    @Test
    fun `cancel while pending fences a late terminal and releases only its own route`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val (nonce, generation) = host.conversations.rootWorkspace.currentDraftOwner()

        val bytesA = ByteArray(154) { it.toByte() }
        val bytesB = ByteArray(77) { (255 - it).toByte() }
        host.attachments.stageSubstitutedSource(null, nonce, generation, memorySource("note-a.txt", bytesA))
        host.attachments.stageSubstitutedSource(null, nonce, generation, memorySource("note-b.txt", bytesB))

        waitUntil {
            val rows = host.conversations.rootWorkspace.draftAttachments.value
            rows.size == 2 && rows.all { stagedFull(it, if (it.displayName == "note-a.txt") bytesA else bytesB) }
        }
        val rows = host.conversations.rootWorkspace.draftAttachments.value
        val rowA = rows.first { it.displayName == "note-a.txt" }
        val rowB = rows.first { it.displayName == "note-b.txt" }
        // Map rows to their real native ingresses through the stage
        // envelopes (the same receipts the native publish reads).
        val stageEnvs = wire.envelopes("attachment.stage")
        assertEquals(2, stageEnvs.size)
        fun ingressFor(rowId: String) = stageEnvs.first { env ->
            (env["payload"] as JsonObject).stringOf("ingressReceipt")!!
                .let { receipt -> channel.ingress(receipt).stagingId == rowId }
        }.let { env -> channel.ingress((env["payload"] as JsonObject).stringOf("ingressReceipt")!!) }
        val ingA = ingressFor(rowA.id)
        val ingB = ingressFor(rowB.id)

        // Both routes are open while both publications are pending.
        assertEquals(2, channel.openRouteCount())

        // Native publication commits A before removal; its success callback
        // is still delayed. Cancelling its ingress cannot release that record.
        channel.retireIngress(ingA.receipt)
        assertTrue(host.attachments.cancelDraft(nonce, rowA.id))
        waitUntil { host.conversations.rootWorkspace.draftAttachments.value.size == 1 }
        // A's route closes exactly once and its ingress is aborted (the two
        // native drains are separate cleanup jobs: await both).
        waitUntil {
            channel.closedRoutes.size == 1
        }
        assertEquals(1, channel.closeCount(ingA.routeReceipt))
        // Sibling B is untouched: route open, bytes intact, not aborted.
        assertEquals(1, channel.openRouteCount())
        assertFalse(channel.abortedIngresses.contains(ingB.receipt))
        assertEquals(77L, channel.ingress(ingB.receipt).bytes.size().toLong())
        // The native cancel command addresses the exact staging identity.
        waitUntil { wire.queuedCount("attachment.staging.cancel") == 1 }
        assertEquals(rowA.id,
            (wire.envelopes("attachment.staging.cancel").single()["payload"] as JsonObject)
                .stringOf("stagingID"))

        // The LATE accepted terminal for the removed row A arrives after
        // the cancel: the row must NOT resurrect and the route must not
        // double-close.
        val lateReceipt = wire.completeWhere(
            "attachment.stage", acceptedStaging(rowA.id, "stag:v1:late-handle-a")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ingA.receipt
        }
        // Wait until the wire has actually served the terminal, let the
        // fenced handler run, then assert nothing resurrected and no route
        // double-closed.
        waitUntil { wire.terminalsServed.contains(lateReceipt) }
        waitUntil { wire.queuedCount("attachment.staging.discard") == 1 }
        assertEquals("stag:v1:late-handle-a",
            (wire.envelopes("attachment.staging.discard").single()["payload"] as JsonObject)
                .stringOf("stagingHandle"))
        assertEquals(listOf(rowB.id),
            host.conversations.rootWorkspace.draftAttachments.value.map { it.id })
        assertEquals(1, channel.closeCount(ingA.routeReceipt))
        assertNull(host.conversations.rootWorkspace.draftAttachments.value
            .firstOrNull { it.id == rowA.id })
        assertEquals(0, wire.queuedCount("run.start"))

        channel.retireIngress(ingB.receipt)
        wire.completeWhere("attachment.stage", acceptedStaging(rowB.id, "stag:v1:handle-b")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ingB.receipt
        }
        waitUntil {
            host.conversations.rootWorkspace.draftAttachments.value
                .singleOrNull { it.id == rowB.id }?.import is AttachmentImportUi.Ready
        }
        waitUntil { channel.closedRoutes.size == 2 }
        assertEquals(1, channel.closeCount(ingB.routeReceipt))
        assertEquals(0, channel.openRouteCount())
        assertEquals(0, wire.queuedCount("run.start"))
    }

    /**
     * A refused publication settles the row as typed Failed (never Ready,
     * never auto-sent) and still releases exactly its own route.
     */
    @Test
    fun `refused publication stays failed and releases its route`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val (nonce, generation) = host.conversations.rootWorkspace.currentDraftOwner()

        host.attachments.stageSubstitutedSource(
            null, nonce, generation, memorySource("floe-g02-r8-note.txt", r8Bytes))
        waitUntil {
            stagedFull(host.conversations.rootWorkspace.draftAttachments.value.singleOrNull(), r8Bytes)
        }
        val ing = channel.ingress(channel.endedIngresses.single())

        // The native publish is refused (the exact Alpha6 symptom class):
        // route stale because the App had closed it early.
        wire.completeWhere("attachment.stage",
            rejectedStaging("stage_refused", "routeStale")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ing.receipt
        }
        waitUntil {
            host.conversations.rootWorkspace.draftAttachments.value
                .singleOrNull()?.import is AttachmentImportUi.Failed
        }
        waitUntil { channel.closedRoutes.size == 1 }
        assertEquals(1, channel.closeCount(ing.routeReceipt))
        assertEquals(0, channel.openRouteCount())
        // No premature Ready, no fabricated handle, no auto-send.
        assertNull(host.attachments.draftHandle(
            host.conversations.rootWorkspace.draftAttachments.value.single().id))
        assertEquals(0, wire.queuedCount("run.start"))
    }

    /**
     * The native Root epoch changing while publication is pending fences
     * the row (cancelled, not Ready) and still releases the route exactly
     * once — the delayed window must keep the existing root fence.
     */
    @Test
    fun `root epoch change before the terminal fences the row and releases the route`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val (nonce, generation) = host.conversations.rootWorkspace.currentDraftOwner()

        host.attachments.stageSubstitutedSource(
            null, nonce, generation, memorySource("floe-g02-r8-note.txt", r8Bytes))
        waitUntil {
            stagedFull(host.conversations.rootWorkspace.draftAttachments.value.singleOrNull(), r8Bytes)
        }
        val ing = channel.ingress(channel.endedIngresses.single())
        assertEquals(1, channel.openRouteCount())

        // Root retires (shutdown/navigation class) BEFORE the terminal.
        host.nativeRootEpochReader = { 32L }
        wire.completeWhere("attachment.stage", acceptedStaging(ing.stagingId, "stag:v1:handle-d")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ing.receipt
        }
        waitUntil { host.conversations.rootWorkspace.draftAttachments.value.isEmpty() }
        waitUntil {
            channel.closedRoutes.size == 1 &&
                channel.abortedIngresses.contains(ing.receipt)
        }
        assertEquals(1, channel.closeCount(ing.routeReceipt))
        assertEquals(0, channel.openRouteCount())
        assertEquals(0, wire.queuedCount("run.start"))
    }

    /**
     * The ordinary-conversation half of the real failure: a session-owned
     * attachment reaches Ready only through the delayed accepted terminal,
     * with the route open until then and closed exactly once after.
     */
    @Test
    fun `ordinary conversation attachment reaches Ready only through the delayed terminal`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val conversationId = "11111111-1111-4111-8111-111111111111"
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        val session = holder.session

        host.attachments.stageSubstitutedSource(
            session, null, 0L, memorySource("floe-g02-r8-note.txt", r8Bytes))
        waitUntil {
            stagedFull(holder.stagedAttachments.value.singleOrNull(), r8Bytes)
        }
        val rowId = holder.stagedAttachments.value.single().id
        val ing = channel.ingress(channel.endedIngresses.single())

        // FAILS ON PREIMAGE: route closed at producer return here.
        assertEquals(1, channel.openRouteCount())
        assertTrue(channel.abortedIngresses.isEmpty())

        channel.retireIngress(ing.receipt)
        wire.completeWhere("attachment.stage", acceptedStaging(rowId, "stag:v1:handle-thread")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ing.receipt
        }
        waitUntil {
            holder.stagedAttachments.value.singleOrNull()?.import is AttachmentImportUi.Ready
        }
        assertEquals(rowId, holder.stagedAttachments.value.single().id)
        assertEquals(listOf("stag:v1:handle-thread"),
            host.attachments.launchHandles(session, holder.stagedAttachments.value))
        waitUntil { channel.closedRoutes.size == 1 }
        assertEquals(1, channel.closeCount(ing.routeReceipt))
        assertTrue(channel.abortedIngresses.isEmpty())
        assertEquals(0, wire.queuedCount("run.start"))
    }

    /**
     * Host teardown with a publication still pending drains every owned
     * route exactly once (no leak) and never auto-sends.
     */
    @Test
    fun `host stop with pending publication drains the owned route exactly once`() = runBlocking {
        val wire = StagingWire()
        val host = hostWith(wire)
        val channel = NativeSemanticsChannel()
        host.attachments.channel = channel
        val (nonce, generation) = host.conversations.rootWorkspace.currentDraftOwner()

        host.attachments.stageSubstitutedSource(
            null, nonce, generation, memorySource("floe-g02-r8-note.txt", r8Bytes))
        waitUntil {
            stagedFull(host.conversations.rootWorkspace.draftAttachments.value.singleOrNull(), r8Bytes)
        }
        val ing = channel.ingress(channel.endedIngresses.single())
        assertEquals(1, channel.openRouteCount())

        host.attachments.stop()
        waitUntil { channel.closedRoutes.size == 1 }
        assertEquals(1, channel.closeCount(ing.routeReceipt))
        assertEquals(0, channel.openRouteCount())
        assertEquals(0, wire.queuedCount("run.start"))
        // A terminal arriving after teardown finds no row: no resurrection.
        val lateReceipt = wire.completeWhere(
            "attachment.stage", rejectedStaging("cancelled", "routeStale")) { env ->
            (env["payload"] as? JsonObject)?.stringOf("ingressReceipt") == ing.receipt
        }
        waitUntil { wire.terminalsServed.contains(lateReceipt) }
        delay(150)
        assertTrue(host.conversations.rootWorkspace.draftAttachments.value.isEmpty())
        assertEquals(1, channel.closeCount(ing.routeReceipt))
        assertEquals(0, wire.queuedCount("run.start"))
    }
}
