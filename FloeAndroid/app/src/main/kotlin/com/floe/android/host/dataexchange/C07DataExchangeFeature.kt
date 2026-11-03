// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import com.floe.android.StorageSettingsEntry
import com.floe.android.FloeSettingsExternalSection
import com.floe.android.design.FloeIcons
import com.floe.android.host.RuntimeHost

/** Settings category contributed by the App host after its real controller is
 * constructed. Appending this to the settings sheet introduces no route,
 * service or default permission; the page itself fails closed without a host. */
internal object C07DataExchangeFeature {
    fun settingsSection(host: RuntimeHost?): FloeSettingsExternalSection =
        FloeSettingsExternalSection(
            key = "data-exchange",
            titleRes = com.floe.android.R.string.storage_data_management,
            icon = FloeIcons.Folder,
            content = {
                Column(Modifier.fillMaxSize()) {
                    StorageSettingsEntry()
                    com.floe.android.FontSettingsEntry()
                    Box(Modifier.weight(1f)) { C07DataExchangeSettingsDestination(host) }
                }
            },
        )
}
