// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The renderer may never allocate outside its public bounds, on EITHER
 * side of the binder: both the host (before mapping) and the service
 * (before allocation) run through these same rules.
 */
class OfficePdfGeometryTest {

    @Test
    fun standardLetterAtDefaultZoomStaysBounded() {
        val size = OfficePdfGeometry.renderSize(612, 792, 100)
        assertNotNull(size)
        val (w, h) = size!!
        assertTrue("letter width $w", w in 1..OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        assertTrue("letter height $h", h <= OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        assertTrue(w.toLong() * h <= OfficePdfGeometry.MAX_RENDER_PIXELS)
        assertTrue("aspect roughly preserved", kotlin.math.abs((h.toFloat() / w) - (792f / 612f)) < 0.05f)
    }

    @Test
    fun hugePageHugeZoomIsStillCapped() {
        // A 2m x 2m "poster" page at 400% zoom must clamp, not explode.
        val size = OfficePdfGeometry.renderSize(5669, 5669, 400)
        assertNotNull(size)
        val (w, h) = size!!
        assertTrue(w <= OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        assertTrue(h <= OfficePdfGeometry.MAX_RENDER_DIMENSION_PX)
        assertTrue(w.toLong() * h <= OfficePdfGeometry.MAX_RENDER_PIXELS)
        assertTrue("square stays square", kotlin.math.abs(w - h) <= 1)
    }

    @Test
    fun degenerateAndAbsurdInputsRefuse() {
        assertNull(OfficePdfGeometry.renderSize(0, 100, 100))
        assertNull(OfficePdfGeometry.renderSize(-5, 100, 100))
        assertNull(OfficePdfGeometry.renderSize(100, 0, 100))
        assertNull(OfficePdfGeometry.renderSize(200_000, 100, 100))
        // Zoom out-of-range is CLAMPED, never refused (a hostile int zoom
        // percent produces the largest legal render, not a crash).
        val clamped = OfficePdfGeometry.renderSize(100, 100, 999_999)
        assertNotNull(clamped)
        val small = OfficePdfGeometry.renderSize(100, 100, -999_999)
        assertNotNull(small)
    }

    @Test
    fun zoomClampMatchesBoundedTable() {
        assertEquals(OfficePdfGeometry.MIN_ZOOM_PERCENT, OfficePdfGeometry.clampZoomPercent(1))
        assertEquals(OfficePdfGeometry.MAX_ZOOM_PERCENT, OfficePdfGeometry.clampZoomPercent(999_999))
        assertEquals(150, OfficePdfGeometry.clampZoomPercent(150))
    }

    @Test
    fun replyValidationRequiresExactArgbConsistency() {
        assertTrue(OfficePdfGeometry.validateReply(100, 100, 100L * 100 * 4))
        // byteCount MUST be exactly w*h*4 (ARGB_8888) — nothing else.
        assertFalse(OfficePdfGeometry.validateReply(100, 100, 100L * 100 * 3))
        assertFalse(OfficePdfGeometry.validateReply(100, 100, 100L * 100 * 4 + 1))
        assertFalse(OfficePdfGeometry.validateReply(0, 10, 400L))
        assertFalse(OfficePdfGeometry.validateReply(-1, -1, 4L))
        assertFalse(OfficePdfGeometry.validateReply(
            OfficePdfGeometry.MAX_RENDER_DIMENSION_PX,
            OfficePdfGeometry.MAX_RENDER_DIMENSION_PX,
            OfficePdfGeometry.MAX_RENDER_DIMENSION_PX.toLong() * OfficePdfGeometry.MAX_RENDER_DIMENSION_PX * 4,
        ))
    }

    @Test
    fun maxRenderBytesInvariant() {
        assertEquals(OfficePdfGeometry.MAX_RENDER_PIXELS * 4, OfficePdfGeometry.MAX_RENDER_BYTES)
    }
}

/**
 * The late-callback fence rule: every new verification/zoom cycle retires
 * ALL older tokens — a slow render for a page the user already left, or a
 * result from a session that has been re-opened, can never paint.
 */
class OfficePdfRenderFenceTest {

    @Test
    fun onlyTheNewestGenerationIsCurrent() {
        val fence = OfficePdfRenderFence()
        val first = fence.bump()
        assertTrue(fence.isCurrent(first))
        val second = fence.bump()
        assertFalse("late result from the old cycle", fence.isCurrent(first))
        assertTrue(fence.isCurrent(second))
        assertEquals(second, fence.current())
    }

    @Test
    fun zeroTokenIsNeverCurrent() {
        val fence = OfficePdfRenderFence()
        assertFalse(fence.isCurrent(0L))
        fence.bump()
        assertFalse(fence.isCurrent(0L))
    }

    @Test
    fun destructionBumpRetiresEverythingInFlight() {
        val fence = OfficePdfRenderFence()
        val live = fence.bump()
        fence.bump() // onDestroy
        assertFalse(fence.isCurrent(live))
    }
}

/**
 * Print callbacks resolve EXACTLY ONE terminal per request — the flaw the
 * AOSP reference class carries (an IOException `onWriteFailed` followed by
 * `onPostExecute`'s `onWriteFinished`) must be impossible here.
 */
class OfficePdfOnceCallbackTest {

    @Test
    fun firstTerminalWinsAndLaterOnesAreIgnored() {
        val gate = OfficePdfOnceCallback("write")
        var calls = 0
        assertTrue(gate.fire(OfficePdfOnceCallback.Terminal.FAILED) { calls++ })
        assertFalse(gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) { calls++ })
        assertFalse(gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { calls++ })
        assertEquals(1, calls)
        assertEquals(OfficePdfOnceCallback.Terminal.FAILED, gate.fired())
    }

    @Test
    fun cancelRaceNeverDoubleResolves() {
        val gate = OfficePdfOnceCallback("layout")
        var finished = 0
        var cancelled = 0
        val threads = listOf(
            Thread { gate.fire(OfficePdfOnceCallback.Terminal.CANCELLED) { cancelled++ } },
            Thread { gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) { finished++ } },
        )
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertEquals("exactly one terminal callback", 1, finished + cancelled)
        assertTrue(gate.fired() != null)
    }

    @Test
    fun pendingOnlyBeforeFirstTerminal() {
        val gate = OfficePdfOnceCallback("write")
        assertTrue(gate.pending())
        gate.fire(OfficePdfOnceCallback.Terminal.FINISHED) { }
        assertFalse(gate.pending())
    }

    @Test
    fun throwingActionStillCountsAsFired() {
        val gate = OfficePdfOnceCallback("layout")
        val fired = gate.fire(OfficePdfOnceCallback.Terminal.FAILED) { throw RuntimeException("callback host died") }
        assertTrue(fired)
        assertEquals(OfficePdfOnceCallback.Terminal.FAILED, gate.fired())
        assertFalse(gate.pending())
    }
}

/**
 * Binder-side shape bounds for the isolated renderer: ids, indices, zooms
 * and statuses outside the contract NEVER reach the parser process, and the
 * OWNER-UID fence (Main repair 2026-10-27) accepts only the exact owning
 * app UID — the delivered raw-range heuristic (refuse 99000..199999, accept
 * everything else) is replaced because it was NOT owner proof: it passed
 * every foreign user-0 app and refused legitimate user-1 instantiations of
 * the app itself, whose UIDs (e.g. 111045) merely fall inside that numeric
 * band.
 */
class OfficePdfRendererBoundsTest {

