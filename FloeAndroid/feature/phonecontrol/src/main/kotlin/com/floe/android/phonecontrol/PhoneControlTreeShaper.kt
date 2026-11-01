// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** One platform node already read into primitives, never a live node handle. */
internal data class PhoneControlRawNode(
    val path: List<Int>,
    val parentPath: List<Int>?,
    val depth: Int,
    val className: String,
    val packageName: String?,
    val viewId: String?,
    val text: String?,
    val contentDescription: String?,
    val hintText: String?,
    val bounds: PhoneControlBounds,
    val visible: Boolean,
    val clickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val enabled: Boolean,
    val selected: Boolean,
    val checkable: Boolean,
    val checked: Boolean,
    val password: Boolean,
)

/** Locator retained for a returned ref; resolved again against a fresh tree. */
internal data class PhoneControlNodeRecord(
    val ref: String,
    val path: List<Int>,
    val className: String,
    val packageName: String?,
    val viewId: String?,
    val bounds: PhoneControlBounds,
    val password: Boolean,
    val redacted: Boolean,
    val clickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
)

internal data class PhoneControlShaped(
    val nodes: List<PhoneControlNode>,
    val records: Map<String, PhoneControlNodeRecord>,
    val truncated: Boolean,
    val maxDepthReached: Boolean,
    val sensitiveWindow: Boolean,
    val fingerprint: Long,
    val textChars: Int,
)

/**
 * Pure shaper: applies visibility, depth, node-count, per-field and total-text
 * caps, redacts password/sensitive fields, reparents included nodes across
 * omitted invisible ancestors, and computes a screen fingerprint. The real
 * path of every returned node is retained in [PhoneControlNodeRecord] so an
 * action can re-resolve that exact node in a fresh tree.
 */
internal object PhoneControlTreeShaper {
    private const val FNV_OFFSET = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    private const val FNV_PRIME = 0x100000001b3L

    fun shape(
        raw: List<PhoneControlRawNode>,
        request: PhoneControlObserveRequest,
        redactAllText: Boolean,
        depthLimited: Boolean,
        nodeLimited: Boolean,
    ): PhoneControlShaped {
        val req = request.normalized()
        val budget = PhoneControlTextBudget(req.textBudgetChars)
        val nodes = ArrayList<PhoneControlNode>(minOf(raw.size, req.maxNodes))
        val records = LinkedHashMap<String, PhoneControlNodeRecord>(minOf(raw.size, req.maxNodes))
        val refByPath = HashMap<List<Int>, String>()
        var anySensitive = redactAllText
        var textTruncated = false

        for (rawNode in raw) {
            if (rawNode.depth > req.maxDepth) continue
            if (nodes.size >= req.maxNodes) break
            if (!req.includeInvisible && !rawNode.visible) continue

            val redacted = redactAllText || rawNode.password ||
                PhoneControlText.isSensitiveViewId(rawNode.viewId)
            if (redacted) anySensitive = true
            val sensitiveField = rawNode.password || redacted

            val textBound = if (sensitiveField) PhoneControlText.Bound(null, false)
            else budget.take(rawNode.text)
            val descriptionBound = if (sensitiveField) PhoneControlText.Bound(null, false)
            else budget.take(rawNode.contentDescription)
            val hintBound = if (sensitiveField) PhoneControlText.Bound(null, false)
            else budget.take(rawNode.hintText)
            val fieldTruncated =
                textBound.truncated || descriptionBound.truncated || hintBound.truncated
            if (budget.truncated) textTruncated = true

            val parentRef = rawNode.path.indices.reversed()
                .asSequence()
                .mapNotNull { cut -> refByPath[rawNode.path.take(cut)] }
                .firstOrNull()
            val ref = "n${nodes.size}"
            val className = PhoneControlText.bound(
                PhoneControlText.clean(rawNode.className) ?: "",
                200,
            ).text ?: ""
            val packageName = PhoneControlText.bound(
                PhoneControlText.clean(rawNode.packageName),
                PhoneControlLimits.MAX_PACKAGE_CHARS,
            ).text
            val viewId = PhoneControlText.bound(PhoneControlText.clean(rawNode.viewId), 255).text

            nodes += PhoneControlNode(
                ref = ref,
                parentRef = parentRef,
                depth = rawNode.depth,
                className = className,
                packageName = packageName,
                viewId = viewId,
                text = textBound.text,
                contentDescription = descriptionBound.text,
                hintText = hintBound.text,
                bounds = rawNode.bounds,
                visible = rawNode.visible,
                clickable = rawNode.clickable,
                editable = rawNode.editable,
                scrollable = rawNode.scrollable,
                enabled = rawNode.enabled,
                selected = rawNode.selected,
                checkable = rawNode.checkable,
                checked = rawNode.checked,
                password = rawNode.password,
                redacted = redacted,
                truncated = fieldTruncated || (budget.truncated && !sensitiveField),
            )
            records[ref] = PhoneControlNodeRecord(
                ref = ref,
                path = rawNode.path.toList(),
                className = className,
                packageName = packageName,
                viewId = viewId,
                bounds = rawNode.bounds,
                password = rawNode.password,
                redacted = redacted,
                clickable = rawNode.clickable,
                editable = rawNode.editable,
                scrollable = rawNode.scrollable,
            )
            refByPath[rawNode.path] = ref
        }

        val truncated = nodeLimited || depthLimited || textTruncated || budget.truncated
        return PhoneControlShaped(
            nodes = nodes,
            records = records,
            truncated = truncated,
            maxDepthReached = depthLimited,
            sensitiveWindow = anySensitive,
            fingerprint = fingerprint(nodes),
            textChars = budget.spent,
        )
    }

    private fun fingerprint(nodes: List<PhoneControlNode>): Long {
        var hash = FNV_OFFSET
        fun mix(value: String?) {
            if (value == null) {
                hash = (hash xor 0xffL) * FNV_PRIME
                return
            }
            for (ch in value) {
                hash = (hash xor ch.code.toLong()) * FNV_PRIME
            }
            hash = (hash xor 0xfeL) * FNV_PRIME
        }
        for (node in nodes) {
            mix(node.className)
            mix(node.packageName)
            mix(node.viewId)
            mix(node.text)
            mix(node.contentDescription)
            mix(node.hintText)
            hash = (hash xor node.bounds.left.toLong()) * FNV_PRIME
            hash = (hash xor node.bounds.top.toLong()) * FNV_PRIME
            hash = (hash xor node.bounds.right.toLong()) * FNV_PRIME
            hash = (hash xor node.bounds.bottom.toLong()) * FNV_PRIME
            var flags = 0
            if (node.visible) flags = flags or 1
            if (node.clickable) flags = flags or 2
            if (node.editable) flags = flags or 4
            if (node.scrollable) flags = flags or 8
            if (node.enabled) flags = flags or 16
            if (node.selected) flags = flags or 32
            if (node.checked) flags = flags or 64
            if (node.password) flags = flags or 128
            hash = (hash xor flags.toLong()) * FNV_PRIME
        }
        return hash
    }
}
