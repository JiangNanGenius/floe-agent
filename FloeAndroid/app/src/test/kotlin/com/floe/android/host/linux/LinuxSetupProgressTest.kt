// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.junit.Assert.*
import org.junit.Test

class LinuxSetupProgressTest {
    @Test fun downloadPercentAndRateComeFromRealCounters() {
        val m = LinuxSetupProgressMeter()
        assertNull(m.sample(LinuxSetupStage.DOWNLOAD, 0, 4_000, 0).bytesPerSecond)
        val p = m.sample(LinuxSetupStage.DOWNLOAD, 2_000, 4_000, 1_000)
        assertEquals(50, p.percent)
        assertEquals(2_000L, p.bytesPerSecond)
    }
    @Test fun unknownLengthKeepsBytesAndRateWithoutInventingPercent() {
        val m = LinuxSetupProgressMeter()
        m.sample(LinuxSetupStage.DOWNLOAD, 100, -1, 0)
        val p = m.sample(LinuxSetupStage.DOWNLOAD, 600, -1, 1_000)
        assertNull(p.percent)
        assertEquals(600L, p.bytes)
        assertEquals(500L, p.bytesPerSecond)
    }
    @Test fun stalledTransferEventuallyShowsZeroRate() {
        val m = LinuxSetupProgressMeter()
        m.sample(LinuxSetupStage.DOWNLOAD, 0, 4_000, 0)
        m.sample(LinuxSetupStage.DOWNLOAD, 2_000, 4_000, 1_000)
        m.sample(LinuxSetupStage.DOWNLOAD, 2_000, 4_000, 6_000)
        assertEquals(0L, m.sample(LinuxSetupStage.DOWNLOAD, 2_000, 4_000, 7_000).bytesPerSecond)
    }
    @Test fun retryAndClockResetCannotReuseAnOlderTransfersRate() {
        val m = LinuxSetupProgressMeter()
        m.sample(LinuxSetupStage.DOWNLOAD, 1_000, 4_000, 1_000)
        m.sample(LinuxSetupStage.DOWNLOAD, 2_000, 4_000, 2_000)
        assertNull(m.sample(LinuxSetupStage.DOWNLOAD, 0, 4_000, 2_500).bytesPerSecond)
        assertNull(m.sample(LinuxSetupStage.DOWNLOAD, 100, 4_000, 100).bytesPerSecond)
    }
    @Test fun extractionUsesItsOwnCountsInsteadOfTransferPercentOrRate() {
        val m = LinuxSetupProgressMeter()
        m.sample(LinuxSetupStage.DOWNLOAD, 4_000, 4_000, 1_000)
        val p = m.sample(LinuxSetupStage.EXTRACT, 4_000, 4_000, 2_000, 123, 20_000)
        assertNull(p.percent)
        assertNull(p.bytesPerSecond)
        assertEquals(123L, p.entries)
        assertEquals(20_000L, p.extractedBytes)
    }
    @Test fun componentCopyDoesNotCountAsLinuxDownloadAndStageResetDropsRate() {
        val m = LinuxSetupProgressMeter()
        m.sample(LinuxSetupStage.COMPONENT_FILE, 0, 1_000, 0)
        assertEquals(50, m.sample(LinuxSetupStage.COMPONENT_FILE, 500, 1_000, 1_000).percent)
        assertNull(m.sample(LinuxSetupStage.DOWNLOAD, 500, 1_000, 2_000).bytesPerSecond)
    }
}
