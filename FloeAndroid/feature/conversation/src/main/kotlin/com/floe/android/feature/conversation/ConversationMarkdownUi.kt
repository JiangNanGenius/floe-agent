// SPDX-License-Identifier: MPL-2.0
//
// Rich message-content presentation for the conversation thread.
//
// RENDERER AUTHORITY + DEPENDENCY TRUTH (verified 2026-10-18 against the
// actual checkout): the ORIGINAL grammar + view behavior is defined by
// FloeAgent/Sources/FloeMarkdown/{MarkdownBlock,MarkdownBlockParser,
// InlineRenderer}.swift rendered by
// FloeAgent/FloeApp/Chat/Render/{MarkdownRendererView,CodeBlockView}.swift.
// That module is NOT a target in FloeAndroid/shared/Package.swift today, and
// InlineRenderer.swift depends on Apple Foundation's
// `AttributedString(markdown:)` (`.inlineOnlyPreservingWhitespace`), whose
// Android/Linux availability is NOT compiled or proven. A portable parser/
// renderer adapter (either a bounded port of the original FloeMarkdown AST
// or a verified JVM/Compose renderer — candidate proposed with license in
// the lane handoff: org.commonmark:commonmark 0.30.1, BSD-2-Clause, plus its
// GFM tables/strikethrough extensions, mapping to the typed projection
// below) is an UNRESOLVED INTEGRATION GATE owned by the dependency/compile
// qualification lane. NOTHING in this file parses Markdown: this module
// consumes only the async typed projection contract defined here, and it
// NEVER claims styled parity before that gate closes.
//
// PROJECTION / LOADING / LITERAL-RECOVERY CONTRACT (holder-coordinated,
// off-UI-thread parse, generation + session-epoch fenced):
//  1. The Compose edge reads ONLY precomputed immutable state
//     [MarkdownContentUi] via the holder cache — zero host/JNI/Swift calls
//     happen during composition.
//  2. Parse requests are scheduled from LaunchedEffect (after composition)
//     with a monotonic generation per source fragment; the host must run the
//     actual parse OFF the UI thread and echo (session, source, generation,
//     blocks-or-failure) back. Late results for a dead epoch or superseded
//     generation are dropped (they can never style another session).
//  3. States: Preparing (scheduled, not yet back), Parsed(blocks), and
//     Literal(source, reason) recovery — when the parse backend is
//     unavailable or fails, the verbatim text still renders and content is
//     NEVER dropped (⇄ InlineRenderer's own degradation rule). Literal is
//     an honest fallback state, explicitly NOT styled-render parity.
//  4. Bounded cache: the streaming tail changes every tick, so parsed
//     results live in an LRU-bounded coordinator (MAX_MARKDOWN_CACHE_ENTRIES)
//     and are invalidated on rebind; nothing grows unbounded.
//  5. The streaming window split (suffix window + last-newline boundary) is
//     pure string arithmetic mirroring MarkdownRendererView.streamingParts();
//     only the FRAGMENT STRINGS reach the host parse — the module never
//     interprets grammar itself.
//
// BLOCK RENDERING MIRRORS the original view layer (structure, not invented
// vocabulary): FloeApp/Chat/Render/MarkdownRendererView.swift (heading ramp,
// hanging lists, quote accent bar, table in a horizontal scroller, stable
// completed+tail sequence so token ticks never refade the answer);
// FloeApp/Chat/Render/CodeBlockView.swift (language tag + copy with an
// explicit "copied" confirmation, monospaced selectable body, horizontal
// scroll, 48dp targets); FloeApp/Chat/ReasoningBlockView.swift (folded
// two-line preview, streaming spinner, full selectable text + copy when
// expanded); UserMessageBubble renders VERBATIM text (never Markdown),
// AssistantMessageView renders Markdown.
//
// LINKS / CODE / ARTIFACT ACTIONS are host effects only:
//  - link taps go through ConversationUiCallbacks.openMessageLink (approved
//    browser host, never a direct network call from this module);
//  - copy goes through the clipboard host effect (exact verbatim text);
//  - code blocks are selectable evidence — nothing runs them;
//  - interactive HTML artifacts remain a digest-verified HOST sandbox
//    affordance (⇄ SandboxedArtifactWebView); this source renders metadata
//    + an explicit host-owned "open preview" request and never embeds an
//    untrusted WebView itself, and no raw untrusted HTML/JS is enabled.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/* ------------------------- typed host projection types ------------------------ */

