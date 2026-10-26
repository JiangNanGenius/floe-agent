// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM regression for the initial page-load geometry invariant
 * ([OfficeLoadGeometry]) — G05-R2, 2026-10-26. The engine page must not
 * begin loading until the exact view is attached with positive real
 * layout size (a 0x0 early navigation can latch the frontend's zero
 * first-canvas measurement; actual sufficiency is the Main device gate).
 * Authored here, NOT RUN — Main runs the grouped JVM pass.
 */
class OfficeLoadGeometryTest {

    @Test
    fun detachedViewNeverPermitsInitialLoad() {
        // The exact factory state that broke C03: full eventual size
        // requested, but the view is not yet attached to a window.
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(false, 2560, 1311))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(false, 0, 0))
    }

    @Test
    fun attachedNonPositiveSizeDoesNotPermitInitialLoad() {
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 0, 0))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 2560, 0))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 0, 1311))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, -1, 100))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 100, -1))
    }

    @Test
    fun attachedPositiveViewPermitsInitialLoad() {
        // Real C03 landscape content-area geometry (WebView bounds
        // 2560x1311 below the toolbar row), and after a rotation portrait.
        assertTrue(OfficeLoadGeometry.permitsInitialLoad(true, 2560, 1311))
        assertTrue(OfficeLoadGeometry.permitsInitialLoad(true, 1600, 1536))
    }

    @Test
    fun boundaryIsAnyPositiveRealLayout() {
        // One device pixel on both axes is the documented invariant edge;
        // nothing larger is "required" and zero on any axis fails closed.
        assertTrue(OfficeLoadGeometry.permitsInitialLoad(true, 1, 1))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 1, 0))
        assertFalse(OfficeLoadGeometry.permitsInitialLoad(true, 0, 1))
    }
}
