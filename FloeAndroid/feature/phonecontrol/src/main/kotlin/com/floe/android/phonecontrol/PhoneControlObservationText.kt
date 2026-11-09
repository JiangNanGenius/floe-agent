// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** Model-facing projection of an already authorized capture; grants nothing. */
object PhoneControlObservationText {
    fun summary(observation: PhoneControlObservation, maxNodes: Int = 24): String {
        val out = StringBuilder(2_000)
        out.append("observation=").append(observation.observationId)
        out.append(" page=").append(observation.packageName ?: "unknown")
        observation.windowTitle?.take(48)?.let { out.append(" title=").append(it) }
        out.append(" nodes=").append(observation.nodes.size)
        if (observation.navigationOnly) {
            return out.append(" navigationOnly\nProtected Floe page; navigation-only (back, home, or launch an allowed app).")
                .toString()
        }
        if (observation.truncated) out.append(" truncated")
        out.append(
            "\nflags: c=click e=setText s=scroll p=protected input " +
                "(fill with setText sensitiveText) -=read-only h=hidden d=disabled",
        )

        val byRef = observation.nodes.associateBy { it.ref }
        fun actionable(node: PhoneControlNode) = node.visible && node.enabled &&
            !node.password && !node.redacted && (node.clickable || node.editable || node.scrollable)
        // Safe structural metadata for a protected field: identity, position
        // and editability may be exposed, never the current contents.
        fun protectedEditable(node: PhoneControlNode) =
            (node.password || node.redacted) && node.visible && node.enabled && node.editable
        fun ownLabel(node: PhoneControlNode): String? =
            if (node.password || node.redacted) null else
                sequenceOf(node.text, node.contentDescription, node.hintText)
                    .filterNotNull().firstOrNull { it.isNotBlank() }

        // A label child is often not clickable itself. Attribute it only to
        // its nearest actionable ancestor, never to an enclosing unrelated
        // button or to another field. Keep the actual parent's ref/flags.
        val childLabels = mutableMapOf<String, String>()
        for (node in observation.nodes) {
            if (!node.visible || actionable(node)) continue
            val label = ownLabel(node) ?: continue
            var parent = node.parentRef
            var depth = 0
            while (parent != null && depth++ < PhoneControlLimits.MAX_DEPTH) {
                val ancestor = byRef[parent] ?: break
                if (actionable(ancestor)) {
                    if (ancestor.clickable && !ancestor.editable && !ancestor.scrollable) {
                        childLabels.putIfAbsent(ancestor.ref, label)
                    }
                    break
                } else parent = ancestor.parentRef
            }
        }

        val ranked = observation.nodes.sortedWith(
            compareBy<PhoneControlNode> {
                when {
                    protectedEditable(it) -> 0
                    actionable(it) && it.editable -> 0
                    actionable(it) -> 1
                    else -> 2
                }
            }.thenBy { it.ref.removePrefix("n").toIntOrNull() ?: Int.MAX_VALUE },
        )
        var count = 0
        for (node in ranked) {
            val label = when {
                node.password || node.redacted -> "[protected]"
                else -> ownLabel(node) ?: childLabels[node.ref] ?: node.viewId?.takeIf { it.isNotBlank() } ?: when {
                    actionable(node) && node.editable -> "[empty input]"
                    actionable(node) && node.clickable -> "[button]"
                    actionable(node) && node.scrollable -> "[scroll area]"
                    else -> null
                }
            } ?: continue
            val flags = buildString {
                if (!node.visible) append('h')
                if (!node.enabled) append('d')
                if (node.password || node.redacted) {
                    append('p')
                    if (protectedEditable(node)) append('e')
                } else if (actionable(node)) {
                    if (node.clickable) append('c')
                    if (node.editable) append('e')
                    if (node.scrollable) append('s')
                }
                if (isEmpty()) append('-')
            }
            val line = "\n${node.ref}|${node.className.substringAfterLast('.').take(24)}|$flags|" +
                label.replace('\n', ' ').replace('\r', ' ').take(56)
            // Leave room for the existing action-result header. Whole rows
            // stay within the platform summary budget; no partial ref/flag.
            if (out.length + line.length > 1_850) break
            out.append(line)
            if (++count >= maxNodes.coerceIn(1, 40)) break
        }
        if (count == 0) out.append("\nNo actionable or labeled nodes on this page.")
        return out.toString()
    }
}
