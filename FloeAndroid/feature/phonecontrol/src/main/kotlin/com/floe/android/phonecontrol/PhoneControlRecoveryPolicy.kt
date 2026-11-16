// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** Read-only recovery is permitted only for a proven pre-dispatch expiry. */
internal object PhoneControlRecoveryPolicy {
    fun eligible(
        reason: PhoneControlDenial,
        action: PhoneControlAction,
        observation: PhoneControlObservation,
        hasSensitiveField: Boolean,
        protectedWindow: Boolean,
    ): Boolean = reason == PhoneControlDenial.OBSERVATION_EXPIRED &&
        !(action is PhoneControlAction.SetText && action.sensitive) &&
        !hasSensitiveField && !protectedWindow && !observation.sensitiveWindow && !observation.navigationOnly

    fun samePage(old: PhoneControlObservation, fresh: PhoneControlObservation): Boolean =
        fresh.owner == old.owner && fresh.windowId == old.windowId &&
            fresh.packageName == old.packageName && fresh.displayId == old.displayId &&
            fresh.windowType == old.windowType && fresh.fenceGeneration == old.fenceGeneration &&
            fresh.pageGeneration == old.pageGeneration && !fresh.sensitiveWindow && !fresh.navigationOnly
}
