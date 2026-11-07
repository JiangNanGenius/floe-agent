// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context

/** Play keeps the ordinary system-settings route and declares no direct
 * exemption-request permission. Real background status is shared. */
internal object BackgroundExemptionRequest {
    fun launch(@Suppress("UNUSED_PARAMETER") context: Context): Boolean = false
}
