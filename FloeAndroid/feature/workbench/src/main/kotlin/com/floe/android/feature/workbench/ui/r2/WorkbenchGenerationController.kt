// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.workbench.CandidateDeliveryOutcome
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.DeliveredCandidate
import com.floe.android.feature.workbench.GenerationModelCatalog
import com.floe.android.feature.workbench.GenerationModelRoute
import com.floe.android.feature.workbench.GenerationKind
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageRequestHandle
import com.floe.android.feature.workbench.ImageRequestState
import com.floe.android.feature.workbench.ImageRequestStatus
import com.floe.android.feature.workbench.MediaCandidate
import com.floe.android.feature.workbench.MediaCandidateState
import com.floe.android.feature.workbench.MediaJobState
import com.floe.android.feature.workbench.MediaJobStatus
import com.floe.android.feature.workbench.VideoGenerationRequest
import com.floe.android.feature.workbench.VideoJobHandle
import com.floe.android.feature.workbench.WorkbenchGenerationHostApi
import com.floe.android.feature.workbench.WorkbenchR2Limits
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class GenerationNotice {
    IMAGE_SUBMITTED,
    VIDEO_SUBMITTED,
    JOB_REFRESHED,
    JOB_CANCELLED,
    RESULT_DELIVERED,
    RESULT_NOT_READY,
    CANDIDATE_ACCEPTED,
    CANDIDATE_REJECTED,
    REQUEST_DISMISSED,
    OUTCOME_UNKNOWN,
    UNKNOWN_REQUEST,
}

/**
 * Retained generation/candidate state for one editor.
 *
 * Catalog routes come from the native host (actually configured providers,
 * model-specific parameters); nothing here hard-codes a model or a price.
 * Provider credentials stay native and never enter this state.
 *
 * Jobs and image requests are durable and owner-bound: they keep running when
 * the editor closes, and the list is reloaded when the project is opened
 * again. Polling is bounded and stops with the retired editor; an
 * `outcomeUnknown` submission is never resubmitted automatically.
 */
