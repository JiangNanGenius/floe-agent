// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Causal regressions for the observed phone observation invalidation gap.
 *
 * Retained device evidence (Local/Private/android-next-20261106):
 * - n02-calculator47-auto: a fresh observation below its 120s TTL was refused
 *   as STALE_OBSERVATION ~64s after issue while the calculator page was
 *   provably unchanged (idle approval queue, no user touch, no navigation).
 * - n02-calculator66-trace: the same page flow completed with observations
 *   up to ~115s old, so age/queue length is not the invalidation cause.
 *
 * These tests pin the production decision: window events attributed to the
 * observed window/app, the active window, or no window at all must still
 * invalidate (real navigation/stale/foreign rejection stays intact), while
 * clearly unrelated or self-generated windows keep a valid observation.
 */
class PhoneControlWindowEventTest {
    private val observedWindow = 112789
    private val observedPackage = "com.sec.android.app.popupcalculator"

    // ---- real navigation / observed-page change must still invalidate ----

    @Test
    fun `windows changed for the observed window invalidates`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = observedWindow,
                eventPackageName = observedPackage,
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `windows removed for the observed window invalidates`() {
        // A removal carries the dying window id: the observed window is gone.
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = observedWindow,
                eventPackageName = null,
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `same package different window invalidates`() {
        // Same-app activity swap or dialog: grant still covers the package
        // but the page semantics may have changed.
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = observedWindow + 7,
                eventPackageName = observedPackage,
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `active window change invalidates even for another package`() {
        // An ACTIVE event always invalidates, even when its package differs.
        // Action dispatch also checks the actual foreground window.
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990001,
                eventPackageName = "com.example.other",
                isWindowStateChanged = false,
                activeWindowChanged = true,
            ),
        )
    }

    @Test
    fun `state changed on the observed window invalidates`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = observedWindow,
                eventPackageName = observedPackage,
                isWindowStateChanged = true,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `state changed in the observed package invalidates`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990002,
                eventPackageName = observedPackage,
                isWindowStateChanged = true,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `unattributable windows changed invalidates`() {
        // Unknown window id and no package: may be the observed window's own
        // removal, so the conservative choice stays.
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = -1,
                eventPackageName = null,
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `unattributable state changed invalidates`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990003,
                eventPackageName = null,
                isWindowStateChanged = true,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `unknown window id naming the observed package invalidates`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = -1,
                eventPackageName = observedPackage,
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    // ---- unrelated / self-generated windows must keep the observation ----

    @Test
    fun `windows changed attributed to another package keeps observation`() {
        // Toast / heads-up / transient system window over an unchanged page.
        assertFalse(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990010,
                eventPackageName = "com.android.systemui",
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `windows changed for floe own overlay keeps observation`() {
        // Floe's own automation overlay is a different package and never the
        // active window; its add/remove must not destroy the observation.
        assertFalse(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990011,
                eventPackageName = "com.floe.agent.full",
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `unrelated window removal keeps observation`() {
        assertFalse(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990012,
                eventPackageName = "com.example.toastapp",
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `state change attributed to another package keeps observation`() {
        // Volume dialog / IME-switch style transient system window; real
        // navigation is still caught by the active-window rule above, and
        // dispatch revalidates bounds/class/viewId against the live tree.
        assertFalse(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990013,
                eventPackageName = "com.android.systemui",
                isWindowStateChanged = true,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `unrelated windows changed with null observed package keeps observation`() {
        // Navigation-only Floe metadata observations carry no package; an
        // attributed foreign window still cannot change their page.
        assertFalse(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = null,
                eventWindowId = 990014,
                eventPackageName = "com.example.other",
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }

    @Test
    fun `empty package is treated as unattributable`() {
        assertTrue(
            windowEventInvalidates(
                observedWindowId = observedWindow,
                observedPackageName = observedPackage,
                eventWindowId = 990015,
                eventPackageName = "",
                isWindowStateChanged = false,
                activeWindowChanged = false,
            ),
        )
    }
}
