// SPDX-License-Identifier: MPL-2.0
//
// REAL Markdown parse adapter (Main's dependency gate, 2026-10-18/19): the
// pure-JVM commonmark-java parser mapped into this module's typed async
// projection contract. This is UI RENDERING INFRASTRUCTURE, not a business
// runtime: it parses fragments off the UI thread and produces immutable
// [MarkdownBlockUi] trees; it never touches provider data, the database, the
// agent loop, the network, raw HTML/JS or code execution.
//
// Dependency truth (verified against Maven Central 2026-10-19):
//  - org.commonmark:commonmark 0.30.1 (latest release; maven-metadata.xml
//    lastUpdated 2026-10-10), BSD 2-Clause "Simplified" License, Copyright
//    (c) 2015 Robin Stocker (upstream LICENSE.txt preserved under
//    FloeAndroid/licenses/commonmark/ and listed in NOTICE.md).
//  - org.commonmark:commonmark-ext-gfm-tables:0.30.1 and
//    org.commonmark:commonmark-ext-gfm-strikethrough:0.30.1 — same group,
//    same pinned version, same license.
//  - The ORIGINAL Swift FloeMarkdown module is NOT the parser here:
//    shared/Package.swift has no FloeMarkdown target and InlineRenderer
//    depends on Apple AttributedString(markdown:) (unproven on Android).
//    The block vocabulary below is the audited original subset
//    (heading/paragraph/list/quote/code/table/thematicBreak — no math case);
//    golden structure is compared against that subset, and styled parity is
//    still NOT a full-native-render equality claim.
//
// BUDGETS (honest release/drop semantics):
//  - input: at most [MAXIMUM_STREAMING_CHARACTERS] per fragment (the window
//    splitter already guarantees this; over-budget fails closed to literal);
//  - AST nodes: [MAX_AST_NODES] visited (pathological input aborts to null →
//    Literal recovery, content never dropped, never an unbounded spin);
//  - nesting depth: [MAX_DEPTH];
//  - output: total inline text is a slicing of the input, bounded by it;
//  - concurrency: [MarkdownParseService] runs at most [workerCount] parses on
//    dedicated daemon workers with at most [maxPending] queued fragments.
//    A newer generation for the SAME source replaces the pending older one
//    (latest-wins conflation) instead of queueing a coroutine per token;
//    queue overflow drops the OLDEST still-unstarted fragment (it belongs to
//    a superseded streaming tail anyway — the coordinator's generation fence
//    would discard its result regardless). Nothing is ever parsed on the UI
//    thread and no parse is blocked on JNI.

package com.floe.android.feature.conversation

import org.commonmark.Extension
import org.commonmark.ext.gfm.strikethrough.Strikethrough
import org.commonmark.ext.gfm.strikethrough.StrikethroughExtension
import org.commonmark.ext.gfm.tables.TableBlock
import org.commonmark.ext.gfm.tables.TableBody
import org.commonmark.ext.gfm.tables.TableCell
import org.commonmark.ext.gfm.tables.TableHead
import org.commonmark.ext.gfm.tables.TablesExtension
import org.commonmark.node.BlockQuote
import org.commonmark.node.BulletList
import org.commonmark.node.Code
import org.commonmark.node.CustomBlock
import org.commonmark.node.CustomNode
import org.commonmark.node.Emphasis
import org.commonmark.node.FencedCodeBlock
import org.commonmark.node.HardLineBreak
import org.commonmark.node.Heading
import org.commonmark.node.HtmlBlock
import org.commonmark.node.HtmlInline
import org.commonmark.node.Image
import org.commonmark.node.IndentedCodeBlock
import org.commonmark.node.Link
import org.commonmark.node.ListItem
import org.commonmark.node.Node
import org.commonmark.node.OrderedList
import org.commonmark.node.Paragraph
import org.commonmark.node.SoftLineBreak
import org.commonmark.node.StrongEmphasis
import org.commonmark.node.Text
import org.commonmark.node.ThematicBreak
import org.commonmark.parser.Parser
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/* --------------------------------- budgets ---------------------------------- */

/** Parse budgets shared by the parser and the scheduler (pure constants). */
object MarkdownParseBudgets {
    /** One parsed-fragment hard input ceiling (⇄ the streaming window cap). */
    const val MAX_INPUT_CHARACTERS = MAXIMUM_STREAMING_CHARACTERS

    /** Total AST nodes one fragment may visit before the parse aborts to the
     * honest Literal fallback. */
    const val MAX_AST_NODES = 60_000

    /** Block-tree nesting ceiling (quote-in-list-in-quote … chains). */
    const val MAX_DEPTH = 48
}

private class MarkdownBudgetException : RuntimeException("markdown parse budget exceeded")

/* ------------------------------- the converter ------------------------------- */

