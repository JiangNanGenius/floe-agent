// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.UiBounds

/**
 * One real, already-read identity anchor. [index] is the live child index for
 * a captured direct child, or -1 for a parent anchor. Password/redacted
 * anchors never carry text: the caller must not read a protected field's
 * contents merely to prove identity.
 */
internal data class UiIdentityAnchor(
    val index: Int,
    val className: String,
    val viewId: String?,
    val bounds: UiBounds,
    val password: Boolean,
    val redacted: Boolean,
    val text: String?,
    val contentDescription: String?,
    val hintText: String?,
)

/**
 * The live identity a dispatch is bound to. It reuses the real observation's
 * primitives and one bounded local re-read of the resolved node (and its
 * direct captured children/parent), never a whole-tree reread.
 */
internal data class UiNodeIdentity(
    val packageName: String?,
    val className: String,
    val viewId: String?,
    val bounds: UiBounds,
    val visible: Boolean,
    val enabled: Boolean,
    val clickable: Boolean,
    val editable: Boolean,
    val password: Boolean,
    val redacted: Boolean,
    val actions: Set<String>,
    val text: String?,
    val contentDescription: String?,
    val hintText: String?,
    val childAnchors: List<UiIdentityAnchor>,
    val parentAnchor: UiIdentityAnchor?,
)

/**
 * Refuses a changed/ambiguous node BEFORE any dispatch. A recycled row or a
 * replaced button of the same widget class cannot silently inherit an old
 * ref: package/class/view id/bounds/enabled/clickable/editable/password and
 * the advertised action set must all still describe the SAME live node.
 *
 * Ordinary text is compared only while the stored node was not redacted. An
 * unchanged real node keeps its action; an unrelated clock elsewhere on the
 * page cannot invalidate this target because the check is target-local. A
 * missing platform view id stays missing (FLAG_REPORT_VIEW_IDS is requested
 * but OEMs may omit it); it never waives the other real anchors and is never
 * treated as proof of identity by itself.
 */
internal object UiNodeIdentityPolicy {

    const val MAX_CHILD_ANCHORS = 6

    fun mismatch(stored: UiNodeIdentity, live: UiNodeIdentity): String? {
        if (stored.packageName != live.packageName) return "node_changed"
        if (stored.className != live.className) return "node_changed"
        if (stored.viewId != live.viewId) return "node_changed"
        if (stored.bounds != live.bounds) return "node_changed"
        if (stored.visible != live.visible) return "node_changed"
        if (stored.enabled != live.enabled) {
            return if (stored.enabled) "node_disabled" else "node_changed"
        }
        if (stored.clickable != live.clickable) return "node_changed"
        if (stored.editable != live.editable) return "node_changed"
        if (stored.password != live.password) return "sensitive_field_changed"
        if (stored.redacted != live.redacted) return "sensitive_field_changed"
        // Every action the observation relied on must still be advertised.
        // Additions (for example focus/IME actions that appear after focus)
        // do not invalidate the same real node; a removed capability does.
        if (!live.actions.containsAll(stored.actions)) return "node_changed"

        if (!stored.redacted) {
            // A value the bounded observation did not carry is not proof that
            // the live node has no such value (text budgets can withhold a
            // late field). Compare only anchors the observation actually
            // captured; a captured label disappearing is still a change.
            if (stored.text != null && stored.text != live.text) return "node_changed"
            if (stored.contentDescription != null &&
                stored.contentDescription != live.contentDescription
            ) {
                return "node_changed"
            }
            if (stored.hintText != null && stored.hintText != live.hintText) {
                return "node_changed"
            }
        }

        if (stored.childAnchors.size != live.childAnchors.size) return "node_changed"
        for (index in stored.childAnchors.indices) {
            if (!anchorMatches(stored.childAnchors[index], live.childAnchors[index])) {
                return "node_changed"
            }
        }

        val storedParent = stored.parentAnchor
        if (storedParent != null) {
            val liveParent = live.parentAnchor ?: return "node_changed"
            if (!anchorMatches(storedParent, liveParent)) return "node_changed"
        }
        return null
    }

    private fun anchorMatches(
        stored: UiIdentityAnchor,
        live: UiIdentityAnchor,
    ): Boolean {
        if (stored.index != live.index) return false
        if (stored.className != live.className) return false
        if (stored.viewId != live.viewId) return false
        if (stored.bounds != live.bounds) return false
        if (stored.password != live.password) return false
        if (stored.redacted != live.redacted) return false
        if (stored.redacted) return true
        if (stored.text != null && stored.text != live.text) return false
        if (stored.contentDescription != null &&
            stored.contentDescription != live.contentDescription
        ) {
            return false
        }
        if (stored.hintText != null && stored.hintText != live.hintText) return false
        return true
    }
}
