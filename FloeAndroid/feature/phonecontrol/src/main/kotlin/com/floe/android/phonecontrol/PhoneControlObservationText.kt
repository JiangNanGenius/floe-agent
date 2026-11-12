// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Model-facing projection of an already authorized capture; grants nothing.
 *
 * Two bounded views of the SAME captured observation exist:
 *  - [summary] is the compact, actionable-first digest returned by the first
 *    `device.observe` call;
 *  - [detail] pages the retained node list by `offset` so a model can read the
 *    rest of the captured tree without a new screen read. Neither view ever
 *    calls a screen capture, extends the observation TTL or changes refs.
 */
object PhoneControlObservationText {
    // Leaves room for device.act's action header inside the 2048 transport cap.
    private const val MAX_SUMMARY_CHARS = 1_800
    /** Reserve for the compact overflow index when many controls exist. */
    private const val OVERFLOW_RESERVE_CHARS = 300
    /** Reserve for the honest "bounded, not absent" footer + paging hint. */
    private const val FOOTER_RESERVE_CHARS = 170
    /** Reserve for a detail page's nextOffset/source footer. */
    private const val DETAIL_FOOTER_RESERVE_CHARS = 200
    private const val MAX_ROW_LABEL_CHARS = 72
    private const val MAX_SECONDARY_LABEL_CHARS = 28
    private const val MAX_FIELD_HINT_CHARS = 24
    private const val MAX_CHILD_LABEL_HOPS = 4
    private const val MAX_DETAIL_TEXT_CHARS = 48
    private const val MAX_DETAIL_HINT_CHARS = 40
    private const val MAX_DETAIL_ROW_LABEL_CHARS = 36

    private enum class LabelKind { TEXT, DESCRIPTION, HINT }

    private data class LabelPart(val value: String, val kind: LabelKind)