/**
 * Maps the commonmark AST into the module's immutable [MarkdownBlockUi]
 * vocabulary. Deterministic for equal input; unknown syntax degrades to
 * literal text (content is NEVER dropped and NO HTML node type is produced).
 */
object CommonMarkMarkdownParser {

    private val extensions: List<Extension> =
        listOf(TablesExtension.create(), StrikethroughExtension.create())

    private val parser: Parser = Parser.builder().extensions(extensions).build()

    /** Parse one window fragment. Returns null on budget abort or any
     * failure — the coordinator then records the honest Literal fallback. */
    fun parseFragment(source: String): List<MarkdownBlockUi>? {
        if (source.length > MarkdownParseBudgets.MAX_INPUT_CHARACTERS) return null
        return try {
            val budget = Budget()
            val doc = parser.parse(source)
            val blocks = ArrayList<MarkdownBlockUi>()
            var child = doc.firstChild
            while (child != null) {
                val next = child.next
                convertBlock(child, blocks, budget, depth = 1)
                child = next
            }
            blocks
        } catch (_: MarkdownBudgetException) {
            null
        } catch (_: RuntimeException) {
            null
        } catch (_: StackOverflowError) {
            null
        }
    }

    private class Budget {
        var nodes = 0
        fun visit(node: Node) {
            nodes += 1
            if (nodes > MarkdownParseBudgets.MAX_AST_NODES) throw MarkdownBudgetException()
        }
    }

    private fun convertBlock(node: Node, out: MutableList<MarkdownBlockUi>, budget: Budget, depth: Int) {
        budget.visit(node)
        if (depth > MarkdownParseBudgets.MAX_DEPTH) throw MarkdownBudgetException()
        when (node) {
            is Heading -> out += MarkdownBlockUi.Heading(node.level, collectInline(node, budget))
            is Paragraph -> out += MarkdownBlockUi.Paragraph(collectInline(node, budget))
            is BulletList -> out += convertList(node, ordered = false, budget, depth)
            is OrderedList -> out += convertList(node, ordered = true, budget, depth)
            is BlockQuote -> {
                val inner = ArrayList<MarkdownBlockUi>()
                var child = node.firstChild
                while (child != null) {
                    val next = child.next
                    convertBlock(child, inner, budget, depth + 1)
                    child = next
                }
                out += MarkdownBlockUi.Quote(inner)
            }
            is FencedCodeBlock -> out += MarkdownBlockUi.CodeBlock(
                language = node.info?.trim()?.takeIf { it.isNotEmpty() },
                // EXACT verbatim code — every character, no trimming of the
                // block content beyond the fence itself (⇄ original rule).
                code = node.literal ?: "",
            )
            is IndentedCodeBlock -> out += MarkdownBlockUi.CodeBlock(null, node.literal ?: "")
            is ThematicBreak -> out += MarkdownBlockUi.ThematicBreak
            is TableBlock -> out += convertTable(node, budget)
            // Raw HTML is NEVER projected as HTML: its literal text is
            // preserved as plain content (selectable, copyable, unrendered).
            is HtmlBlock -> out += MarkdownBlockUi.Paragraph(InlineTextUi.plain(node.literal ?: ""))
            is CustomBlock -> {
                // Extension blocks that own children convert normally; an
                // opaque custom block degrades to its literal text.
                val hadChildren = node.firstChild != null
                if (hadChildren) {
                    var child = node.firstChild
                    while (child != null) {
                        val next = child.next
                        convertBlock(child, out, budget, depth + 1)
                        child = next
                    }
                } else {
                    out += MarkdownBlockUi.Paragraph(InlineTextUi.plain(collectLiteral(node)))
                }
            }
            else -> out += MarkdownBlockUi.Paragraph(collectInline(node, budget))
        }
    }

    private fun convertList(list: Node, ordered: Boolean, budget: Budget, depth: Int): MarkdownBlockUi.ListBlock {
        val items = ArrayList<ListItemUi>()
        var child = list.firstChild
        while (child != null) {
            val next = child.next
            if (child is ListItem) {
                budget.visit(child)
                // ⇄ original shape: the item's first paragraph is the row
                // content; any deeper blocks (nested lists, quotes, code)
                // become structured children.
                var content: InlineTextUi? = null
                val children = ArrayList<MarkdownBlockUi>()
                var inner = child.firstChild
                while (inner != null) {
                    val innerNext = inner.next
                    if (content == null && inner is Paragraph) {
                        content = collectInline(inner, budget)
                    } else {
                        convertBlock(inner, children, budget, depth + 1)
                    }
                    inner = innerNext
                }
                items += ListItemUi(content = content ?: InlineTextUi.plain(""), children = children)
            } else {
                budget.visit(child)
            }
            child = next
        }
        return MarkdownBlockUi.ListBlock(ordered = ordered, items = items)
    }

