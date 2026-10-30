// SPDX-License-Identifier: MPL-2.0
//
// In-thread find bar (⇄ ThreadSearchBar). It searches the CURRENT task's
// visible user/assistant text only and keeps the selected hit after Done.
// All matching/loading is host-owned; this file renders state and owns no
// store, no second reader and no durable write.
package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import kotlinx.coroutines.delay

@Composable
fun ThreadSearchBar(
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
) {
    val state = holder.threadSearch
    // Debounced native query; a newer query cancels the previous wait. The
    // holder's monotonic generation fences an out-of-order native reply.
    LaunchedEffect(state.query) {
        val trimmed = state.query.trim()
        if (trimmed.isBlank()) return@LaunchedEffect
        delay(220)
        holder.searchThread()
    }
    Column(modifier = modifier.fillMaxWidth().background(Floe.colors.groupedSurface)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            FloeSearchField(
                value = state.query,
                onValueChange = holder::setThreadSearchQuery,
                placeholder = stringResource(R.string.thread_search_placeholder),
                modifier = Modifier.weight(1f),
            )
            val count = when {
                state.isSearching -> "…"
                state.hits.isEmpty() && state.hasQuery -> stringResource(R.string.thread_search_no_matches)
                else -> state.countLabel
            }
            FloeText(
                count,
                style = Floe.typography.metadata,
                color = if (state.hits.isEmpty() && state.hasQuery) {
                    Floe.colors.secondaryLabel
                } else {
                    Floe.colors.label
                },
                modifier = Modifier.widthIn(min = 42.dp),
            )
            val previousLabel = stringResource(R.string.thread_search_previous)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .widthIn(min = FloeLayout.MinimumTarget)
                    .clickable(enabled = state.hits.isNotEmpty()) {
                        holder.previousThreadSearchHit()
                    }
                    .semantics { contentDescription = previousLabel },
                contentAlignment = Alignment.Center,
            ) {
                IconGlyph(
                    FloeIcons.ChevronUp,
                    if (state.hits.isNotEmpty()) Floe.colors.accent else Floe.colors.tertiaryLabel,
                    18.dp,
                )
            }
            val nextLabel = stringResource(R.string.thread_search_next)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .widthIn(min = FloeLayout.MinimumTarget)
                    .clickable(enabled = state.hits.isNotEmpty()) {
                        holder.nextThreadSearchHit()
                    }
                    .semantics { contentDescription = nextLabel },
                contentAlignment = Alignment.Center,
            ) {
                IconGlyph(
                    FloeIcons.ChevronDown,
                    if (state.hits.isNotEmpty()) Floe.colors.accent else Floe.colors.tertiaryLabel,
                    18.dp,
                )
            }
            val doneLabel = stringResource(R.string.thread_search_done)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable { holder.endThreadSearch() }
                    .padding(horizontal = 8.dp)
                    .semantics { contentDescription = doneLabel },
                contentAlignment = Alignment.Center,
            ) {
                FloeText(doneLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.accent)
            }
        }
        val message = when (state.error) {
            ThreadSearchErrorUi.OLDER_MATCH_UNAVAILABLE ->
                stringResource(R.string.thread_search_older_unavailable)
            ThreadSearchErrorUi.SEARCH_FAILED,
            ThreadSearchErrorUi.STALE_QUERY -> stringResource(R.string.thread_search_failed)
            null -> null
        }
        if (message != null) {
            FloeText(
                message,
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp),
            )
        } else if (state.includesDurableHistory) {
            FloeText(
                stringResource(R.string.thread_search_includes_history),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp),
            )
        }
        FloeDivider()
    }
}
