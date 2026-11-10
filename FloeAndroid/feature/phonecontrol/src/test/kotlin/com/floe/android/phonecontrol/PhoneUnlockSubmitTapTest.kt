// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.*
import org.junit.Test

/**
 * Pure decision tests for the OEM touch-tap submit fallback, built from the
 * fresh device76 case-I structure (SYSTEMUI_METADATA_AFTER_FAILURE.json):
 * Samsung key_enter_text is a native TextView with enabled=true,
 * clickable=false, visibly bounded
 * [716,1437][896,1617], parented only by the wholly nonclickable
 * keyguard_host_view -> unnamed FrameLayout ancestry. The live adapter separately checks offered click actions. No Android types, no
 * device and no credential material are involved.
 */
class PhoneUnlockSubmitTapTest {
    private val visibleWindow = intArrayOf(0, 0, 1080, 2400)
    private fun tapPoint(node: SubmitWalkNode) = nativeSubmitTapPoint(node, visibleWindow)
    private fun select(candidates: List<SubmitWalkNode>) = selectNativeSubmitTap(candidates, visibleWindow)
    private class TapNode(
        private val systemUi: Boolean = true,
        private val open: Boolean = true,
        private val tappable: Boolean = false,
        private val onScreen: Boolean = true,
        private val currentWindow: Boolean = true,
        private val box: IntArray = intArrayOf(716, 1437, 896, 1617),
        private val parentNode: SubmitWalkNode? = null,
        private val clickAccepted: Boolean = true,
    ) : SubmitWalkNode {
        var clicks = 0
        override val systemUiPackage get() = systemUi
        override val enabled get() = open
        override val clickable get() = tappable
        override val visibleToUser get() = onScreen
        override val sameWindowAsRoot get() = currentWindow
        override val bounds get() = box
        override val parent: SubmitWalkNode? get() = parentNode
        override fun performClick(): Boolean { clicks++; return clickAccepted }
    }

    @Test fun observedNonclickableSamsungSubmitResolvesItsLiveCentre() {
        // The recorded bounds [716,1437][896,1617] centre exactly here;
        // the tap uses only this live-bounds point, never a saved screen
        // coordinate and never a general unlock gesture.
        assertEquals(NativeSubmitTapPoint(806, 1527), tapPoint(TapNode()))
    }

    @Test fun clickAdvertisedControlKeepsItsOwnChannelAndIsNeverTapped() {
        // Metadata-clickable OR an offered ACTION_CLICK both fold into
        // SubmitWalkNode.clickable in the live adapter: such a control's own
        // accept/refuse stays final and no touch fallback may bypass it.
        assertNull(tapPoint(TapNode(tappable = true)))
    }

    @Test fun foreignStaleDisabledAndInvisibleSubmitsAreRejected() {
        // Foreign package, a tree no longer inside the freshly validated
        // credential window, disabled and off-screen controls are all
        // refused before any gesture exists.
        assertNull(tapPoint(TapNode(systemUi = false)))
        assertNull(tapPoint(TapNode(currentWindow = false)))
        assertNull(tapPoint(TapNode(open = false)))
        assertNull(tapPoint(TapNode(onScreen = false)))
    }

    @Test fun nonPositiveBoundsAreNeverTapped() {
        assertNull(tapPoint(TapNode(box = intArrayOf(716, 1437, 716, 1437))))
        assertNull(tapPoint(TapNode(box = intArrayOf(896, 1617, 716, 1437))))
        assertNull(tapPoint(TapNode(box = intArrayOf(0, 0, 0))))
    }

    @Test fun twoEligibleLabelsAreAmbiguousAndUntapped() {
        assertNull(select(listOf(
            TapNode(),
            TapNode(box = intArrayOf(100, 200, 300, 400)),
        )))
    }

    @Test fun unqualifiedSiblingsDoNotCreateAmbiguity() {
        // Only controls that could act at all compete for uniqueness; a
        // foreign or stale sibling neither blocks nor gets tapped.
        val foreign = TapNode(systemUi = false)
        val stale = TapNode(currentWindow = false)
        val eligible = TapNode()
        assertEquals(NativeSubmitTapPoint(806, 1527),
            select(listOf(foreign, stale, eligible)))
        assertEquals(0, foreign.clicks)
        assertEquals(0, stale.clicks)
    }

    @Test fun emptyCandidateListTapsNothing() {
        assertNull(select(emptyList()))
    }

    @Test fun legacyAncestorNodesKeepDefaultTrustFlags() {
        // The earlier PhoneUnlockSubmitAncestorTest node shape predates the
        // tap gates. The interface defaults must stay permissive so the
        // preserved ancestor decision cannot shift with this change.
        val legacy = object : SubmitWalkNode {
            override val systemUiPackage = true
            override val enabled = true
            override val clickable = false
            override val bounds = intArrayOf(716, 1437, 896, 1617)
            override val parent: SubmitWalkNode? = null
            override fun performClick() = true
        }
        assertTrue(legacy.visibleToUser)
        assertTrue(legacy.sameWindowAsRoot)
        assertEquals(NativeSubmitTapPoint(806, 1527), tapPoint(legacy))
    }

    @Test fun aRefusedClickableAncestorCannotBeBypassedByTappingItsChild() {
        val parent = TapNode(tappable = true, box = intArrayOf(700, 1400, 950, 1650), clickAccepted = false)
        val child = TapNode(parentNode = parent)
        assertSame(parent, findBoundedClickableSubmitAncestor(child))
        assertFalse(parent.performClick())
        assertNull(select(listOf(child)))
        assertEquals(1, parent.clicks)
        assertEquals(0, child.clicks)
    }

    @Test fun aRefusedClickChannelCannotFallThroughToAnotherLabel() {
        val clickable = TapNode(tappable = true, clickAccepted = false)
        val touchOnly = TapNode(box = intArrayOf(100, 200, 300, 400))
        assertFalse(clickable.performClick())
        assertNull(select(listOf(clickable, touchOnly)))
        assertEquals(1, clickable.clicks)
        assertEquals(0, touchOnly.clicks)
    }

    @Test fun aControlOutsideTheVisibleCredentialWindowIsNotTapped() {
        assertNull(nativeSubmitTapPoint(TapNode(), intArrayOf(0, 0, 700, 1400)))
        assertNull(nativeSubmitTapPoint(TapNode(), intArrayOf(0, 0, 0, 0)))
        assertNull(tapPoint(TapNode(box = intArrayOf(-100, 200, 300, 400))))
    }
}
