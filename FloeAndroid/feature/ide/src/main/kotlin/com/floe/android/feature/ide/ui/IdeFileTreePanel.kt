// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.ide.IdeTreeState
import com.floe.android.feature.ide.R
import com.floe.android.feature.ide.api.IdeSearchHit

/**
 * Explorer-style lazy tree, mirroring the iPad FileTreeView structure (search
 * field on top, flat search-hit list while typing, disclosure rows at 48dp
 * targets). Expansion, search and open are host-authority callbacks — the
 * module never lists a directory by itself.
 */
@Composable
internal fun IdeFileTreePanel(
    state: IdeTreeState,
    onQuery: (String) -> Unit,
    onToggle: (String) -> Unit,
    onOpenFile: (String) -> Unit,
    onOpenHit: (IdeSearchHit) -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    Column(modifier.background(colors.sidebarSurface)) {
        // Search field (iOS FileTreeView.searchField: icon + plain field + clear).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconGlyph(
                icon = FloeIcons.Magnifier,
                tint = colors.secondaryLabel,
                size = 18.dp,
            )
            Spacer(Modifier.width(8.dp))
            Box(Modifier.weight(1f)) {
                // Resolved once in the composable context; the semantics
                // callback captures the same string.
                val searchPlaceholder = stringResource(R.string.ide_search_placeholder)
                if (state.searchQuery.isEmpty()) {
                    FloeText(
                        text = searchPlaceholder,
                        style = Floe.typography.body,
                        color = colors.placeholderText,
                        maxLines = 1,
                    )
                }
                BasicTextField(
                    value = state.searchQuery,
                    onValueChange = onQuery,
                    singleLine = true,
                    textStyle = Floe.typography.body.copy(color = colors.label),
                    cursorBrush = SolidColor(colors.accent),
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = searchPlaceholder },
                )
            }
            if (state.searchQuery.isNotEmpty()) {
                val clearCd = stringResource(R.string.ide_search_clear_cd)
                Box(
                    modifier = Modifier
                        .size(FloeLayout.MinimumTarget)
                        .clickable { onQuery("") }
                        .semantics { contentDescription = clearCd },
                    contentAlignment = Alignment.Center,
                ) {
                    IconGlyph(
                        icon = FloeIcons.Xmark,
                        tint = colors.secondaryLabel,
                        size = 16.dp,
                    )
                }
            }
            val refreshCd = stringResource(R.string.ide_tree_refresh_cd)
            FloeCircleButton(
                icon = FloeIcons.Refresh,
                contentDescription = refreshCd,
                onClick = onRefresh,
                visualSize = 34.dp,
                iconSize = 15.dp,
            )
        }
        FloeDivider()
        val searching = state.searchQuery.isNotEmpty()
        when {
            searching -> {
                when {
                    state.searchInProgress -> LoadingRow(Modifier.fillMaxSize())
                    state.searchError != null -> MessageRow(state.searchError!!)
                    state.searchHits.isEmpty() -> EmptyRow(
                        title = stringResource(R.string.ide_search_empty),
                        detail = state.searchQuery,
                    )
                    else -> LazyColumn(Modifier.fillMaxSize()) {
                        items(state.searchHits) { hit ->
                            SearchHitRow(hit = hit, onClick = { onOpenHit(hit) })
                        }
                    }
                }
            }
            state.rootLoading && state.rows.isEmpty() -> LoadingRow(Modifier.fillMaxSize())
            state.rootError != null && state.rows.isEmpty() -> MessageRow(state.rootError!!)
            state.rows.isEmpty() -> EmptyRow(
                title = stringResource(R.string.ide_tree_empty),
                detail = null,
            )
            else -> LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = 4.dp),
            ) {
                items(state.rows, key = { it.file.relativePath }) { row ->
                    TreeRow(
                        name = row.file.name,
                        isDirectory = row.file.isDirectory,
                        depth = row.depth,
                        expanded = row.expanded,
                        loading = row.childrenLoading,
                        onClick = {
                            if (row.file.isDirectory) onToggle(row.file.relativePath)
                            else onOpenFile(row.file.relativePath)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun TreeRow(
    name: String,
    isDirectory: Boolean,
    depth: Int,
    expanded: Boolean,
    loading: Boolean,
    onClick: () -> Unit,
) {
    val colors = Floe.colors
    val cd = if (isDirectory) {
        stringResource(R.string.ide_row_dir_cd, name)
    } else {
        stringResource(R.string.ide_row_file_cd, name)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(onClick = onClick)
            .padding(start = (10 + depth * 14).dp, end = 10.dp)
            .semantics { contentDescription = cd },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (isDirectory) {
            IconGlyph(
                icon = if (expanded) FloeIcons.ChevronDown else FloeIcons.ChevronForward,
                tint = colors.secondaryLabel,
                size = 12.dp,
            )
        } else {
            Spacer(Modifier.width(12.dp))
        }
        Spacer(Modifier.width(6.dp))
        IconGlyph(
            icon = if (isDirectory) FloeIcons.Folder else FloeIdeIcons.DocPage,
            tint = if (isDirectory) colors.accent else colors.secondaryLabel,
            size = 18.dp,
        )
        Spacer(Modifier.width(8.dp))
        FloeText(
            text = name,
            style = Floe.typography.body,
            color = colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (loading) {
            androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 1.5.dp,
                color = colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun SearchHitRow(hit: IdeSearchHit, onClick: () -> Unit) {
    val colors = Floe.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        FloeText(
            text = if (hit.lineNumber > 0) "${hit.relativePath}:${hit.lineNumber}" else hit.relativePath,
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeText(
            text = hit.context,
            style = Floe.typography.evidence.copy(fontSize = 13.sp),
            color = colors.label,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun LoadingRow(modifier: Modifier = Modifier) {
    val colors = Floe.colors
    Box(modifier.padding(16.dp), contentAlignment = Alignment.Center) {
        // Tree/search loading uses the Floe accent spinner.
        androidx.compose.material3.CircularProgressIndicator(
            modifier = Modifier.size(22.dp),
            color = colors.accent,
            strokeWidth = 2.dp,
        )
    }
}

@Composable
private fun MessageRow(message: String) {
    val colors = Floe.colors
    Box(Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
        FloeText(
            text = message,
            style = Floe.typography.metadata,
            color = colors.destructive,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun EmptyRow(title: String, detail: String?) {
    val colors = Floe.colors
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconGlyph(
            icon = FloeIcons.Folder,
            tint = colors.tertiaryLabel,
            size = 30.dp,
        )
        Spacer(Modifier.height(8.dp))
        FloeText(title, style = Floe.typography.body, color = colors.secondaryLabel)
        if (detail != null) {
            FloeText(
                detail,
                style = Floe.typography.metadata,
                color = colors.tertiaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
