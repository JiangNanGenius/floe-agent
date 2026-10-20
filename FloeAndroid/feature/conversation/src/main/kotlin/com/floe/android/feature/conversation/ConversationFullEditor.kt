// SPDX-License-Identifier: MPL-2.0
//
// The composer's expand destination: ⇄ FloeApp/Chat/ComposerFullEditorSheet.
//
// ONE SHARED DRAFT: the sheet binds the holder's SAME TextFieldValue state
// object as the inline field — one text, one caret/selection, one draft
// generation, one send pipeline (⇄ "binds the *same* draft as the inline
// field, so both surfaces always agree"). There is deliberately no second
// draft store and no second submit path; the send control runs the holder's
// canonical [ConversationFlowHolder.sendFromFullEditor], which mirrors the
// iOS rule "Done only dismisses — it never sends" and closes the sheet only
// when the send actually started.
//
// EDIT SUPPORT mirrors the source sheet within platform honesty:
//  - undo/redo over the holder's bounded, RAM-only shared edit history
//    (⇄ the composer-owned shared UndoManager — the inline field and this
//    editor record into the SAME stack);
//  - select-all through the same draft pipeline;
//  - a debounced, revision-conflated character count + rough token estimate
//    footer (⇄ ComposerFooterCounts 220 ms debounce + generation fence;
//    ⇄ ComposerTokenEstimator: CJK scalars ≈ 1 token each, everything else
//    ≈ 4 scalars per token, presented as an estimate — never exact);
//  - the send button applies the SAME guarded policy as the inline circle
//    (blank draft, IME marked composition, provider configured, attachments
//    processing) via [ConversationFlowHolder.fullEditorCanSend]; plain
//    Return is a newline (multiline IME action), never a send.
//
// FIND/REPLACE is a real, local editing surface (not a platform omission and
// not an invented system navigator). The toolbar magnifier — plus a hardware
// Ctrl/Cmd+F — opens a native-style bar over the SAME draft:
//  - the query and replacement are LITERAL (no user-facing regex; `$` and `\`
//    stay ordinary characters), with Match Case and Whole Word;
//  - total count and current ordinal, previous/next with wrapping;
//  - Replace Current and Replace All. Navigation changes ONLY the shared
//    draft selection; each replacement runs through the holder's ONE
//    [ConversationFlowHolder] edit/undo/save/send pipeline, and Replace All is
//    one atomic undoable edit;
//  - the current match's real range in the shared TextFieldValue is selected
//    and scrolled into view using the actual text layout; a visual
//    transformation only ADDS a highlight over those same immutable ranges,
//    never edits or copies the draft text;
//  - Back/Escape close the Find bar first and preserve the editor/draft; a
//    second Back/Done then dismisses the editor. Nothing here sends.
//
// The search runs synchronously over the in-memory draft String; it never
// contacts a provider/backend and creates no second text cache. Presentation
// state lives in the holder so a same-process configuration change keeps it,
// while a real new session/temporary discard resets it (see
// ConversationFlowHolder.findReplace).
//
// Back/Done always just dismisses (when Find is closed). The expand ENTRY
// follows the iOS trigger rule (the control appears only once the draft no
// longer fits the inline field's line cap). In a bound conversation the
// trigger is computed from the ACTUAL inline field width measured by the
// shared composer plus real Compose text layout (ConversationComposerUi).
// [FullEditorPolicy] remains the G01 component-preview fallback for hosts that
// have not measured a pane yet.
//
// This sheet is a separate Dialog: it deliberately uses its OWN dialog bounds
// and IME handling, never the detail-pane geometry passed to the destination.
// Applying the inline pane width here would be a new, incorrect clamp.
//
// The glyph is a FLOE-OWNED module-local vector (no Apple SF Symbol asset,
// no design-system change): two outward diagonal corner arrows.

package com.floe.android.feature.conversation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeText
import java.text.BreakIterator
import kotlin.math.roundToInt

/* --------------------------------- the policy -------------------------------- */

/**
 * Pure presentation policy for the expand destination (JVM-testable, no
 * Android runtime): the entry trigger, the footer counts and the rough token
 * estimate. The estimates are exactly the iOS rules; the entry is a
 * deterministic content-based approximation of "the inline field reached its
 * line cap and scrolls".
 */
