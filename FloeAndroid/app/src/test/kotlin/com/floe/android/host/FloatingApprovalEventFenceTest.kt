// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FloatingApprovalEventFenceTest {
    @Test fun staleDismissCannotRemoveNewWaitingCardWhenMainDeliveryIsReordered() {
        val fence = FloatingApprovalEventFence()
        var visible = "old"
        val dismiss = fence.issue()
        val replacement = fence.issue()
        // Execute the newer notification first, then the delayed old null.
        if (fence.isCurrent(replacement)) visible = "new"
        if (fence.isCurrent(dismiss)) visible = ""
        assertEquals("new", visible)
        assertFalse(fence.isCurrent(dismiss))
        assertTrue(fence.isCurrent(replacement))
    }

    @Test fun holderReleaseFencesOldNotificationsWithoutAffectingReplacement() {
        val oldHolder = FloatingApprovalEventFence()
        val old = oldHolder.issue()
        val newHolder = FloatingApprovalEventFence()
        val current = newHolder.issue()
        oldHolder.invalidate()
        assertFalse(oldHolder.isCurrent(old))
        assertTrue(newHolder.isCurrent(current))
    }
}
