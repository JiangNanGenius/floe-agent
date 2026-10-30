// SPDX-License-Identifier: MPL-2.0
//
// Focused pure-JVM tests for the G07.3A in-thread find semantics.
//
// These cover: whitespace-AND/quoted-phrase normalization, Unicode case/
// diacritic/width folding with offsets into the ORIGINAL visible string,
// Markdown-visible projection (link labels kept, hidden targets excluded),
// out-of-order query fencing, and the retained-hit selection rule.
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationThreadSearchTest {

    private val session = ConversationSessionToken("conv-1", 0L)

    @Test
    fun queryNormalizesWhitespaceAndQuotedPhrase() {
        val query = ThreadSearchQuery("  alpha \"beta gamma\"  ALPHA ")
        assertEquals(2, query.terms.size)
        assertEquals(ThreadSearchQuery.Term.Word("alpha"), query.terms[0])
        assertEquals(ThreadSearchQuery.Term.Phrase("beta gamma"), query.terms[1])
        assertTrue(query.matches("alpha and beta gamma"))
        assertFalse(query.matches("alpha only"))
    }

    @Test
    fun queryTermsAreBoundedAndEmptyIsNotAMatch() {
        val many = ThreadSearchQuery((1..20).joinToString(" ") { "w$it" })
        assertEquals(ThreadSearchQuery.MAXIMUM_TERMS, many.terms.size)
        val empty = ThreadSearchQuery("   ")
        assertTrue(empty.isEmpty)
        assertFalse(ThreadSearchMatcher.matches("anything", empty))
        assertEquals(emptyList<IntRange>(), ThreadSearchMatcher.ranges("anything", empty))
    }

    @Test
    fun assistantVisibleProjectionDropsMarkdownSyntaxAndHiddenUrl() {
        val source = "Read [docs](https://secret.example/private) and **now**."
        val visible = ThreadSearchVisible.visibleText(MessageRoleUi.ASSISTANT, source)
        assertEquals("Read docs and now.", visible)
        val docs = ThreadSearchQuery("docs")
        val secret = ThreadSearchQuery("secret")
        assertTrue(ThreadSearchMatcher.matches(visible, docs))
        assertFalse(ThreadSearchMatcher.matches(visible, secret))

        val fenced = ThreadSearchVisible.visibleText(
            MessageRoleUi.ASSISTANT,
            "intro\n```kotlin\nval hidden = 1\n```\nend",
        )
        assertTrue(fenced.contains("val hidden = 1"))
        assertFalse(fenced.contains("```"))
    }

    @Test
    fun userTextIsVerbatimAndNotMarkdownFlattened() {
        val source = "literal [not a link](x) **stars**"
        assertEquals(
            source,
            ThreadSearchVisible.visibleText(MessageRoleUi.USER, source),
        )
    }

    @Test
    fun unicodeFoldingMapsRangesToOriginalUtf16Offsets() {
        val text = "Café Ｆｌｏｅ"
        val cafe = ThreadSearchQuery("cafe")
        assertTrue(ThreadSearchMatcher.matches(text, cafe))
        val range = ThreadSearchMatcher.ranges(text, cafe).single()
        assertEquals(0, range.first)
        assertEquals("Café", text.substring(0, range.last + 1))

        val wide = ThreadSearchQuery("floe")
        assertTrue(ThreadSearchMatcher.matches(text, wide))
        val wideRange = ThreadSearchMatcher.ranges(text, wide).single()
        assertEquals("Ｆｌｏｅ", text.substring(wideRange.first, wideRange.last + 1))
    }

    @Test
    fun outOfOrderQueryRepliesAreDroppedWhole() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))

        holder.beginThreadSearch()
        holder.setThreadSearchQuery("first")
        holder.searchThread()
        val firstEpoch = holder.threadSearch.requestGeneration
        holder.setThreadSearchQuery("second")
        holder.searchThread()
        val secondEpoch = holder.threadSearch.requestGeneration
        assertTrue(secondEpoch > firstEpoch)

        holder.applyThreadSearchResult(
            session, firstEpoch,
            ThreadSearchResultUi(listOf(hit("m1", "first"))),
        )
        assertTrue(holder.threadSearch.hits.isEmpty())

        holder.applyThreadSearchResult(
            session, secondEpoch,
            ThreadSearchResultUi(listOf(hit("m2", "second"), hit("m3", "second"))),
        )
        assertEquals(2, holder.threadSearch.hits.size)
        assertEquals(1, holder.threadSearch.currentIndex)
        assertEquals("m3", holder.threadSearch.currentHit?.messageId)
    }

    @Test
    fun nextAndPreviousWrapAndEndKeepsSelectedHit() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.beginThreadSearch()
        holder.setThreadSearchQuery("hit")
        holder.searchThread()
        val generation = holder.threadSearch.requestGeneration
        holder.applyThreadSearchResult(
            session, generation,
            ThreadSearchResultUi(listOf(hit("m1", "hit"), hit("m2", "hit"))),
        )
        assertEquals(1, holder.threadSearch.currentIndex)
        holder.nextThreadSearchHit()
        assertEquals(0, holder.threadSearch.currentIndex)
        holder.previousThreadSearchHit()
        assertEquals(1, holder.threadSearch.currentIndex)

        holder.endThreadSearch()
        assertFalse(holder.threadSearchVisible)
        assertEquals("m2", holder.threadSearch.focusedMessageId)
        assertTrue(holder.threadSearch.hits.isEmpty())
    }

    @Test
    fun staleFocusTokenCannotMoveTheSelection() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-1")
        holder.applyHostSnapshot(threadState(session))
        holder.beginThreadSearch()
        holder.setThreadSearchQuery("hit")
        holder.searchThread()
        val generation = holder.threadSearch.requestGeneration
        holder.applyThreadSearchResult(
            session, generation, ThreadSearchResultUi(listOf(hit("m1", "hit"))),
        )
        val token = holder.threadSearch.focusRowToken
        holder.applyThreadSearchFocus(session, token + 1, "foreign")
        assertEquals("m1", holder.threadSearch.focusedMessageId)
    }

    @Test
    fun temporarySearchResultRequiresTemporaryProjection() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "conv-temp")
        holder.applyHostSnapshot(
            threadState(ConversationSessionToken("conv-temp", 0L), isTemporary = true),
        )
        holder.beginThreadSearch()
        holder.setThreadSearchQuery("x")
        holder.searchThread()
        val generation = holder.threadSearch.requestGeneration
        holder.applyThreadSearchResult(
            ConversationSessionToken("conv-temp", 0L), generation,
            ThreadSearchResultUi(listOf(hit("m1", "x")), isTemporary = false),
        )
        assertTrue(holder.threadSearch.hits.isEmpty())
    }

    private fun hit(id: String, snippet: String) = ThreadSearchHitUi(
        messageId = id,
        role = MessageRoleUi.ASSISTANT,
        snippet = snippet,
        createdAtLabel = "10:00",
    )
}