    fun summary(observation: PhoneControlObservation, maxNodes: Int = 24): String {
        val out = StringBuilder(2_000)
        out.append("observation=").append(observation.observationId)
        out.append(" page=").append(observation.packageName ?: "unknown")
        observation.windowTitle?.replace('\n', ' ')?.replace('\r', ' ')?.take(48)?.let { out.append(" title=").append(it) }
        out.append(" window=").append(observation.windowId)
        out.append(" display=").append(observation.displayId)
        out.append(" nodes=").append(observation.nodes.size)
        if (observation.scannedNodeCount > observation.nodes.size) {
            out.append('/').append(observation.scannedNodeCount)
        }
        out.append(" actions=").append(observation.nodes.count { node ->
            node.visible && node.enabled &&
                (isClickable(node) || node.editable || isScrollable(node))
        })
        if (observation.navigationOnly) {
            return out.append(" navigationOnly\nProtected Floe page; navigation-only (back, home, or launch an allowed app).")
                .toString()
        }
        if (observation.truncated) {
            out.append(" truncated")
            val reasons = observation.truncationReasons
            if (reasons.isNotEmpty()) out.append('=').append(reasons.joinToString(","))
        }
        out.append(
            "\nflags: c=click e=setText s=scroll f=focus F=focused i=IME " +
                "p=protected input (fill with setText sensitiveText) -=read-only " +
                "h=hidden d=disabled",
        )
        val reasons = observation.truncationReasons
        if (observation.scannedNodeCount > observation.nodes.size ||
            observation.omittedActionableCount > 0 ||
            reasons.isNotEmpty()
        ) {
            out.append("\nscan: captured=").append(observation.nodes.size)
            out.append('/').append(observation.scannedNodeCount)
            out.append(" visible=").append(observation.nodes.count { it.visible })
            if (observation.omittedActionableCount > 0) {
                out.append(" omittedActions=").append(observation.omittedActionableCount)
            }
            if (reasons.isNotEmpty()) out.append(" reasons=").append(reasons.joinToString(","))
        }

        val byRef = observation.nodes.associateBy { it.ref }
        fun isProtected(node: PhoneControlNode) = protectedNode(node)
        fun actionable(node: PhoneControlNode) = actionableNode(node)
        fun ownLabel(node: PhoneControlNode): String? =
            if (isProtected(node)) null else ownLabels(node).firstOrNull()?.value

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
                    if (isClickOnly(ancestor)) {
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
            node.visible && node.enabled && isClickable(node) -> "[button]"
            node.visible && node.enabled && isScrollable(node) -> "[scroll area]"
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

        // Distinct, non-redundant secondary metadata. A real month header can
        // carry a mode-switch hint while its text is the visible month/year;
        // taking only the first field hid that actionable hint. Hints are
        // always kept; a differing description is kept only where it clarifies
        // an input/option, so decorative button descriptions do not crowd the
        // bounded digest.
        fun secondaryLabel(node: PhoneControlNode): LabelPart? {
            if (isProtected(node)) return null
            val labels = ownLabels(node)
            if (labels.size < 2) return null
            val second = labels[1]
            val relevant = second.kind == LabelKind.HINT || node.editable ||
                node.selected || node.checkable
            if (!relevant) return null
            val value = second.value.take(MAX_SECONDARY_LABEL_CHARS).trim()
            return value.takeIf { it.isNotBlank() }?.let { LabelPart(it, second.kind) }
        }

        fun rowLabel(node: PhoneControlNode): String? {
            val base = displayLabel(node) ?: return null
            if (isProtected(node)) return base
            var label = base.take(MAX_ROW_LABEL_CHARS)
            rowHint(node)?.let { hint ->
                val suffix = " ($hint)"
                if (!label.endsWith(suffix)) {
                    val keep = (MAX_ROW_LABEL_CHARS - suffix.length).coerceAtLeast(1)
                    label = label.take(keep) + suffix
                }
            }
            secondaryLabel(node)?.let { secondary ->
                val marker = when (secondary.kind) {
                    LabelKind.HINT -> "hint"
                    LabelKind.DESCRIPTION -> "desc"
                    LabelKind.TEXT -> "value"
                }
                val suffix = " [$marker:${secondary.value}]"
                if (!label.contains(suffix)) {
                    val keep = (MAX_ROW_LABEL_CHARS - suffix.length).coerceAtLeast(1)
                    label = label.take(keep) + suffix
                }
            }
            return label
        }

        // Meaningful direct controls first, then unlabelled chrome, then
        // nearby text. Read-only nodes with no label at all (generic container
        // ids) are omitted instead of crowding the transport.
        fun priority(node: PhoneControlNode): Int {
            val protected = isProtected(node)
            val visibleEnabled = node.visible && node.enabled
            val meaningful = meaningfulLabel(node) != null
            val direct = visibleEnabled && !protected && (isClickable(node) || node.editable)
            val scroll = visibleEnabled && !protected && isScrollable(node)
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
            val flags = summaryFlags(node)
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
                .append(" rows (bounded; omitted rows are not absent controls; ")
                .append("page the captured list with observationId+offset)")
        }
        return out.toString()
    }

    /**
     * One bounded page of the retained node list. [offset] is a node index;
     * the caller pages with the returned [PhoneControlDetailPage.nextOffset].
     * Nothing here performs a capture: the same observation id, TTL, fence and
     * package scope remain authoritative.
     */
    fun detail(observation: PhoneControlObservation, offset: Int): PhoneControlDetailPage {
        val total = observation.nodes.size
        val start = offset.coerceIn(0, total)
        val out = StringBuilder(2_000)
        out.append("observation=").append(observation.observationId)
        out.append(" page=").append(observation.packageName ?: "unknown")
        observation.windowTitle?.replace('\n', ' ')?.replace('\r', ' ')?.take(32)?.let { out.append(" title=").append(it) }
        out.append(" window=").append(observation.windowId)
        out.append(" display=").append(observation.displayId)
        out.append(" total=").append(total)
        out.append(" offset=").append(start)
        if (observation.scannedNodeCount > total) {
            out.append(" scanned=").append(observation.scannedNodeCount)
        }
        if (observation.truncated) {
            out.append(" truncated")
            val reasons = observation.truncationReasons
            if (reasons.isNotEmpty()) out.append('=').append(reasons.joinToString(","))
        }
        if (observation.navigationOnly) {
            out.append("\nProtected Floe page; this observation carries no node detail.")
            return PhoneControlDetailPage(
                observationId = observation.observationId,
                offset = start,
                rows = 0,
                total = total,
                nextOffset = null,
                text = out.toString(),
                expiresAtElapsedRealtimeMillis = observation.expiresAtElapsedRealtimeMillis,
            )
        }
        val byRef = observation.nodes.associateBy { it.ref }
        val children = HashMap<String?, ArrayList<PhoneControlNode>>()
        for (node in observation.nodes) {
            children.getOrPut(node.parentRef) { ArrayList() }.add(node)
        }
        val siblingIndex = HashMap<String, Int>(total)
        for (siblings in children.values) {
            siblings.forEachIndexed { index, node -> siblingIndex[node.ref] = index }
        }
        var end = start
        for (index in start until total) {
            val node = observation.nodes[index]
            val line = detailRow(node, byRef, children, siblingIndex)
            if (out.length + 1 + line.length + DETAIL_FOOTER_RESERVE_CHARS >
                MAX_SUMMARY_CHARS
            ) {
                break
            }
            out.append('\n').append(line)
            end = index + 1
        }
        if (end == start && start < total) {
            // Defensive progress guarantee: even an unexpectedly long first
            // row yields a bounded (possibly shortened) line, so nextOffset
            // always advances and the model cannot loop on the same page.
            val line = detailRow(
                observation.nodes[start], byRef, children, siblingIndex,
            )
            val room = (MAX_SUMMARY_CHARS - out.length -
                DETAIL_FOOTER_RESERVE_CHARS - 1).coerceAtLeast(64)
            val bounded = PhoneControlText.bound(line, room)
            out.append('\n').append(bounded.text ?: line.take(64))
            end = start + 1
        }
        val next = end.takeIf { it < total }
        if (end == start) {
            out.append("\nNo nodes at this offset (total=").append(total).append(").")
        }
        if (next != null) {
            out.append("\nnextOffset=").append(next)
                .append(" (pass it with this observationId)")
        } else {
            out.append("\nlastPage=1")
        }
        val shortenedValue = (start until end).any { index ->
            val node = observation.nodes[index]
            !protectedNode(node) && (
                (node.text?.length ?: 0) > MAX_DETAIL_TEXT_CHARS ||
                    (node.contentDescription?.length ?: 0) > MAX_DETAIL_HINT_CHARS ||
                    (node.hintText?.length ?: 0) > MAX_DETAIL_HINT_CHARS
                )
        }
        if (shortenedValue) {
            out.append("\nnote=values over ").append(MAX_DETAIL_TEXT_CHARS)
                .append(" chars are shortened on this page")
        }
        out.append("\nsource=capturedObservation (not a new screen read)")
        return PhoneControlDetailPage(
            observationId = observation.observationId,
            offset = start,
            rows = end - start,
            total = total,
            nextOffset = next,
            text = out.toString(),
            expiresAtElapsedRealtimeMillis = observation.expiresAtElapsedRealtimeMillis,
        )
    }

    private fun detailRow(
        node: PhoneControlNode,
        byRef: Map<String, PhoneControlNode>,
        children: Map<String?, List<PhoneControlNode>>,
        siblingIndex: Map<String, Int>,
    ): String {
        val protected = protectedNode(node)
        val parts = ArrayList<String>(12)
        parts += node.ref
        parts += node.className.substringAfterLast('.').take(20).ifEmpty { "-" }
        parts += "d=${node.depth}"
        node.parentRef?.let { parts += "p=$it" }
        parts += "f=${detailFlags(node)}"
        if (protected) {
            parts += "fields=protected"
        } else {
            node.viewId?.substringAfterLast('/')?.take(28)?.let { parts += "id=$it" }
            node.text?.let { parts += "text=" + quoted(it, MAX_DETAIL_TEXT_CHARS) }
            node.contentDescription?.let { parts += "desc=" + quoted(it, MAX_DETAIL_HINT_CHARS) }
            node.hintText?.let { parts += "hint=" + quoted(it, MAX_DETAIL_HINT_CHARS) }
            relationLabel(node, byRef, children, siblingIndex)?.let {
                parts += "row=" + quoted(it, MAX_DETAIL_ROW_LABEL_CHARS)
            }
        }
        if (node.selected) parts += "sel=1"
        if (node.checkable) parts += if (node.checked) "chk=on" else "chk=off"
        node.range?.let { parts += "rng=" + formatRange(it) }
        if (node.actions.isNotEmpty()) {
            parts += "act=" + node.actions.joinToString(",") { it.wireName }
        }
        parts += "b=${node.bounds.left},${node.bounds.top}," +
            "${node.bounds.right},${node.bounds.bottom}"
        if (node.truncated) parts += "cut=1"
        return parts.joinToString("|")
    }

    /**
     * Nearest real structural relation for a field: a labelled ancestor, else
     * the immediately preceding direct sibling that carries a label. Both are
     * tree facts, never a class-name or text-similarity guess.
     */
    private fun relationLabel(
        node: PhoneControlNode,
        byRef: Map<String, PhoneControlNode>,
        children: Map<String?, List<PhoneControlNode>>,
        siblingIndex: Map<String, Int>,
    ): String? {
        val own = ownLabels(node).firstOrNull()?.value
        var parent = node.parentRef
        var hops = 0
        while (parent != null && hops < MAX_CHILD_LABEL_HOPS) {
            val ancestor = byRef[parent] ?: break
            val label = ownLabels(ancestor).firstOrNull()?.value
            if (label != null && !label.equals(own, ignoreCase = true)) {
                return label.take(MAX_DETAIL_ROW_LABEL_CHARS)
            }
            parent = ancestor.parentRef
            hops++
        }
        val index = siblingIndex[node.ref] ?: return null
        if (index <= 0) return null
        val previous = children[node.parentRef]?.getOrNull(index - 1) ?: return null
        if (protectedNode(previous)) return null
        // Only a label-like sibling, never a neighbouring control's caption:
        // an actionable preceding button/field is not this field's row label.
        if (previous.visible && previous.enabled &&
            (isClickable(previous) || previous.editable || isScrollable(previous))
        ) {
            return null
        }
        val label = ownLabels(previous).firstOrNull()?.value ?: return null
        if (label.equals(own, ignoreCase = true)) return null
        return label.take(MAX_DETAIL_ROW_LABEL_CHARS)
    }

    private fun summaryFlags(node: PhoneControlNode): String = buildString {
        if (!node.visible) append('h')
        if (!node.enabled) append('d')
        if (protectedNode(node)) {
            append('p')
            if (node.visible && node.enabled && node.editable) append('e')
        } else if (actionableNode(node)) {
            if (isClickable(node)) append('c')
            if (node.editable) append('e')
            if (isScrollable(node)) append('s')
            // Focus/IME hints stay on editable fields only: a button that is
            // focusable is ordinary chrome, not an input-commit capability.
            if (node.editable) {
                if (node.focusable || node.advertises(PhoneControlNodeAction.FOCUS)) append('f')
                if (node.focused) append('F')
                if (node.advertises(PhoneControlNodeAction.IME_ENTER)) append('i')
            }
        }
        if (isEmpty()) append('-')
    }

    private fun detailFlags(node: PhoneControlNode): String = buildString {
        if (!node.visible) append('h')
        if (!node.enabled) append('d')
        if (protectedNode(node)) {
            append('p')
        } else {
            if (isClickable(node)) append('c')
            if (node.editable) append('e')
            if (isScrollable(node)) append('s')
        }
        if (node.focusable || node.advertises(PhoneControlNodeAction.FOCUS)) append('f')
        if (node.focused) append('F')
        if (node.advertises(PhoneControlNodeAction.IME_ENTER)) append('i')
        if (isEmpty()) append('-')
    }

    private fun appendOverflow(
        ranked: List<PhoneControlNode>,
        labels: Map<String, String>,
        hints: Map<String, String>,
        shown: Set<String>,
        out: StringBuilder,
        limit: Int,
    ) {
        val remaining = ranked.filter { node ->
            node.visible && node.enabled && !protectedNode(node) && actionableNode(node) &&
                node.ref !in shown
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
                isClickable(node) -> "c"
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

    private fun protectedNode(node: PhoneControlNode): Boolean =
        node.password || node.redacted

    private fun isClickable(node: PhoneControlNode): Boolean =
        node.clickable || node.advertises(PhoneControlNodeAction.CLICK)

    private fun isScrollable(node: PhoneControlNode): Boolean =
        node.scrollable || node.actions.any { it.isScrollAction }

    private fun isClickOnly(node: PhoneControlNode): Boolean =
        isClickable(node) && !node.editable && !isScrollable(node)

    private fun actionableNode(node: PhoneControlNode): Boolean =
        node.visible && node.enabled && !protectedNode(node) &&
            (isClickable(node) || node.editable || isScrollable(node))

    /** Ordered, distinct non-blank own labels: text, description, hint. */
    private fun ownLabels(node: PhoneControlNode): List<LabelPart> {
        val labels = ArrayList<LabelPart>(3)
        fun add(raw: String?, kind: LabelKind) {
            val value = cleanLabel(raw) ?: return
            if (labels.any { it.value.equals(value, ignoreCase = true) }) return
            labels += LabelPart(value, kind)
        }
        add(node.text, LabelKind.TEXT)
        add(node.contentDescription, LabelKind.DESCRIPTION)
        add(node.hintText, LabelKind.HINT)
        return labels
    }

    private fun cleanLabel(raw: String?): String? =
        raw?.replace('\n', ' ')?.replace('\r', ' ')?.replace('|', '/')
            ?.trim()?.takeIf { it.isNotBlank() }

    private fun quoted(value: String, maxChars: Int): String {
        val clean = cleanLabel(value) ?: return "\"\""
        val bounded = PhoneControlText.bound(clean, maxChars)
        val body = (bounded.text ?: "") + if (bounded.truncated) "…" else ""
        return "\"" + body + "\""
    }

    private fun formatRange(range: PhoneControlRangeInfo): String =
        formatNumber(range.min) + ".." + formatNumber(range.max) +
            "@" + formatNumber(range.current)

    private fun formatNumber(value: Float): String {
        val rounded = Math.round(value * 100f) / 100f
        return if (rounded == rounded.toLong().toFloat()) {
            rounded.toLong().toString()
        } else {
            rounded.toString()
        }
    }
}
