// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.host.WorkspaceSourceChannel
import com.floe.android.host.WorkspaceSourceHostController
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Headless runtime-owned lane isolation for the Office AI original push
 * (Main host20, AUTHORED NOTRUN — Main runs the composed batch). The
 * additive [WorkspaceSourceHostController.headlessLaneFor] map shares ONLY
 * the pure Lane ladder with the UI map: a live-ticket headless closure and a
 * UI pane owner closure can never rebind, steal or retire-race each other.
 * Pins: distinct instances per map, monotonic rebind inside each map only,
 * per-lane admission fences driving the SAME gateway provider independently,
 * and retireEpoch fencing BOTH maps (after which neither can rebind).
 */
class OfficeAiHeadlessLaneIsolationTest {

    private val task = UUID.randomUUID().toString()
    private val workspace = UUID.randomUUID().toString()
    private val epoch = 31L

    private val gatewayCalls = AtomicInteger()
    private val current = AtomicLong(epoch)
    private val tmp = File(System.getProperty("java.io.tmpdir"), "floe-headless-lane-" + UUID.randomUUID())

    /** Construction-only channel stub: no native hop may run in these
     * isolation checks (gatewayProvider stays null below, so the ladder
     * refuses before any channel call). */
    private object NoChannel : WorkspaceSourceChannel {
        private fun nope(): Nothing = throw AssertionError("native channel must not be reached")
        override fun stageOpen(epoch: Long, taskID: String, workspaceID: String, purpose: String,
            logicalPath: String, sourceReference: String, sourceDocumentID: String, sourceID: String): Long = nope()
        override fun stageWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int = nope()
        override fun stageFinish(ticket: Long, reply: ByteArray): Int = nope()
        override fun stageAbort(ticket: Long): Int = nope()
        override fun egressOpen(epoch: Long, mode: String, taskID: String, workspaceID: String,
            logicalPath: String, sourceID: String): Long = nope()
        override fun egressInfo(ticket: Long, reply: ByteArray): Int = nope()
        override fun egressRead(ticket: Long, offset: Long, target: ByteArray): Int = nope()
        override fun egressVerify(egressTicket: Long, stageTicket: Long, reply: ByteArray): Int = nope()
        override fun egressClose(ticket: Long): Int = nope()
        override fun savePrepare(saveTicket: Long, backupTicket: Long, receiptToken: String, reply: ByteArray): Int = nope()
        override fun saveClaim(saveTicket: Long, freshTicket: Long, reply: ByteArray): Int = nope()
        override fun savePermit(saveTicket: Long, receiptToken: String): Int = nope()
        override fun saveSettle(saveTicket: Long, readbackTicket: Long, reply: ByteArray): Int = nope()
        override fun saveRetain(saveTicket: Long, reply: ByteArray): Int = nope()
        override fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int = nope()
        override fun sourceLookup(epoch: Long, workspaceID: String, logicalPath: String, reply: ByteArray): Int = nope()
        override fun recoveryPage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int = nope()
        override fun reconcileRun(epoch: Long, workspaceID: String, reply: ByteArray): Int = nope()
        override fun reconcileStaged(epoch: Long, taskID: String, workspaceID: String, recoveryID: String,
            stageTicket: Long, reply: ByteArray): Int = nope()
        override fun hostStats(reply: ByteArray): Int = nope()
    }

    private fun newController(): WorkspaceSourceHostController {
        tmp.mkdirs()
        return WorkspaceSourceHostController(
            recoveryRoot = tmp,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob()),
            ioDispatcher = kotlinx.coroutines.Dispatchers.IO,
            currentNativeEpoch = { current.get().takeIf { it > 0 } },
            gatewayProvider = { _ -> gatewayCalls.incrementAndGet(); null },
            backendProvider = { null },
            channel = NoChannel,
        )
    }

    @Test
    fun headlessAndUiMapsNeverShareALaneInstance() {
        val controller = newController()
        var uiAlive = true
        var ticketAlive = true
        val ui = controller.laneFor(task, workspace, epoch, 5L) { uiAlive }
        val headless = controller.headlessLaneFor(task, workspace, epoch, 7L) { ticketAlive }
        assertNotNull(ui)
        assertNotNull(headless)
        assertNotSame(ui, headless)
        // Rebinding the UI lane to a newer pane NEVER touches the headless
        // lane (different map; its owner closure remains the ticket's).
        val uiRebound = controller.laneFor(task, workspace, epoch, 9L) { false }
        assertSame(ui, uiRebound)
        uiAlive = false
        runBlocking {
            // Dead UI owner fence: admission refuses BEFORE the gateway.
            val before = gatewayCalls.get()
            val result = ui!!.savePathToProvider("a.docx")
            assertEquals(before, gatewayCalls.get())
            assertEquals("runtimeUnavailable", result.status)
            // Live ticket closure on the SAME identity still reaches the
            // gateway admission (null provider here = honest refuse AFTER
            // admission; the counter proves the fence is the ticket's own).
            val headlessResult = headless!!.savePathToProvider("a.docx")
            assertEquals(before + 1, gatewayCalls.get())
            assertEquals("runtimeUnavailable", headlessResult.status)
        }
    }

    @Test
    fun rebindMonotonicityIsPerMapNeverCrossMap() {
        val controller = newController()
        val headless = controller.headlessLaneFor(task, workspace, epoch, 8L) { true }
        assertNotNull(headless)
        // Older generation into the SAME headless lane: refused.
        assertNull(controller.headlessLaneFor(task, workspace, epoch, 7L) { true })
        // The UI map is completely independent: it can bind at a LOWER
        // generation without seeing the headless lane's owner generation.
        assertNotNull(controller.laneFor(task, workspace, epoch, 1L) { true })
    }

    @Test
    fun retireEpochFencesBothMaps() {
        val controller = newController()
        val ui = controller.laneFor(task, workspace, epoch, 5L) { true }
        val headless = controller.headlessLaneFor(task, workspace, epoch, 5L) { true }
        assertNotNull(ui); assertNotNull(headless)
        controller.retireEpoch(epoch)
        assertFalse(ui!!.state.value.runtimeAvailable || ui.state.value.busy)
        // Retired epochs can never rebind either map again (permanent fence).
        assertNull(controller.laneFor(task, workspace, epoch, 6L) { true })
        assertNull(controller.headlessLaneFor(task, workspace, epoch, 6L) { true })
    }

    @Test
    fun invalidIdentityAndEpochFencesRefuseHeadlessBinding() {
        val controller = newController()
        assertNull(controller.headlessLaneFor("not-a-uuid", workspace, epoch, 1L) { true })
        assertNull(controller.headlessLaneFor(task, workspace, 0L, 1L) { true })
        current.set(epoch + 5)
        assertNull(controller.headlessLaneFor(task, workspace, epoch, 1L) { true })
    }
}