object FullEditorPolicy {

    /** ⇄ average advance of one glyph at the composer field size, in dp.
     * A deliberately rough constant: only the > line-cap transition matters,
     * and hysteresis is bounded by the integer line count. */
    const val APPROX_CHAR_WIDTH_DP: Float = 8.6f

    /** Visual lines: each hard line is at least one; longer lines wrap at
     * the field's approximate characters-per-line budget. */
    fun visualLineCount(text: String, inlineMaxLines: Int, fieldWidthDp: Float): Int {
        if (text.isEmpty()) return 1
        val charsPerLine = (fieldWidthDp / APPROX_CHAR_WIDTH_DP).toInt().coerceAtLeast(1)
        var lines = 0
        var index = 0
        while (true) {
            val newline = text.indexOf('\n', index)
            val end = if (newline < 0) text.length else newline
            val segmentLength = end - index
            lines += if (segmentLength == 0) 1 else {
                (segmentLength + charsPerLine - 1) / charsPerLine
            }
            if (newline < 0) break
            index = newline + 1
            // A trailing newline still owns the empty last line.
            if (index == text.length) lines += 1
        }
        return lines.coerceAtLeast(1)
    }

    /** ⇄ ThreadComposerView isInlineFieldOverflowing: the entry appears only
     * while the draft no longer fits the inline field's line cap. */
    fun shouldOfferFullEditor(text: String, inlineMaxLines: Int, fieldWidthDp: Float): Boolean =
        visualLineCount(text, inlineMaxLines, fieldWidthDp) > inlineMaxLines

    /** ⇄ ComposerFooterCounts characters (grapheme clusters). */
    fun characterCount(text: String): Int {
        if (text.isEmpty()) return 0
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count += 1
        return count
    }

    /** ⇄ ComposerTokenEstimator.estimatedTokens: CJK (U+3400..U+9FFF) ≈ 1
     * token each, remaining scalars ≈ 4 per token; always an estimate. */
    fun estimatedTokens(text: String): Int {
        if (text.isEmpty()) return 0
        var cjk = 0
        var total = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            total += 1
            if (cp in 0x3400..0x9FFF) cjk += 1
            i += Character.charCount(cp)
        }
        val nonCjk = total - cjk
        return maxOf(1, cjk + (nonCjk + 3) / 4)
    }

    /** ⇄ ComposerFooterCounts debounce window. */
    const val FOOTER_DEBOUNCE_MILLIS = 220L
}

/** G01 fallback inline-field width for component previews / unbound hosts:
 * the centred chrome (capped at the captured 720dp reading width) minus the
 * composer's own outer/inner paddings and controls. A host that supplies
 * [ConversationPaneGeometry] does NOT use this function: its trigger comes
 * from the measured field slot width and actual text layout. Kept only so the
 * existing preview/host path keeps its exact behaviour until RB7 binds a real
 * holder. */
internal fun legacyFullEditorFieldWidthDp(screenWidthDp: Float): Float {
    val chrome = minOf(screenWidthDp, 720f)
    val controls = 3f * 48f + 4f * 8f
    return (chrome - 48f - controls).coerceAtLeast(120f)
}

/* --------------------------- the module-local glyph --------------------------- */

/** ⇄ "arrow.up.left.and.arrow.down.right" — Floe-owned vector strokes
 * (viewport 24, the design system's uniform outline style): two corner
 * arrows pointing outward. Tinted at render time by IconGlyph. */
internal val ExpandEditorGlyph: ImageVector by lazy {
    ImageVector.Builder(
        name = "floe.expand_editor_arrows",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).path(
        fill = null,
        stroke = SolidColor(androidx.compose.ui.graphics.Color.Black),
        strokeLineWidth = 1.8f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
        pathBuilder = {
            // Upper-left arrow: head + diagonal shaft.
            moveTo(9.4f, 4f); lineTo(4f, 4f); lineTo(4f, 9.4f)
            moveTo(4f, 4f); lineTo(10.8f, 10.8f)
            // Lower-right arrow: head + diagonal shaft.
            moveTo(14.6f, 20f); lineTo(20f, 20f); lineTo(20f, 14.6f)
            moveTo(20f, 20f); lineTo(13.2f, 13.2f)
        },
    ).build()
}