    @Test
    fun requestIdMustBePositive() {
        assertFalse(OfficePdfRendererContract.validRequestId(0L))
        assertFalse(OfficePdfRendererContract.validRequestId(-1L))
        assertTrue(OfficePdfRendererContract.validRequestId(1L))
    }

    @Test
    fun pageIndexAndZoomAndStatusAreBounded() {
        assertTrue(OfficePdfRendererContract.validPageIndex(0))
        assertTrue(OfficePdfRendererContract.validPageIndex(OfficePdfRendererContract.MAX_PAGE_INDEX - 1))
        assertFalse(OfficePdfRendererContract.validPageIndex(-1))
        assertFalse(OfficePdfRendererContract.validPageIndex(OfficePdfRendererContract.MAX_PAGE_INDEX))

        assertFalse(OfficePdfRendererContract.validZoom(0))
        assertTrue(OfficePdfRendererContract.validZoom(OfficePdfGeometry.MIN_ZOOM_PERCENT))
        assertTrue(OfficePdfRendererContract.validZoom(OfficePdfGeometry.MAX_ZOOM_PERCENT))
        assertFalse(OfficePdfRendererContract.validZoom(OfficePdfGeometry.MAX_ZOOM_PERCENT + 1))

        assertTrue(OfficePdfRendererContract.validStatus(OfficePdfRendererContract.S_OK))
        assertTrue(OfficePdfRendererContract.validStatus(OfficePdfRendererContract.S_INTERNAL))
        assertFalse(OfficePdfRendererContract.validStatus(99))
        assertFalse(OfficePdfRendererContract.validStatus(-1))
    }

