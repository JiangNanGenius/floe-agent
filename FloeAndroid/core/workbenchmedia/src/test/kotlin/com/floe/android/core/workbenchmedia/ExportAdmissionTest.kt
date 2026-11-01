// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.export.ExportAdmission
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportAdmissionTest {
    @Test
    fun reservationsBoundQueuedPlusLiveAndCanBeCancelled() {
        val admission = ExportAdmission(maxLive = 2, maxRetainedTerminal = 3)
        assertTrue(admission.reserve())
        assertTrue(admission.reserve())
        assertFalse(admission.reserve())
        assertEquals(2, admission.reservedCount())

        admission.commitReservation()
        admission.commitReservation()
        assertEquals(2, admission.liveCount())
        assertFalse(admission.reserve())

        admission.releaseLive()
        assertEquals(1, admission.liveCount())
        assertTrue(admission.reserve())
        admission.cancelReservation()
        assertEquals(1, admission.liveCount())
        assertEquals(0, admission.reservedCount())
    }

    @Test
    fun terminalRetentionBoundPrunesOnlyTheExcess() {
        val admission = ExportAdmission(maxLive = 8, maxRetainedTerminal = 16)
        assertEquals(0, admission.terminalExcess(16))
        assertEquals(1, admission.terminalExcess(17))
        assertEquals(4, admission.terminalExcess(20))
    }
}
