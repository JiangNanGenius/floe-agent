// SPDX-License-Identifier: MPL-2.0
// Proposed JVM regression source. Authored only in this private lane; Main
// runs it in the batched JVM set. No compile/run claim here.
package com.floe.android.host.networkartifact

import com.floe.android.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Coverage limitation copy (Samsung device QA 2026-10-31: limitation sentences
 * stayed English in a Chinese UI).
 *
 * The core renderer remains the English/protocol authority for exports; the
 * app maps only its KNOWN user-facing templates to localized resources. The
 * counts and the truthful caveats (user-sampled, strongest real-scan AP not a
 * calibrated heatmap, no GPS/RTT/background/synthetic data, cached-scan age)
 * must survive the mapping. Unknown text is NEVER rewritten.
 */
class CoverageLimitationCopyTest {

    @Test
    fun fixedCaveatSentencesMapToTheirOwnCopy() {
        assertEquals(R.string.coverage_limitation_sampled, CoverageLimitationCopy.match(
            "Coverage is user-sampled at explicit points; it is not a continuous RF survey.")?.resourceId)
        assertEquals(R.string.coverage_limitation_strongest, CoverageLimitationCopy.match(
            "Signal level is the strongest access point seen by a real scan; it is not a calibrated heatmap.")?.resourceId)
        assertEquals(R.string.coverage_limitation_no_telemetry, CoverageLimitationCopy.match(
            "No GPS, RTT ranging, background scanning or synthetic access points are used.")?.resourceId)
        assertEquals(R.string.coverage_limitation_no_floorplan, CoverageLimitationCopy.match(
            "No floorplan is attached; the grid view is shown.")?.resourceId)
    }

    @Test
    fun countedSentencesKeepTheirRealCount() {
        assertEquals(CoverageLimitationCopy.Matched(R.string.coverage_limitation_stale, listOf(3)),
            CoverageLimitationCopy.match("3 points are older than 10 minutes."))
        assertEquals(CoverageLimitationCopy.Matched(R.string.coverage_limitation_cached, listOf(2)),
            CoverageLimitationCopy.match("2 points use a cached scan; its age is shown."))
        assertEquals(CoverageLimitationCopy.Matched(R.string.coverage_limitation_permission, listOf(4)),
            CoverageLimitationCopy.match("4 samples lack Wi-Fi scan permission/location services."))
        assertEquals(CoverageLimitationCopy.Matched(R.string.coverage_limitation_no_signal, listOf(1)),
            CoverageLimitationCopy.match("1 samples returned no access point."))
        assertEquals(CoverageLimitationCopy.Matched(R.string.coverage_limitation_unsampled, listOf(12)),
            CoverageLimitationCopy.match("12 grid cells have no sample."))
    }

    @Test
    fun unknownCopyIsNeverTranslatedOrGuessed() {
        assertNull(CoverageLimitationCopy.match("Wi-Fi scan failed with code scanUnavailable"))
        assertNull(CoverageLimitationCopy.match("3 points are older than 11 minutes."))
        assertNull(CoverageLimitationCopy.match(""))
        assertNull(CoverageLimitationCopy.match("no points are older than 10 minutes."))
    }
}
