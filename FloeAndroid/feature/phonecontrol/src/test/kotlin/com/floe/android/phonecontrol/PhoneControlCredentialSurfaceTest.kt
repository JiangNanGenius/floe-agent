// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.*
import org.junit.Test

/**
 * Authored-only determinism for the default-display SystemUI credential
 * surface selection. Every scenario exercises metadata, never content: the
 * candidate fakes expose gates and a boolean probe, and the observation may
 * only ever contain the closed [SurfaceStage] labels.
 */
class PhoneControlCredentialSurfaceTest {
    private class Candidate(
        val onDisplay: Boolean = true,
        val content: Boolean = true,
        val systemUi: Boolean = true,
        val alive: Boolean = true,
        val focused: Boolean = false,
        val shows: Boolean = false,
        val probeCounter: MutableList<Int>? = null,
    ) : SurfaceCandidate {
        override val onDefaultDisplay get() = onDisplay
        override val contentAvailable get() = content
        override val trustedSystemUiRoot get() = systemUi
        override val lifecycleConsistent get() = alive
        override val inputFocused get() = focused
        override fun showsCredentialContent(): Boolean {
            probeCounter?.add(1)
            return shows
        }
    }

    private fun ready(o: SurfaceObservation) =
        o.outcome == SurfaceStage.SURFACE_READY_ACTIVE_ROOT ||
            o.outcome == SurfaceStage.SURFACE_READY_WINDOW