    private fun convertTable(table: TableBlock, budget: Budget): MarkdownBlockUi.Table {
        val header = ArrayList<InlineTextUi>()
        val rows = ArrayList<List<InlineTextUi>>()
        var section = table.firstChild
        while (section != null) {
            val sectionNext = section.next
            when (section) {
                is TableHead -> section.firstChild?.let { row -> collectCells(row, header, budget) }
                is TableBody -> {
                    var row = section.firstChild
                    while (row != null) {
                        val cells = ArrayList<InlineTextUi>()
                        collectCells(row, cells, budget)
                        rows += cells
                        row = row.next
                    }
                }
            }
            section = sectionNext
        }
        return MarkdownBlockUi.Table(header = header, rows = rows)
    }

    private fun collectCells(row: Node, out: MutableList<InlineTextUi>, budget: Budget) {
        budget.visit(row)
        var cell = row.firstChild
        while (cell != null) {
            val next = cell.next
            if (cell is TableCell) {
                // Table cells own their inline children directly (extension
                // spec): convert them as one InlineTextUi per cell.
                out += collectInline(cell, budget)
            }
            cell = next
        }
    }

    /* --------------------------------- inlines -------------------------------- */

    private data class InlineFlags(
        val bold: Boolean = false,
        val italic: Boolean = false,
        val strike: Boolean = false,
        val link: String? = null,
    )

    private fun collectInline(block: Node, budget: Budget): InlineTextUi {
        val spans = ArrayList<InlineSpanUi>()
        var child = block.firstChild
        while (child != null) {
            val next = child.next
            collectInlineNode(child, InlineFlags(), spans, budget)
            child = next
        }
        return InlineTextUi(spans)
    }

    private fun collectInlineNode(
        node: Node,
        flags: InlineFlags,
        spans: MutableList<InlineSpanUi>,
        budget: Budget,
    ) {
        budget.visit(node)
        when (node) {
            is Text -> spans += InlineSpanUi(node.literal ?: "", flags.bold, flags.italic, flags.strike, false, flags.link)
            is Code -> spans += InlineSpanUi(node.literal ?: "", flags.bold, flags.italic, flags.strike, true, flags.link)
            is Emphasis -> nodeChildren(node, flags.copy(italic = true), spans, budget)
            is StrongEmphasis -> nodeChildren(node, flags.copy(bold = true), spans, budget)
            is Strikethrough -> nodeChildren(node, flags.copy(strike = true), spans, budget)
            is Link -> nodeChildren(node, flags.copy(link = node.destination ?: ""), spans, budget)
            is SoftLineBreak -> spans += InlineSpanUi("\n", flags.bold, flags.italic, flags.strike, false, flags.link)
            is HardLineBreak -> spans += InlineSpanUi("\n", flags.bold, flags.italic, flags.strike, false, flags.link)
            // Images have no block in the audited iOS subset: commonmark-java
            // stores the alternative text as the node's INLINE CHILDREN, so
            // the literal child text is preserved as selectable content
            // (never dropped, never a fetch, never an invented node type).
            is Image -> spans += InlineSpanUi(collectLiteral(node), flags.bold, flags.italic, flags.strike, false, flags.link)
            is HtmlInline -> spans += InlineSpanUi(node.literal ?: "", flags.bold, flags.italic, flags.strike, false, flags.link)
            is CustomNode -> {
                if (node.firstChild != null) nodeChildren(node, flags, spans, budget) else spans += InlineSpanUi(collectLiteral(node))
            }
            else -> {
                if (node.firstChild != null) nodeChildren(node, flags, spans, budget) else spans += InlineSpanUi(collectLiteral(node))
            }
        }
    }

    private fun nodeChildren(node: Node, flags: InlineFlags, spans: MutableList<InlineSpanUi>, budget: Budget) {
        var child = node.firstChild
        while (child != null) {
            val next = child.next
            collectInlineNode(child, flags, spans, budget)
            child = next
        }
    }

    /** Last-resort literal text for unknown/opaque nodes (content is never
     * dropped; empty custom nodes contribute nothing). */
    private fun collectLiteral(node: Node): String {
        val sb = StringBuilder()
        collectLiteralInto(node, sb)
        return sb.toString()
    }