@Stable
class WorkbenchGenerationController(
    private val api: WorkbenchGenerationHostApi,
    private val context: CreativeProjectContext,
    private val scope: CoroutineScope,
    private val isRetired: () -> Boolean,
    private val onProjectMutated: () -> Unit,
) {
    var catalog: GenerationModelCatalog? by mutableStateOf(null)
        private set
    var loadingCatalog: Boolean by mutableStateOf(false)
        private set
    var refreshing: Boolean by mutableStateOf(false)
        private set
    var imageSubmitting: Boolean by mutableStateOf(false)
        private set
    var videoSubmitting: Boolean by mutableStateOf(false)
        private set
    var imageRequests: List<ImageRequestStatus> by mutableStateOf(emptyList())
        private set
    var jobs: List<MediaJobStatus> by mutableStateOf(emptyList())
        private set
    var candidates: List<MediaCandidate> by mutableStateOf(emptyList())
        private set
    var busyJobs: Set<String> by mutableStateOf(emptySet())
        private set
    var busyCandidates: Set<String> by mutableStateOf(emptySet())
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var notice: GenerationNotice? by mutableStateOf(null)
        private set

    /** Image idempotency keys whose transport outcome is not known yet. */
    var unknownImageKeys: Set<String> by mutableStateOf(emptySet())
        private set
    var unknownVideoKeys: Set<String> by mutableStateOf(emptySet())
        private set

    /**
     * The last confirmed review that did not reach a confirmed handle. It is
     * retained across rotation/outcomeUnknown so a manual retry reuses the
     * SAME idempotency key. No automatic resubmission ever happens.
     */
    var pendingImageRequest: ImageGenerationRequest? by mutableStateOf(null)
        private set
    var pendingVideoRequest: VideoGenerationRequest? by mutableStateOf(null)
        private set

    private var pollJob: Job? = null

    val imageRoutes: List<GenerationModelRoute>
        get() = catalog?.image.orEmpty()
    val videoRoutes: List<GenerationModelRoute>
        get() = catalog?.video.orEmpty()
    val anyAvailableRoute: Boolean
        get() = catalog != null &&
            (catalog!!.image.any { it.enabled && it.available } ||
                catalog!!.video.any { it.enabled && it.available })

    fun start() {
        if (isRetired()) return
        scope.launch { loadCatalog() }
        scope.launch { refreshLists() }
        startPolling()
    }

    fun stop() {
        pollJob?.cancel()
        pollJob = null
    }

    fun clearFailure() {
        failure = null
    }

    fun clearNotice() {
        notice = null
    }

    fun refreshAll() {
        scope.launch { loadCatalog() }
        scope.launch { refreshLists() }
    }

    private fun startPolling() {
        if (pollJob != null) return
        pollJob = scope.launch {
            while (!isRetired()) {
                delay(POLL_INTERVAL_MS)
                if (isRetired()) break
                val activeJobs = jobs.filter { it.isActive() }
                if (activeJobs.isEmpty() && imageRequests.none { it.isActive() }) continue
                for (job in activeJobs.take(MAX_POLL_ITEMS)) {
                    if (isRetired()) break
                    runCatching { api.refreshJob(context, job.jobID) }
                        .getOrNull()
                        ?.let { replaceJob(it) }
                }
                for (request in imageRequests.filter { it.isActive() }.take(MAX_POLL_ITEMS)) {
                    if (isRetired()) break
                    runCatching { api.imageStatus(context, request.requestID) }
                        .getOrNull()
                        ?.let { replaceImageRequest(it) }
                }
            }
        }
    }

    private suspend fun loadCatalog() {
        if (isRetired()) return
        loadingCatalog = true
        try {
            val value = api.models()
            if (!isRetired()) catalog = value
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (!isRetired()) failure = MediaFailures.from(error)
        } finally {
            loadingCatalog = false
        }
    }

    suspend fun refreshLists() {
        if (isRetired()) return
        refreshing = true
        var firstError: Throwable? = null
        try {
            runCatching { api.jobs(context, WorkbenchR2Limits.JOB_LIST_DEFAULT) }
                .onSuccess {
                    if (!isRetired()) jobs = it.sortedByDescending { job -> job.updatedAt }
                }
                .onFailure { if (firstError == null) firstError = it }
            runCatching { api.candidates(context) }
                .onSuccess { if (!isRetired()) candidates = it }
                .onFailure { if (firstError == null) firstError = it }
            val knownRequests = imageRequests
            if (knownRequests.isNotEmpty()) {
                val updated = ArrayList<ImageRequestStatus>(knownRequests.size)
                for (request in knownRequests.take(MAX_POLL_ITEMS)) {
                    if (isRetired()) break
                    runCatching { api.imageStatus(context, request.requestID) }
                        .getOrNull()
                        ?.let { updated += it }
                }
                if (!isRetired() && updated.isNotEmpty()) imageRequests = mergeImageRequests(updated)
            }
        } finally {
            if (!isRetired()) {
                refreshing = false
                firstError?.let { failure = MediaFailures.from(it) }
            }
        }
    }

    // MARK: - Submit

    fun submitImageAtRevision(request: ImageGenerationRequest, expectedRevision: Long) {
        if (isRetired() || imageSubmitting) return
        pendingImageRequest = request
        scope.launch {
            imageSubmitting = true
            failure = null
            try {
                handleImageHandle(
                    handle = api.submitImage(
                        context = context,
                        expectedRevision = expectedRevision,
                        opID = java.util.UUID.randomUUID().toString(),
                        request = request,
                    ),
                    idempotencyKey = request.idempotencyKey,
                )
                pendingImageRequest = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                onSubmitFailure(error, request.idempotencyKey, video = false)
            } finally {
                imageSubmitting = false
            }
        }
    }

    fun retryPendingImage(expectedRevision: Long) {
        val request = pendingImageRequest ?: return
        submitImageAtRevision(request, expectedRevision)
    }

    fun discardPendingImage() {
        val request = pendingImageRequest ?: return
        unknownImageKeys = unknownImageKeys - request.idempotencyKey
        pendingImageRequest = null
        notice = null
    }

    fun submitVideoAtRevision(request: VideoGenerationRequest, expectedRevision: Long) {
        if (isRetired() || videoSubmitting) return
        pendingVideoRequest = request
        scope.launch {
            videoSubmitting = true
            failure = null
            try {
                handleVideoHandle(
                    handle = api.submitVideo(
                        context = context,
                        expectedRevision = expectedRevision,
                        opID = java.util.UUID.randomUUID().toString(),
                        request = request,
                    ),
                    idempotencyKey = request.idempotencyKey,
                )
                pendingVideoRequest = null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                onSubmitFailure(error, request.idempotencyKey, video = true)
            } finally {
                videoSubmitting = false
            }
        }
    }

    fun retryPendingVideo(expectedRevision: Long) {
        val request = pendingVideoRequest ?: return
        submitVideoAtRevision(request, expectedRevision)
    }

    fun discardPendingVideo() {
        val request = pendingVideoRequest ?: return
        unknownVideoKeys = unknownVideoKeys - request.idempotencyKey
        pendingVideoRequest = null
        notice = null
    }

    private suspend fun handleImageHandle(
        handle: ImageRequestHandle,
        idempotencyKey: String,
    ) {
        unknownImageKeys = unknownImageKeys - idempotencyKey
        val status = runCatching { api.imageStatus(context, handle.requestID) }.getOrNull()
        if (!isRetired()) {
            replaceImageRequest(
                status ?: ImageRequestStatus(
                    requestID = handle.requestID,
                    projectID = handle.projectID,
                    state = handle.state,
                    submittedAt = handle.acceptedAt,
                    updatedAt = handle.acceptedAt,
                ),
            )
            notice = GenerationNotice.IMAGE_SUBMITTED
        }
    }

    private suspend fun handleVideoHandle(
        handle: VideoJobHandle,
        idempotencyKey: String,
    ) {
        unknownVideoKeys = unknownVideoKeys - idempotencyKey
        val job = runCatching { api.refreshJob(context, handle.jobID) }.getOrNull()
        if (!isRetired()) {
            job?.let { replaceJob(it) }
            notice = GenerationNotice.VIDEO_SUBMITTED
        }
    }

    private fun onSubmitFailure(error: Throwable, idempotencyKey: String, video: Boolean) {
        val mapped = MediaFailures.from(error)
        failure = mapped
        val unknown = mapped.kind ==
            com.floe.android.feature.workbench.ui.presentation.MediaFailureKind.OUTCOME_UNKNOWN
        if (unknown) {
            if (video) unknownVideoKeys = unknownVideoKeys + idempotencyKey
            else unknownImageKeys = unknownImageKeys + idempotencyKey
            notice = GenerationNotice.OUTCOME_UNKNOWN
        }
    }

    // MARK: - Image requests

    fun refreshImageRequest(requestID: String) {
        runJobAction(requestID) {
            replaceImageRequest(api.imageStatus(context, requestID))
            notice = GenerationNotice.JOB_REFRESHED
        }
    }

    fun dismissImageRequest(requestID: String) {
        runJobAction(requestID) {
            api.dismissImageRequest(
                context,
                requestID,
                java.util.UUID.randomUUID().toString(),
            )
            imageRequests = imageRequests.filterNot { it.requestID == requestID }
            notice = GenerationNotice.REQUEST_DISMISSED
        }
    }

    // MARK: - Jobs

    fun refreshJob(jobID: String) {
        runJobAction(jobID) {
            replaceJob(api.refreshJob(context, jobID))
            notice = GenerationNotice.JOB_REFRESHED
        }
    }

    fun cancelJob(jobID: String) {
        runJobAction(jobID) {
            replaceJob(api.cancelJob(context, jobID, java.util.UUID.randomUUID().toString()))
            notice = GenerationNotice.JOB_CANCELLED
        }
    }

    fun deliverResult(jobID: String) {
        runJobAction(jobID) {
            val delivered: DeliveredCandidate = api.deliverResult(
                context,
                jobID,
                java.util.UUID.randomUUID().toString(),
            )
            when (delivered.outcome) {
                CandidateDeliveryOutcome.READY -> {
                    delivered.candidate?.let { candidate ->
                        candidates = upsertCandidate(candidates, candidate)
                    }
                    notice = GenerationNotice.RESULT_DELIVERED
                }
                CandidateDeliveryOutcome.NOT_READY -> {
                    notice = GenerationNotice.RESULT_NOT_READY
                }
                CandidateDeliveryOutcome.OUTCOME_UNKNOWN -> {
                    failure = MediaFailure(
                        com.floe.android.feature.workbench.ui.presentation.MediaFailureKind.OUTCOME_UNKNOWN,
                        "outcomeUnknown",
                    )
                    notice = GenerationNotice.OUTCOME_UNKNOWN
                }
            }
            runCatching { api.refreshJob(context, jobID) }.getOrNull()?.let { replaceJob(it) }
        }
    }

    // MARK: - Candidates

    fun rejectCandidate(candidateID: String) {
        if (isRetired() || candidateID in busyCandidates) return
        scope.launch {
            busyCandidates = busyCandidates + candidateID
            failure = null
            try {
                val receipt = api.rejectCandidate(
                    context,
                    candidateID,
                    java.util.UUID.randomUUID().toString(),
                )
                if (!isRetired()) {
                    candidates = candidates.map {
                        if (it.candidateID == receipt.candidateID) it.copy(state = receipt.state) else it
                    }
                    notice = GenerationNotice.CANDIDATE_REJECTED
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (!isRetired()) failure = MediaFailures.from(error)
            } finally {
                busyCandidates = busyCandidates - candidateID
            }
        }
    }

    fun acceptCandidate(candidateID: String, expectedRevision: Long) {
        if (isRetired() || candidateID in busyCandidates) return
        scope.launch {
            busyCandidates = busyCandidates + candidateID
            failure = null
            try {
                api.acceptCandidate(
                    context,
                    expectedRevision,
                    candidateID,
                    java.util.UUID.randomUUID().toString(),
                )
                if (!isRetired()) {
                    candidates = candidates.map {
                        if (it.candidateID == candidateID) it.copy(state = MediaCandidateState.ACCEPTED) else it
                    }
                    notice = GenerationNotice.CANDIDATE_ACCEPTED
                    onProjectMutated()
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (!isRetired()) failure = MediaFailures.from(error)
            } finally {
                busyCandidates = busyCandidates - candidateID
            }
        }
    }

    // MARK: - Helpers

    private fun runJobAction(jobID: String, block: suspend () -> Unit) {
        if (isRetired() || jobID in busyJobs) return
        scope.launch {
            busyJobs = busyJobs + jobID
            failure = null
            try {
                block()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (!isRetired()) failure = MediaFailures.from(error)
            } finally {
                busyJobs = busyJobs - jobID
            }
        }
    }

    private fun replaceJob(job: MediaJobStatus) {
        if (isRetired()) return
        jobs = mergeJobs(jobs + job)
    }

    private fun replaceImageRequest(request: ImageRequestStatus) {
        if (isRetired()) return
        imageRequests = mergeImageRequests(imageRequests + request)
    }

    private fun mergeJobs(next: List<MediaJobStatus>): List<MediaJobStatus> {
        val byID = LinkedHashMap<String, MediaJobStatus>()
        for (job in jobs) byID[job.jobID] = job
        for (job in next) byID[job.jobID] = job
        return byID.values.sortedByDescending { it.updatedAt }
    }

    private fun mergeImageRequests(
        next: List<ImageRequestStatus>,
    ): List<ImageRequestStatus> {
        val byID = LinkedHashMap<String, ImageRequestStatus>()
        for (request in imageRequests) byID[request.requestID] = request
        for (request in next) byID[request.requestID] = request
        return byID.values.sortedByDescending { it.updatedAt }
    }

    private fun upsertCandidate(
        list: List<MediaCandidate>,
        candidate: MediaCandidate,
    ): List<MediaCandidate> {
        val index = list.indexOfFirst { it.candidateID == candidate.candidateID }
        if (index < 0) return list + candidate
        return list.toMutableList().also { it[index] = candidate }
    }

    private fun ImageRequestStatus.isActive(): Boolean =
        state == ImageRequestState.SUBMITTED ||
            state == ImageRequestState.RUNNING ||
            state == ImageRequestState.OUTCOME_UNKNOWN

    private fun MediaJobStatus.isActive(): Boolean =
        state == MediaJobState.SUBMITTED ||
            state == MediaJobState.RUNNING ||
            state == MediaJobState.WAITING_FOR_PROVIDER ||
            state == MediaJobState.DOWNLOADING ||
            state == MediaJobState.OUTCOME_UNKNOWN

    fun routesFor(kind: GenerationKind): List<GenerationModelRoute> =
        when (kind) {
            GenerationKind.IMAGE -> imageRoutes
            GenerationKind.VIDEO -> videoRoutes
        }

    private companion object {
        const val POLL_INTERVAL_MS = 4_000L
        const val MAX_POLL_ITEMS = 8
    }
}
