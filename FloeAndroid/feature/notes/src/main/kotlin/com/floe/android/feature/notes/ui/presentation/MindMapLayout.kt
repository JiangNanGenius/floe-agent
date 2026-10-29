// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteRect
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

public enum class MindMapLayoutDirection(public val wire: Int) {
    RIGHT(0),
    LEFT(1),
    DOWN(2),
    ;

    public companion object {
        public fun fromWire(value: Int?): MindMapLayoutDirection =
            entries.firstOrNull { it.wire == value } ?: RIGHT
    }
}

public data class MindMapNodeSize(public val width: Double, public val height: Double)

public data class MindMapLayoutEdge(
    public val id: String,
    public val from: String,
    public val to: String,
    public val tree: Boolean,
)

public data class MindMapLayoutResult(
    public val frames: Map<String, NoteRect>,
    public val visibleNodes: List<MindMapNode>,
    public val edges: List<MindMapLayoutEdge>,
    public val bounds: NoteRect,
)

/**
 * Deterministic tree layout shared by the canvas and the JVM tests.
 *
 * * RIGHT / LEFT: depth columns, siblings stacked by subtree height.
 * * DOWN: depth rows, siblings placed by subtree width.
 * * A node with an explicit [MindMapNode.position] keeps that saved position
 *   (free layout after a drag); auto layout remains the default for nodes that
 *   have never been moved.
 * * Collapsed nodes hide their descendants; their fold control still shows
 *   that hidden children exist.
 */
public object MindMapLayoutEngine {
    private const val H_GAP = 72.0
    private const val V_GAP = 28.0
    private const val ROOT_GAP = 96.0

    public fun nodeSize(node: MindMapNode): MindMapNodeSize {
        val titleCharsPerLine = 16
        val titleLines = max(1, ceil(node.title.length.toDouble() / titleCharsPerLine).toInt())
        val noteLines = min(4, if (node.note.isBlank()) 0 else node.note.lines().size)
        val width = (96.0 + min(node.title.length, 40) * 4.2).coerceIn(132.0, 300.0)
        val height = 56.0 + (titleLines - 1) * 18.0 + noteLines * 15.0 +
            (if (node.imageResourceID != null) 100.0 else 0.0) +
            ((node.attachments?.size ?: 0) * 16.0)
        return MindMapNodeSize(width, height.coerceAtLeast(56.0))
    }

    public fun layout(
        document: NoteDocument,
        direction: MindMapLayoutDirection = MindMapLayoutDirection.fromWire(document.mindMapDirection),
        sizes: Map<String, MindMapNodeSize> = emptyMap(),
    ): MindMapLayoutResult {
        val nodes = document.nodes
        if (nodes.isEmpty()) {
            return MindMapLayoutResult(emptyMap(), emptyList(), emptyList(), NoteRect(0.0, 0.0, 1.0, 1.0))
        }
        val byID = nodes.associateBy { it.id }
        val children = nodes.filter { it.parentID != null }
            .groupBy { it.parentID!! }
            .mapValues { (_, value) -> value.sortedWith(compareBy({ it.order }, { it.id })) }
        val roots = nodes.filter { it.parentID == null || byID[it.parentID] == null }
            .sortedWith(compareBy({ it.order }, { it.id }))
        val primary = roots.first()
        val frames = mutableMapOf<String, NoteRect>()
        val visible = mutableListOf<MindMapNode>()
        val sizeOf: (MindMapNode) -> MindMapNodeSize = { node -> sizes[node.id] ?: nodeSize(node) }

        val visibleSet = LinkedHashSet<String>()
        fun walk(node: MindMapNode) {
            if (!visibleSet.add(node.id)) return
            visible += node
            if (!node.isCollapsed) children[node.id].orEmpty().forEach(::walk)
        }
        walk(primary)

        val depth = mutableMapOf<String, Int>()
        fun assignDepth(node: MindMapNode, value: Int) {
            if (depth[node.id] != null) return
            depth[node.id] = value
            if (!node.isCollapsed) children[node.id].orEmpty().forEach { assignDepth(it, value + 1) }
        }
        assignDepth(primary, 0)

        when (direction) {
            MindMapLayoutDirection.RIGHT, MindMapLayoutDirection.LEFT ->
                layoutHorizontal(primary, children, visibleSet, sizeOf, frames, direction)
            MindMapLayoutDirection.DOWN ->
                layoutDown(primary, children, visibleSet, sizeOf, frames)
        }

        // Disconnected/orphan topics stay visible and editable instead of
        // silently disappearing from the canvas.
        var orphanY = (frames.values.maxOfOrNull { it.y + it.height } ?: 0.0) + ROOT_GAP
        roots.drop(1).forEach { root ->
            if (!visibleSet.add(root.id)) return@forEach
            visible += root
            val nodeSize = sizeOf(root)
            frames[root.id] = NoteRect(0.0, orphanY, nodeSize.width, nodeSize.height)
            orphanY += nodeSize.height + V_GAP
        }

        // Explicit saved positions win over the generated layout.
        visible.forEach { node ->
            node.position?.let { point ->
                val nodeSize = sizeOf(node)
                frames[node.id] = NoteRect(
                    x = point.x.coerceIn(-100_000.0, 100_000.0),
                    y = point.y.coerceIn(-100_000.0, 100_000.0),
                    width = nodeSize.width,
                    height = nodeSize.height,
                )
            }
        }

        val visibleIDs = visible.map { it.id }.toSet()
        val edges = mutableListOf<MindMapLayoutEdge>()
        visible.forEach { node ->
            if (!node.isCollapsed) {
                children[node.id].orEmpty().filter { it.id in visibleIDs }.forEach { child ->
                    edges += MindMapLayoutEdge(
                        id = "tree:${node.id}:${child.id}",
                        from = node.id,
                        to = child.id,
                        tree = true,
                    )
                }
            }
        }
        document.connections.forEach { connection ->
            if (connection.from in visibleIDs && connection.to in visibleIDs) {
                edges += MindMapLayoutEdge(connection.id, connection.from, connection.to, tree = false)
            }
        }

        val bounds = frames.values.reduceOrNull { first, second ->
            NoteRect(
                x = min(first.x, second.x),
                y = min(first.y, second.y),
                width = max(first.x + first.width, second.x + second.width) - min(first.x, second.x),
                height = max(first.y + first.height, second.y + second.height) - min(first.y, second.y),
            )
        } ?: NoteRect(0.0, 0.0, 1.0, 1.0)

        return MindMapLayoutResult(frames, visible, edges, bounds)
    }

