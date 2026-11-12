// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Minimal live-tree adapter for the bounded capture walk. The walker owns
 * every handle returned by [child] and releases it exactly once through
 * [recycle]; the root handle is borrowed from the caller and is never
 * recycled by the walker.
 */
internal interface PhoneControlCaptureTreeAdapter<T> {
    fun child(node: T, index: Int): T?
    fun recycle(node: T)
}

/**
 * Pure, level-order traversal used by [PhoneControlSnapshotter]. Reading node
 * properties remains the caller's job; this object only decides which real
 * tree path is visited next and enforces the global node/depth/time bounds.
 *
 * Why level order instead of a recursive per-branch quota: a recursive fair
 * split gives a deep branch only its current share, and a later shallow
 * sibling that consumes less never returns that unused share to the earlier
 * branch. A bounded ordinary form can therefore lose deep date/time controls
 * even when the whole tree is far below [PhoneControlLimits.MAX_SCAN_NODES].
 * Level order spends the one global budget across the actual tree; a fully
 * reachable form is read completely, and a genuinely wide screen still yields
 * its shallow toolbar/FAB controls before deep content.
 *
 * Pending work is represented by integer paths, not by retained node handles.
 * The path cursor keeps at most one handle per level plus the child currently
 * being visited, so an arbitrarily wide tree cannot accumulate an unbounded
 * number of live AccessibilityNodeInfo objects.
 */
internal object PhoneControlCaptureWalk {
    enum class VisitState { CONTINUE, OBSOLETE, CANCELLED }

    /**
     * Result of reading one node. [childCount] and [scrollable] are read from
     * the same live handle as the node's other properties; the walker uses
     * them to schedule children without touching the handle again.
     */
    data class Visit(
        val state: VisitState = VisitState.CONTINUE,
        val childCount: Int = 0,
        val scrollable: Boolean = false,
    )

    data class Result(
        val visitedNodeCount: Int,
        val depthLimited: Boolean,
        val scanLimited: Boolean,
        val timedOut: Boolean,
        val obsolete: Boolean,
        val cancelled: Boolean,
        /** Real tree paths in visit order; exposed for focused unit tests. */
        val visitedPaths: List<List<Int>>,
    )

    private data class LevelEntry(
        val path: List<Int>,
        val childCount: Int,
        val insideScrollable: Boolean,
        val scrollable: Boolean,
    )