/** One inline run projected from the Swift AttributedString (⇄ InlineRenderer).
 * [linkUrl] is an opaque host-provided target; presentation never fetches. */
data class InlineSpanUi(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val strikethrough: Boolean = false,
    val code: Boolean = false,
    val linkUrl: String? = null,
)

/** A paragraph-scale inline sequence. [plainText] is the exact selectable /
 * copyable text (matches the iOS verbatim copy semantics). */
data class InlineTextUi(val spans: List<InlineSpanUi>) {
    val plainText: String get() = spans.joinToString("") { it.text }
    val hasLinks: Boolean get() = spans.any { it.linkUrl != null }

    companion object {
        fun plain(text: String): InlineTextUi = InlineTextUi(listOf(InlineSpanUi(text)))
    }
}

/** ⇄ FloeMarkdown.MarkdownBlock (exact node set; names localized at render). */
sealed interface MarkdownBlockUi {
    /** ATX heading, level clamped 1...6 host-side. */
    data class Heading(val level: Int, val text: InlineTextUi) : MarkdownBlockUi
    /** Flow paragraph; inner newlines preserved host-side. */
    data class Paragraph(val text: InlineTextUi) : MarkdownBlockUi
    /** Bullet/numbered list; nested lists live in item.children. */
    data class ListBlock(val ordered: Boolean, val items: List<ListItemUi>) : MarkdownBlockUi
    /** Block quote — recursively parsed blocks. */
    data class Quote(val inner: List<MarkdownBlockUi>) : MarkdownBlockUi
    /** Fenced code: verbatim [code], language nil without info string. */
    data class CodeBlock(val language: String?, val code: String) : MarkdownBlockUi
    /** GFM pipe table; rows padded to the header column count host-side. */
    data class Table(val header: List<InlineTextUi>, val rows: List<List<InlineTextUi>>) : MarkdownBlockUi
    /** Horizontal rule. */
    data object ThematicBreak : MarkdownBlockUi
}

data class ListItemUi(val content: InlineTextUi, val children: List<MarkdownBlockUi>)

/* --------------------------- streaming window logic --------------------------- */

/** ⇄ MarkdownBlockParser.maximumStreamingCharacters (131_072). */
const val MAXIMUM_STREAMING_CHARACTERS = 131_072

/**
 * ⇄ MarkdownRendererView.streamingParts() window split WITHOUT parsing: the
 * visible window is the last [MAXIMUM_STREAMING_CHARACTERS] chars, split at
 * the LAST newline into a stable completed prefix and a changing tail. These
 * are plain string fragments handed to the async projection coordinator;
 * the module never interprets them as grammar.
 */
object StreamingMarkdownWindow {

    data class Fragments(val completedSource: String, val tailSource: String)

    fun split(source: String): Fragments {
        val visibleWindow = if (source.length <= MAXIMUM_STREAMING_CHARACTERS) source
        else source.substring(source.length - MAXIMUM_STREAMING_CHARACTERS)
        val lastNewline = visibleWindow.lastIndexOf('\n')
        if (lastNewline < 0) return Fragments("", visibleWindow)
        return Fragments(
            completedSource = visibleWindow.substring(0, lastNewline + 1),
            tailSource = visibleWindow.substring(lastNewline + 1),
        )
    }
}

/* ---------------------------- projection state model ---------------------------- */

/** Why a fragment renders as literal text instead of styled blocks. */
enum class MarkdownLiteralReason {
    /** The parse backend (shared runtime adapter) is not available right now. */
    BACKEND_UNAVAILABLE,
    /** The host parse reported failure for this fragment. */
    PARSE_FAILED,
}

/**
 * Precomputed, immutable render state for one Markdown fragment. The
 * Compose edge ONLY reads these states (scheduled by the holder
 * coordinator); grammar interpretation lives behind the host seam and is
 * gated by the dependency qualification described in the file header.
 */
sealed interface MarkdownContentUi {
    /** Request scheduled with the host; nothing has come back yet. */
    data object Preparing : MarkdownContentUi
    data class Parsed(val blocks: List<MarkdownBlockUi>) : MarkdownContentUi
    /** Honest literal recovery: verbatim content is NEVER dropped, and this
     * state is explicitly NOT a styled-render claim. */
    data class Literal(val text: String, val reason: MarkdownLiteralReason) : MarkdownContentUi
}

/* ------------------------- bounded async coordinator ------------------------- */

/** Outcome of handing one generation to the host scheduler. */
enum class MarkdownScheduleResult { SCHEDULED, BACKEND_UNAVAILABLE }

