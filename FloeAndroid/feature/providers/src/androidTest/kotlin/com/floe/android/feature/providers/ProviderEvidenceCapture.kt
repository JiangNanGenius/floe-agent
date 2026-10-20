// SPDX-License-Identifier: MPL-2.0
//
// Test-only rendered-evidence helper: writes the real Compose semantics tree
// (all roots, merged and unmerged nodes) next to each provider screenshot.
// Synthetic fixture content only; no backend, credential or App state.

package com.floe.android.feature.providers

import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteractionsProvider
import androidx.compose.ui.test.isRoot
import java.io.File

internal fun writeProviderComposeHierarchy(
    provider: SemanticsNodeInteractionsProvider,
    file: File,
) {
    val text = runCatching {
        val roots = provider.onAllNodes(isRoot(), useUnmergedTree = true)
        val nodes = roots.fetchSemanticsNodes()
        buildString {
            appendLine("roots=${nodes.size}")
            for (index in nodes.indices) {
                appendProviderNode(this, roots[index].fetchSemanticsNode(), 0)
            }
        }
    }.getOrElse { error -> "hierarchy unavailable: ${error.message}" }
    file.writeText(text)
}

private fun appendProviderNode(out: StringBuilder, node: SemanticsNode, depth: Int) {
    out.append("  ".repeat(depth))
        .append("id=").append(node.id)
        .append(" bounds=").append(node.boundsInRoot)
    node.config.getOrNull(SemanticsProperties.TestTag)?.let { out.append(" tag=").append(it) }
    node.config.getOrNull(SemanticsProperties.Role)?.let { out.append(" role=").append(it) }
    node.config.getOrNull(SemanticsProperties.ContentDescription)
        ?.let { out.append(" cd=").append(it) }
    node.config.getOrNull(SemanticsProperties.Text)
        ?.let { list -> out.append(" text=").append(list.joinToString("|") { it.text }) }
    out.appendLine()
    node.children.forEach { appendProviderNode(out, it, depth + 1) }
}
