// SPDX-License-Identifier: MPL-2.0
//
// Find/Replace bar for the full composer editor.
//
// The bar is ordinary Floe-owned chrome over the SAME holder draft. It owns no
// text and no search state: query/replacement/options/count/current match live
// in ConversationFlowHolder.findReplace (RAM only). Every visible control maps
// to one holder action, so the editor, inline field, undo history and send
// pipeline remain the single source of truth.
//
// Accessibility and hit targets:
//  - the query/replacement fields expose their localized labels as content
//    descriptions;
//  - Previous/Next/Close are 48dp targets with localized action descriptions;
//  - Replace/Replace All keep the module's existing 48dp text affordance;
//  - Match Case/Whole Word are checkbox rows with a 48dp target;
//  - the count is exposed as text (and as the same content description), and
//    the no-match state is announced instead of silently looking unchanged.
//
// The optional highlight layer is derived from the same immutable match ranges
// as the selected current match. It never alters the text, the selection or
// the undo stack: the authoritative current match is still the real range in
// the shared TextFieldValue, and this transformation only paints a background
// over those real ranges so the match stays visible while the query field owns
// the keyboard focus.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeText

/**
 * The complete Find/Replace surface. It is shown between the full editor's
 * toolbar and its text field while [FindReplaceUiState.isOpen] is true.
 */
@Composable
internal fun FindReplaceBar(
    holder: ConversationFlowHolder,
    find: FindReplaceUiState,
    queryFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val findHint = stringResource(R.string.composer_editor_find_hint)
    val replaceHint = stringResource(R.string.composer_editor_replace_hint)
    val previousLabel = stringResource(R.string.composer_editor_find_previous)
    val nextLabel = stringResource(R.string.composer_editor_find_next)
    val closeLabel = stringResource(R.string.composer_editor_find_close)
    val replaceLabel = stringResource(R.string.composer_editor_replace)
    val replaceAllLabel = stringResource(R.string.composer_editor_replace_all)
    val matchCaseLabel = stringResource(R.string.composer_editor_match_case)
    val wholeWordLabel = stringResource(R.string.composer_editor_whole_word)
    val noResultsLabel = stringResource(R.string.composer_editor_find_no_results)

    val positionText = when {
        find.query.isEmpty() -> ""
        find.totalMatches == 0 -> noResultsLabel
        else -> stringResource(
            R.string.composer_editor_find_position,
            find.currentOrdinal.coerceAtLeast(0) + 1,
            find.totalMatches,
        )
    }
    val hasMatches = find.hasMatches
    val countModifier = if (positionText.isEmpty()) {
        Modifier
    } else {
        Modifier.semantics { contentDescription = positionText }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.groupedSurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeSearchField(
                value = find.query,
                onValueChange = holder::setFindQuery,
                placeholder = findHint,
                modifier = Modifier
                    .weight(1f)
                    .focusRequester(queryFocusRequester),
            )
            FloeText(
                positionText,
                style = Floe.typography.metadata,
                color = if (find.query.isNotEmpty() && !hasMatches) {
                    colors.pending
                } else {
                    colors.secondaryLabel
                },
                maxLines = 1,
                modifier = countModifier,
            )
            FloeCircleButton(
                icon = FloeIcons.ChevronUp,
                contentDescription = previousLabel,
                onClick = { holder.findPrevious() },
                enabled = hasMatches,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
            FloeCircleButton(
                icon = FloeIcons.ChevronDown,
                contentDescription = nextLabel,
                onClick = { holder.findNext() },
                enabled = hasMatches,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
            FloeCircleButton(
                icon = FloeIcons.Xmark,
                contentDescription = closeLabel,
                onClick = holder::closeFindInFullEditor,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloePlainFormField(
                label = replaceHint,
                value = find.replacement,
                onValueChange = holder::setFindReplacement,
                modifier = Modifier.weight(1f),
            )
            EditorBarButton(
                label = replaceLabel,
                enabled = hasMatches,
                onClick = { holder.replaceCurrentFindMatch() },
            )
            EditorBarButton(
                label = replaceAllLabel,
                enabled = hasMatches,
                onClick = { holder.replaceAllFindMatches() },
            )
        }
        if (find.replaceAllRefused) {
            val tooLarge = stringResource(R.string.composer_editor_replace_too_large)
            FloeText(
                tooLarge,
                style = Floe.typography.metadata,
                color = colors.destructive,
                modifier = Modifier.semantics { contentDescription = tooLarge },
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeCheckboxRow(
                label = matchCaseLabel,
                checked = find.matchCase,
                onCheckedChange = holder::setFindMatchCase,
                modifier = Modifier.weight(1f),
            )
            FloeCheckboxRow(
                label = wholeWordLabel,
                checked = find.wholeWord,
                onCheckedChange = holder::setFindWholeWord,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/**
 * Builds the optional highlight layer for the current Find snapshot. The
 * helper is remembered on the exact query/options/current match; the plain
 * text is supplied by the text field at filter time.
 */
@Composable
internal fun rememberFindHighlightTransformation(find: FindReplaceUiState): VisualTransformation {
    val colors = Floe.colors
    val matchBackground = colors.accentFillBubble
    val currentBackground = colors.accent.copy(alpha = 0.32f)
    return remember(
        find.isOpen,
        find.query,
        find.matchCase,
        find.wholeWord,
        find.currentMatch,
        matchBackground,
        currentBackground,
    ) {
        if (!find.isOpen || find.query.isEmpty()) {
            VisualTransformation.None
        } else {
            FindHighlightTransformation(
                query = find.query,
                options = find.options,
                currentMatch = find.currentMatch,
                matchBackground = matchBackground,
                currentBackground = currentBackground,
            )
        }
    }
}

/**
 * Background-only transformation over real match ranges.
 *
 * It deliberately uses [OffsetMapping.Identity]: the text and every cursor
 * offset are unchanged. The transformation never edits, reorders or replaces
 * the draft; it only adds background spans computed from the same literal
 * scanner the holder uses. The highlight window is bounded so a pathological
 * number of matches cannot create an unbounded AnnotatedString; the total
 * count and Replace All still cover every match.
 */
private class FindHighlightTransformation(
    private val query: String,
    private val options: FindOptions,
    private val currentMatch: FindMatch?,
    private val matchBackground: Color,
    private val currentBackground: Color,
) : VisualTransformation {

    private var cachedText: String? = null
    private var cachedResult: TransformedText? = null

    override fun filter(text: AnnotatedString): TransformedText {
        if (cachedText === text.text) {
            cachedResult?.let { return it }
        }
        val ranges = FindScanner(text.text, query, options)
            .matches(FindScanner.MAX_HIGHLIGHT_MATCHES)
        val transformed = if (ranges.isEmpty()) {
            TransformedText(text, OffsetMapping.Identity)
        } else {
            val builder = AnnotatedString.Builder(text)
            ranges.forEach { match ->
                builder.addStyle(
                    SpanStyle(background = matchBackground),
                    match.start,
                    match.end,
                )
            }
            currentMatch?.let { match ->
                if (match.start >= 0 && match.end <= text.length) {
                    builder.addStyle(
                        SpanStyle(background = currentBackground),
                        match.start,
                        match.end,
                    )
                }
            }
            TransformedText(builder.toAnnotatedString(), OffsetMapping.Identity)
        }
        cachedText = text.text
        cachedResult = transformed
        return transformed
    }
}
