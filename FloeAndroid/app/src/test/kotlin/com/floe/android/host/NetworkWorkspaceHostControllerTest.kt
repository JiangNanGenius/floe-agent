// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G04-R1 network workspace host controller — controller-lane tests.
 * AUTHORED, NOT RUN (Main runs the composed batch). The native C ABI is
 * injected through the [NetworkWorkspaceChannel] seam (a scripted model of
 * G04NetworkWorkspaceHostAPI: epoch fences, ok/ok:0 bodies, -6xx statuses,
 * staged RAM tickets), while the LAN boundary is injected through the
 * trusted gate seam, so broker dispatch/denial/chain semantics are
 * provable on the JVM without the platform dialog. No device, no network,
 * no real credentials; all secret bytes below are synthetic.
 */
class NetworkWorkspaceHostControllerTest {

    private val task = "00000000-0000-4000-8000-000000000001".uppercase()
    private val workspace = "00000000-0000-4000-8000-000000000002".uppercase()
    private val epochHolder = AtomicLong(77L)
    private var generation = 7L
    private val ownerLive = AtomicBoolean(true)

    // ------------------------------------------------------------------
    // scripted fake channel
    // ------------------------------------------------------------------

    private inner class FakeChannel : NetworkWorkspaceChannel {
        val calls = CopyOnWriteArrayList<String>()
        val stagedSecrets = CopyOnWriteArrayList<ByteArray>()
        val abortedTickets = CopyOnWriteArrayList<Long>()
        var nextTicket = 1L
        var mountPageRows = "[]"
        var sourceRows = "[]"
        var mountAddBody: (String) -> String = {
            """{"ok":1,"mountID":"00000000-0000-4000-8000-0000000000ad","status":"connected"}"""
        }
        val opStatusScript = AtomicReference<List<String>>(emptyList())
        var opCloseStatus = 0
        var opCancelStatus = 0

        private fun write(buffer: ByteArray, body: String): Int {
            val bytes = body.toByteArray(Charsets.UTF_8)
            if (bytes.size + 1 > buffer.size) return -106
            System.arraycopy(bytes, 0, buffer, 0, bytes.size)
            return bytes.size
        }

        private fun fenced(epoch: Long): Int? =
            if (epoch != epochHolder.get()) -602 else null

        override fun credStage(epoch: Long, data: ByteArray, offset: Int, length: Int): Long {
            calls.add("credStage")
            fenced(epoch)?.let { return it.toLong() }
            stagedSecrets.add(data.copyOfRange(offset, offset + length))
            return nextTicket++
        }

        override fun credAbort(ticket: Long): Int {
            calls.add("credAbort:$ticket")
            abortedTickets.add(ticket)
            return 0
        }

        override fun mountPage(epoch: Long, taskID: String, workspaceID: String, reply: ByteArray): Int {
            calls.add("mountPage")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"rows":$mountPageRows}""")
        }

        override fun mountAdd(epoch: Long, taskID: String, workspaceID: String, name: String,
                              transport: String, endpoint: String, rootPath: String,
                              username: String, readOnly: Boolean, credentialTicket: Long,
                              reply: ByteArray): Int {
            calls.add("mountAdd:$name:$transport:$endpoint:cred=$credentialTicket")
            fenced(epoch)?.let { return it }
            return write(reply, mountAddBody(endpoint))
        }

        override fun mountUpdate(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                                 name: String, transport: String, endpoint: String,
                                 rootPath: String, username: String, readOnly: Boolean,
                                 credentialTicket: Long, reply: ByteArray): Int {
            calls.add("mountUpdate:$mountID:cred=$credentialTicket")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"mountID":"$mountID","status":"connected"}""")
        }

        override fun mountProbe(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                                reply: ByteArray): Int {
            calls.add("mountProbe:$mountID")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"status":"connected"}""")
        }

        override fun mountDisconnect(epoch: Long, taskID: String, workspaceID: String,
                                     mountID: String, reply: ByteArray): Int {
            calls.add("mountDisconnect:$mountID")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"cancelled":[],"outstanding":[]}""")
        }

        override fun mountRemove(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                                 forgetCredential: Boolean, reply: ByteArray): Int {
            calls.add("mountRemove:$mountID:forget=$forgetCredential")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"credential":"deleted","outstanding":[]}""")
        }

        override fun browse(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                            path: String, reply: ByteArray): Int {
            calls.add("browse:$path")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"entries":[{"name":"a.txt","path":"a.txt",
                "isDirectory":0,"bytes":3}],"truncated":0}""")
        }

        override fun stat(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                          path: String, reply: ByteArray): Int {
            calls.add("stat:$path")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"path":"$path","isDirectory":0,"bytes":3}""")
        }

        override fun opImport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                              remotePath: String, logicalPath: String, recursive: Boolean,
                              conflict: String): Long {
            calls.add("opImport:$remotePath->$logicalPath:recursive=$recursive:conflict=$conflict")
            if (epoch != epochHolder.get()) return -602
            return nextTicket++
        }

        override fun opExport(epoch: Long, taskID: String, workspaceID: String, mountID: String,
                              logicalPath: String, remotePath: String, policy: String): Long {
            calls.add("opExport:$logicalPath->$remotePath:policy=$policy")
            if (epoch != epochHolder.get()) return -602
            return nextTicket++
        }

        override fun opSave(epoch: Long, taskID: String, workspaceID: String, sourceID: String): Long {
            calls.add("opSave:$sourceID")
            if (epoch != epochHolder.get()) return -602
            return nextTicket++
        }

        override fun opReconcile(epoch: Long, taskID: String, workspaceID: String,
                                 recoveryID: String): Long {
            calls.add("opReconcile:$recoveryID")
            if (epoch != epochHolder.get()) return -602
            return nextTicket++
        }

        override fun opStatus(ticket: Long, reply: ByteArray): Int {
            val script = opStatusScript.get()
            val next = if (script.isEmpty()) """{"ok":1,"id":$ticket,"kind":"import",
                "mountID":"m","state":"completed","phase":"done","bytesDone":0,
                "totalBytes":0,"entriesDone":1,"entriesFailed":0,"failures":[],
                "errorCode":"","retryable":0,"result":{}}""" else script.first()
            if (script.isNotEmpty()) opStatusScript.set(script.drop(1))
            calls.add("opStatus")
            return write(reply, next)
        }

        override fun opCancel(ticket: Long): Int {
            calls.add("opCancel:$ticket")
            return opCancelStatus
        }

        override fun opClose(ticket: Long): Int {
            calls.add("opClose:$ticket")
            return opCloseStatus
        }

        override fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int,
                                reply: ByteArray): Int {
            calls.add("sourcePage")
            fenced(epoch)?.let { return it }
            return write(reply, """{"ok":1,"rows":$sourceRows}""")
        }

        override fun hostStats(reply: ByteArray): Int =
            write(reply, """{"ok":1,"counters":{}}""")
    }

    private val channel = FakeChannel()

    private fun controller(gate: NetworkWorkspaceGate? = null) = NetworkWorkspaceHostController(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        ioDispatcher = Dispatchers.IO,
        currentNativeEpoch = { epochHolder.get() },
        localNetwork = { null },
        channel = channel,
        gateOverride = gate,
    )

    private fun lane(controller: NetworkWorkspaceHostController) =
        controller.laneFor(task, workspace, epochHolder.get(), generation) { ownerLive.get() }!!

    private suspend fun awaitUntil(timeoutMillis: Long = 4_000, message: String,
                                  predicate: () -> Boolean) {
        withTimeout(timeoutMillis) { while (!predicate()) delay(20) }
        @Suppress("UNUSED_EXPRESSION") message
    }

    // ------------------------------------------------------------------
    // 1. lane identity fences
    // ------------------------------------------------------------------

    @Test
    fun laneRequiresExactEpochCanonicalIdentityAndRebindRules() {
        val controller = controller()
        assertNull(controller.laneFor(task, workspace, 99L, generation) { true })
        assertNull(controller.laneFor("not-a-uuid", workspace, epochHolder.get(), generation) { true })
        val lowerTask = task.lowercase()
        val laneA = controller.laneFor(lowerTask, workspace, epochHolder.get(), 8L) { ownerLive.get() }
        checkNotNull(laneA)
        // an OLDER pane generation cannot take over
        assertNull(controller.laneFor(task, workspace, epochHolder.get(), 7L) { true })
        // a NEWER generation rebinds the same lane
        val laneB = controller.laneFor(task, workspace, epochHolder.get(), 9L) { true }
        checkNotNull(laneB)
        assertEquals(laneA, laneB)
        // retiring the epoch drops the lane; the same identity then mints a
        // FRESH lane (the stopped one is never reused)
        controller.retireEpoch(epochHolder.get())
        val laneC = controller.laneFor(task, workspace, epochHolder.get(), 10L) { true }
        checkNotNull(laneC)
        assertFalse(laneC === laneB)
        assertFalse(laneB.state.value.runtimeAvailable)   // stopped lane stays fenced
    }

    // ------------------------------------------------------------------
    // 2. credential staging + add
    // ------------------------------------------------------------------

    @Test
    fun addMountStagesUnicodePasswordThenZeroesAndSubmitsTicket() = runBlocking {
        val controller = controller()
        val lane = lane(controller)
        channel.mountPageRows = """[{"id":"A","name":"Team","transport":"webdav",
            "endpoint":"https://dav.example.test/files","rootPath":"","username":"alice",
            "readOnly":0,"status":"connected"}]"""
        val password = "密码 secret".toCharArray()
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Team", transport = "webdav", endpoint = "https://dav.example.test/files",
            rootPath = "", username = "alice", readOnly = false, password = password))
        awaitUntil(message = "staged") { channel.calls.contains("credStage") }
        awaitUntil(message = "added") { channel.calls.any { it.startsWith("mountAdd:") } }
        awaitUntil(message = "mounts visible") { lane.state.value.mounts.size == 1 }
        // the local array was zeroed immediately after staging
        assertTrue(password.all { it == '\u0000' })
        // the staged bytes carried the exact password once
        assertEquals(1, channel.stagedSecrets.size)
        assertEquals("密码 secret", String(channel.stagedSecrets[0], Charsets.UTF_8))
        // no secret bytes anywhere in state
        assertFalse(lane.state.value.toString().contains("密码"))
        assertFalse(lane.state.value.busy)
    }

    @Test
    fun addMountActionableBodyKeepsTypedTokenAndBusyClears() = runBlocking {
        val controller = controller()
        val lane = lane(controller)
        channel.mountAddBody = { """{"ok":0,"errorCode":"authenticationFailed","retryable":0}""" }
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Team", transport = "webdav", endpoint = "https://dav.example.test",
            rootPath = "", username = "", readOnly = false))
        awaitUntil(message = "refused") { lane.state.value.messageToken == "authenticationFailed" }
        assertFalse(lane.state.value.busy)
    }

    // ------------------------------------------------------------------
    // 3. LAN broker boundary
    // ------------------------------------------------------------------

    @Test
    fun deniedGateNeverDispatchesAndMarksTypedDenial() = runBlocking {
        val gate: NetworkWorkspaceGate = { _, _, _, onDenied, _ -> onDenied(LocalNetworkAccessBroker.CODE_DENIED); false }
        val controller = controller(gate)
        val lane = lane(controller)
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Team", transport = "webdav", endpoint = "http://192.168.150.9:5005/dav",
            rootPath = "", username = "", readOnly = false))
        awaitUntil(message = "denied") {
            lane.state.value.messageToken == LocalNetworkAccessBroker.CODE_DENIED
        }
        assertFalse(channel.calls.any { it.startsWith("mountAdd") })
        assertFalse(lane.state.value.busy)
    }

    @Test
    fun chainedGateDispatchRunsExactlyWhenPermissionResolves() = runBlocking {
        val pending = AtomicReference<(() -> Unit)?>()
        val gate: NetworkWorkspaceGate = { _, _, _, _, dispatch -> pending.set(dispatch); true }
        val controller = controller(gate)
        val lane = lane(controller)
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Team", transport = "webdav", endpoint = "http://192.168.150.9:5005/dav",
            rootPath = "", username = "", readOnly = false))
        // busy until the dialog actually dispatches
        awaitUntil(message = "pending") { pending.get() != null }
        assertTrue(lane.state.value.busy)
        pending.get()!!.invoke()
        awaitUntil(message = "dispatched") { channel.calls.any { it.startsWith("mountAdd") } }
        // dispatching again is a no-op (once flag)
        pending.get()!!.invoke()
        assertEquals(1, channel.calls.count { it.startsWith("mountAdd") })
    }

    @Test
    fun busyLaneRefusesSecondAction() = runBlocking {
        val holding = AtomicReference<(() -> Unit)?>()
        val gate: NetworkWorkspaceGate = { _, _, _, _, dispatch -> holding.set(dispatch); true }
        val controller = controller(gate)
        val lane = lane(controller)
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "One", transport = "webdav", endpoint = "https://a.example.test",
            rootPath = "", username = "", readOnly = false))
        awaitUntil(message = "pending") { holding.get() != null }
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Two", transport = "webdav", endpoint = "https://b.example.test",
            rootPath = "", username = "", readOnly = false))
        assertEquals("busy", lane.state.value.messageToken)
        // release the first chain
        holding.get()!!.invoke()
        awaitUntil(message = "first ran") { channel.calls.any { it.contains("name=One") || it.contains(":One:") } }
    }

    // ------------------------------------------------------------------
    // 4. operations: cancel REQUEST vs physical settlement
    // ------------------------------------------------------------------

    @Test
    fun operationStaysVisibleUntilNativeTerminalAndDismissRefusesLive() = runBlocking {
        val controller = controller()
        val lane = lane(controller)
        val running = """{"ok":1,"id":5,"kind":"import","mountID":"M5",
            "state":"running","phase":"stream","bytesDone":100,"totalBytes":200,
            "entriesDone":0,"entriesFailed":0,"failures":[],"errorCode":"","retryable":0,"result":{}}"""
        val cancelling = running.replace("running", "cancelRequested")
        val cancelled = running.replace("running", "cancelled").replace("stream", "cancelled")
        channel.opStatusScript.set(listOf(running, cancelling, cancelled))
        channel.opCancelStatus = 0
        channel.opCloseStatus = -604
        lane.startImport("M5", "big.bin", "Big/big.bin", false, false, "https://dav.example.test")
        awaitUntil(message = "running entry") { lane.state.value.operations.any { it.state == "running" } }
        val ticket = lane.state.value.operations.first().id
        lane.cancelOperation(ticket)
        awaitUntil(message = "request visible") {
            lane.state.value.operations.any { it.state == "cancelRequested" }
        }
        assertTrue(channel.calls.any { it.startsWith("opCancel:") })
        // dismiss a non-terminal entry: native refused (-604) => still listed
        lane.dismissOperation(lane.state.value.operations.first().id)
        awaitUntil(message = "close attempted") { channel.calls.any { it.startsWith("opClose:") } }
        // terminal arrival removes liveness; then dismissal succeeds
        channel.opCloseStatus = 0
        awaitUntil(message = "settled") { lane.state.value.operations.none { it.isLive } }
        lane.dismissOperation(lane.state.value.operations.first().id)
        awaitUntil(message = "gone") { lane.state.value.operations.isEmpty() }
    }

    // ------------------------------------------------------------------
    // 5. epoch retirement
    // ------------------------------------------------------------------

    @Test
    fun retireEpochFencesLateWorkAndRuntimeBecomesUnavailable() = runBlocking {
        val controller = controller()
        val lane = lane(controller)
        lane.refresh()
        awaitUntil(message = "refresh ran") { channel.calls.contains("mountPage") }
        epochHolder.set(epochHolder.get() + 1)   // root rebind
        controller.retireEpoch(epochHolder.get() - 1)
        lane.refresh()
        awaitUntil(message = "fenced") { !lane.state.value.runtimeAvailable }
        // a late chain-dispatch after retire must not present stale availability
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Late", transport = "webdav", endpoint = "https://x.example.test",
            rootPath = "", username = "", readOnly = false))
        awaitUntil(message = "refused", timeoutMillis = 2_000) {
            lane.state.value.messageToken == "runtimeUnavailable" ||
                lane.state.value.messageToken == "epochMismatch"
        }
    }

    @Test
    fun okZeroBodyCredentialFailureSurfacesClosedToken() = runBlocking {
        val controller = controller()
        val lane = lane(controller)
        channel.mountAddBody = { """{"ok":0,"errorCode":"credentialTicketRefused"}""" }
        lane.addMount(NetworkWorkspaceHostController.NetworkMountDraft(
            name = "Team", transport = "smb", endpoint = "smb://fileserv/share",
            rootPath = "", username = "bob", readOnly = false,
            password = "x".toCharArray()))
        awaitUntil(message = "token") { lane.state.value.messageToken == "credentialTicketRefused" }
        // the refused path leaves no mounted rows and no busy latch
        assertFalse(lane.state.value.busy)
        assertNull(lane.state.value.mounts.firstOrNull())
    }
}
