// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.workbench.EnhancementBackendConfiguration
import com.floe.android.feature.workbench.WorkbenchEnhancementConfigurationHostApi
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Retained state for the super-resolution backend configuration sheet.
 *
 * The controller owns no secret: the key lives only in the save call
 * arguments and is handed to the App host, which writes the bytes to the
 * original credential store (zeroing its copy). Unknown codes from the
 * native save refusal surface as typed failures; known codes map to concise
 * actionable copy in the sheet.
 */
@Stable
class WorkbenchEnhancementConfigurationController(
    private val api: WorkbenchEnhancementConfigurationHostApi,
    private val scope: CoroutineScope,
) {
    var configuration: EnhancementBackendConfiguration? by mutableStateOf(null)
        private set
    var loading: Boolean by mutableStateOf(false)
        private set
    var saving: Boolean by mutableStateOf(false)
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var notice: Notice? by mutableStateOf(null)
        private set

    private var loadJob: Job? = null

    enum class Notice {
        SAVED,
        REVOKED,
    }

    val busy: Boolean get() = loading || saving

    /** True when a credential exists (row + key) — drives Revoke vs Save. */
    val configured: Boolean
        get() = configuration?.let {
            it.configured && it.credentialConfigured && !it.legacyProviderProfileReferenced
        } == true

    fun reload() {
        if (loading) return
        loading = true
        failure = null
        loadJob?.cancel()
        loadJob = scope.launch {
            try {
                configuration = api.getConfiguration()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                loading = false
            }
        }
    }

    /**
     * Saves the configuration. A non-blank [apiKey] is written to the
     * original credential store by the App host; null keeps the existing
     * key (display-name-only edits). The endpoint rides on the loaded
     * configuration (the native side supplies its documented default), so a
     * save before the first successful load is refused rather than guessed.
     */
    fun save(displayName: String?, apiKey: String?) {
        if (saving) return
        val current = configuration ?: run {
            reload()
            return
        }
        saving = true
        failure = null
        notice = null
        scope.launch {
            try {
                configuration = api.saveConfiguration(
                    displayName = displayName?.trim()?.ifEmpty { null },
                    endpointID = current.endpointID,
                    credentialAccount =
                        EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                    apiKey = apiKey,
                )
                notice = Notice.SAVED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                saving = false
            }
        }
    }

    /** Revokes the configuration and erases the credential reference. */
    fun revoke() {
        if (saving) return
        saving = true
        failure = null
        notice = null
        scope.launch {
            try {
                configuration = api.clearConfiguration()
                notice = Notice.REVOKED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                saving = false
            }
        }
    }

    fun dismiss() {
        loadJob?.cancel()
        loadJob = null
    }
}
