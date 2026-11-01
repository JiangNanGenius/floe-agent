// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import com.floe.android.FloeSettingsExternalSection
import com.floe.android.design.FloeIcons
import com.floe.android.feature.dataexchange.R
import com.floe.android.host.RuntimeHost

/** Settings category contributed by the App host after its real controller is
 * constructed. Appending this to the settings sheet introduces no route,
 * service or default permission; the page itself fails closed without a host. */
internal object C07DataExchangeFeature {
    fun settingsSection(host: RuntimeHost?): FloeSettingsExternalSection =
        FloeSettingsExternalSection(
            key = "data-exchange",
            titleRes = R.string.dataexchange_title,
            icon = FloeIcons.Folder,
            content = { C07DataExchangeSettingsDestination(host) },
        )
}
