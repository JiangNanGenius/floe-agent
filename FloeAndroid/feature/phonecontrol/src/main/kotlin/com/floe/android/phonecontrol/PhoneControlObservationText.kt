// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** Model-facing projection of an already authorized capture; grants nothing. */
object PhoneControlObservationText {
    // Leaves room for device.act's action header inside the 2048 transport cap.
    private const val MAX_SUMMARY_CHARS = 1_800
    /** Reserve for the compact overflow index when many controls exist. */
    private const val OVERFLOW_RESERVE_CHARS = 300
    /** Reserve for the honest "bounded, not absent" footer. */
    private const val FOOTER_RESERVE_CHARS = 110
    private const val MAX_OWN_LABEL_CHARS = 56
    private const val MAX_ROW_LABEL_CHARS = 72
    private const val MAX_FIELD_HINT_CHARS = 24
    private const val MAX_CHILD_LABEL_HOPS = 4

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
        fun isProtected(node: PhoneControlNode) = node.password || node.redacted
        fun actionable(node: PhoneControlNode) = node.visible && node.enabled &&
            !isProtected(node) && (node.clickable || node.editable || node.scrollable)
        // Safe structural metadata for a protected field: identity, position
        // and editability may be exposed, never the current contents.
        fun protectedEditable(node: PhoneControlNode) =
            isProtected(node) && node.visible && node.enabled && node.editable
        fun ownLabel(node: PhoneControlNode): String? =
            if (isProtected(node)) null else
                sequenceOf(node.text, node.contentDescription, node.hintText)
                    .filterNotNull().firstOrNull { it.isNotBlank() }
                    ?.replace('\n', ' ')?.replace('\r', ' ')?.replace('|', '/')
                    ?.trim()?.take(MAX_OWN_LABEL_CHARS)?.takeIf { it.isNotBlank() }

        // A label child is often not clickable itself. Attribute it only to
        // its nearest actionable ancestor, never to an enclosing unrelated
        // button or to another field. Keep the actual parent's ref/flags.
        val childLabels = mutableMapOf<String, String>()
        for (node in observation.nodes) {
            if (!node.visible || actionable(node)) continue
            val label = ownLabel(node) ?: continue
            var parent = node.parentRef
            var depth = 0
            while (parent != null && depth++ < MAX_CHILD_LABEL_HOPS) {
                val ancestor = byRef[parent] ?: break
                if (actionable(ancestor)) {
                    if (ancestor.clickable && !ancestor.editable && !ancestor.scrollable) {
                        childLabels.putIfAbsent(ancestor.ref, label)
                    }
                    break
                } else parent = ancestor.parentRef
            }
        }

        fun meaningfulLabel(node: PhoneControlNode): String? =
            if (isProtected(node)) null else ownLabel(node) ?: childLabels[node.ref]

        fun placeholder(node: PhoneControlNode): String? = when {
            node.visible && node.enabled && node.editable -> "[empty input]"
            node.visible && node.enabled && node.clickable -> "[button]"
            node.visible && node.enabled && node.scrollable -> "[scroll area]"
            else -> null
        }

        fun displayLabel(node: PhoneControlNode): String? =
            if (isProtected(node)) "[protected]"
            else meaningfulLabel(node) ?: placeholder(node)

        // A real field id is useful only to distinguish otherwise identical
        // labels (for example two equal date values). It never replaces a
        // meaningful text label and never adds a flag or a capability.
        val labelCounts = HashMap<String, Int>()
        for (node in observation.nodes) {
            if (!node.visible) continue
            val label = meaningfulLabel(node) ?: continue
            labelCounts[label] = (labelCounts[label] ?: 0) + 1
        }

        fun fieldHint(viewId: String?): String? {
            val raw = viewId?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: return null
            val clean = raw.map { ch ->
                if (ch.isLetterOrDigit() || ch == '_' || ch == '-' || ch == '.') ch else '_'
            }.joinToString("").trim('_').take(MAX_FIELD_HINT_CHARS)
            return clean.takeIf { it.isNotBlank() }
        }

        fun rowHint(node: PhoneControlNode): String? {
            if (isProtected(node)) return null
            val meaningful = meaningfulLabel(node) ?: return null
            if ((labelCounts[meaningful] ?: 0) <= 1) return null
            return fieldHint(node.viewId)
        }

        fun rowLabel(node: PhoneControlNode): String? {
            val base = displayLabel(node) ?: return null
            if (isProtected(node)) return base
            val hint = rowHint(node) ?: return base
            val suffix = " ($hint)"
            if (base.endsWith(suffix)) return base
            val keep = (MAX_ROW_LABEL_CHARS - suffix.length).coerceAtLeast(1)
            return base.take(keep) + suffix
        }