    // ---- owner-UID fence (replaces the old isolated-range heuristic) ----

    @Test
    fun ownerUidEqualityAllowsExactlyTheOwningApp() {
        // The app's own main process, same user: allowed.
        assertTrue(OfficePdfRendererBinder.callerIsOwner(10_123, 10_123))
        // A same-app second non-isolated process (the engine + viewer share
        // the app UID across :floe_office and main): allowed by equality.
        assertTrue(OfficePdfRendererBinder.callerIsOwner(10_123, 10_123))
    }

    @Test
    fun foreignNormalAppUidIsRefusedUnderEveryUser() {
        // Foreign user-0 app: the OLD heuristic accepted all of these.
        assertFalse(OfficePdfRendererBinder.callerIsOwner(10_999, 10_123))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(2_000, 10_123))
        // Foreign user-1 app whose UID numerically sits inside the old
        // isolated band: refused as non-owner, not "refused as isolated".
        assertFalse(OfficePdfRendererBinder.callerIsOwner(111_099, 111_045))
        // A caller that happens to equal an old-band edge but not the owner.
        assertFalse(OfficePdfRendererBinder.callerIsOwner(99_000, 10_123))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(199_999, 10_123))
    }

    @Test
    fun secondaryUserExactOwnerMatchIsAllowed() {
        // THE multiuser regression: user 1 instantiates the same app with
        // UID 111_045 — inside the raw band the old heuristic refused it.
        // Owner equality accepts the app's OWN UID under any user.
        assertTrue(OfficePdfRendererBinder.callerIsOwner(111_045, 111_045))
        // And user 10 (UID 1_011_045, far outside the old band): still exact.
        assertTrue(OfficePdfRendererBinder.callerIsOwner(1_011_045, 1_011_045))
        // Cross-user equality is impossible: user 0's own UID never equals
        // user 1's owner value.
        assertFalse(OfficePdfRendererBinder.callerIsOwner(10_123, 111_045))
    }

    @Test
    fun isolatedProcessUidIsNeverTheOwner() {
        // A (second) isolated process driving the parser would carry an
        // isolated UID — never equal to the app owner UID, so refused.
        assertFalse(OfficePdfRendererBinder.callerIsOwner(99_123, 10_123))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(160_000, 10_123))
        // The renderer service's OWN isolated uid is irrelevant: the fence
        // compares the CALLER against the owner anchor, never against
        // Process.myUid() of this process.
        assertFalse(OfficePdfRendererBinder.callerIsOwner(10_123, 99_123))
    }

    @Test
    fun nonPositiveUidsAreInvalidAndRefused() {
        assertFalse(OfficePdfRendererBinder.callerIsOwner(0, 0))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(-1, -1))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(10_123, 0))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(10_123, -1))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(0, 10_123))
        assertFalse(OfficePdfRendererBinder.callerIsOwner(-1, 10_123))
        assertFalse(OfficePdfRendererBinder.isPlausibleOwnerAppUid(0))
        assertFalse(OfficePdfRendererBinder.isPlausibleOwnerAppUid(-1))
        assertTrue(OfficePdfRendererBinder.isPlausibleOwnerAppUid(10_123))
    }
}
