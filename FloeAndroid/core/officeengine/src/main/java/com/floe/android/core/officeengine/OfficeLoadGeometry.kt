// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pure initial-page-load geometry invariant (G05-R2, 2026-10-26).
 *
 * The engine page may only start loading in a view that is attached to a
 * window AND has positive real layout size. Both initial-load branches of
 * [OfficeEngineService] funnel through this predicate.
 *
 * Mechanism: the pinned frontend measures its initial canvas geometry from
 * the live DOM at doc-layer setup (`CanvasTileLayer._setup` ->
 * `_syncTileContainerSize` -> the document-container rect ->
 * `CanvasSectionContainer.onResize`), and only the Calc/zoom message paths
 * re-run that measurement — Writer has no message-driven canvas re-sync. A
 * navigation begun while the view is still unattached/unmeasured (0x0) can
 * therefore latch a zero first canvas until a REAL viewport change re-runs
 * the resize chain; the actual Alpha13 C03 session showed exactly that
 * steady state. The full evidence and the residual unknown (which exact
 * internal path keeps the zero latch) live in the private handoff; whether
 * this invariant fully resolves the first paint is decided by the Main
 * device run. This wait is a lifecycle invariant, not a sleep, a resize
 * hack, a poll loop, or a readiness claim.
 */
object OfficeLoadGeometry {

    /** The initial (and only) page load of a mount may start only here. */
    fun permitsInitialLoad(attachedToWindow: Boolean, widthPx: Int, heightPx: Int): Boolean =
        attachedToWindow && widthPx > 0 && heightPx > 0
}
