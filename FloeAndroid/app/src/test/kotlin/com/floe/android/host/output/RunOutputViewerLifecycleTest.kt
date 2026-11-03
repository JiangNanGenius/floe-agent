// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class RunOutputViewerLifecycleTest {
    @Test
    fun samplingBoundsRoundedDecodedDimensions() {
        for ((dimension, expected) in listOf(
            4096 to 1, 4097 to 2, 8000 to 2, 8191 to 2,
            8192 to 2, 8193 to 4, 12288 to 4, 32767 to 8,
        )) {
            val sample = runOutputImageSampleSize(dimension, dimension, 4096)
            assertEquals(expected, sample)
            assertTrue((dimension.toLong() + sample - 1) / sample <= 4096)
        }
        assertTrue(runCatching { runOutputImageSampleSize(0, 1, 4096) }.isFailure)
        assertTrue(runCatching { runOutputImageSampleSize(Int.MAX_VALUE, 1, 1) }.isFailure)
    }

    @Test
    fun closeRetainsSnapshotUntilViewerActuallyQuiesces() {
        val registry = RunOutputViewerLaunchRegistry()
        val staged = snapshot()
        val ticket = registry.admitStaging()
        assertTrue(registry.publishLive(ticket, staged) { true })
        assertTrue(registry.claim(staged.launchToken) is RunOutputViewerClaim.Live)
        assertTrue(registry.attachViewer(staged.launchToken))
        registry.userClose(staged.launchToken)
        assertTrue(registry.drainPurges().isEmpty())
        registry.viewerQuiesced(staged.launchToken)
        assertEquals(listOf(staged), registry.drainPurges())
        registry.viewerQuiesced(staged.launchToken)
        registry.userClose(staged.launchToken)
        assertTrue(registry.drainPurges().isEmpty())
    }

    @Test
    fun unknownTokenCannotClaimLiveOutputAndRetiredOwnerCannotReopen() {
        val registry = RunOutputViewerLaunchRegistry()
        val staged = snapshot()
        var current = true
        assertTrue(registry.publishLive(registry.admitStaging(), staged) { current })
        assertTrue(registry.claim(UUID.randomUUID().toString()) is RunOutputViewerClaim.Expired)
        assertTrue(registry.slotBusy())
        assertTrue(registry.drainPurges().isEmpty())
        current = false
        assertTrue(registry.claim(staged.launchToken) is RunOutputViewerClaim.Expired)
        assertFalse(registry.slotBusy())
        assertEquals(listOf(staged), registry.drainPurges())
    }

    private fun snapshot(): RunOutputViewerStaged {
        val token = UUID.randomUUID().toString()
        val directory = File("/virtual/RunOutputViewerPreview/$token")
        return RunOutputViewerStaged(
            token, directory, File(directory, "document.md"), 49,
            "0".repeat(64), "qa_report.md", "text/markdown",
            "11111111-2222-3333-4444-555555555555",
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "f".repeat(64),
        )
    }
}
