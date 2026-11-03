// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.workbench.WorkbenchEnhancementConfigurationHostApi
import com.floe.android.feature.workbench.ui.r2.WorkbenchEnhancementConfigurationController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Application-retained owner of the super-resolution backend configuration
 * flow shown in Settings.
 *
 * The native side owns the one typed configuration row and the credential in
 * the original stores; this controller only carries the retained UI state
 * and resolves the CURRENT configuration host lazily so a Root/epoch
 * replacement never leaves the settings sheet bound to a stale adapter.
 * There is deliberately no second credential store or cached key here.
 */
class MediaEnhancementSettingsHostController(
    apiProvider: () -> WorkbenchEnhancementConfigurationHostApi?,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val configuration = WorkbenchEnhancementConfigurationController(
        api = object : WorkbenchEnhancementConfigurationHostApi {
            private val live: WorkbenchEnhancementConfigurationHostApi
                get() = apiProvider()
                    ?: throw com.floe.android.feature.canvas.CreativeException(
                        "staleGeneration", "acceptedRootNotLive", retryable = true)

            override suspend fun getConfiguration() = live.getConfiguration()
            override suspend fun credentialReference(credentialAccount: String) =
                live.credentialReference(credentialAccount)
            override suspend fun saveConfiguration(
                displayName: String?,
                endpointID: String,
                credentialAccount: String,
                apiKey: String?,
            ) = live.saveConfiguration(displayName, endpointID, credentialAccount, apiKey)
            override suspend fun clearConfiguration() = live.clearConfiguration()
        },
        scope = scope,
    )
}
