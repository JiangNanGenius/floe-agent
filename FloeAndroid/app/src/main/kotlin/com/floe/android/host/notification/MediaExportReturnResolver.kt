// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import com.floe.android.core.workbenchmedia.export.MediaExportReturns
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.host.creative.GenerationReturnDecision
import com.floe.android.host.creative.GenerationReturnRejection
import com.floe.android.host.creative.GenerationReturnTarget
import com.floe.android.host.creative.isExplicitReturnStorage

/** Reuse the original media-return coordinator; authority comes from the live export registry. */
internal fun resolveExportReturn(token: String, liveEpoch: Long?, availability: CreativeAvailability): GenerationReturnDecision {
    val export = MediaExportReturns.resolve(token)
        ?: return GenerationReturnDecision.Rejected(GenerationReturnRejection.UNKNOWN_TOKEN)
    if (availability != CreativeAvailability.Available) return GenerationReturnDecision.Rejected(GenerationReturnRejection.HOST_UNAVAILABLE)
    if (liveEpoch != export.epoch) return GenerationReturnDecision.Rejected(GenerationReturnRejection.EPOCH_MISMATCH)
    if (!isExplicitReturnStorage(export.context.storage) || export.context.origin?.isValid() == false)
        return GenerationReturnDecision.Rejected(GenerationReturnRejection.NO_CONTEXT)
    return GenerationReturnDecision.Authorized(GenerationReturnTarget(export.token, export.jobID, export.epoch,
        export.context.projectID, export.context.storage, export.context.origin))
}