    @Test fun displayIdleShortCircuitsEveryOtherSignal() {
        val active = Candidate(shows = true)
        val windows = listOf(Candidate(shows = true, focused = true))
        val o = selectCredentialSurface(false, active, windows)
        assertEquals(SurfaceStage.DISPLAY_IDLE, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun activeRootFastPathNeverProbesWindows() {
        val probes = mutableListOf<Int>()
        val active = Candidate(shows = true)
        val o = selectCredentialSurface(true, active, listOf(Candidate(shows = true, probeCounter = probes)))
        assertEquals(SurfaceStage.SURFACE_READY_ACTIVE_ROOT, o.outcome)
        assertTrue(ready(o))
        assertEquals(0, probes.size)
        assertEquals("", o.context.joinToString())
    }

    @Test fun missingActiveRootAndWindowsReportsBothLayers() {
        val o = selectCredentialSurface(true, null, emptyList())
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_ABSENT), o.context)
        assertEquals(SurfaceStage.WINDOWS_EMPTY, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun foreignActiveRootResolvesThroughTrustedWindow() {
        val active = Candidate(systemUi = false, shows = true)
        val o = selectCredentialSurface(true, active, listOf(Candidate(shows = true)))
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_FOREIGN), o.context)
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, o.outcome)
        assertEquals(0, o.windowIndex)
    }

    @Test fun activeRootWithoutSurfaceResolvesThroughWindowSet() {
        val active = Candidate(shows = false)
        val o = selectCredentialSurface(true, active,
            listOf(Candidate(systemUi = false), Candidate(shows = true)))
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_NO_SURFACE), o.context)
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, o.outcome)
        // The index refers to the ORIGINAL window order, not the filtered chain.
        assertEquals(1, o.windowIndex)
    }

    @Test fun staleActiveRootFallsBackToWindows() {
        val active = Candidate(alive = false, shows = true)
        val o = selectCredentialSurface(true, active, listOf(Candidate(shows = true)))
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_STALE), o.context)
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, o.outcome)
    }

    @Test fun activeRootOnForeignDisplayIsNeverTrustedEvenShowingContent() {
        val active = Candidate(onDisplay = false, shows = true)
        val o = selectCredentialSurface(true, active, emptyList())
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_FOREIGN_DISPLAY), o.context)
        assertEquals(SurfaceStage.WINDOWS_EMPTY, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun nonDefaultDisplayWindowsAreNotEligible() {
        val o = selectCredentialSurface(true, Candidate(shows = false),
            listOf(Candidate(onDisplay = false, shows = true)))
        assertEquals(SurfaceStage.WINDOWS_EMPTY, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun windowsWithoutRetrievableContentReportTheirOwnStage() {
        val o = selectCredentialSurface(true, null, listOf(Candidate(content = false)))
        assertEquals(SurfaceStage.WINDOWS_NO_CONTENT, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun foreignWindowRootsReportTheirOwnStage() {
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(systemUi = false, shows = true)))
        assertEquals(SurfaceStage.WINDOWS_FOREIGN, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun staleSystemUiWindowTreesReportTheirOwnStage() {
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(alive = false, shows = true)))
        assertEquals(SurfaceStage.WINDOWS_STALE, o.outcome)
        assertFalse(ready(o))
    }

    @Test fun liveTrustedWindowWithoutSurfaceIsPendingThenReady() {
        // Late readiness: the same trusted window decides per fresh observation;
        // the resolver caches nothing between polls.
        val pending = selectCredentialSurface(true, null, listOf(Candidate(shows = false)))
        assertEquals(SurfaceStage.WINDOW_SURFACE_PENDING, pending.outcome)
        assertFalse(ready(pending))
        val readyNow = selectCredentialSurface(true, null, listOf(Candidate(shows = true)))
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, readyNow.outcome)
    }

    @Test fun multipleCredentialSurfacesWithoutUniqueFocusAreAmbiguous() {
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(shows = true), Candidate(shows = true)))
        assertEquals(SurfaceStage.SURFACE_AMBIGUOUS, o.outcome)
        assertEquals(-1, o.windowIndex)
        assertFalse(ready(o))
    }

    @Test fun multipleCredentialSurfacesWithUniqueFocusResolveThatWindow() {
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(shows = true), Candidate(shows = true, focused = true),
                Candidate(shows = true)))
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, o.outcome)
        assertEquals(1, o.windowIndex)
    }

    @Test fun focusTiebreakOnlyConsidersEligibleSurfaces() {
        // A focused foreign window must not decide between two SystemUI surfaces.
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(shows = true), Candidate(systemUi = false, shows = true, focused = true)))
        assertEquals(SurfaceStage.SURFACE_READY_WINDOW, o.outcome)
        assertEquals(0, o.windowIndex)
    }

    @Test fun traceTextCarriesClosedLabelsOnly() {
        val o = selectCredentialSurface(true, null,
            listOf(Candidate(shows = false)))
        assertTrue(o.traceText().matches(Regex("[A-Z_ ]+")))
        assertEquals("ACTIVE_ROOT_ABSENT WINDOW_SURFACE_PENDING", o.traceText())
    }

    @Test fun trustedButEmptyWindowListStillReportsActiveRootContext() {
        val o = selectCredentialSurface(true, Candidate(content = false, shows = true), emptyList())
        assertEquals(listOf(SurfaceStage.ACTIVE_ROOT_ABSENT), o.context)
        assertEquals(SurfaceStage.WINDOWS_EMPTY, o.outcome)
    }

    @Test fun nativeClickNeedsEnabledAndEitherClickableOrAnOfferedAction() {
        assertTrue(acceptsNativeClickAction(true, true, false))
        // The OEM-metadata case: not marked clickable but genuinely offering ACTION_CLICK.
        assertTrue(acceptsNativeClickAction(true, false, true))
        assertFalse(acceptsNativeClickAction(false, true, true))
        assertFalse(acceptsNativeClickAction(true, false, false))
    }

    // ------------------------------------------------------------------
    // Pure pre-reveal readiness mapping (display-ready-next): an awake
    // default display plus a live trusted SystemUI window is the only
    // observation that may permit the one reveal; power decides first.
    // ------------------------------------------------------------------

    private fun obs(outcome: SurfaceStage) = SurfaceObservation(emptyList(), outcome)

    @Test fun powerOffDecidesIdleBeforeAnySurfaceOutcome() {
        // Even a fully resolved credential observation cannot make an
        // un-interactive panel reveal-ready: uncertain/failed power reads
        // arrive here as displayPowerOn=false and stay not-ready.
        for (outcome in SurfaceStage.values()) {
            assertEquals(PhoneRevealReadiness.DISPLAY_IDLE, mapRevealReadiness(false, obs(outcome)))
        }
    }

    @Test fun liveTrustedWindowWithoutSurfaceIsTheOnlyRevealReadyOutcome() {
        assertEquals(PhoneRevealReadiness.REVEAL_READY, mapRevealReadiness(true, obs(SurfaceStage.WINDOW_SURFACE_PENDING)))
    }

    @Test fun resolvedCredentialSurfacesMapToEnterNotSwipe() {
        assertEquals(PhoneRevealReadiness.CREDENTIAL_VISIBLE,
            mapRevealReadiness(true, obs(SurfaceStage.SURFACE_READY_ACTIVE_ROOT)))
        assertEquals(PhoneRevealReadiness.CREDENTIAL_VISIBLE,
            mapRevealReadiness(true, obs(SurfaceStage.SURFACE_READY_WINDOW)))
    }

    @Test fun untrustedOrAmbiguousWindowOutcomesNeverQualifyReveal() {
        val notReady = listOf(
            SurfaceStage.DISPLAY_IDLE, SurfaceStage.WINDOWS_EMPTY, SurfaceStage.WINDOWS_NO_CONTENT,
            SurfaceStage.WINDOWS_FOREIGN, SurfaceStage.WINDOWS_STALE, SurfaceStage.SURFACE_AMBIGUOUS,
            SurfaceStage.ACTIVE_ROOT_ABSENT, SurfaceStage.ACTIVE_ROOT_FOREIGN,
            SurfaceStage.ACTIVE_ROOT_STALE, SurfaceStage.ACTIVE_ROOT_FOREIGN_DISPLAY,
            SurfaceStage.ACTIVE_ROOT_NO_SURFACE,
        )
        for (outcome in notReady) {
            val mapped = mapRevealReadiness(true, obs(outcome))
            assertNotEquals(outcome.toString(), PhoneRevealReadiness.REVEAL_READY, mapped)
            assertNotEquals(outcome.toString(), PhoneRevealReadiness.CREDENTIAL_VISIBLE, mapped)
            if (outcome == SurfaceStage.DISPLAY_IDLE) assertEquals(PhoneRevealReadiness.DISPLAY_IDLE, mapped)
            else assertEquals(outcome.toString(), PhoneRevealReadiness.SYSTEM_UI_PENDING, mapped)
        }
    }
}