    private fun collectLiteralInto(node: Node, sb: StringBuilder) {
        when (node) {
            is Text -> sb.append(node.literal ?: "")
            is Code -> { sb.append('`'); sb.append(node.literal ?: ""); sb.append('`') }
            is HtmlBlock -> sb.append(node.literal ?: "")
            is HtmlInline -> sb.append(node.literal ?: "")
            is FencedCodeBlock -> sb.append(node.literal ?: "")
            is IndentedCodeBlock -> sb.append(node.literal ?: "")
            is Image -> {
                // The Image node's inline children ARE the alt text.
                sb.append("![")
                var child = node.firstChild
                while (child != null) { collectLiteralInto(child, sb); child = child.next }
                sb.append("]("); sb.append(node.destination ?: ""); sb.append(')')
            }
            is Link -> {
                sb.append('[')
                var child = node.firstChild
                while (child != null) { collectLiteralInto(child, sb); child = child.next }
                sb.append("]("); sb.append(node.destination ?: ""); sb.append(')')
            }
            is SoftLineBreak -> sb.append('\n')
            is HardLineBreak -> sb.append('\n')
            else -> {
                var child = node.firstChild
                while (child != null) { collectLiteralInto(child, sb); child = child.next }
            }
        }
    }
}

/* -------------------------------- scheduler -------------------------------- */

/**
 * Bounded off-UI-thread parse scheduler behind the existing
 * [ConversationUiCallbacks.requestMarkdownParse] seam.
 *
 *  - at most [workerCount] parses ever run concurrently (dedicated daemon
 *    threads — no coroutine-per-token/render-loop parse storm);
 *  - at most [maxPending] fragments wait; a newer generation for the SAME
 *    source REPLACES the older pending job (latest-generation conflation);
 *  - queue overflow drops the OLDEST unstarted fragment (its result would be
 *    a superseded generation anyway; the holder's coordinator fences the
 *    echo), never the newest;
 *  - [close] stops taking work, releases the pool and never delivers to
 *    dropped/in-flight jobs — honest release semantics;
 *  - the actual parse runs only inside the workers; the caller thread does
 *    queue bookkeeping only. [deliver] is invoked on a worker thread and the
 *    HOST must post the holder echo to the main thread (never the reverse).
 */
class MarkdownParseService(
    private val parse: (String) -> List<MarkdownBlockUi>? = CommonMarkMarkdownParser::parseFragment,
    workerCount: Int = DEFAULT_WORKERS,
    private val maxPending: Int = DEFAULT_MAX_PENDING,
) : AutoCloseable {

    companion object {
        const val DEFAULT_WORKERS = 2
        const val DEFAULT_MAX_PENDING = 64
    }

    private class Job(val source: String, val generation: Long, val deliver: (String, Long, List<MarkdownBlockUi>?) -> Unit)

    private val lock = Any()
    private var closed = false
    private val queue = ArrayDeque<Job>()
    private val queuedBySource = HashMap<String, Job>()
    private val running = AtomicInteger(0)
    private val executor = Executors.newFixedThreadPool(workerCount) { runnable ->
        Thread(runnable, "floe-markdown-parse-${counter.incrementAndGet()}").apply { isDaemon = true }
    }
    private val counter = AtomicInteger(0)

    /** True if this generation was retained for execution. False = the
     * service is closed (the coordinator records BACKEND_UNAVAILABLE
     * literal recovery). Dropped-by-conflation/overflow jobs deliver
     * nothing; the holder's generation fence already treats them as dead. */
    fun schedule(source: String, generation: Long, deliver: (String, Long, List<MarkdownBlockUi>?) -> Unit): Boolean {
        synchronized(lock) {
            if (closed) return false
            // Latest-generation conflation for the same fragment source.
            queuedBySource.remove(source)?.let { queue.remove(it) }
            while (queue.size >= maxPending) {
                val dropped = queue.removeFirst()
                queuedBySource.remove(dropped.source)
            }
            val job = Job(source, generation, deliver)
            queue.addLast(job)
            queuedBySource[source] = job
            startWorkersLocked()
            return true
        }
    }

    private fun startWorkersLocked() {
        // Caller holds [lock]. Launch only up to workerCount concurrent jobs.
        while (running.get() < workerCapacity && queue.isNotEmpty()) {
            val job = queue.removeFirst()
            if (queuedBySource[job.source] === job) queuedBySource.remove(job.source)
            running.incrementAndGet()
            executor.execute {
                val blocks = try {
                    parse(job.source)
                } catch (_: Throwable) {
                    null
                }
                running.decrementAndGet()
                val delivered = synchronized(lock) {
                    if (closed) {
                        false
                    } else {
                        startWorkersLocked()
                        true
                    }
                }
                if (delivered) job.deliver(job.source, job.generation, blocks)
            }
        }
    }

    private val workerCapacity: Int = workerCount.coerceAtLeast(1)

    /** Live counts for diagnostics/tests (never a public product surface). */
    fun queuedCount(): Int = synchronized(lock) { queue.size }
    fun runningCount(): Int = running.get()
    fun isClosed(): Boolean = synchronized(lock) { closed }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            queue.clear()
            queuedBySource.clear()
        }
        executor.shutdownNow()
    }
}
