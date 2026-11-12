// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.UiBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A cached ref is dispatched only while the live node is still the SAME real
 * node: same package/class/view id/bounds/state and the same target-local
 * row context. A replacement of the same widget class must be refused before
 * any click, while an unrelated clock elsewhere on the page cannot stale the
 * target because the identity is target-local.
 */
class UiNodeIdentityPolicyTest {

    private val bounds = UiBounds(0, 0, 120, 48)

    private fun anchor(
        index: Int = 0,
        className: String = "android.widget.TextView",
        viewId: String? = null,
        text: String? = null,
        password: Boolean = false,
        redacted: Boolean = false,
        bounds: UiBounds = UiBounds(0, 0, 120, 48),
    ): UiIdentityAnchor = UiIdentityAnchor(
        index = index,
        className = className,
        viewId = viewId,
        bounds = bounds,
        password = password,
        redacted = redacted,
        text = text,
        contentDescription = null,
        hintText = null,
    )

    private fun identity(
        packageName: String? = "com.example.target",
        className: String = "android.widget.Button",
        viewId: String? = "com.example.target:id/save",
        bounds: UiBounds = this.bounds,
        visible: Boolean = true,
        enabled: Boolean = true,
        clickable: Boolean = true,
        editable: Boolean = false,
        password: Boolean = false,
        redacted: Boolean = false,
        actions: Set<String> = setOf("click"),
        text: String? = "Save",
        childAnchors: List<UiIdentityAnchor> = emptyList(),
        parentAnchor: UiIdentityAnchor? = null,
    ): UiNodeIdentity = UiNodeIdentity(
        packageName = packageName,
        className = className,
        viewId = viewId,
        bounds = bounds,
        visible = visible,
        enabled = enabled,
        clickable = clickable,
        editable = editable,
        password = password,
        redacted = redacted,
        actions = actions,
        text = text,
        contentDescription = null,
        hintText = null,
        childAnchors = childAnchors,
        parentAnchor = parentAnchor,
    )

    @Test fun unchangedRealNodeKeepsItsAction() {
        assertNull(UiNodeIdentityPolicy.mismatch(identity(), identity()))
    }

    @Test fun sameClassDifferentViewIdIsStale() {
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(
                identity(),
                identity(viewId = "com.example.target:id/delete"),
            ),
        )
    }

    @Test fun sameBoundsAndViewIdButDifferentTextIsAReplacedButton() {
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(identity(), identity(text = "Delete")),
        )
    }

    @Test fun sameClassAndBoundsButMovedNodeIsStale() {
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(
                identity(),
                identity(bounds = UiBounds(0, 60, 120, 108)),
            ),
        )
    }

    @Test fun recycledClickableRowWithDifferentChildTextIsStale() {
        val stored = identity(
            className = "android.widget.LinearLayout",
            viewId = null,
            clickable = true,
            actions = setOf("click"),
            text = null,
            childAnchors = listOf(anchor(text = "Alice")),
        )
        val live = stored.copy(
            childAnchors = listOf(anchor(text = "Bob")),
        )
        assertEquals("node_changed", UiNodeIdentityPolicy.mismatch(stored, live))
    }

    @Test fun sameRowWithSameChildTextStillMatches() {
        val stored = identity(
            className = "android.widget.LinearLayout",
            viewId = null,
            actions = setOf("click"),
            text = null,
            childAnchors = listOf(anchor(text = "Alice")),
        )
        assertNull(UiNodeIdentityPolicy.mismatch(stored, stored.copy()))
    }

    @Test fun parentRowReplacementIsStale() {
        val stored = identity(parentAnchor = anchor(index = -1, text = "Alice"))
        val live = stored.copy(parentAnchor = anchor(index = -1, text = "Bob"))
        assertEquals("node_changed", UiNodeIdentityPolicy.mismatch(stored, live))
    }

    @Test fun aLostAdvertisedActionIsStaleButAnAddedOneIsNot() {
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(
                identity(actions = setOf("click", "longClick")),
                identity(actions = setOf("click")),
            ),
        )
        assertNull(
            UiNodeIdentityPolicy.mismatch(
                identity(actions = setOf("click")),
                identity(actions = setOf("click", "ime")),
            ),
        )
    }

    @Test fun disabledLiveNodeIsReportedAsDisabled() {
        assertEquals(
            "node_disabled",
            UiNodeIdentityPolicy.mismatch(identity(), identity(enabled = false)),
        )
    }

    @Test fun protectionChangeIsSensitiveAndStale() {
        assertEquals(
            "sensitive_field_changed",
            UiNodeIdentityPolicy.mismatch(identity(), identity(password = true)),
        )
        assertEquals(
            "sensitive_field_changed",
            UiNodeIdentityPolicy.mismatch(
                identity(password = true, redacted = true, text = null),
                identity(password = false, redacted = false, text = null),
            ),
        )
    }

    @Test fun protectedIdentityNeverComparesText() {
        // A redacted field carries no stored text; even if a live value were
        // present the policy must not compare or expose it.
        assertNull(
            UiNodeIdentityPolicy.mismatch(
                identity(password = true, redacted = true, text = null),
                identity(password = true, redacted = true, text = "canary"),
            ),
        )
    }

    @Test fun aValueTheObservationDidNotCarryIsNotTreatedAsAbsentLiveContent() {
        // The bounded text budget may withhold a late field's text. A live
        // value appearing for a stored null is not, by itself, a change; all
        // other real anchors still have to match.
        assertNull(
            UiNodeIdentityPolicy.mismatch(
                identity(text = null),
                identity(text = "loaded later"),
            ),
        )
    }

    @Test fun aCapturedLabelThatDisappearsIsStillStale() {
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(identity(text = "Save"), identity(text = null)),
        )
    }

    @Test fun aMissingViewIdNeverWaivesTheOtherRealAnchors() {
        val stored = identity(viewId = null)
        assertNull(UiNodeIdentityPolicy.mismatch(stored, identity(viewId = null)))
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(stored, identity(viewId = null, text = "Delete")),
        )
        assertEquals(
            "node_changed",
            UiNodeIdentityPolicy.mismatch(
                stored,
                identity(viewId = null, className = "android.widget.TextView"),
            ),
        )
    }

    @Test fun anUnrelatedPageNodeCannotChangeTargetIdentity() {
        // The identity model has no page-wide text/hash input; two target
        // records that describe the same node match regardless of what else a
        // clock or list elsewhere on the page is doing.
        assertNull(UiNodeIdentityPolicy.mismatch(identity(), identity()))
    }
}