/** Streaming tail churn bounds the parsed-fragment cache; old fragments are
 * evicted (LRU) and everything is dropped on rebind. */
const val MAX_MARKDOWN_CACHE_ENTRIES = 64

/**
 * Presentation-side state machine for the [MarkdownContentUi] contract.
 * Pure logic (JVM-testable): monotonic generations, exactly-once scheduling
 * per (source, generation), stale/superseded echo rejection, LRU bounding
 * and full invalidation. No parsing, no coroutines, no host calls inside —
 * the caller supplies the schedule function.
 */
class MarkdownParseCoordinator(private val maxEntries: Int = MAX_MARKDOWN_CACHE_ENTRIES) {

    // accessOrder = true → LRU eviction of parsed fragments.
    private val states = object : LinkedHashMap<String, MarkdownContentUi>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, MarkdownContentUi>): Boolean =
            size > maxEntries
    }
    private val pendingGeneration = mutableMapOf<String, Long>()
    private var generationCounter = 0L

    /** Composition-safe read: never mutates, never schedules. Unknown
     * fragments report Preparing because the post-composition effect will
     * request them on this frame. */
    fun state(source: String): MarkdownContentUi = when {
        source in states -> states.getValue(source)
        source in pendingGeneration -> MarkdownContentUi.Preparing
        else -> MarkdownContentUi.Preparing
    }

    /** Post-composition scheduling. Duplicate requests for an already-parsed
     * or already-pending fragment dispatch nothing. */
    fun ensureRequested(source: String, schedule: (generation: Long) -> MarkdownScheduleResult) {
        if (source in states || source in pendingGeneration) return
        generationCounter += 1
        val generation = generationCounter
        pendingGeneration[source] = generation
        when (schedule(generation)) {
            MarkdownScheduleResult.SCHEDULED -> Unit
            MarkdownScheduleResult.BACKEND_UNAVAILABLE -> {
                pendingGeneration.remove(source)
                states[source] = MarkdownContentUi.Literal(source, MarkdownLiteralReason.BACKEND_UNAVAILABLE)
            }
        }
    }

    /** Host echo. Only the generation this coordinator issued for this exact
     * source is accepted; anything else (stale tail, dead epoch that reached
     * here anyway) is dropped, leaving the honest literal/Preparing state. */
    fun applyResult(source: String, generation: Long, blocks: List<MarkdownBlockUi>?) {
        if (pendingGeneration[source] != generation) return
        pendingGeneration.remove(source)
        states[source] = if (blocks != null) {
            MarkdownContentUi.Parsed(blocks)
        } else {
            MarkdownContentUi.Literal(source, MarkdownLiteralReason.PARSE_FAILED)
        }
    }

    fun invalidateAll() {
        states.clear()
        pendingGeneration.clear()
    }

    fun cachedCount(): Int = states.size
    fun pendingCount(): Int = pendingGeneration.size
}

/* ------------------------------ the renderer --------------------------------- */

/**
 * Assistant-side Markdown surface driven by the holder's async projection
 * states. While [isStreaming] the stable completed+tail fragment sequence
 * keeps existing blocks mounted (only new blocks appear — token updates
 * never refade the answer, ⇄ the SwiftUI contract and the "stable streaming
 * layout" repo invariant). Parse requests are scheduled from
 * [LaunchedEffect], never during composition.
 */
@Composable
fun FloeMarkdownMessage(
    source: String,
    holder: ConversationFlowHolder,
    onLinkOpen: (String) -> Unit,
    onCopyText: (String) -> Unit,
    modifier: Modifier = Modifier,
    isStreaming: Boolean = false,
    highlightQuery: String? = null,
) {
    val fragments: List<String> = if (isStreaming) {
        StreamingMarkdownWindow.split(source).let { f ->
            listOfNotNull(f.completedSource.ifEmpty { null }, f.tailSource.ifEmpty { null })
        }
    } else {
        listOf(source).filter { it.isNotEmpty() }
    }
    androidx.compose.runtime.LaunchedEffect(fragments) {
        // Post-composition scheduling only; the host parses off the UI
        // thread and echoes generation-fenced results back to the holder.
        fragments.forEach { holder.ensureMarkdownParse(it) }
    }
    val searchQuery = highlightQuery?.takeIf { it.isNotBlank() }?.let(::ThreadSearchQuery)
    SelectionContainer {
        Column(
            modifier = modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            fragments.forEach { fragment ->
                when (val state = holder.markdownState(fragment)) {
                    is MarkdownContentUi.Parsed -> state.blocks.forEach { block ->
                        MarkdownBlockView(block, onLinkOpen, onCopyText, searchQuery)
                    }
                    // Preparing / Literal: verbatim text remains visible
                    // (content is never dropped); no styled claim is made.
                    else -> FloeText(
                        when (state) {
                            is MarkdownContentUi.Literal -> state.text
                            else -> fragment
                        },
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                    )
                }
            }
        }
    }
}