    private fun layoutHorizontal(
        root: MindMapNode,
        children: Map<String, List<MindMapNode>>,
        visibleIDs: Set<String>,
        sizeOf: (MindMapNode) -> MindMapNodeSize,
        frames: MutableMap<String, NoteRect>,
        direction: MindMapLayoutDirection,
    ) {
        val subtreeHeights = mutableMapOf<String, Double>()
        fun subtreeHeight(node: MindMapNode): Double {
            subtreeHeights[node.id]?.let { return it }
            val self = sizeOf(node).height
            if (node.isCollapsed) return self.also { subtreeHeights[node.id] = it }
            val values = children[node.id].orEmpty().filter { it.id in visibleIDs }
            if (values.isEmpty()) return self.also { subtreeHeights[node.id] = it }
            val total = values.sumOf { subtreeHeight(it) } + V_GAP * (values.size - 1)
            return max(self, total).also { subtreeHeights[node.id] = it }
        }

        val depthWidths = mutableMapOf<Int, Double>()
        fun collectDepth(node: MindMapNode, depth: Int) {
            depthWidths[depth] = max(depthWidths[depth] ?: 0.0, sizeOf(node).width)
            if (!node.isCollapsed) children[node.id].orEmpty()
                .filter { it.id in visibleIDs }
                .forEach { collectDepth(it, depth + 1) }
        }
        collectDepth(root, 0)
        val depthOffsets = mutableMapOf<Int, Double>()
        var offset = 0.0
        for (index in 0..(depthWidths.keys.maxOrNull() ?: 0)) {
            depthOffsets[index] = offset
            offset += (depthWidths[index] ?: 0.0) + H_GAP
        }

        fun place(node: MindMapNode, depth: Int, centerY: Double) {
            val nodeSize = sizeOf(node)
            val x = if (direction == MindMapLayoutDirection.LEFT) {
                -(depthOffsets[depth] ?: 0.0) - nodeSize.width
            } else {
                depthOffsets[depth] ?: 0.0
            }
            frames[node.id] = NoteRect(x, centerY - nodeSize.height / 2.0, nodeSize.width, nodeSize.height)
            if (node.isCollapsed) return
            val values = children[node.id].orEmpty().filter { it.id in visibleIDs }
            if (values.isEmpty()) return
            val total = values.sumOf { subtreeHeight(it) } + V_GAP * (values.size - 1)
            var cursor = centerY - total / 2.0
            values.forEach { child ->
                val height = subtreeHeight(child)
                place(child, depth + 1, cursor + height / 2.0)
                cursor += height + V_GAP
            }
        }
        place(root, 0, 0.0)
    }

