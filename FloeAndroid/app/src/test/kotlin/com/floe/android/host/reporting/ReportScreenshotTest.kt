package com.floe.android.host.reporting

import org.junit.Assert.*
import org.junit.Test

class ReportScreenshotTest {
    @Test fun fourImagesAndManifestFitTheWholeMobileBudget() {
        assertEquals(500 * 1024, ReportScreenshot.attachmentBudget(1))
        for (count in 1..4) assertTrue(ReportScreenshot.attachmentBudget(count) * count + 32768 <= 1024 * 1024)
    }
    @Test fun typicalScreenshotIsNotUnnecessarilyReduced() {
        assertEquals(1, ReportScreenshot.sampleSize(1080, 2400))
    }
    @Test fun longAndLargeImagesAreBoundedBeforeDecode() {
        for ((w, h) in listOf(1440 to 30000, 8000 to 8000, Int.MAX_VALUE to 1)) {
            val sample = ReportScreenshot.sampleSize(w, h)
            val dw = (w.toLong() + sample - 1) / sample
            val dh = (h.toLong() + sample - 1) / sample
            assertTrue(dw <= 4096 && dh <= 4096)
            assertTrue(dw * dh <= 4_000_000)
        }
    }
    @Test(expected = IllegalArgumentException::class) fun invalidBoundsAreRejectedBeforeAllocation() {
        ReportScreenshot.sampleSize(-1, 3000)
    }
}