@Composable
private fun MarkdownBlockView(
    block: MarkdownBlockUi,
    onLinkOpen: (String) -> Unit,
    onCopyText: (String) -> Unit,
    searchQuery: ThreadSearchQuery? = null,
) {
    val colors = Floe.colors
    when (block) {
        is MarkdownBlockUi.Heading -> {
            Box(modifier = Modifier.semantics { heading() }) {
                InlineTextView(
                    block.text,
                    style = headingStyle(block.level),
                    onLinkOpen = onLinkOpen,
                    highlightRanges = searchQuery?.let {
                        ThreadSearchMatcher.ranges(block.text.plainText, it)
                    }.orEmpty(),
                )
            }
        }
        is MarkdownBlockUi.Paragraph -> {
            InlineTextView(
                block.text,
                style = Floe.typography.body,
                onLinkOpen = onLinkOpen,
                highlightRanges = searchQuery?.let {
                    ThreadSearchMatcher.ranges(block.text.plainText, it)
                }.orEmpty(),
            )
        }
        is MarkdownBlockUi.ListBlock -> {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                block.items.forEachIndexed { position, item ->
                    Column {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            val marker = if (block.ordered) "${position + 1}." else "\u2022"
                            FloeText(
                                marker,
                                style = Floe.typography.body,
                                color = colors.secondaryLabel,
                            )
                            InlineTextView(
                                item.content,
                                style = Floe.typography.body,
                                onLinkOpen = onLinkOpen,
                                highlightRanges = searchQuery?.let {
                                    ThreadSearchMatcher.ranges(item.content.plainText, it)
                                }.orEmpty(),
                            )
                        }
                        if (item.children.isNotEmpty()) {
                            Column(modifier = Modifier.padding(start = 22.dp)) {
                                item.children.forEach { child ->
                                    MarkdownBlockView(child, onLinkOpen, onCopyText, searchQuery)
                                }
                            }
                        }
                    }
                }
            }
        }
        is MarkdownBlockUi.Quote -> {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 2.dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .heightIn(min = 16.dp)
                        .clip(RoundedCornerShape(1.5.dp))
                        .background(colors.accent.copy(alpha = 0.5f)),
                ) {}
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    block.inner.forEach { inner ->
                        MarkdownBlockView(inner, onLinkOpen, onCopyText, searchQuery)
                    }
                }
            }
        }
        is MarkdownBlockUi.CodeBlock -> FloeCodeBlock(
            block, onCopyText,
            searchQuery?.let { ThreadSearchMatcher.ranges(block.code, it) }.orEmpty())
        is MarkdownBlockUi.Table -> MarkdownTable(block, onLinkOpen, onCopyText, searchQuery)
        MarkdownBlockUi.ThematicBreak -> FloeDivider(modifier = Modifier.padding(vertical = 2.dp))
    }
}

/** ⇄ MarkdownRendererView.headingFont ramp. */
@Composable
private fun headingStyle(level: Int) = when (level) {
    1 -> Floe.typography.title
    2 -> Floe.typography.section
    3 -> Floe.typography.body.copy(fontWeight = FontWeight.SemiBold)
    else -> Floe.typography.body.copy(fontWeight = FontWeight.Medium)
}

/** Inline runs → AnnotatedString; tappable when links exist (selection
 * still works via the surrounding SelectionContainer for text parts). */
@Composable
private fun InlineTextView(
    text: InlineTextUi,
    style: androidx.compose.ui.text.TextStyle,
    onLinkOpen: (String) -> Unit,
    highlightRanges: List<IntRange> = emptyList(),
) {
    val colors = Floe.colors
    val annotated = inlineAnnotated(
        text, linkColor = colors.accent, highlightRanges = highlightRanges,
        highlightColor = colors.pending.copy(alpha = 0.35f))
    if (text.hasLinks) {
        ClickableText(
            text = annotated,
            style = style.copy(color = colors.label),
            onClick = { offset ->
                annotated.getStringAnnotations("URL", offset, offset).firstOrNull()?.let {
                    onLinkOpen(it.item)
                }
            },
        )
    } else {
        // FloeText only accepts plain strings; the annotated variant keeps
        // the same Floe color/typography roles.
        androidx.compose.material3.Text(
            text = annotated,
            style = style.copy(color = colors.label),
        )
    }
}

