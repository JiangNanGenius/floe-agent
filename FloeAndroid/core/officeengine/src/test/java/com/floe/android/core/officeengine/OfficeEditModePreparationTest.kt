// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic JVM source for the real page-edit handshake and ordered dispatch. */
class OfficeEditModePreparationTest {

    private class FakeHost : OfficeEditModePreparation.Host {
        lateinit var preparation: OfficeEditModePreparation
        var mountLive = true
        var editableReady = true
        var pageEditMode = false
        var hookResult = true
        var schedulerAvailable = true
        var beforeNative: (() -> Unit)? = null

        val events = ArrayList<String>()
        val diagnostics = ArrayList<String>()
        private val timeouts = ArrayList<Runnable>()
        private val cancelledTimeouts = HashSet<Int>()
        private data class QueuedHook(
            val token: OfficeEditModePreparationToken,
            val callback: (Boolean) -> Unit,
        )
        private val hooks = ArrayList<QueuedHook>()

        override fun isMountLive() = mountLive
        override fun isEditableReady() = editableReady
        override fun isPageEditMode() = pageEditMode

        override fun sendNativeEditable(token: OfficeEditModePreparationToken): Boolean {
            beforeNative?.invoke()
            // Mirrors Session's actual execution-point token fence.
            return preparation.runIfActive(token) { events.add("native") }
        }

        override fun enterPageEditMode(
            token: OfficeEditModePreparationToken,
            onHookResult: (Boolean) -> Unit,
        ) {
            hooks.add(QueuedHook(token, onHookResult))
        }

        override fun runOnControlLane(task: Runnable): Boolean {
            task.run()
            return true
        }

        override fun scheduleTimeout(delayMs: Long, task: Runnable): Any? {
            if (!schedulerAvailable) return null
            timeouts.add(task)
            return timeouts.lastIndex
        }

        override fun cancelTimeout(handle: Any) {
            cancelledTimeouts.add(handle as Int)
        }

        override fun recordDiagnostic(detail: String) {
            diagnostics.add(detail)
        }

        fun runQueuedHook() {
            val hook = hooks.removeFirst()
            val started = preparation.runIfActive(hook.token) {
                events.add("js")
                hook.callback(hookResult)
            }
            if (!started) events.add("js-fenced")
        }

        fun emitPageEditMode(enabled: Boolean) {
            pageEditMode = enabled
            preparation.onPageEditMode(enabled)
        }

        /** Deliberately fires even a cancelled task to prove late callbacks stay fenced. */
        fun fireLatestTimeout() {
            timeouts.last().run()
        }

        fun queuedHookCount() = hooks.size
        fun nativeSendCount() = events.count { it == "native" }
    }

    private fun fixture(): Pair<FakeHost, OfficeEditModePreparation> {
        val host = FakeHost()
        val preparation = OfficeEditModePreparation(host)
        host.preparation = preparation
        return host to preparation
    }

    @Test
    fun barrierFalsePageFalseReadySequenceRequiresActualEditAck() {
        val host = FakeHost()
        val preparation = OfficeEditModePreparation(host)
        host.preparation = preparation
        // Exact C07 ordering: the load .uno:ReadOnly barrier was false and
        // READY_EDITABLE was promoted, but the page then reported Viewing.
        host.editableReady = true
        host.pageEditMode = false
        var result: OfficeEditModePreparationResult? = null

        preparation.prepare("select-1") { result = it }
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())

        // A successful JS hook invocation is NOT edit-mode evidence.
        host.runQueuedHook()
        assertNull(result)
        host.emitPageEditMode(true)
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-observed", result!!.detail)
    }

    @Test
    fun pageViewingDuringPreparationRefusesBeforeAnyOperation() {
        val (host, preparation) = fixture()
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-1") { result = it }
        host.emitPageEditMode(false)
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-viewing-during-edit-preparation", result?.detail)
    }

    @Test
    fun alreadyObservedEditingIsReadyWithoutOptimisticBootstrap() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("select-2") { result = it }
        assertTrue(result!!.isReady)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun timeoutAndLateAckCannotCompleteTwice() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-timeout") { results.add(it) }
        host.fireLatestTimeout()
        host.emitPageEditMode(true)
        assertEquals(1, results.size)
        assertEquals(OfficeEditModePreparationFailure.TIMEOUT, results.single().failure)
    }

    @Test
    fun readOnlyMountIsRefusedWithoutNativeOrPageMutation() {
        val (host, preparation) = fixture()
        host.editableReady = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("readonly") { result = it }
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertTrue(host.events.isEmpty())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun cancelAtNativeExecutionPointSuppressesSendAndLaterHook() {
        val (host, preparation) = fixture()
        var result: OfficeEditModePreparationResult? = null
        host.beforeNative = { preparation.cancel("apply-cancel-native") }

        preparation.prepare("apply-cancel-native") { result = it }
        // cancel owns the operation settlement; preparation itself is silent.
        assertNull(result)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
        host.emitPageEditMode(true)
        assertNull(result)
    }

    @Test
    fun cancelBeforeQueuedWebViewRunnableFencesJsAndTimeout() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-cancel-js") { results.add(it) }
        preparation.cancel("apply-cancel-js")
        host.runQueuedHook()
        host.fireLatestTimeout()
        assertTrue(results.isEmpty())
        assertEquals(listOf("native", "js-fenced"), host.events)
    }

    @Test
    fun closeBeforeQueuedHookFencesJsTimeoutAndFuturePreparation() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-close") { results.add(it) }
        preparation.close()
        host.runQueuedHook()
        host.fireLatestTimeout()
        host.emitPageEditMode(true)
        assertTrue(results.isEmpty())

        preparation.prepare("after-close") { results.add(it) }
        assertEquals(OfficeEditModePreparationFailure.SESSION_ENDING, results.single().failure)
        assertEquals(listOf("native", "js-fenced"), host.events)
    }

    @Test
    fun hookFailureIsTypedWithoutClaimingPageEdit() {
        val (host, preparation) = fixture()
        host.hookResult = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-hook-missing") { result = it }
        host.runQueuedHook()
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-edit-hook-unavailable", result?.detail)
    }

    @Test
    fun ownedDispatchRequiresPageModeAndOrdersNativeBeforeOperation() {
        val events = ArrayList<String>()
        var pageEditing = true
        val sent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = { events.add("native") },
            sendOperation = { events.add("operation") },
        )
        assertTrue(sent)
        assertEquals(listOf("native", "operation"), events)

        pageEditing = false
        val viewingSent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = { events.add("late-native") },
            sendOperation = { events.add("late-operation") },
        )
        assertFalse(viewingSent)
        assertEquals(listOf("native", "operation"), events)
    }

    @Test
    fun nativeReentryToViewingBlocksFollowingOperationSend() {
        val events = ArrayList<String>()
        var pageEditing = true
        val sent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = {
                events.add("native")
                pageEditing = false // synchronous host/page callback
            },
            sendOperation = { events.add("operation") },
        )
        assertFalse(sent)
        assertEquals(listOf("native"), events)
    }
}