    /**
     * @param maxNodes global number of live nodes read, including the root.
     * @param maxDepth deepest node depth that may be visited (root is 0).
     * @param deadlineElapsedRealtimeMillis absolute monotonic deadline.
     * @param nowElapsedRealtimeMillis monotonic clock in the same domain.
     */
    fun <T> walk(
        root: T,
        adapter: PhoneControlCaptureTreeAdapter<T>,
        maxNodes: Int = PhoneControlLimits.MAX_SCAN_NODES,
        maxDepth: Int = PhoneControlLimits.MAX_DEPTH,
        deadlineElapsedRealtimeMillis: Long,
        nowElapsedRealtimeMillis: () -> Long,
        isCancelled: () -> Boolean = { false },
        visit: (path: List<Int>, depth: Int, node: T, insideScrollable: Boolean) -> Visit,
    ): Result {
        val nodeLimit = maxNodes.coerceAtLeast(1)
        val depthLimit = maxDepth.coerceAtLeast(0)
        var visited = 0
        var depthLimited = false
        var scanLimited = false
        var timedOut = false
        var obsolete = false
        var cancelled = false
        val paths = ArrayList<List<Int>>(minOf(nodeLimit, 256))

        fun stop(): Boolean = obsolete || cancelled

        fun cancelIfNeeded(): Boolean {
            if (cancelled) return true
            if (isCancelled()) {
                cancelled = true
                return true
            }
            return false
        }

        fun timeExceeded(): Boolean {
            if (timedOut) return true
            if (nowElapsedRealtimeMillis() > deadlineElapsedRealtimeMillis) {
                timedOut = true
                scanLimited = true
                return true
            }
            return false
        }

        if (cancelIfNeeded()) {
            return Result(
                visitedNodeCount = 0,
                depthLimited = false,
                scanLimited = false,
                timedOut = false,
                obsolete = false,
                cancelled = true,
                visitedPaths = emptyList(),
            )
        }
        val rootVisit = visit(emptyList(), 0, root, false)
        if (rootVisit.state != VisitState.CONTINUE) {
            obsolete = rootVisit.state == VisitState.OBSOLETE
            cancelled = rootVisit.state == VisitState.CANCELLED
            return Result(
                visitedNodeCount = 0,
                depthLimited = false,
                scanLimited = false,
                timedOut = false,
                obsolete = obsolete,
                cancelled = cancelled,
                visitedPaths = emptyList(),
            )
        }
        visited = 1
        paths.add(emptyList())
        if (depthLimit == 0 && rootVisit.childCount > 0) depthLimited = true

        var current = ArrayList<LevelEntry>(4)
        if (depthLimit > 0 && rootVisit.childCount > 0) {
            current += LevelEntry(
                path = emptyList(),
                childCount = rootVisit.childCount,
                insideScrollable = false,
                scrollable = rootVisit.scrollable,
            )
        }

        val cursor = PathCursor(root, adapter)
        try {
            var depth = 0
            while (current.isNotEmpty() && depth < depthLimit) {
                if (stop() || timedOut || scanLimited) break
                val next = ArrayList<LevelEntry>(minOf(current.size * 2, nodeLimit))
                for (entry in current) {
                    if (stop() || timedOut || scanLimited) break
                    if (cancelIfNeeded() || timeExceeded()) break
                    if (visited >= nodeLimit) {
                        // Every enqueued entry has at least one child, so the
                        // node budget has real pending work behind it.
                        scanLimited = true
                        break
                    }
                    val parent = cursor.resolve(entry.path)
                    if (parent == null) {
                        // A path that no longer resolves means the source tree
                        // changed. This is an unavailable capture, not a partial
                        // observation of a stale page.
                        obsolete = true
                        break
                    }
                    for (index in 0 until entry.childCount) {
                        if (stop() || timedOut || scanLimited) break
                        if (cancelIfNeeded() || timeExceeded()) break
                        val child = adapter.child(parent, index) ?: continue
                        try {
                            if (visited >= nodeLimit) {
                                scanLimited = true
                                break
                            }
                            val childPath = entry.path + index
                            val inside = entry.insideScrollable || entry.scrollable
                            val childVisit = visit(childPath, depth + 1, child, inside)
                            when (childVisit.state) {
                                VisitState.OBSOLETE -> {
                                    obsolete = true
                                    break
                                }
                                VisitState.CANCELLED -> {
                                    cancelled = true
                                    break
                                }
                                VisitState.CONTINUE -> Unit
                            }
                            visited += 1
                            paths += childPath
                            if (depth + 1 >= depthLimit && childVisit.childCount > 0) {
                                depthLimited = true
                            } else if (childVisit.childCount > 0) {
                                next += LevelEntry(
                                    path = childPath,
                                    childCount = childVisit.childCount,
                                    insideScrollable = inside,
                                    scrollable = childVisit.scrollable,
                                )
                            }
                        } finally {
                            adapter.recycle(child)
                        }
                    }
                }
                if (stop() || timedOut || scanLimited) break
                current = next
                depth += 1
            }
        } finally {
            cursor.close()
        }

        return Result(
            visitedNodeCount = visited,
            depthLimited = depthLimited,
            scanLimited = scanLimited,
            timedOut = timedOut,
            obsolete = obsolete,
            cancelled = cancelled,
            visitedPaths = paths,
        )
    }

    /**
     * Resolves one real path at a time while reusing the longest shared prefix
     * with the previous path. Level-order paths are generated in lexicographic
     * order, so the cursor opens each non-root node roughly once instead of
     * re-descending from the root for every entry.
     */
    private class PathCursor<T>(
        private val root: T,
        private val adapter: PhoneControlCaptureTreeAdapter<T>,
    ) {
        private val indices = ArrayList<Int>()
        private val handles = ArrayList<T>()

        fun resolve(path: List<Int>): T? {
            var common = 0
            val limit = minOf(indices.size, path.size)
            while (common < limit && indices[common] == path[common]) common++
            while (indices.size > common) {
                adapter.recycle(handles.removeAt(handles.size - 1))
                indices.removeAt(indices.size - 1)
            }
            var node = handles.lastOrNull() ?: root
            while (indices.size < path.size) {
                val index = path[indices.size]
                val child = adapter.child(node, index)
                if (child == null) {
                    close()
                    return null
                }
                indices += index
                handles += child
                node = child
            }
            return node
        }

        fun close() {
            while (handles.isNotEmpty()) {
                adapter.recycle(handles.removeAt(handles.size - 1))
            }
            indices.clear()
        }
    }
}
