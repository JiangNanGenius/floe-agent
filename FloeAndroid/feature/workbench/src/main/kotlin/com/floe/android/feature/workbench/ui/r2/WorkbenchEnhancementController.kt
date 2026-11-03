// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.EnhancementCapability
import com.floe.android.feature.workbench.EnhancementJobState
import com.floe.android.feature.workbench.EnhancementRequest
import com.floe.android.feature.workbench.EnhancementStatus
import com.floe.android.feature.workbench.WorkbenchEnhancementHostApi
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class EnhancementNotice {
    SUBMITTED,
    RUNNING,
    COMPLETED,
    FAILED,
    CANCELLED,
    OUTCOME_UNKNOWN,
}

/**
 * Retained enhancement state for one editor.
 *
 * The controller owns no capability decision and no measured fact: the
 * native service reports honest per-engine availability, real ffmpeg
 * interpolation progress, configured-backend super-resolution progress, and
 * measured receipts. Polling is bounded, stops with the retired editor, and
 * an `outcomeUnknown` job is never resubmitted automatically.
 */
@Stable
class WorkbenchEnhancementController(
    private val api: WorkbenchEnhancementHostApi,
    private val context: CreativeProjectContext,
    private val scope: CoroutineScope,
    private val isRetired: () -> Boolean,
) {
    var capability: EnhancementCapability? by mutableStateOf(null)
        private set
    var capabilityLoading: Boolean by mutableStateOf(false)
        private set
    var submitting: Boolean by mutableStateOf(false)
        private set
    var status: EnhancementStatus? by mutableStateOf(null)
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var notice: EnhancementNotice? by mutableStateOf(null)
        private set

    private var pollJob: Job? = null

    val busy: Boolean get() = submitting || pollJob != null

    fun reloadCapability() {
        if (capabilityLoading) return
        capabilityLoading = true
        failure = null
        scope.launch {
            try {
                capability = api.enhancementCapability(context)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                capabilityLoading = false
            }
        }
    }

    fun submit(request: EnhancementRequest) {
        if (submitting) return
        submitting = true
        failure = null
        notice = null
        scope.launch {
            try {
                val jobID = api.submitEnhancement(context, request)
                notice = EnhancementNotice.SUBMITTED
                startPolling(jobID)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                submitting = false
            }
        }
    }

    fun refresh() {
        val jobID = status?.jobID ?: return
        startPolling(jobID)
    }

    fun cancel() {
        val jobID = status?.jobID ?: return
        scope.launch {
            try {
                status = api.cancelEnhancement(context, jobID)
                notice = EnhancementNotice.CANCELLED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                pollJob?.cancel()
                pollJob = null
            }
        }
    }

    /**
     * Retries the original importAsset ownership for the completed job.
     * Updates the retained status; the sheet reloads the project envelope
     * when the imported asset identity appears.
     */
    fun importOutput() {
        val jobID = status?.jobID ?: return
        scope.launch {
            try {
                status = api.importEnhancementOutput(context, jobID)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            }
        }
    }

    fun dismiss() {
        pollJob?.cancel()
        pollJob = null
        status = null
        failure = null
        notice = null
    }

    private fun startPolling(jobID: String) {
        pollJob?.cancel()
        pollJob = scope.launch {
            try {
                while (true) {
                    if (isRetired()) return@launch
                    val current = api.enhancementStatus(context, jobID)
                    status = current
                    when {
                        current.receipt != null && current.state == EnhancementJobState.COMPLETED -> {
                            notice = EnhancementNotice.COMPLETED
                            return@launch
                        }
                        current.state == EnhancementJobState.CANCELLED -> {
                            notice = EnhancementNotice.CANCELLED
                            return@launch
                        }
                        current.state == EnhancementJobState.OUTCOME_UNKNOWN -> {
                            notice = EnhancementNotice.OUTCOME_UNKNOWN
                            return@launch
                        }
                        current.state.isTerminal -> {
                            notice = EnhancementNotice.FAILED
                            return@launch
                        }
                        else -> notice = EnhancementNotice.RUNNING
                    }
                    delay(1_000)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                pollJob = null
            }
        }
    }
}
