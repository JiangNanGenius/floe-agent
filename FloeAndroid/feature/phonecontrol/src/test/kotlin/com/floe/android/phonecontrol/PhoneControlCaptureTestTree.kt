// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * In-memory capture tree for exercising the real bounded traversal strategy.
 * It intentionally mirrors only the platform handle operations the walker
 * uses: child acquisition, child count/scrollable facts read by the visitor,
 * and recycling.
 */
internal class TestCaptureNode(
    val className: String = "android.widget.FrameLayout",
    val viewId: String? = null,
    val text: String? = null,
    val contentDescription: String? = null,
    val hintText: String? = null,
    val clickable: Boolean = false,
    val editable: Boolean = false,
    val scrollable: Boolean = false,
    val visible: Boolean = true,
    val enabled: Boolean = true,
    val password: Boolean = false,
    val children: MutableList<TestCaptureNode> = mutableListOf(),
)

internal fun testCaptureNode(
    className: String = "android.widget.FrameLayout",
    viewId: String? = null,
    text: String? = null,
    contentDescription: String? = null,
    hintText: String? = null,
    clickable: Boolean = false,
    editable: Boolean = false,
    scrollable: Boolean = false,
    visible: Boolean = true,
    enabled: Boolean = true,
    password: Boolean = false,
    children: List<TestCaptureNode> = emptyList(),
): TestCaptureNode = TestCaptureNode(
    className = className,
    viewId = viewId,
    text = text,
    contentDescription = contentDescription,
    hintText = hintText,
    clickable = clickable,
    editable = editable,
    scrollable = scrollable,
    visible = visible,
    enabled = enabled,
    password = password,
    children = children.toMutableList(),
)

/** Wraps [inner] in [depth] single-child containers. */
internal fun testWrap(depth: Int, inner: TestCaptureNode): TestCaptureNode {
    var node = inner
    repeat(depth) { node = testCaptureNode(children = listOf(node)) }
    return node
}

internal fun testCapturePaths(root: TestCaptureNode): Set<List<Int>> {
    val out = HashSet<List<Int>>()
    fun walk(node: TestCaptureNode, path: List<Int>) {
        out += path
        node.children.forEachIndexed { index, child -> walk(child, path + index) }
    }
    walk(root, emptyList())
    return out
}

internal fun testMaxDepth(root: TestCaptureNode): Int {
    fun depth(node: TestCaptureNode): Int =
        1 + (node.children.maxOfOrNull { depth(it) } ?: 0)
    return depth(root) - 1
}

internal class TestCaptureAdapter : PhoneControlCaptureTreeAdapter<TestCaptureNode> {
    var open = 0
        private set
    var peak = 0
        private set
    var acquired = 0
        private set
    var recycled = 0
        private set

    override fun child(node: TestCaptureNode, index: Int): TestCaptureNode? {
        val child = node.children.getOrNull(index) ?: return null
        open += 1
        acquired += 1
        if (open > peak) peak = open
        return child
    }

    override fun recycle(node: TestCaptureNode) {
        open -= 1
        recycled += 1
    }
}

internal class TestCaptureCollector {
    val raw = ArrayList<PhoneControlRawNode>()
    var obsoleteAt: List<Int>? = null
    var onVisit: ((List<Int>) -> Unit)? = null

    fun visit(
        path: List<Int>,
        depth: Int,
        node: TestCaptureNode,
        insideScrollable: Boolean,
    ): PhoneControlCaptureWalk.Visit {
        onVisit?.invoke(path)
        if (obsoleteAt == path) {
            return PhoneControlCaptureWalk.Visit(
                state = PhoneControlCaptureWalk.VisitState.OBSOLETE,
            )
        }
        val redact = node.password
        raw += PhoneControlRawNode(
            path = path.toList(),
            parentPath = if (path.isEmpty()) null else path.dropLast(1),
            depth = depth,
            className = node.className,
            packageName = "com.example.app",
            viewId = node.viewId,
            text = if (redact) null else node.text,
            contentDescription = if (redact) null else node.contentDescription,
            hintText = if (redact) null else node.hintText,
            bounds = PhoneControlBounds(0, 0, 100, 50),
            visible = node.visible,
            clickable = node.clickable,
            editable = node.editable,
            scrollable = node.scrollable,
            enabled = node.enabled,
            selected = false,
            checkable = false,
            checked = false,
            password = node.password,
            insideScrollable = insideScrollable,
        )
        return PhoneControlCaptureWalk.Visit(
            childCount = node.children.size,
            scrollable = node.scrollable,
        )
    }
}