    private fun layoutDown(
        root: MindMapNode,
        children: Map<String, List<MindMapNode>>,
        visibleIDs: Set<String>,
        sizeOf: (MindMapNode) -> MindMapNodeSize,
        frames: MutableMap<String, NoteRect>,
    ) {
        val subtreeWidths = mutableMapOf<String, Double>()
        fun subtreeWidth(node: MindMapNode): Double {
            subtreeWidths[node.id]?.let { return it }
            val self = sizeOf(node).width
            if (node.isCollapsed) return self.also { subtreeWidths[node.id] = it }
            val values = children[node.id].orEmpty().filter { it.id in visibleIDs }
            if (values.isEmpty()) return self.also { subtreeWidths[node.id] = it }
            val total = values.sumOf { subtreeWidth(it) } + H_GAP * (values.size - 1)
            return max(self, total).also { subtreeWidths[node.id] = it }
        }

        val depthHeights = mutableMapOf<Int, Double>()
        fun collectDepth(node: MindMapNode, depth: Int) {
            depthHeights[depth] = max(depthHeights[depth] ?: 0.0, sizeOf(node).height)
            if (!node.isCollapsed) children[node.id].orEmpty()
                .filter { it.id in visibleIDs }
                .forEach { collectDepth(it, depth + 1) }
        }
        collectDepth(root, 0)
        val depthOffsets = mutableMapOf<Int, Double>()
        var offset = 0.0
        for (index in 0..(depthHeights.keys.maxOrNull() ?: 0)) {
            depthOffsets[index] = offset
            offset += (depthHeights[index] ?: 0.0) + V_GAP * 2.0
        }

        fun place(node: MindMapNode, depth: Int, left: Double): Double {
            val nodeSize = sizeOf(node)
            val y = depthOffsets[depth] ?: 0.0
            if (node.isCollapsed) {
                frames[node.id] = NoteRect(left, y, nodeSize.width, nodeSize.height)
                return left + nodeSize.width
            }
            val values = children[node.id].orEmpty().filter { it.id in visibleIDs }
            if (values.isEmpty()) {
                frames[node.id] = NoteRect(left, y, nodeSize.width, nodeSize.height)
                return left + nodeSize.width
            }
            val childrenWidth = values.sumOf { subtreeWidth(it) } + H_GAP * (values.size - 1)
            val ownLeft = left + max(0.0, (childrenWidth - nodeSize.width) / 2.0)
            frames[node.id] = NoteRect(ownLeft, y, nodeSize.width, nodeSize.height)
            var cursor = left
            values.forEach { child ->
                val width = subtreeWidth(child)
                place(child, depth + 1, cursor)
                cursor += width + H_GAP
            }
            return left + max(childrenWidth, nodeSize.width)
        }
        place(root, 0, 0.0)
    }

    /** Outline order (pre-order) with depth, used by the accessible list view. */
    public fun outline(document: NoteDocument): List<Pair<MindMapNode, Int>> {
        val byID = document.nodes.associateBy { it.id }
        val children = document.nodes.filter { it.parentID != null }
            .groupBy { it.parentID!! }
            .mapValues { (_, value) -> value.sortedWith(compareBy({ it.order }, { it.id })) }
        val roots = document.nodes.filter { it.parentID == null || byID[it.parentID] == null }
            .sortedWith(compareBy({ it.order }, { it.id }))
        val output = mutableListOf<Pair<MindMapNode, Int>>()
        val seen = mutableSetOf<String>()
        fun walk(node: MindMapNode, depth: Int) {
            if (!seen.add(node.id)) return
            output += node to depth
            if (!node.isCollapsed) children[node.id].orEmpty().forEach { walk(it, depth + 1) }
        }
        roots.forEach { walk(it, 0) }
        document.nodes.filter { it.id !in seen }.forEach { output += it to 0 }
        return output
    }

    /** Saved free position for a dragged topic. */
    public fun movedNode(node: MindMapNode, frame: NoteRect): MindMapNode =
        node.copy(position = MindMapPoint(frame.x, frame.y))

    /** Removes explicit positions so the automatic layout applies again. */
    public fun automaticNodes(document: NoteDocument): List<MindMapNode> =
        document.nodes.map { it.copy(position = null) }
}
