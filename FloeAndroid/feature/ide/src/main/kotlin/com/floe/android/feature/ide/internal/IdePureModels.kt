// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.internal

import com.floe.android.feature.ide.IdeDiffLine
import com.floe.android.feature.ide.IdeDiffLineKind
import com.floe.android.feature.ide.IdeTreeRow
import com.floe.android.feature.ide.api.IdeFileRow

/**
 * Pure tree flattening mirroring the iOS FileTreeViewModel.visibleNodes rule:
 * a directory's children render only while expanded AND loaded; lazy children
 * arrive from the host via ExpandTree replies.
 */
internal object IdeFileTreeModel {

    fun flatten(
        rootChildren: List<IdeFileRow>?,
        childrenByPath: Map<String, List<IdeFileRow>>,
        expandedPaths: Set<String>,
        loadingPaths: Set<String>,
    ): List<IdeTreeRow> {
        val rows = ArrayList<IdeTreeRow>()
        val root = rootChildren ?: return rows
        appendLevel(rows, root, childrenByPath, expandedPaths, loadingPaths, depth = 0)
        return rows
    }

    private fun appendLevel(
        rows: MutableList<IdeTreeRow>,
        level: List<IdeFileRow>,
        childrenByPath: Map<String, List<IdeFileRow>>,
        expandedPaths: Set<String>,
        loadingPaths: Set<String>,
        depth: Int,
    ) {
        for (row in level) {
            val expanded = row.isDirectory && row.relativePath in expandedPaths
            rows += IdeTreeRow(
                file = row,
                depth = depth,
                expanded = expanded,
                childrenLoading = row.relativePath in loadingPaths,
            )
            if (expanded) {
                val children = childrenByPath[row.relativePath]
                if (children != null) {
                    appendLevel(rows, children, childrenByPath, expandedPaths, loadingPaths, depth + 1)
                }
            }
        }
    }
}

/**
 * Unified-diff line classification mirroring iOS DiffView.swift (headers ---
 * / +++, hunk @@, +/- body, everything else context; blank lines dropped).
 */
internal object IdeDiffModel {

    data class Classified(val lines: List<IdeDiffLine>, val additions: Int, val removals: Int)

    fun classify(unifiedDiff: String): Classified {
        var additions = 0
        var removals = 0
        val lines = unifiedDiff.split('\n').mapNotNull { raw ->
            if (raw.isEmpty()) return@mapNotNull null
            val kind = when {
                raw.startsWith("---") || raw.startsWith("+++") -> IdeDiffLineKind.HEADER
                raw.startsWith("@@") -> IdeDiffLineKind.HUNK_HEADER
                raw.startsWith("+") -> {
                    additions++
                    IdeDiffLineKind.ADDITION
                }
                raw.startsWith("-") -> {
                    removals++
                    IdeDiffLineKind.REMOVAL
                }
                else -> IdeDiffLineKind.CONTEXT
            }
            IdeDiffLine(raw, kind)
        }
        return Classified(lines, additions, removals)
    }
}
