// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic regressions for bounded window-id attribution.
 *
 * The synthetic device sequence: a calculator observation targets window101;
 * a package-carrying state change from transient window202 is kept because it
 * is unrelated; the following package-less WINDOWS_CHANGED for202 must use the
 * identity learned from that state change; a later post-action observation is
 * cleared by a package-less WINDOWS_CHANGED for303 unless the explicit
 * observation snapshot positively identified that window. Unknown events,
 * observed-window events, active-window changes, removals and reused ids stay
 * fail-closed.
 */
class PhoneControlWindowAttributionTest {
    private val observedWindow = 101
    private val observedPackage = "com.sec.android.app.popupcalculator"
    private val transientPackage = "android"
    private val overlayPackage = "com.android.systemui"

    @Test
    fun `synthetic transient layer sequence keeps a fresh observation`() {
        val attribution = PhoneControlWindowAttribution()
        // The explicit observation snapshot saw the second transient layer.
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )

        // 1. Framework package metadata on the first transient layer is unrelated.
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                nowMillis = 1_050L,
            ),
        )
        // 2. Its following ADDED event carries no package; the identity learned
        //    from step 1 attributes it instead of clearing.
        assertFalse(attribution.event(202, windowAdded = true, nowMillis = 1_060L))
        // 3. A post-action observation has a new page epoch and is
        //    seeded from its explicit snapshot; the package-less 303 layer event
        //    must not clear it.
        attribution.seed(
            1,
            2,
            1_070L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )
        assertFalse(attribution.event(303, pageGeneration = 2, nowMillis = 1_200L))

        // The observed page itself still invalidates.
        assertTrue(attribution.event(observedWindow, pageGeneration = 2, nowMillis = 1_210L))
    }

    @Test
    fun `snapshot seeded identity attributes a package-less event`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )

        assertFalse(attribution.event(303, nowMillis = 1_100L))
    }

    @Test
    fun `stale snapshot identity is not reused for a later added window`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(202, overlayPackage)),
        )

        // Beyond the add burst the numeric id may have been reused; the old
        // snapshot cannot prove the new window belongs to the same package.
        assertTrue(attribution.event(202, windowAdded = true, nowMillis = 12_000L))
        assertNull(attribution.trustedPackage(202))
    }

    @Test
    fun `stale event identity is not reused for a later added event`() {
        val attribution = PhoneControlWindowAttribution()
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                nowMillis = 1_000L,
            ),
        )

        // Beyond the bounded add burst the numeric id may have been reused.
        assertTrue(attribution.event(202, windowAdded = true, nowMillis = 12_000L))
        assertNull(attribution.trustedPackage(202))
    }

    @Test
    fun `removal forgets an identity so a later reuse fails closed`() {
        val attribution = PhoneControlWindowAttribution()
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                nowMillis = 1_000L,
            ),
        )
        assertEquals(transientPackage, attribution.trustedPackage(202))

        // Removing the unrelated window is safe to skip, but it must forget the id.
        assertFalse(attribution.event(202, windowRemoved = true, nowMillis = 1_010L))
        assertNull(attribution.trustedPackage(202))

        // A reused id with no fresh attribution is unknown and invalidates.
        assertTrue(attribution.event(202, nowMillis = 1_020L))
    }

    @Test
    fun `a package carrying event replaces a reused window identity`() {
        val attribution = PhoneControlWindowAttribution()
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                nowMillis = 1_000L,
            ),
        )
        assertFalse(attribution.event(202, windowRemoved = true, nowMillis = 1_010L))
        assertNull(attribution.trustedPackage(202))

        // A new package for the reused numeric id is a fresh positive identity.
        assertFalse(
            attribution.event(
                202,
                "com.example.other",
                windowAdded = true,
                nowMillis = 1_020L,
            ),
        )
        assertEquals("com.example.other", attribution.trustedPackage(202))
        assertFalse(attribution.event(202, nowMillis = 1_030L))
    }

    @Test
    fun `fence and page generation changes drop retained identities`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )
        assertEquals(overlayPackage, attribution.trustedPackage(303))

        // Fence generation changed (new owner, release, block or arm).
        attribution.seed(2, 1, 1_100L, emptyList())
        assertNull(attribution.trustedPackage(303))
        assertTrue(
            attribution.event(
                303,
                fenceGeneration = 2,
                pageGeneration = 1,
                nowMillis = 1_200L,
            ),
        )

        // A later explicit observation re-seeds the same page epoch.
        attribution.seed(
            2,
            1,
            1_300L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )
        assertEquals(overlayPackage, attribution.trustedPackage(303))

        // Page generation changed (root/page invalidated): drop it again.
        attribution.seed(2, 2, 1_400L, emptyList())
        assertNull(attribution.trustedPackage(303))
        assertTrue(
            attribution.event(
                303,
                fenceGeneration = 2,
                pageGeneration = 2,
                nowMillis = 1_500L,
            ),
        )
    }

    @Test
    fun `identity capacity is bounded`() {
        val attribution = PhoneControlWindowAttribution(capacity = 2)
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(
                PhoneControlWindowIdentity(201, "com.example.one"),
                PhoneControlWindowIdentity(202, "com.example.two"),
            ),
        )
        attribution.seed(
            1,
            1,
            1_100L,
            listOf(PhoneControlWindowIdentity(203, "com.example.three")),
        )

        assertNull(attribution.trustedPackage(201))
        assertEquals("com.example.two", attribution.trustedPackage(202))
        assertEquals("com.example.three", attribution.trustedPackage(203))
    }

    @Test
    fun `observed active and unknown events still invalidate`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(
                // Even a stale foreign identity for the observed id is irrelevant.
                PhoneControlWindowIdentity(observedWindow, overlayPackage),
                PhoneControlWindowIdentity(303, overlayPackage),
                // A window positively attributed to the observed package.
                PhoneControlWindowIdentity(404, observedPackage),
            ),
        )

        assertTrue(attribution.event(observedWindow, nowMillis = 1_100L))
        assertTrue(
            attribution.event(303, activeWindowChanged = true, nowMillis = 1_110L),
        )
        assertTrue(attribution.event(999, nowMillis = 1_120L))
        assertTrue(attribution.event(404, nowMillis = 1_130L))
        assertTrue(
            attribution.event(202, observedPackage, nowMillis = 1_140L),
        )
    }

    @Test
    fun `empty package is missing attribution and cannot keep an unknown id`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )

        assertFalse(
            attribution.event(303, eventPackageName = "", nowMillis = 1_100L),
        )
        assertTrue(
            attribution.event(998, eventPackageName = "", nowMillis = 1_110L),
        )
    }

    @Test
    fun `no observation returns no invalidation and still records attribution`() {
        val attribution = PhoneControlWindowAttribution()

        // No observation yet: the decision is irrelevant but attribution is kept
        // for the caller's current generation.
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                observed = false,
                nowMillis = 1_000L,
            ),
        )
        assertEquals(transientPackage, attribution.trustedPackage(202))
        assertFalse(attribution.event(202, nowMillis = 1_100L))
    }

    @Test
    fun `retained identity also classifies a package-less state change`() {
        val attribution = PhoneControlWindowAttribution()
        assertFalse(
            attribution.event(
                202,
                transientPackage,
                isWindowStateChanged = true,
                nowMillis = 1_000L,
            ),
        )

        assertFalse(
            attribution.event(202, isWindowStateChanged = true, nowMillis = 1_100L),
        )
        assertTrue(
            attribution.event(555, isWindowStateChanged = true, nowMillis = 1_200L),
        )
    }

    @Test
    fun `removal of the observed window invalidates even with a retained identity`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(observedWindow, overlayPackage)),
        )

        assertTrue(
            attribution.event(observedWindow, windowRemoved = true, nowMillis = 1_100L),
        )
    }

    @Test
    fun `clear drops every identity`() {
        val attribution = PhoneControlWindowAttribution()
        attribution.seed(
            1,
            1,
            1_000L,
            listOf(PhoneControlWindowIdentity(303, overlayPackage)),
        )
        assertEquals(overlayPackage, attribution.trustedPackage(303))

        attribution.clear()

        assertNull(attribution.trustedPackage(303))
        assertTrue(attribution.event(303, nowMillis = 1_100L))
    }

    private fun PhoneControlWindowAttribution.event(
        eventWindowId: Int,
        eventPackageName: String? = null,
        isWindowStateChanged: Boolean = false,
        activeWindowChanged: Boolean = false,
        windowAdded: Boolean = false,
        windowRemoved: Boolean = false,
        observed: Boolean = true,
        fenceGeneration: Long = 1,
        pageGeneration: Long = 1,
        nowMillis: Long = 1_000L,
    ): Boolean = onWindowEvent(
        fenceGeneration = fenceGeneration,
        pageGeneration = pageGeneration,
        elapsedRealtimeMillis = nowMillis,
        observedWindowId = if (observed) observedWindow else null,
        observedPackageName = if (observed) observedPackage else null,
        eventWindowId = eventWindowId,
        eventPackageName = eventPackageName,
        isWindowStateChanged = isWindowStateChanged,
        activeWindowChanged = activeWindowChanged,
        windowAdded = windowAdded,
        windowRemoved = windowRemoved,
    )
}
