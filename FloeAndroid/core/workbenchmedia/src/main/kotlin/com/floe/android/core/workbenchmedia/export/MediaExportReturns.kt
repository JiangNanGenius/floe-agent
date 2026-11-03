// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

import com.floe.android.feature.workbench.CreativeProjectContext
import java.util.UUID

/** Produced from an actual accepted export, never from Intent project/path extras. */
data class MediaExportReturnTarget(
    val token: String,
    val jobID: String,
    val epoch: Long,
    val context: CreativeProjectContext,
)

object MediaExportReturns {
    const val ACTION = "com.floe.android.media.OPEN_OWNED_EXPORT"
    const val EXTRA_REQUEST_ID = "floe.notification.requestID"
    const val EXTRA_TOKEN = "floe.notification.exportToken"

    fun resolve(token: String): MediaExportReturnTarget? {
        if (runCatching { UUID.fromString(token).toString() == token }.getOrDefault(false).not()) return null
        return ExportRuntimeHolder.current()?.resolveReturn(token)
    }
}
