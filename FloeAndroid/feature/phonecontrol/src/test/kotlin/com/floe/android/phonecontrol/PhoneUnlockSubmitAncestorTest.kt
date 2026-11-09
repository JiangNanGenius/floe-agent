// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.*
import org.junit.Test

/**
 * Pure decision tests for the OEM submit fallback, built from the recorded
 * safe SystemUI ancestry metadata (Samsung key_enter_text bounds). No Android
 * types, no device and no credential material are involved.
 */
class PhoneUnlockSubmitAncestorTest {
    private class Node(
        private val systemUi: Boolean = true,
        private val open: Boolean = true,
        private val tappable: Boolean = false,
        private val box: IntArray = intArrayOf(0, 0, 100, 100),
    ) : SubmitWalkNode {
        var clicks = 0
        var upper: SubmitWalkNode? = null
        override val systemUiPackage get() = systemUi
        override val enabled get() = open
        override val clickable get() = tappable
        override val bounds get() = box
        override val parent get() = upper
        override fun performClick(): Boolean { clicks++; return true }
    }

    // Observed empty-keyguard label: [716,1437][896,1617].
    private fun labelledSubmit() = Node(box = intArrayOf(716, 1437, 896, 1617))

    @Test fun clickableBoundedSystemUiAncestorActsForLabelledChild() {
        val child = labelledSubmit()
        val container = Node(tappable = true, box = intArrayOf(660, 1380, 950, 1670))
        val host = Node(box = intArrayOf(0, 0, 1080, 2277))
        child.upper = container; container.upper = host
        val target = findBoundedClickableSubmitAncestor(child)
        assertSame(container, target)
        assertTrue(target!!.performClick())
        assertEquals(1, container.clicks)
        assertEquals(0, host.clicks)
        assertEquals(0, child.clicks)
    }

    @Test fun observedEmptySamsungAncestryFindsNoClickableTarget() {
        // EMPTY_SYSTEM_PIN_SUBMIT_ANCESTRY.json: key_enter_text -> nonclickable
        // keyguard_host_view -> nonclickable unnamed FrameLayout -> no parent.
        val child = labelledSubmit()
        val host = Node(box = intArrayOf(0, 0, 1080, 2277))
        val frame = Node(box = intArrayOf(0, 0, 1080, 2277))
        child.upper = host; host.upper = frame
        assertNull(findBoundedClickableSubmitAncestor(child))
        assertEquals(0, host.clicks)
        assertEquals(0, frame.clicks)
    }

    @Test fun foreignPackageAncestorStopsTheWalk() {
        val child = labelledSubmit()
        val foreign = Node(systemUi = false, tappable = true, box = intArrayOf(660, 1380, 950, 1670))
        val valid = Node(tappable = true, box = intArrayOf(660, 1380, 950, 1670))
        child.upper = foreign; foreign.upper = valid
        assertNull(findBoundedClickableSubmitAncestor(child))
        assertEquals(0, valid.clicks)
    }

    @Test fun disabledAncestorIsSkippedButSameWindowWalkContinues() {
        val child = labelledSubmit()
        val disabled = Node(open = false, tappable = true, box = intArrayOf(660, 1380, 950, 1670))
        val container = Node(tappable = true, box = intArrayOf(640, 1360, 970, 1690))
        child.upper = disabled; disabled.upper = container
        assertSame(container, findBoundedClickableSubmitAncestor(child))
    }

    @Test fun walkIsBoundedToFourSystemUiAncestors() {
        // A valid target at the fourth ancestor (hop index 3) is reachable.
        val near = labelledSubmit()
        val b1 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val b2 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val b3 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val b4 = Node(tappable = true, box = intArrayOf(0, 0, 1080, 2277))
        near.upper = b1; b1.upper = b2; b2.upper = b3; b3.upper = b4
        assertSame(b4, findBoundedClickableSubmitAncestor(near))
        // A valid target at the fifth ancestor is never reached under the
        // default bound and only with an explicitly widened walk.
        val deep = labelledSubmit()
        val c1 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val c2 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val c3 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val c4 = Node(box = intArrayOf(0, 0, 1080, 2277))
        val c5 = Node(tappable = true, box = intArrayOf(0, 0, 1080, 2277))
        deep.upper = c1; c1.upper = c2; c2.upper = c3; c3.upper = c4; c4.upper = c5
        assertNull(findBoundedClickableSubmitAncestor(deep))
        assertSame(c5, findBoundedClickableSubmitAncestor(deep, maxHops = 5))
    }

    @Test fun ancestorMustBoundTheLabelledNodePositively() {
        val child = labelledSubmit()
        val sibling = Node(tappable = true, box = intArrayOf(0, 0, 700, 1400))
        child.upper = sibling
        assertNull(findBoundedClickableSubmitAncestor(child))
        assertFalse(boundsPositivelyContain(intArrayOf(0, 0, 100, 100), intArrayOf(10, 10, 10, 10)))
        assertFalse(boundsPositivelyContain(intArrayOf(0, 0, 0, 0), intArrayOf(10, 10, 20, 20)))
        assertTrue(boundsPositivelyContain(intArrayOf(716, 1437, 896, 1617), intArrayOf(716, 1437, 896, 1617)))
    }

    @Test fun equalBoundsContainerActsForTheLabel() {
        val child = labelledSubmit()
        val container = Node(tappable = true, box = intArrayOf(716, 1437, 896, 1617))
        child.upper = container
        assertSame(container, findBoundedClickableSubmitAncestor(child))
    }
}