        // Meaningful direct controls first, then unlabelled chrome, then
        // nearby text. Read-only nodes with no label at all (generic container
        // ids) are omitted instead of crowding the transport.
        fun priority(node: PhoneControlNode): Int {
            val protected = isProtected(node)
            val visibleEnabled = node.visible && node.enabled
            val meaningful = meaningfulLabel(node) != null
            val direct = visibleEnabled && !protected && (node.clickable || node.editable)
            val scroll = visibleEnabled && !protected && node.scrollable
            return when {
                visibleEnabled && node.editable -> 0
                protected -> 1
                direct && meaningful -> if (!node.insideScrollable) 2 else 3
                direct -> if (!node.insideScrollable) 4 else 5
                scroll && meaningful -> if (!node.insideScrollable) 6 else 7
                scroll -> if (!node.insideScrollable) 8 else 9
                meaningful -> if (!node.insideScrollable) 10 else 11
                else -> Int.MAX_VALUE
            }
        }

        val ranked = observation.nodes
            .filter { priority(it) != Int.MAX_VALUE && rowLabel(it) != null }
            .sortedWith(
                compareBy<PhoneControlNode> { priority(it) }
                    .thenBy { it.ref.removePrefix("n").toIntOrNull() ?: Int.MAX_VALUE },
            )
        val labels = LinkedHashMap<String, String>(ranked.size)
        val hints = HashMap<String, String>(ranked.size)
        for (node in ranked) {
            val label = rowLabel(node) ?: continue
            labels[node.ref] = label
            rowHint(node)?.let { hints[node.ref] = it }
        }
        val actionableTotal = ranked.count { actionable(it) }
        val bodyLimit = MAX_SUMMARY_CHARS - FOOTER_RESERVE_CHARS
        val rowLimit = bodyLimit - when {
            actionableTotal > 18 -> OVERFLOW_RESERVE_CHARS
            actionableTotal > 0 -> 120
            else -> 0
        }
        val shown = HashSet<String>()
        var count = 0
        for (node in ranked) {
            val label = labels[node.ref] ?: continue
            val flags = buildString {
                if (!node.visible) append('h')
                if (!node.enabled) append('d')
                if (isProtected(node)) {
                    append('p')
                    if (protectedEditable(node)) append('e')
                } else if (actionable(node)) {
                    if (node.clickable) append('c')
                    if (node.editable) append('e')
                    if (node.scrollable) append('s')
                }
                if (isEmpty()) append('-')
            }
            val line = "\n${node.ref}|${node.className.substringAfterLast('.').take(24)}|$flags|$label"
            // Leave room for the existing action-result header. Whole rows
            // stay within the platform summary budget; no partial ref/flag.
            if (out.length + line.length > rowLimit) break
            out.append(line)
            shown += node.ref
            if (++count >= maxNodes.coerceIn(1, 40)) break
        }
        // Late actionable controls must stay discoverable even when the full
        // rows are exhausted: an actual ref is still usable by device.act.
        appendOverflow(ranked, labels, hints, shown, out, bodyLimit)
        if (count == 0) {
            if (observation.nodes.isEmpty()) {
                out.append("\nNo actionable or labeled nodes on this page.")
            } else {
                out.append("\nNo actionable or labeled nodes fit this bounded summary.")
            }
        }
        if (shown.size < observation.nodes.size) {
            // The observation may be complete even when its bounded model
            // projection is not; do not imply that omitted rows are absent
            // platform capability.
            out.append("\nsummary=").append(shown.size).append('/')
                .append(observation.nodes.size)
                .append(" rows (bounded; omitted rows are not absent controls)")
        }
        return out.toString()
    }

    private fun appendOverflow(
        ranked: List<PhoneControlNode>,
        labels: Map<String, String>,
        hints: Map<String, String>,
        shown: Set<String>,
        out: StringBuilder,
        limit: Int,
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
            val full = labels[node.ref] ?: continue
            val hint = hints[node.ref]
            val label = if (hint == null) {
                full.replace('\n', ' ').replace('\r', ' ').take(18)
            } else {
                // Put the distinguishing field id first so equal values stay
                // distinguishable even in the compact overflow index.
                (hint.take(16) + ":" + full.removeSuffix(" ($hint)"))
                    .replace('\n', ' ').replace('\r', ' ').take(26)
            }
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
                limit
            ) {
                break
            }
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