/* ---------------------------------- the sheet --------------------------------- */

/**
 * The full-screen editor sheet over the SAME holder draft state. Hosted by
 * [FloeConversationDestination]'s sheet area; visible while
 * [ConversationFlowHolder.showsFullEditor].
 */
@Composable
fun ComposerFullEditorSheet(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    FloePageSheet(
        visible = holder.showsFullEditor,
        onDismiss = holder::closeFullEditor,
        modifier = modifier,
    ) {
        FullEditorContent(holder)
    }
}

@Composable
private fun FullEditorContent(holder: ConversationFlowHolder) {
    val colors = Floe.colors
    val find = holder.findReplace
    val queryFocusRequester = remember { FocusRequester() }
    val editorFocusRequester = remember { FocusRequester() }
    var findWasOpen by remember { mutableStateOf(false) }
    val scrollState = rememberScrollState()
    var textLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val density = LocalDensity.current
    val fieldTopPaddingPx = with(density) { 12.dp.toPx() }
    val scrollMarginPx = with(density) { 24.dp.toPx() }

    // Back while Find is open closes ONLY the Find bar. The sheet's own
    // dismiss handler stays authoritative once the bar is closed.
    BackHandler(enabled = find.isOpen) { holder.closeFindInFullEditor() }

    // Keep the keyboard focus on the surface the user is actually using:
    // query when Find opens, editor when it closes. Purely local focus, never
    // a draft edit or a send.
    LaunchedEffect(find.isOpen) {
        if (find.isOpen) {
            findWasOpen = true
            requestFocusSafely(queryFocusRequester)
        } else if (findWasOpen) {
            findWasOpen = false
            requestFocusSafely(editorFocusRequester)
        }
    }

    // Bring the CURRENT REAL match into view from the actual Compose text
    // layout. The selected range remains the shared TextFieldValue selection;
    // this effect only adjusts the parent scroll offset.
    LaunchedEffect(find.isOpen, find.currentMatch, find.currentOrdinal, textLayout) {
        val match = find.currentMatch
        val layout = textLayout
        if (!find.isOpen || match == null || layout == null) return@LaunchedEffect
        val startLine = layout.getLineForOffset(match.start)
        val endLine = layout.getLineForOffset((match.end - 1).coerceAtLeast(match.start))
        val target = FindScrollPolicy.targetOffset(
            matchTop = layout.getLineTop(startLine) + fieldTopPaddingPx,
            matchBottom = layout.getLineBottom(endLine) + fieldTopPaddingPx,
            scrollOffset = scrollState.value,
            viewportHeight = scrollState.viewportSize,
            maxScroll = scrollState.maxValue,
            marginPx = scrollMarginPx.roundToInt(),
        )
        if (target != scrollState.value) scrollState.animateScrollTo(target)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.readingSurface)
            .onPreviewKeyEvent { event ->
                handleEditorKeyEvent(event, holder, find.isOpen, queryFocusRequester)
            },
    ) {
        // Use the smaller of the dialog's actual width and the device
        // configuration width: a narrow phone (including the synthetic compact
        // fixture) gets the two-row toolbar, while a tablet dialog keeps the
        // full single row. A narrow split-screen dialog also gets the safe
        // two-row layout.
        val configurationWidth = LocalConfiguration.current.screenWidthDp.dp
        val effectiveWidth = minOf(maxWidth, configurationWidth)
        val compact = effectiveWidth < 560.dp
        Column(modifier = Modifier.fillMaxSize()) {
            FullEditorToolbar(
                holder = holder,
                compact = compact,
                findOpen = find.isOpen,
            )
            FloeDivider()
            if (find.isOpen) {
                FindReplaceBar(
                    holder = holder,
                    find = find,
                    queryFocusRequester = queryFocusRequester,
                )
                FloeDivider()
            }
            FullEditorTextField(
                holder = holder,
                find = find,
                focusRequester = editorFocusRequester,
                scrollState = scrollState,
                onTextLayout = { textLayout = it },
                modifier = Modifier.weight(1f),
            )
            FloeDivider()
            FullEditorFooter(holder)
        }
    }
}

