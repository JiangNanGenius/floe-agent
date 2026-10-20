// SPDX-License-Identifier: MPL-2.0
//
// REAL commonmark-java adapter qualification (Main's Markdown gate):
//  - golden corpus over the audited ORIGINAL FloeMarkdown subset
//    (heading/paragraph/list/quote/code/table/thematicBreak — no math case):
//    structure is compared against that subset; this is explicitly NOT a
//    full native-render equality claim;
//  - verbatim fenced code, exact inline runs (bold/italic/strike/code/link),
//    nested lists, quotes with inner blocks, GFM tables, streaming partial
//    fences, malformed input, CJK, emoji, and the "content never dropped"
//    rule for unknown/raw-HTML syntax (literal fallback, never HTML nodes);
//  - budgets: input ceiling, AST-node ceiling, depth ceiling abort to the
//    honest Literal recovery;
//  - [MarkdownParseService]: off-UI-thread workers, bounded pending queue,
//    latest-generation conflation per fragment, oldest-drop under pressure,
//    close() release semantics, determinism, and the end-to-end holder echo
//    over the REAL adapter (no fake backend).

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class ConversationCommonMarkAdapterTest {

    private fun parse(source: String): List<MarkdownBlockUi>? =
        CommonMarkMarkdownParser.parseFragment(source)

    /* ------------------------------ golden corpus ------------------------------ */

    @Test
    fun headingsLevelsOneThroughSix() {
        val blocks = parse(
            "# H1\n\n## H2\n\n###### H6\n",
        )!!
        assertEquals(
            listOf(
                MarkdownBlockUi.Heading(1, InlineTextUi.plain("H1")),
                MarkdownBlockUi.Heading(2, InlineTextUi.plain("H2")),
                MarkdownBlockUi.Heading(6, InlineTextUi.plain("H6")),
            ),
            blocks,
        )
    }

    @Test
    fun inlineRunsBoldItalicStrikeCodeLinkStayDistinctSpans() {
        val blocks = parse("a **b** *c* ~~d~~ `e` [f](https://example.invalid/x)")!!
        val paragraph = blocks.single() as MarkdownBlockUi.Paragraph
        val spans = paragraph.text.spans
        // Inter-scope spaces are their own literal spans (exact selectable
        // copy text is preserved by construction).
        assertEquals(listOf("a ", "b", " ", "c", " ", "d", " ", "e", " ", "f"), spans.map { it.text })
        assertEquals(InlineSpanUi("b", bold = true), spans[1])
        assertEquals(InlineSpanUi("c", italic = true), spans[3])
        assertEquals(InlineSpanUi("d", strikethrough = true), spans[5])
        assertEquals(InlineSpanUi("e", code = true), spans[7])
        assertEquals(
            InlineSpanUi("f", linkUrl = "https://example.invalid/x"),
            spans[9],
        )
        // plainText is the exact selectable/copyable text (link labels kept,
        // URL is not spliced into the text).
        assertEquals("a b c d e f", paragraph.text.plainText)
        assertTrue(paragraph.text.hasLinks)
    }

    @Test
    fun nestedListsPreserveChildrenAndOrderFlags() {
        val blocks = parse(
            """
            - outer
              - inner a
            - second
            """.trimIndent(),
        )!!
        val list = blocks.single() as MarkdownBlockUi.ListBlock
        assertEquals(false, list.ordered)
        assertEquals(2, list.items.size)
        val outer = list.items[0]
        assertEquals("outer", outer.content.plainText)
        assertEquals(1, outer.children.size)
        val inner = outer.children.single() as MarkdownBlockUi.ListBlock
        assertEquals(false, inner.ordered) // bullet list nested
        assertEquals("inner a", inner.items.single().content.plainText)
        assertEquals("second", list.items[1].content.plainText)

        val ordered = parse("1. one\n2. two\n")!!.single() as MarkdownBlockUi.ListBlock
        assertTrue(ordered.ordered)
        assertEquals(listOf("one", "two"), ordered.items.map { it.content.plainText })
    }

    @Test
    fun quotesHoldNestedBlocksRecursively() {
        val blocks = parse("> quoted **text**\n>\n> - nested item\n")!!
        val quote = blocks.single() as MarkdownBlockUi.Quote
        assertEquals(2, quote.inner.size)
        assertEquals(
            "quoted text",
            (quote.inner[0] as MarkdownBlockUi.Paragraph).text.plainText,
        )
        assertEquals(true, (quote.inner[0] as MarkdownBlockUi.Paragraph).text.spans[1].bold)
        val list = quote.inner[1] as MarkdownBlockUi.ListBlock
        assertEquals("nested item", list.items.single().content.plainText)
    }

    @Test
    fun fencedCodeIsVerbatimAndLanguageFromInfoString() {
        val body = "val a=1\n  indented   kept\nemoji 🎯 exact\n"
        val blocks = parse("```kotlin\n$body```\n")!!
        val code = blocks.single() as MarkdownBlockUi.CodeBlock
        assertEquals("kotlin", code.language)
        assertEquals(body, code.code) // EXACT verbatim, no trimming
        val bare = parse("```\nplain\n```")!!.single() as MarkdownBlockUi.CodeBlock
        assertNull(bare.language)
        val indented = parse("    indented code\n")!!.single() as MarkdownBlockUi.CodeBlock
        assertNull(indented.language)
        assertEquals("indented code\n", indented.code)
    }

    @Test
    fun gfmTableMapsHeaderRowsAndInlineCells() {
        val blocks = parse(
            """
            | Col a | Col b |
            |-------|-------|
            | **x** | `y`   |
            | 1     | 2     |
            """.trimIndent(),
        )!!
        val table = blocks.first { it is MarkdownBlockUi.Table } as MarkdownBlockUi.Table
        assertEquals(listOf("Col a", "Col b"), table.header.map { it.plainText })
        assertEquals(2, table.rows.size)
        assertTrue(table.rows[0][0].spans.single().bold)
        assertEquals("x", table.rows[0][0].plainText)
        assertTrue(table.rows[0][1].spans.single().code)
        assertEquals(listOf("1", "2"), table.rows[1].map { it.plainText })
    }

    @Test
    fun thematicBreakAndParagraphs() {
        val blocks = parse("para\n\n---\n\nnext\n")!!
        assertEquals(3, blocks.size)
        assertTrue(blocks[1] is MarkdownBlockUi.ThematicBreak)
    }

    @Test
    fun streamingPartialFenceKeepsAllContentInsideCode() {
        // An unterminated fence (the streaming tail case): the partial block
        // still yields a code block containing everything sent so far.
        val blocks = parse("intro\n\n```python\nprint('half')\nmore incoming")!!
        assertTrue(blocks[0] is MarkdownBlockUi.Paragraph)
        val code = blocks[1] as MarkdownBlockUi.CodeBlock
        assertEquals("python", code.language)
        assertTrue(code.code.startsWith("print('half')"))
        assertTrue(code.code.contains("more incoming"))
    }

    @Test
    fun malformedInputKeepsContentNeverDrops() {
        // Unclosed emphasis and stray markers degrade to literal text.
        val blocks = parse("broken **bold and `code never closed~~")!!
        val text = blocks.joinToString("") { block ->
            when (block) {
                is MarkdownBlockUi.Paragraph -> block.text.plainText
                else -> ""
            }
        }
        assertTrue("content preserved: $text", text.contains("broken"))
        assertTrue(text.contains("bold"))
        assertTrue(text.contains("never closed"))
    }

    @Test
    fun rawHtmlDegradesToLiteralTextAndNeverProducesHtml() {
        val blocks = parse("before\n\n<div>raw **not rendered**</div>\n\nafter\n")!!
        val htmlLiteral = blocks.filterIsInstance<MarkdownBlockUi.Paragraph>()
            .first { it.text.plainText.contains("<div>") }
        // The markup survives as LITERAL, selectable text — never projected
        // as HTML, never executed; the block vocabulary itself has no HTML
        // case, which is the structural guarantee the golden test pins.
        assertTrue(htmlLiteral.text.plainText.contains("raw **not rendered**</div>"))
        assertTrue(blocks.any { (it as? MarkdownBlockUi.Paragraph)?.text?.plainText == "before" })
        assertTrue(blocks.any { (it as? MarkdownBlockUi.Paragraph)?.text?.plainText == "after" })
    }

    @Test
    fun cjkEmojiAndLinksSurviveRoundTrip() {
        val source = "## 总结\n\n- 关键：**中文要点** 🎉\n- 参考 [文档](https://example.invalid/文档)\n"
        val blocks = parse(source)!!
        val heading = blocks[0] as MarkdownBlockUi.Heading
        assertEquals(2, heading.level)
        assertEquals("总结", heading.text.plainText)
        val list = blocks[1] as MarkdownBlockUi.ListBlock
        assertEquals("关键：中文要点 🎉", list.items[0].content.plainText)
        val linkSpan = list.items[1].content.spans.first { it.linkUrl != null }
        assertEquals("文档", linkSpan.text)
        assertTrue(linkSpan.linkUrl!!.contains("example.invalid"))
    }

    @Test
    fun parseIsDeterministicForEqualInput() {
        val source = "# T\n\n- a\n  - b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n> q\n"
        assertEquals(parse(source), parse(source))
    }

    /* -------------------------------- budgets -------------------------------- */

    @Test
    fun oversizedInputFailsClosedToNullLiteralFallback() {
        val tooBig = "a".repeat(MarkdownParseBudgets.MAX_INPUT_CHARACTERS + 1)
        assertNull(parse(tooBig))
        // Exactly at the ceiling is accepted (bounded, and a single long
        // paragraph parses quickly — the parser is O(input)).
        val atLimit = "a".repeat(MarkdownParseBudgets.MAX_INPUT_CHARACTERS)
        val blocks = parse(atLimit)
        assertNotNull(blocks)
        assertEquals(atLimit, (blocks!!.single() as MarkdownBlockUi.Paragraph).text.plainText)
    }

    @Test
    fun deepNestingAbortsInsteadOfStackOverflowOrUnboundedWork() {
        val deep = ">".repeat(MarkdownParseBudgets.MAX_DEPTH * 4) + " x\n"
        // Pathological quote nesting hits the depth budget and fails closed.
        assertNull(parse(deep))
    }

    /* ------------------------------- scheduler ------------------------------- */

    private class RecordingSink {
        val results = java.util.concurrent.ConcurrentHashMap<String, MutableList<Triple<Long, List<MarkdownBlockUi>?, String>>>()
        fun deliver(source: String, generation: Long, blocks: List<MarkdownBlockUi>?) {
            results.computeIfAbsent(source) { mutableListOf() } +=
                Triple(generation, blocks, Thread.currentThread().name)
        }
    }

    @Test
    fun parsesRunOffTheCallerThreadOnBoundedWorkers() {
        val service = MarkdownParseService(workerCount = 2, maxPending = 8)
        try {
            val latch = CountDownLatch(1)
            val sink = RecordingSink()
            val callerThread = Thread.currentThread().name
            assertTrue(service.schedule("# header", 1) { s, g, b -> sink.deliver(s, g, b); latch.countDown() })
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            val (generation, blocks, workerName) = sink.results.getValue("# header").single()
            assertEquals(1L, generation)
            assertNotNull(blocks)
            assertNotEquals(callerThread, workerName)
            assertTrue("worker thread name: $workerName", workerName.startsWith("floe-markdown-parse"))
        } finally {
            service.close()
        }
    }

    @Test
    fun sameFragmentConflationKeepsOnlyTheLatestPendingGeneration() {
        val gate = CountDownLatch(1)
        val release = CountDownLatch(1)
        val service = MarkdownParseService(
            parse = { source ->
                if (source == "block") gate.countDown()
                if (source == "block") release.await(5, TimeUnit.SECONDS)
                CommonMarkMarkdownParser.parseFragment(source)
            },
            workerCount = 1,
            maxPending = 8,
        )
        try {
            assertTrue(service.schedule("block", 1) { _, _, _ -> })
            assertTrue(gate.await(5, TimeUnit.SECONDS)) // worker now busy on gen 1
            // Later generations for the SAME pending fragments conflate.
            service.schedule("tail", 2) { _, _, _ -> }
            service.schedule("tail", 3) { _, _, _ -> }
            assertEquals(1, service.queuedCount()) // only the latest "tail" stands
            val delivered = AtomicReference<List<Long>>(emptyList())
            val done = CountDownLatch(1)
            // Conflated "tail" generation 3 then delivers after release.
            service.schedule("tail", 4) { _, g, _ -> delivered.set(delivered.get() + g); done.countDown() }
            // (schedule(4) replaces 3: the retained latest pending generation is 4)
            release.countDown()
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(4L), delivered.get())
        } finally {
            release.countDown()
            service.close()
        }
    }

    @Test
    fun queuePressureDropsTheOldestUnstartedFragmentAndKeepsTheNewest() {
        val gate = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivered = java.util.concurrent.ConcurrentHashMap<String, Long>()
        val service = MarkdownParseService(
            parse = { source ->
                if (source == "block") gate.countDown()
                if (source == "block") release.await(5, TimeUnit.SECONDS)
                listOf(MarkdownBlockUi.ThematicBreak)
            },
            workerCount = 1,
            maxPending = 2,
        )
        try {
            service.schedule("block", 1) { s, g, _ -> delivered[s] = g }
            assertTrue(gate.await(5, TimeUnit.SECONDS))
            service.schedule("old", 2) { s, g, _ -> delivered[s] = g }
            service.schedule("mid", 3) { s, g, _ -> delivered[s] = g }
            // Queue at cap: scheduling the newest drops the OLDEST pending.
            service.schedule("new", 4) { s, g, _ -> delivered[s] = g }
            release.countDown()
            val deadline = System.currentTimeMillis() + 5_000
            while (delivered.size < 2 && System.currentTimeMillis() < deadline) {
                Thread.sleep(10)
            }
            assertEquals(4L, delivered["new"])
            assertEquals(3L, delivered["mid"])
            assertNull("oldest pending fragment was dropped", delivered["old"])
        } finally {
            release.countDown()
            service.close()
        }
    }

    @Test
    fun closeReleasesPendingWorkAndRefusesNewSchedules() {
        val gate = CountDownLatch(1)
        val never = AtomicInteger(0)
        val service = MarkdownParseService(
            parse = { source ->
                gate.countDown()
                Thread.sleep(50)
                listOf(MarkdownBlockUi.ThematicBreak)
            },
            workerCount = 1,
            maxPending = 4,
        )
        service.schedule("first", 1) { _, _, _ -> never.incrementAndGet() }
        assertTrue(gate.await(5, TimeUnit.SECONDS))
        service.schedule("second", 2) { _, _, _ -> never.incrementAndGet() }
        service.close()
        assertTrue(service.isClosed())
        assertEquals(false, service.schedule("third", 3) { _, _, _ -> never.incrementAndGet() })
        Thread.sleep(150) // give any in-flight parse time to finish
        // Honest release semantics: after close nothing is delivered.
        assertEquals(0, never.get())
    }

    @Test
    fun parserExceptionsArriveAsNullNotAsCrashes() {
        val service = MarkdownParseService(
            parse = { throw IllegalStateException("synthetic parser boom") },
            workerCount = 1,
            maxPending = 4,
        )
        try {
            val latch = CountDownLatch(1)
            val blocks = AtomicReference<List<MarkdownBlockUi>?>(emptyList())
            service.schedule("x", 1) { _, _, b -> blocks.set(b); latch.countDown() }
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            assertNull(blocks.get())
        } finally {
            service.close()
        }
    }

    @Test
    fun endToEndHolderEchoOverTheRealAdapterKeepsGenerationFences() {
        // requestMarkdownParse -> service -> applyMarkdownParseResult: the
        // typed async protocol with the REAL parser (no fake backend). The
        // echo is delivered directly from the worker (a UI host would post
        // it to the main thread; the holder's fences are identical either
        // way and pinned separately above).
        val service = MarkdownParseService(workerCount = 1, maxPending = 4)
        val recorder = RecordingHost()
        lateinit var holder: ConversationFlowHolder
        val host = object : ConversationUiCallbacks by recorder {
            override fun requestMarkdownParse(
                session: ConversationSessionToken,
                source: String,
                generation: Long,
            ): Boolean {
                // Record the seam call, then run the REAL service.
                recorder.requestMarkdownParse(session, source, generation)
                return service.schedule(source, generation) { s, g, blocks ->
                    holder.applyMarkdownParseResult(session, s, g, blocks)
                }
            }
        }
        try {
            holder = ConversationFlowHolder(host, "conv-1")
            holder.applyHostSnapshot(threadState(holder.session))
            val source = "# real\n\n- parsed via commonmark\n"
            holder.ensureMarkdownParse(source)
            val deadline = System.currentTimeMillis() + 5_000
            while (holder.markdownState(source) is MarkdownContentUi.Preparing &&
                System.currentTimeMillis() < deadline
            ) {
                Thread.sleep(5)
            }
            val state = holder.markdownState(source)
            assertTrue("expected Parsed, got $state", state is MarkdownContentUi.Parsed)
            val blocks = (state as MarkdownContentUi.Parsed).blocks
            assertTrue(blocks[0] is MarkdownBlockUi.Heading)
            assertEquals(1, holder.markdownCacheSize())
            assertEquals(1, recorder.count("requestMarkdownParse"))
        } finally {
            service.close()
        }
    }
}