private fun inlineAnnotated(
    text: InlineTextUi,
    linkColor: Color,
    highlightRanges: List<IntRange> = emptyList(),
    highlightColor: Color = Color.Transparent,
): AnnotatedString {
    val builder = AnnotatedString.Builder()
    builder.withStyle(SpanStyle()) {
        text.spans.forEach { span ->
            if (span.linkUrl != null) pushStringAnnotation("URL", span.linkUrl)
            withStyle(
                SpanStyle(
                    fontWeight = if (span.bold) FontWeight.Bold else null,
                    fontStyle = if (span.italic) FontStyle.Italic else null,
                    fontFamily = if (span.code) FontFamily.Monospace else null,
                    textDecoration = when {
                        span.linkUrl != null -> TextDecoration.Underline
                        span.strikethrough -> TextDecoration.LineThrough
                        else -> null
                    },
                    color = if (span.linkUrl != null) linkColor else Color.Unspecified,
                )
            ) {
                append(span.text)
            }
            if (span.linkUrl != null) pop()
        }
    }
    val length = builder.length
    for (range in highlightRanges) {
        val start = range.first.coerceIn(0, length)
        val end = (range.last + 1).coerceIn(start, length)
        if (end > start) {
            builder.addStyle(SpanStyle(background = highlightColor), start, end)
        }
    }
    return builder.toAnnotatedString()
}

/** ⇄ CodeBlockView: language tag + copy with explicit "copied" confirmation
 * over a horizontally scrollable monospaced body. Never executed. */
@Composable
private fun FloeCodeBlock(
    block: MarkdownBlockUi.CodeBlock,
    onCopyText: (String) -> Unit,
    highlightRanges: List<IntRange> = emptyList(),
) {
    val colors = Floe.colors
    var didCopy by remember(block.code) { mutableStateOf(false) }
    val copyLabel = stringResource(if (didCopy) R.string.action_copied else R.string.action_copy)
    val languageLabel = stringResource(R.string.codeblock_language)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.groupedSurface),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 10.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (!block.language.isNullOrEmpty()) {
                FloeText(
                    block.language,
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                    modifier = Modifier.semantics { contentDescription = "$languageLabel ${block.language}" },
                )
            }
            Spacer(Modifier.weight(1f))
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .widthIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable {
                        onCopyText(block.code)
                        didCopy = true
                    }
                    .semantics { contentDescription = copyLabel },
                contentAlignment = Alignment.Center,
            ) {
                // Copy affordance: text label carries the meaning. The frozen
                // FloeIcons set has no doc.on.doc glyph (reported in the lane
                // inventory for the icon owner); no paperclip mislabel here.
                FloeText(
                    copyLabel,
                    style = Floe.typography.metadata,
                    color = if (didCopy) colors.success else colors.accent,
                    modifier = Modifier.padding(horizontal = 10.dp),
                )
            }
        }
        SelectionContainer {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(10.dp),
            ) {
                androidx.compose.material3.Text(
                    text = codeAnnotated(block.code, highlightRanges, colors.pending.copy(alpha = 0.35f)),
                    style = Floe.typography.evidence.copy(color = colors.label),
                )
            }
        }
    }
}

/** ⇄ MarkdownTableView: horizontal scroller + Grid columns never clip a
 * wide table; header semibold, body secondary, hairline under the header. */
@Composable
private fun MarkdownTable(
    block: MarkdownBlockUi.Table,
    onLinkOpen: (String) -> Unit,
    onCopyText: (String) -> Unit,
    searchQuery: ThreadSearchQuery? = null,
) {
    val colors = Floe.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.groupedSurface)
            .horizontalScroll(rememberScrollState())
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            block.header.forEach { cell ->
                InlineTextView(
                    cell,
                    style = Floe.typography.metadata.copy(fontWeight = FontWeight.SemiBold),
                    onLinkOpen = onLinkOpen,
                    highlightRanges = searchQuery?.let {
                        ThreadSearchMatcher.ranges(cell.plainText, it)
                    }.orEmpty(),
                )
            }
        }
        FloeDivider()
        block.rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                row.forEach { cell ->
                    InlineTextView(
                        cell,
                        style = Floe.typography.metadata,
                        onLinkOpen = onLinkOpen,
                        highlightRanges = searchQuery?.let {
                            ThreadSearchMatcher.ranges(cell.plainText, it)
                        }.orEmpty(),
                    )
                }
            }
        }
    }
}

