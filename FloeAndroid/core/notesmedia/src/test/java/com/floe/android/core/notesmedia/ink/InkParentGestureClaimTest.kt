// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real [InkPointerRouter] through the finger sequences observed on
 * the tablet and pins when the view must claim/release parent interception.
 * The interop delivery itself needs a device check; this covers the lifecycle
 * contract that lets a swipe survive and page scrolling recover afterwards.
 */
class InkParentGestureClaimTest {

    private val transitions = ArrayList<Boolean>()

    private fun apply(claim: InkParentGestureClaim, intent: InkGestureIntent) {
        claim.apply(intent)?.let { transitions.add(it) }
    }

    private fun apply(claim: InkParentGestureClaim, intents: List<InkGestureIntent>) {
        for (intent in intents) apply(claim, intent)
    }

    private fun sample(
        action: InkPointerAction,
        pointerId: Int = 0,
        pointerCount: Int = 1,
        x: Float = 100f,
        y: Float = 100f,
        pointers: List<InkPointerPosition> = listOf(InkPointerPosition(pointerId, x, y)),
    ) = InkPointerSample(
        action = action,
        pointerId = pointerId,
        pointerCount = pointerCount,
        toolType = InkPointerKind.FINGER,
        xPx = x,
        yPx = y,
        pointers = pointers,
    )

    @Test
    fun fingerSwipeClaimsOnDownAndReleasesOnUp() {
        val router = InkPointerRouter { InkInputConfig() }
        val claim = InkParentGestureClaim()
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(claim, router.onSample(sample(InkPointerAction.MOVE, x = 140f, y = 130f)))
        apply(claim, router.onSample(sample(InkPointerAction.MOVE, x = 220f, y = 200f)))
        assertTrue("a live stroke must own the parent stream", claim.isHeld)
        apply(claim, router.onSample(sample(InkPointerAction.UP, x = 220f, y = 200f)))
        assertEquals(listOf(true, false), transitions)
        assertFalse(claim.isHeld)
    }

    @Test
    fun cancelReleasesTheClaimForPageScrolling() {
        val router = InkPointerRouter { InkInputConfig() }
        val claim = InkParentGestureClaim()
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(claim, router.onSample(sample(InkPointerAction.CANCEL)))
        assertEquals(listOf(true, false), transitions)
        assertFalse(claim.isHeld)
    }

    @Test
    fun cancelAfterSeveralMovesStillReleasesTheClaim() {
        val router = InkPointerRouter { InkInputConfig() }
        val claim = InkParentGestureClaim()
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(claim, router.onSample(sample(InkPointerAction.MOVE, x = 160f, y = 140f)))
        apply(claim, router.onSample(sample(InkPointerAction.MOVE, x = 260f, y = 220f)))
        assertTrue(claim.isHeld)
        apply(claim, router.onSample(sample(InkPointerAction.CANCEL, x = 260f, y = 220f)))
        assertEquals(listOf(true, false), transitions)
        assertFalse(claim.isHeld)
    }

    @Test
    fun singleTapClaimsAndReleasesExactlyOnce() {
        val router = InkPointerRouter { InkInputConfig() }
        val claim = InkParentGestureClaim()
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(claim, router.onSample(sample(InkPointerAction.UP)))
        assertEquals(listOf(true, false), transitions)
    }

    @Test
    fun secondFingerCancelsStrokeButTransformKeepsTheClaim() {
        val router = InkPointerRouter { InkInputConfig() }
        val claim = InkParentGestureClaim()
        val twoPointers = listOf(
            InkPointerPosition(0, 100f, 100f),
            InkPointerPosition(1, 300f, 100f),
        )
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(
            claim,
            router.onSample(
                sample(
                    InkPointerAction.POINTER_DOWN,
                    pointerId = 1,
                    pointerCount = 2,
                    x = 300f,
                    pointers = twoPointers,
                ),
            ),
        )
        apply(
            claim,
            router.onSample(sample(InkPointerAction.MOVE, pointerCount = 2, pointers = twoPointers)),
        )
        apply(
            claim,
            router.onSample(
                sample(InkPointerAction.POINTER_UP, pointerId = 1, pointerCount = 2, x = 300f, pointers = twoPointers),
            ),
        )
        apply(claim, router.onSample(sample(InkPointerAction.UP)))
        assertEquals(listOf(true, false, true, false), transitions)
        assertFalse(claim.isHeld)
    }

    @Test
    fun penOnlyFingerNavigationNeverClaims() {
        val router = InkPointerRouter { InkInputConfig(penOnly = true, fingerWriting = false) }
        val claim = InkParentGestureClaim()
        apply(claim, router.onSample(sample(InkPointerAction.DOWN)))
        apply(claim, router.onSample(sample(InkPointerAction.MOVE, x = 220f, y = 200f)))
        apply(claim, router.onSample(sample(InkPointerAction.UP, x = 220f, y = 200f)))
        assertTrue("pen-only fingers must leave page scrolling to the host", transitions.isEmpty())
    }

    @Test
    fun pageChangeReleaseIsIdempotent() {
        val claim = InkParentGestureClaim()
        assertNull(claim.release())
        assertTrue(claim.apply(InkGestureIntent.BeginStroke(0, InkPointerKind.FINGER)) == true)
        assertTrue(claim.release() == false)
        assertNull(claim.release())
        assertFalse(claim.isHeld)
    }
}
