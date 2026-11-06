// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** At most one text request and one attachment request. A slow screenshot
 * upload must not hold up a newly submitted text report. Report identities
 * and durable admission/retry state remain owned by DiagnosticReportService. */
internal class ReportUploadLanes {
    private val text = Mutex()
    private val attachments = Mutex()

    suspend fun <T> withPermit(hasAttachments: Boolean, action: suspend () -> T): T =
        (if (hasAttachments) attachments else text).withLock { action() }
}
