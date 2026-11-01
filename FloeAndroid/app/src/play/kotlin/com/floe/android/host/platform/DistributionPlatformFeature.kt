// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.platform

import android.content.Context
import com.floe.android.host.EmptyRuntimePlatformExtension
import com.floe.android.host.RuntimePlatformExtension

/**
 * PLAY-channel factory. Google Play physically excludes phone control,
 * embedded ADB and root access, so this channel contributes an inert extension
 * and must never import a Full controller, page, tool name or backend class.
 */
internal object DistributionPlatformFeature {
    fun create(context: Context): RuntimePlatformExtension =
        EmptyRuntimePlatformExtension
}
