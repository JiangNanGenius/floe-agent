// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused regression for the ACTUAL live-file receipt resolver used by
 * [LinuxShellPump.handle] (G07.3A repaired live tree/read path).
 *
 * `workspace.files.tree` and `workspace.files.read` are queued RuntimeKernel
 * execute() operations, not the synchronous `shell.poll` memory snapshot.
 * Forwarding their immediate `state=queued` control receipt made the Core
 * live-file mailbox answer `replyMalformed` even though the engine request was
 * valid. These cases drive the same resolver that now polls the exact
 * requestID to a completed result, including the typed retry/refused results
 * and the bounded read-only timeout (which must never stop a terminal).
 */
class LinuxShellLiveFileReceiptTest {

    @Test
    fun queuedReceiptIsPolledToTheCompletedResultAndNeverForwarded() = runBlocking {
        val polled = mutableListOf<String>()
        var pollCount = 0
        val result = LinuxShellPump.awaitLiveFileReceipt(
            first = JSONObject().put("state", "queued").put("requestID", "file-1"),
            poll = { requestID ->
                polled += requestID
                pollCount += 1
                if (pollCount == 1) {
                    JSONObject().put("state", "running").put("requestID", requestID)
                } else {
                    JSONObject().put("state", "completed").put(
                        "result",
                        JSONObject().put("state", "ok").put("entries", 2),
                    )
                }
            },
            budgetMillis = 2_000L,
        )
        assertEquals(listOf("file-1", "file-1"), polled)
        assertEquals("ok", result.getString("state"))
        assertEquals(2, result.getInt("entries"))
        assertFalse("the queued control receipt must never leak as the result",
            result.has("requestID"))
    }

    @Test
    fun immediateCompletedReceiptNeedsNoPoll() = runBlocking {
        var polls = 0
        val result = LinuxShellPump.awaitLiveFileReceipt(
            first = JSONObject().put("state", "completed").put(
                "result", JSONObject().put("state", "ok"),
            ),
            poll = {
                polls += 1
                JSONObject().put("state", "queued")
            },
            budgetMillis = 100L,
        )
        assertEquals(0, polls)
        assertEquals("ok", result.getString("state"))
    }

    @Test
    fun completedRetryAndRefusedResultsRideThroughUnchanged() = runBlocking {
        for ((state, code) in listOf(
            "retry" to "changedDuringRead",
            "refused" to "staleSession",
        )) {
            val result = LinuxShellPump.awaitLiveFileReceipt(
                first = JSONObject().put("state", "completed").put(
                    "result", JSONObject().put("state", state).put("code", code),
                ),
                poll = { error("a completed receipt must not be polled") },
                budgetMillis = 100L,
            )
            assertEquals(state, result.getString("state"))
            assertEquals(code, result.getString("code"))
        }
    }

    @Test
    fun failedReceiptIsATypedFailureNotAQueuedForward() = runBlocking {
        var failed = false
        try {
            LinuxShellPump.awaitLiveFileReceipt(
                first = JSONObject().put("state", "queued").put("requestID", "file-2"),
                poll = {
                    JSONObject().put("state", "failed").put("code", "operation_failed")
                },
                budgetMillis = 100L,
            )
        } catch (_: IllegalStateException) {
            failed = true
        }
        assertTrue("a failed kernel receipt must surface as failure", failed)
    }

    @Test
    fun boundedWaitReturnsTypedRetryWithoutStoppingAnything() = runBlocking {
        var polls = 0
        val started = System.nanoTime()
        val result = LinuxShellPump.awaitLiveFileReceipt(
            first = JSONObject().put("state", "queued").put("requestID", "file-3"),
            poll = {
                polls += 1
                JSONObject().put("state", "running").put("requestID", "file-3")
            },
            budgetMillis = 120L,
        )
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertEquals("retry", result.getString("state"))
        assertEquals("awaitBudgetExpired", result.getString("code"))
        assertTrue("the resolver really polled before its budget expired", polls >= 1)
        assertTrue("bounded wait returned (${elapsedMillis}ms)", elapsedMillis < 2_000)
    }
}
