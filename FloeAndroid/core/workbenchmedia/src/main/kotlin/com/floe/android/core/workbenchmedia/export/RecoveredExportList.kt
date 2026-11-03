// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

import com.floe.android.feature.workbench.MediaExportStatus

/**
 * Exact de-dupe and final ordering for [listRecoveredExports]. Active in-memory
 * statuses are authoritative for a job id; a recovered journal entry with the
 * same id is never appended. Both inputs are expected to be already owner/root
 * filtered and bounded by the caller.
 */
internal object RecoveredExportList {
    private val ORDER = compareByDescending<MediaExportStatus> { it.updatedAt }
        .thenBy { it.jobID }

    fun merge(
        active: List<MediaExportStatus>,
        recovered: List<MediaExportStatus>,
        limit: Int,
    ): List<MediaExportStatus> {
        if (limit <= 0) return emptyList()
        val seen = HashSet<String>(limit * 2)
        val merged = ArrayList<MediaExportStatus>(limit)
        fun append(statuses: List<MediaExportStatus>) {
            for (status in statuses) {
                if (merged.size >= limit) return
                if (seen.add(status.jobID)) merged += status
            }
        }
        append(active.sortedWith(ORDER))
        append(recovered.sortedWith(ORDER))
        return merged.sortedWith(ORDER)
    }
}
