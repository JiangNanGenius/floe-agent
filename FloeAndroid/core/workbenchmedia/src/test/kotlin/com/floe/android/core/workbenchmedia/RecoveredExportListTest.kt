// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.core.workbenchmedia.export.RecoveredExportList
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class RecoveredExportListTest {
    @Test
    fun activeStatusWinsExactDeDupeAndLimitIsApplied() {
        val active = listOf(
            status("a", "2026-11-01T00:00:03Z"),
            status("b", "2026-11-01T00:00:02Z"),
        )
        val recovered = listOf(
            status("a", "2026-11-01T00:00:04Z"),
            status("c", "2026-11-01T00:00:01Z"),
            status("c", "2026-11-01T00:00:01Z"),
        )
        assertEquals(
            listOf("a", "b", "c"),
            RecoveredExportList.merge(active, recovered, limit = 3).map { it.jobID },
        )
        assertEquals(
            listOf("a", "b"),
            RecoveredExportList.merge(active, recovered, limit = 2).map { it.jobID },
        )
    }

    @Test
    fun fullActiveLimitNeverLeaksARecoveredDuplicate() {
        val active = listOf(
            status("a", "2026-11-01T00:00:02Z"),
            status("b", "2026-11-01T00:00:01Z"),
        )
        val recovered = listOf(status("b", "2026-11-01T00:00:03Z"))
        val result = RecoveredExportList.merge(active, recovered, limit = 1)
        assertEquals(listOf("a"), result.map { it.jobID })
    }

    private fun status(jobID: String, updatedAt: String): MediaExportStatus =
        MediaExportStatus(
            jobID = jobID,
            kind = MediaExportKind.IMAGE,
            state = MediaExportState.COMPLETED,
            updatedAt = updatedAt,
        )
}
