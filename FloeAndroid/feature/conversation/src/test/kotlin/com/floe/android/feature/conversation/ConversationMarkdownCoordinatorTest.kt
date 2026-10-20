// SPDX-License-Identifier: MPL-2.0
//
// Async Markdown projection coordinator tests (dependency qualification gate:
// see ConversationMarkdownUi.kt header). These pin the CONTRACT only — no
// Markdown parser runs here:
//  - composition never parses; requests are scheduled once per fragment with
//    a monotonic generation;
//  - late/superseded/foreign-generation echoes cannot style another fragment;
//  - a missing backend or a failed parse falls back to LITERAL recovery so
//    content is never dropped (and no styled parity is claimed);
//  - the cache is LRU-bounded (streaming tails churn) and fully invalidated
//    on rebind/retirement;
//  - the streaming window split mirrors MarkdownRendererView.streamingParts().

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationMarkdownCoordinatorTest {

    private fun holder(host: RecordingHost): ConversationFlowHolder {
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(holder.session))
        return holder
    }

    @Test
    fun scheduleIsExactlyOncePerFragmentWithMonotonicGenerations() {
        val host = RecordingHost()
        val holder = holder(host)

        holder.ensureMarkdownParse("hello")
        holder.ensureMarkdownParse("hello")

        assertEquals(1, host.count("requestMarkdownParse"))
        val generation = host.lastArgs("requestMarkdownParse")!![2] as Long
        assertTrue(generation > 0)
        assertTrue(holder.markdownState("hello") is MarkdownContentUi.Preparing)
    }

    @Test
    fun staleGenerationEchoIsDropped() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.ensureMarkdownParse("a")
        val generation = host.lastArgs("requestMarkdownParse")!![2] as Long

        holder.applyMarkdownParseResult(holder.session, "a", generation + 5, listOf(MarkdownBlockUi.ThematicBreak))
        assertTrue(holder.markdownState("a") is MarkdownContentUi.Preparing)

        holder.applyMarkdownParseResult(holder.session, "a", generation, listOf(MarkdownBlockUi.ThematicBreak))
        assertTrue(holder.markdownState("a") is MarkdownContentUi.Parsed)
    }

    @Test
    fun foreignSessionEchoCannotStyleThisThread() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.ensureMarkdownParse("a")
        val generation = host.lastArgs("requestMarkdownParse")!![2] as Long

        holder.applyMarkdownParseResult(
            ConversationSessionToken("conv-1", holder.session.sessionEpoch + 9),
            "a",
            generation,
            listOf(MarkdownBlockUi.ThematicBreak),
        )

        assertTrue(holder.markdownState("a") is MarkdownContentUi.Preparing)
    }

    @Test
    fun unavailableBackendFallsBackToLiteralRecovery() {
        val host = RecordingHost()
        host.markdownBackendAvailable = false
        val holder = holder(host)

        holder.ensureMarkdownParse("plain text stays visible")

        val state = holder.markdownState("plain text stays visible")
        assertTrue(state is MarkdownContentUi.Literal)
        assertEquals(MarkdownLiteralReason.BACKEND_UNAVAILABLE, (state as MarkdownContentUi.Literal).reason)
        assertEquals("plain text stays visible", state.text)
        // No rescheduling loop once the fallback is recorded.
        holder.ensureMarkdownParse("plain text stays visible")
        assertEquals(1, host.names().count { it == "requestMarkdownParse" })
    }

    @Test
    fun failedParseFallsBackToLiteralWithoutDroppingContent() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.ensureMarkdownParse("# heading")
        val generation = host.lastArgs("requestMarkdownParse")!![2] as Long

        holder.applyMarkdownParseResult(holder.session, "# heading", generation, null)

        val state = holder.markdownState("# heading")
        assertTrue(state is MarkdownContentUi.Literal)
        assertEquals(MarkdownLiteralReason.PARSE_FAILED, (state as MarkdownContentUi.Literal).reason)
        assertEquals("# heading", state.text)
    }

    @Test
    fun cacheIsLruBoundedUnderStreamingTailChurn() {
        val host = RecordingHost()
        val holder = holder(host)
        repeat(MAX_MARKDOWN_CACHE_ENTRIES + 20) { index ->
            val source = "tail-$index"
            holder.ensureMarkdownParse(source)
            val generation = host.lastArgs("requestMarkdownParse")!![2] as Long
            holder.applyMarkdownParseResult(holder.session, source, generation, listOf(MarkdownBlockUi.ThematicBreak))
        }
        assertTrue(holder.markdownCacheSize() <= MAX_MARKDOWN_CACHE_ENTRIES)
    }

    @Test
    fun rebindInvalidatesParsedCache() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.ensureMarkdownParse("abc")
        val generation = host.lastArgs("requestMarkdownParse")!![2] as Long
        holder.applyMarkdownParseResult(holder.session, "abc", generation, listOf(MarkdownBlockUi.ThematicBreak))
        assertTrue(holder.markdownState("abc") is MarkdownContentUi.Parsed)

        holder.rebind("conv-2")

        assertTrue(holder.markdownState("abc") is MarkdownContentUi.Preparing)
        assertEquals(0, holder.markdownCacheSize())
    }

    @Test
    fun retirementStopsSchedulingNewParses() {
        val host = RecordingHost()
        val holder = holder(host)
        holder.retireForNavigation()
        val before = host.count("requestMarkdownParse")

        holder.ensureMarkdownParse("never")

        assertEquals(before, host.count("requestMarkdownParse"))
    }

    /* ------------------------------ window split ------------------------------ */

    @Test
    fun windowSplitKeepsCompletedPrefixAndTail() {
        val parts = StreamingMarkdownWindow.split("line one\nline two")
        assertEquals("line one\n", parts.completedSource)
        assertEquals("line two", parts.tailSource)
    }

    @Test
    fun windowSplitWithoutNewlineIsAllTail() {
        val parts = StreamingMarkdownWindow.split("# partial")
        assertEquals("", parts.completedSource)
        assertEquals("# partial", parts.tailSource)
    }

    @Test
    fun windowSuffixIsBoundedAndContiguous() {
        val long = "x".repeat(MAXIMUM_STREAMING_CHARACTERS + 500) + "\ntail"
        val parts = StreamingMarkdownWindow.split(long)
        val visible = long.takeLast(MAXIMUM_STREAMING_CHARACTERS)
        val joined = parts.completedSource + parts.tailSource
        assertEquals(visible, joined)
        assertEquals("tail", parts.tailSource)
    }
}
