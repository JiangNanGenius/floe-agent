// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.toolresults

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolResultDetailReducerTest {
    private fun page(
        offset: Int,
        text: String,
        end: Int = offset + text.toByteArray(Charsets.UTF_8).size,
        next: Int? = null,
        total: Int = end,
        sha: String = "a".repeat(64),
        ref: String = "tr_" + "b".repeat(24),
        callId: String = "call-1",
        executionTruncated: Boolean = false,
        retentionTruncated: Boolean = false,
    ) = ToolResultPageUi(
        ref = ref,
        runId = "run-1",
        callId = callId,
        toolName = "exec.shell",
        status = "ok",
        offset = offset,
        endOffset = end,
        nextOffset = next,
        totalBytes = total,
        text = text,
        sha256 = sha,
        originalDigest = null,
        executionReportedTruncation = executionTruncated,
        retentionTruncated = retentionTruncated,
        durability = "durable",
        restoredFromDisk = false,
        evictedCopies = 0,
    )

    @Test
    fun temporaryConversationNeverOpensAPersistentReader() {
        val state = ToolResultDetailReducer.open("task", "call", null, temporary = true)
        assertEquals(ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE, state.phase)
        assertFalse(state.inFlight)
    }

    @Test
    fun pageUsesActualNextOffsetAndNeverSkipsBytes() {
        var state = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        assertEquals(0, state.offset)
        state = ToolResultDetailReducer.loaded(
            state,
            page(offset = 0, text = "abc中", next = 5, total = 10),
        )
        assertEquals(ToolResultDetailState.Phase.READY, state.phase)
        assertEquals(5, state.offset)
        assertEquals(5, state.endOffset)
        assertEquals(5, state.nextOffset)
        assertEquals("abc中", state.text)
    }

    @Test
    fun replyThatStartsAtTheWrongOffsetFailsClosed() {
        val opened = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        val first = ToolResultDetailReducer.loaded(
            opened,
            page(offset = 0, text = "abcde", next = 5, total = 10),
        )
        val second = ToolResultDetailReducer.loadingFrom(first, 5)
        val wrong = ToolResultDetailReducer.loaded(
            second,
            page(offset = 6, text = "fghij", next = null, total = 10),
        )
        assertEquals(ToolResultDetailState.Phase.ERROR, wrong.phase)
        assertEquals("cursorMismatch", wrong.errorCode)
    }

    @Test
    fun declaredWindowMustMatchDeliveredUtf8Bytes() {
        val opened = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        val bad = ToolResultDetailReducer.loaded(
            opened,
            page(offset = 0, text = "😀", end = 8, total = 8),
        )
        assertEquals(ToolResultDetailState.Phase.ERROR, bad.phase)
        assertEquals("badWindow", bad.errorCode)
    }

    @Test
    fun nextOffsetMustEqualEndOffset() {
        val opened = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        val bad = ToolResultDetailReducer.loaded(
            opened,
            page(offset = 0, text = "abcd", next = 9, total = 9),
        )
        assertEquals(ToolResultDetailState.Phase.ERROR, bad.phase)
        assertEquals("cursorMismatch", bad.errorCode)
    }

    @Test
    fun changedDigestBetweenPagesIsRefused() {
        val opened = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        val first = ToolResultDetailReducer.loaded(
            opened,
            page(offset = 0, text = "abcd", next = 4, total = 8, sha = "a".repeat(64)),
        )
        val second = ToolResultDetailReducer.loadingFrom(first, 4)
        val changed = ToolResultDetailReducer.loaded(
            second,
            page(offset = 4, text = "efgh", next = null, total = 8, sha = "c".repeat(64)),
        )
        assertEquals(ToolResultDetailState.Phase.ERROR, changed.phase)
        assertEquals("staleCapture", changed.errorCode)
        assertEquals("abcd", changed.text)
    }

    @Test
    fun missingAndTemporaryFailuresStayHonest() {
        val opened = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        val missing = ToolResultDetailReducer.failed(opened, "missing", "not retained")
        assertEquals(ToolResultDetailState.Phase.LEGACY_SUMMARY_ONLY, missing.phase)
        assertFalse(missing.inFlight)
        val temporary = ToolResultDetailReducer.failed(opened, "temporaryTaskRefused", "RAM only")
        assertEquals(ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE, temporary.phase)
    }

    @Test
    fun pagesReassembleToTheRetainedDigestWithNoGaps() {
        val text = buildString {
            repeat(200) { append("值😀abc-") }
        }
        val bytes = text.toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        var state = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        var emitted = ByteArray(0)
        var offset = 0
        var pageCount = 0
        while (offset < bytes.size) {
            var end = minOf(offset + 7, bytes.size)
            // The native store returns whole-scalar windows; mirror that
            // boundary instead of inventing U+FFFD bytes. Trimming a trailing
            // lead byte is as important as trimming a continuation byte.
            while (end > offset) {
                val candidate = bytes.copyOfRange(offset, end)
                val text = String(candidate, Charsets.UTF_8)
                if (text.toByteArray(Charsets.UTF_8).contentEquals(candidate)) break
                end -= 1
            }
            val window = bytes.copyOfRange(offset, end)
            val windowText = String(window, Charsets.UTF_8)
            if (state.phase == ToolResultDetailState.Phase.READY) {
                state = ToolResultDetailReducer.next(state)
            }
            state = ToolResultDetailReducer.loaded(
                state,
                page(
                    offset = offset,
                    text = windowText,
                    end = end,
                    next = if (end < bytes.size) end else null,
                    total = bytes.size,
                    sha = digest,
                ),
            )
            assertEquals(ToolResultDetailState.Phase.READY, state.phase)
            emitted += state.text.toByteArray(Charsets.UTF_8)
            offset = state.endOffset
            pageCount += 1
            assertTrue(pageCount < 100_000)
        }
        assertTrue(pageCount > 100)
        assertTrue(emitted.contentEquals(bytes))
        assertEquals(digest, state.sha256)
        assertNull(state.nextOffset)
    }

    @Test
    fun previousAndNextUseVisitedOffsets() {
        var state = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        state = ToolResultDetailReducer.loaded(
            state,
            page(offset = 0, text = "abcd", next = 4, total = 8),
        )
        state = ToolResultDetailReducer.next(state)
        assertEquals(4, state.offset)
        state = ToolResultDetailReducer.loaded(
            state,
            page(offset = 4, text = "efgh", next = null, total = 8),
        )
        assertTrue(state.hasPrevious)
        state = ToolResultDetailReducer.previous(state)
        assertEquals(0, state.offset)
        assertEquals(0, state.previousOffsets.size)
        assertFalse(state.hasPrevious)
    }

    @Test
    fun restartClearsBytesAndDigestAfterAChangedRecord() {
        var state = ToolResultDetailReducer.open("task", "call", null, temporary = false)
        state = ToolResultDetailReducer.loaded(
            state,
            page(offset = 0, text = "abcd", next = 4, total = 8, sha = "a".repeat(64)),
        )
        state = ToolResultDetailReducer.loadingFrom(state, 4)
        state = ToolResultDetailReducer.loaded(
            state,
            page(offset = 4, text = "efgh", next = null, total = 8, sha = "b".repeat(64)),
        )
        assertEquals(ToolResultDetailState.Phase.ERROR, state.phase)
        state = ToolResultDetailReducer.restart(state)
        assertEquals(ToolResultDetailState.Phase.LOADING, state.phase)
        assertEquals(0, state.offset)
        assertEquals("", state.text)
        assertNull(state.sha256)
        assertNull(state.nextOffset)
        assertTrue(state.previousOffsets.isEmpty())
    }

    @Test
    fun captureStateNeverClaimsDroppedBytesAreRecoverable() {
        val complete = page(0, "abc")
        assertEquals("complete", complete.captureState)
        val upstream = page(0, "abc", executionTruncated = true)
        assertEquals("executionOutputTruncated", upstream.captureState)
        val retained = page(0, "abc", retentionTruncated = true)
        assertEquals("retentionTruncated", retained.captureState)
        val both = page(0, "abc", executionTruncated = true, retentionTruncated = true)
        assertEquals("executionOutputTruncated+retentionTruncated", both.captureState)
        assertNotNull(complete.sha256)
    }
}