/** Focus is a UX enhancement, never a correctness requirement: a future
 * Cupertino wrapper change that detaches the request target must not crash the
 * editor. The user can always tap the field. */
private fun requestFocusSafely(requester: FocusRequester) {
    try {
        requester.requestFocus()
    } catch (_: IllegalStateException) {
        // No attached focus target in this composition.
    }
}

/** Hardware Ctrl/Cmd+F opens/re-focuses Find; Escape closes only Find. A
 * closed Find bar never consumes Escape, so the platform Back/Done path keeps
 * its ordinary dismissal semantics. */
private fun handleEditorKeyEvent(
    event: KeyEvent,
    holder: ConversationFlowHolder,
    findOpen: Boolean,
    queryFocusRequester: FocusRequester,
): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    if ((event.isCtrlPressed || event.isMetaPressed) && event.key == Key.F) {
        if (findOpen) requestFocusSafely(queryFocusRequester) else holder.openFindInFullEditor()
        return true
    }
    if (event.key == Key.Escape && findOpen) {
        holder.closeFindInFullEditor()
        return true
    }
    return false
}

/* --------------------------------- the toolbar -------------------------------- */

@Composable
private fun FullEditorToolbar(
    holder: ConversationFlowHolder,
    compact: Boolean,
    findOpen: Boolean,
) {
    val colors = Floe.colors
    val undoLabel = stringResource(R.string.composer_editor_undo)
    val redoLabel = stringResource(R.string.composer_editor_redo)
    val selectAllLabel = stringResource(R.string.composer_editor_select_all)
    val sendLabel = stringResource(R.string.composer_editor_send)
    val doneLabel = stringResource(R.string.action_done)
    val title = stringResource(R.string.composer_editor_title)

    if (compact) {
        // Narrow phone: the historical single row cannot hold Undo/Redo,
        // title, Find, Select All, Send and Done without clipping. Two rows
        // keep every control a real ≥48dp target and preserve the existing
        // text labels used by the component contract.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                EditorBarButton(label = undoLabel, enabled = holder.canUndoDraft) {
                    holder.undoDraft()
                }
                EditorBarButton(label = redoLabel, enabled = holder.canRedoDraft) {
                    holder.redoDraft()
                }
                Spacer(Modifier.weight(1f))
                FloeText(
                    title,
                    style = Floe.typography.toolbarTitle,
                    color = colors.label,
                    modifier = Modifier.semantics { contentDescription = title },
                )
                Spacer(Modifier.weight(1f))
                FindToolbarButton(holder = holder, findOpen = findOpen)
                EditorBarButton(label = doneLabel, enabled = true, emphasized = true) {
                    holder.closeFullEditor()
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                EditorBarButton(
                    label = selectAllLabel,
                    enabled = holder.draft.value.text.isNotEmpty(),
                ) {
                    holder.selectAllDraft()
                }
                Spacer(Modifier.weight(1f))
                EditorBarButton(
                    label = sendLabel,
                    enabled = holder.fullEditorCanSend(),
                ) {
                    holder.sendFromFullEditor()
                }
            }
        }
    } else {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            EditorBarButton(label = undoLabel, enabled = holder.canUndoDraft) {
                holder.undoDraft()
            }
            EditorBarButton(label = redoLabel, enabled = holder.canRedoDraft) {
                holder.redoDraft()
            }
            Spacer(Modifier.weight(1f))
            FloeText(
                title,
                style = Floe.typography.toolbarTitle,
                color = colors.label,
                modifier = Modifier.semantics { contentDescription = title },
            )
            Spacer(Modifier.weight(1f))
            FindToolbarButton(holder = holder, findOpen = findOpen)
            EditorBarButton(
                label = selectAllLabel,
                enabled = holder.draft.value.text.isNotEmpty(),
            ) {
                holder.selectAllDraft()
            }
            EditorBarButton(
                label = sendLabel,
                enabled = holder.fullEditorCanSend(),
            ) {
                holder.sendFromFullEditor()
            }
            EditorBarButton(label = doneLabel, enabled = true, emphasized = true) {
                holder.closeFullEditor()
            }
        }
    }
}

