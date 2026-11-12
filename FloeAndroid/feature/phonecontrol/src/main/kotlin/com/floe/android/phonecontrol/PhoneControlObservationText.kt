// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** Model-facing projection of an already authorized capture; grants nothing. */
object PhoneControlObservationText {
    // Leaves room for device.act's action header inside the 2048 transport cap.
    private const val MAX_SUMMARY_CHARS = 1_800
    /** Reserve for the compact overflow index when many controls exist. */
    private const val OVERFLOW_RESERVE_CHARS = 300

    fun summary(observation: PhoneControlObservation, maxNodes: Int = 24): String {
        val out = StringBuilder(2_000)
        out.append("observation=").append(observation.observationId)
        out.append(" page=").append(observation.packageName ?: "unknown")
        observation.windowTitle?.take(48)?.let { out.append(" title=").append(it) }
        out.append(" window=").append(observation.windowId)
        out.append(" display=").append(observation.displayId)
        out.append(" nodes=").append(observation.nodes.size)
        if (observation.scannedNodeCount > observation.nodes.size) {
            out.append('/').append(observation.scannedNodeCount)
        }
        out.append(" actions=").append(observation.nodes.count { node ->
            node.visible && node.enabled &&
                (node.clickable || node.editable || node.scrollable)
        })
        if (observation.navigationOnly) {
            return out.append(" navigationOnly\nProtected Floe page; navigation-only (back, home, or launch an allowed app).")
                .toString()
        }
        if (observation.truncated) out.append(" truncated")
        out.append(
            "\nflags: c=click e=setText s=scroll p=protected input " +
                "(fill with setText sensitiveText) -=read-only h=hidden d=disabled",
        )
        if (observation.scannedNodeCount > observation.nodes.size ||
            observation.omittedActionableCount > 0
        ) {
            out.append("\nscan: captured=").append(observation.nodes.size)
            out.append('/').append(observation.scannedNodeCount)
            out.append(" visible=").append(observation.nodes.count { it.visible })
            if (observation.omittedActionableCount > 0) {
                out.append(" omittedActions=").append(observation.omittedActionableCount)
            }
        }

        val byRef = observation.nodes.associateBy { it.ref }
        fun actionable(node: PhoneControlNode) = node.visible && node.enabled &&
            !node.password && !node.redacted && (node.clickable || node.editable || node.scrollable)
        fun directAction(node: PhoneControlNode) = node.visible && node.enabled &&
            !node.password && !node.redacted && (node.clickable || node.editable)
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

        // Fixed-screen chrome (a toolbar action or FAB outside a scrollable
        // container) keeps its full row ahead of content that is only
        // reachable by scrolling. Editable/protected fields stay first.
        val ranked = observation.nodes.sortedWith(
            compareBy<PhoneControlNode> {
                when {
                    protectedEditable(it) -> 0
                    actionable(it) && it.editable -> 0
                    directAction(it) && !it.insideScrollable -> 1
                    directAction(it) -> 2
                    actionable(it) && !it.insideScrollable -> 3
                    actionable(it) -> 4
                    else -> 5
                }
            }.thenBy { it.ref.removePrefix("n").toIntOrNull() ?: Int.MAX_VALUE },
        )
        val actionableTotal = ranked.count { actionable(it) }
        val rowLimit = MAX_SUMMARY_CHARS - when {
            actionableTotal > 18 -> OVERFLOW_RESERVE_CHARS
            actionableTotal > 0 -> 120
            else -> 0
        }
        val shown = HashSet<String>()
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
            if (out.length + line.length > rowLimit) break
            out.append(line)
            shown += node.ref
            if (++count >= maxNodes.coerceIn(1, 40)) break
        }
        // Late actionable controls must stay discoverable even when the full
        // rows are exhausted: an actual ref is still usable by device.act.
        appendOverflow(ranked, shown, out)
        if (count == 0) out.append("\nNo actionable or labeled nodes on this page.")
        return out.toString()
    }

    private fun appendOverflow(
        ranked: List<PhoneControlNode>,
        shown: Set<String>,
        out: StringBuilder,
    ) {
        val remaining = ranked.filter {
            it.visible && it.enabled && !it.password && !it.redacted &&
                (it.clickable || it.editable || it.scrollable) && it.ref !in shown
        }
        if (remaining.isEmpty()) return
        val prefix = "\nmoreActions(c=click e=input s=scroll): "
        var listed = 0
        val body = StringBuilder()
        for (node in remaining) {
            val label = (
                node.text ?: node.contentDescription ?: node.hintText
                    ?: node.viewId?.substringAfterLast('/')
                    ?: if (node.editable) "[input]" else "[action]"
                ).replace('\n', ' ').replace('\r', ' ').take(18)
            val marker = when {
                node.editable -> "e"
                node.clickable -> "c"
                else -> "s"
            }
            // Same ref|flags|label shape as a full row, so the model never
            // mistakes the compact flag for part of the ref.
            val entry = "${node.ref}|$marker|$label"
            val separator = if (listed == 0) 0 else 1
            // Reserve room for a trailing " +N" without cutting an entry.
            if (out.length + prefix.length + body.length + entry.length + separator + 8 >
                MAX_SUMMARY_CHARS
            ) break
            if (listed > 0) body.append(',')
            body.append(entry)
            listed += 1
        }
        if (listed == 0) return
        out.append(prefix).append(body)
        val hidden = remaining.size - listed
        if (hidden > 0) out.append(" +").append(hidden)
    }
}