private fun codeAnnotated(
    code: String,
    highlightRanges: List<IntRange>,
    highlightColor: Color,
): AnnotatedString {
    val builder = AnnotatedString.Builder()
    builder.append(code)
    for (range in highlightRanges) {
        val start = range.first.coerceIn(0, code.length)
        val end = (range.last + 1).coerceIn(start, code.length)
        if (end > start) {
            builder.addStyle(SpanStyle(background = highlightColor), start, end)
        }
    }
    return builder.toAnnotatedString()
}

/* ----------------------------- reasoning blocks ----------------------------- */

/**
 * ⇄ ReasoningBlockView: folded 2-line preview (space reserved so streaming
 * fragments never shrink the row), a streaming spinner, and full selectable
 * text plus a copy action when expanded. Long (>8192-char) reasoning keeps
 * the fold without the soft animation (the Swift rule).
 */
@Composable
fun ConversationReasoningBlock(
    text: String,
    isStreaming: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    onCopyText: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: String = "",
) {
    val colors = Floe.colors
    var didCopy by remember(text) { mutableStateOf(false) }
    val title = stringResource(R.string.reasoning_title)
    val thinking = stringResource(R.string.reasoning_thinking)
    val viewRecord = stringResource(R.string.reasoning_view_record)
    val copyLabel = stringResource(if (didCopy) R.string.action_copied else R.string.action_copy)
    val fullLabel = stringResource(
        if (isStreaming) R.string.reasoning_still_updating else R.string.reasoning_full
    )
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.groupedSurface)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(onClick = onToggle),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(modifier = Modifier.width(26.dp), contentAlignment = Alignment.Center) {
                if (isStreaming) FloeActivityIndicator() else IconGlyph(FloeIcons.Wand, colors.accent, 16.dp)
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                FloeText(if (label.isEmpty()) title else label, style = Floe.typography.bodyEmphasized, color = colors.label)
                if (!expanded) {
                    FloeText(
                        preview(text).ifEmpty { if (isStreaming) thinking else viewRecord },
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        maxLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            IconGlyph(
                if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown,
                colors.secondaryLabel,
                14.dp,
            )
        }
        if (expanded) {
            SelectionContainer {
                FloeText(text, style = Floe.typography.metadata, color = colors.label)
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable {
                        onCopyText(text)
                        didCopy = true
                    }
                    .semantics { contentDescription = copyLabel },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(copyLabel, style = Floe.typography.metadata, color = if (didCopy) colors.success else colors.accent)
                FloeText(fullLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
            }
        }
    }
}

/** ⇄ preview: first two rendered lines of the reasoning excerpt. */
internal fun preview(text: String): String {
    val lines = text.split('\n').filter { it.isNotBlank() }
    return lines.take(2).joinToString(" ")
}

/* ------------------------- interactive artifact affordance ------------------- */

/** ⇄ RichArtifactView boundary for Android: the host owns the sandboxed
 * preview. This presents verified metadata + an explicit host request only. */
@Composable
fun RichArtifactAffordance(
    artifact: ToolArtifactUi,
    canOpenPreview: Boolean,
    onOpenPreview: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val openLabel = stringResource(R.string.artifact_open_preview)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.groupedSurface)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.Chip, colors.secondaryLabel, 16.dp)
        Column(modifier = Modifier.weight(1f)) {
            FloeText(
                artifact.relativePath.substringAfterLast('/'),
                style = Floe.typography.metadata,
                color = colors.label,
                maxLines = 1,
            )
            FloeText(
                artifact.mimeType,
                style = Floe.typography.evidence,
                color = colors.secondaryLabel,
            )
        }
        if (canOpenPreview) {
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(8.dp))
                    .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(8.dp))
                    .clickable(onClick = onOpenPreview)
                    .padding(horizontal = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(openLabel, style = Floe.typography.metadata, color = colors.accent)
            }
        }
    }
}

/** Copied-confirmation auto-reset helper (⇄ the 2s Task.sleep reset). */
@Composable
fun rememberCopiedResetEffect(didCopy: Boolean, onReset: () -> Unit) {
    val scope = rememberCoroutineScope()
    androidx.compose.runtime.LaunchedEffect(didCopy) {
        if (didCopy) {
            scope.launch {
                delay(2_000)
                onReset()
            }
        }
    }
}