@Composable
private fun FindToolbarButton(holder: ConversationFlowHolder, findOpen: Boolean) {
    val colors = Floe.colors
    val label = stringResource(R.string.composer_editor_find)
    FloeCircleButton(
        icon = FloeIcons.Magnifier,
        contentDescription = label,
        onClick = {
            if (findOpen) holder.closeFindInFullEditor() else holder.openFindInFullEditor()
        },
        background = if (findOpen) colors.accentFillFaint else colors.chromeSurface,
        tint = if (findOpen) colors.accent else colors.label,
    )
}

/* --------------------------------- the field ---------------------------------- */

@Composable
private fun FullEditorTextField(
    holder: ConversationFlowHolder,
    find: FindReplaceUiState,
    focusRequester: FocusRequester,
    scrollState: androidx.compose.foundation.ScrollState,
    onTextLayout: (TextLayoutResult) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val title = stringResource(R.string.composer_editor_title)
    val highlight = rememberFindHighlightTransformation(find)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(scrollState)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        BasicTextField(
            value = holder.draft.value,
            onValueChange = holder::onDraftChange,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 240.dp)
                .focusRequester(focusRequester)
                .semantics { contentDescription = title },
            textStyle = Floe.typography.composerField.copy(color = colors.label),
            cursorBrush = SolidColor(colors.accent),
            visualTransformation = highlight,
            onTextLayout = onTextLayout,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                keyboardType = androidx.compose.ui.text.input.KeyboardType.Text,
                imeAction = androidx.compose.ui.text.input.ImeAction.Default,
            ),
            decorationBox = { innerTextField ->
                Box(modifier = Modifier.fillMaxWidth()) {
                    if (holder.draft.value.text.isEmpty()) {
                        FloeText(
                            stringResource(R.string.composer_placeholder),
                            style = Floe.typography.composerField,
                            color = colors.placeholderText,
                        )
                    }
                    innerTextField()
                }
            },
        )
    }
}

/* --------------------------------- the footer --------------------------------- */

@Composable
private fun FullEditorFooter(holder: ConversationFlowHolder) {
    val colors = Floe.colors

    // ⇄ ComposerFooterCounts: the first value is computed when the editor
    // opens (onAppear setImmediately), later keystroke bursts are recounted
    // behind the debounce; a newer revision replaces the pending older one
    // because the effect restarts on every text change.
    val draftText = holder.draft.value.text
    var characters by remember { mutableStateOf(0) }
    var tokens by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        characters = FullEditorPolicy.characterCount(holder.draft.value.text)
        tokens = FullEditorPolicy.estimatedTokens(holder.draft.value.text)
    }
    LaunchedEffect(draftText) {
        kotlinx.coroutines.delay(FullEditorPolicy.FOOTER_DEBOUNCE_MILLIS)
        characters = FullEditorPolicy.characterCount(draftText)
        tokens = FullEditorPolicy.estimatedTokens(draftText)
    }

    // ⇄ footer: characters + rough token estimate, both metadata-styled.
    val charactersText = stringResource(R.string.composer_editor_characters, characters)
    val tokensText = stringResource(R.string.composer_editor_tokens, tokens)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            charactersText,
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            modifier = Modifier.semantics { contentDescription = charactersText },
        )
        Spacer(Modifier.weight(1f))
        FloeText(
            tokensText,
            style = Floe.typography.metadata,
            color = colors.tertiaryLabel,
        )
    }
}

/** 48dp text affordance control (matches the module's existing honest text
 * targets; no invented glyph). Shared with the Find/Replace bar in this same
 * feature package. */
@Composable
internal fun EditorBarButton(
    label: String,
    enabled: Boolean,
    emphasized: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(9.dp)
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .then(
                if (emphasized) {
                    Modifier.background(
                        if (enabled) colors.accentFillFaint else colors.fillTertiary,
                    )
                } else {
                    Modifier
                },
            )
            .border(0.5.dp, colors.chromeHairline, shape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = when {
                !enabled -> colors.tertiaryLabel
                emphasized -> colors.accent
                else -> colors.label
            },
        )
    }
}
