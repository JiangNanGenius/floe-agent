// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * G09-R2 generation DTOs.
 *
 * Only CONFIGURED provider routes are listed; availability is the actual
 * adapter state, not a universal promise. `costNote` is provider-reported text
 * or the honest "the provider account is authoritative" wording — never an
 * invented price. Provider credentials, raw provider task IDs and raw request
 * bodies never appear in these UI-facing DTOs.
 *
 * Image requests are durable image-request records. Video generation uses the
 * existing durable `MediaGenerationJob` store. In both cases the native host
 * writes the durable record BEFORE the provider call and an unknown transport
 * outcome is never automatically resubmitted.
 */
enum class GenerationKind(val wire: String) {
    IMAGE("image"),
    VIDEO("video"),
}

data class CodecContract(
    val mimeType: String,
    val width: Int,
    val height: Int,
    val frameRate: Double,
)

/**
 * Per-route parameter contract. `null` means the route does not constrain the
 * field; an empty list means the route exposes no value for it.
 */
data class GenerationParameterContract(
    val sizes: List<String>? = null,
    val aspectRatios: List<String>? = null,
    val resolutions: List<String>? = null,
    val durationSeconds: List<Double>? = null,
    val maxCount: Int = 1,
    val maxReferenceImages: Int = 0,
    val supportsImageToVideo: Boolean = false,
    val supportsFirstFrame: Boolean = false,
    val codecs: List<CodecContract> = emptyList(),
)

/**
 * Per-provider reference-image bounds. These are route-specific; the native
 * host validates the owned project asset and its bytes against this policy.
 */
data class ReferenceImagePolicy(
    val maxImages: Int = 0,
    val maxBytesPerImage: Long = 0,
    val acceptedMimeTypes: List<String> = emptyList(),
    val minWidth: Int? = null,
    val maxWidth: Int? = null,
    val minHeight: Int? = null,
    val maxHeight: Int? = null,
)

/**
 * One configured route. `available` is actual adapter availability; when
 * false, `unavailableReason` is a bounded honest reason (missing route,
 * account/configuration not present, route removed). It is never a developer
 * subscription gate on an otherwise configured provider.
 */
data class GenerationModelRoute(
    val routeID: String,
    val remoteModelID: String,
    val providerID: String,
    val providerName: String,
    val kind: GenerationKind,
    val enabled: Boolean,
    val available: Boolean,
    val unavailableReason: String? = null,
    val parameters: GenerationParameterContract = GenerationParameterContract(),
    val referenceImagePolicy: ReferenceImagePolicy = ReferenceImagePolicy(),
    val costNote: String,
)

data class GenerationModelCatalog(
    val image: List<GenerationModelRoute> = emptyList(),
    val video: List<GenerationModelRoute> = emptyList(),
)

data class ImageGenerationRequest(
    val prompt: String,
    val modelRouteID: String,
    val size: String? = null,
    val count: Int = 1,
    /** Owned project asset ID; never an arbitrary URL or absolute path. */
    val sourceAssetID: String? = null,
    /** Owned project asset IDs, validated against the route reference policy. */
    val referenceAssetIDs: List<String> = emptyList(),
    /** UI-minted per confirmed review; retry never silently mints a new one. */
    val idempotencyKey: String,
)

data class VideoGenerationRequest(
    val prompt: String,
    val modelRouteID: String,
    val durationSeconds: Double? = null,
    val aspectRatio: String? = null,
    val resolution: String? = null,
    /** Owned project asset IDs; no arbitrary URL/path authority. */
    val sourceAssetID: String? = null,
    val referenceAssetIDs: List<String> = emptyList(),
    val idempotencyKey: String,
)

data class ImageRequestHandle(
    val requestID: String,
    val projectID: String,
    val acceptedAt: String,
    val state: ImageRequestState,
    val idempotent: Boolean,
)

data class VideoJobHandle(
    val jobID: String,
    val projectID: String,
    val acceptedAt: String,
    val state: MediaJobState,
    val idempotent: Boolean,
)

enum class ImageRequestState(val wire: String) {
    SUBMITTED("submitted"),
    RUNNING("running"),
    COMPLETED("completed"),
    FAILED("failed"),
    INTERRUPTED("interrupted"),
    OUTCOME_UNKNOWN("outcomeUnknown"),
    DISMISSED("dismissed"),
}

enum class MediaJobState(val wire: String) {
    SUBMITTED("submitted"),
    RUNNING("running"),
    WAITING_FOR_PROVIDER("waitingForProvider"),
    DOWNLOADING("downloading"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    INTERRUPTED("interrupted"),
    OUTCOME_UNKNOWN("outcomeUnknown"),
}

enum class MediaCandidateState(val wire: String) {
    PENDING("pending"),
    ACCEPTED("accepted"),
    REJECTED("rejected"),
    STALE("stale"),
}

enum class CandidateDeliveryOutcome(val wire: String) {
    READY("ready"),
    NOT_READY("notReady"),
    OUTCOME_UNKNOWN("outcomeUnknown"),
}

data class MediaCandidate(
    val candidateID: String,
    val projectID: String,
    val kind: GenerationKind,
    val modelDisplayName: String? = null,
    val createdAt: String,
    val byteCount: Long,
    val sha256: String,
    /** Native-verified safe relative path under the project media root. */
    val relativePath: String,
    val requestID: String? = null,
    val state: MediaCandidateState = MediaCandidateState.PENDING,
)

data class ImageRequestStatus(
    val requestID: String,
    val projectID: String,
    val state: ImageRequestState,
    val submittedAt: String,
    val updatedAt: String,
    val candidate: MediaCandidate? = null,
    val errorCode: String? = null,
    val retryable: Boolean = false,
)

/**
 * UI-safe job status. `providerTaskReferencePresent` says only that the durable
 * job holds an internal provider reference; the raw task ID never crosses this
 * boundary.
 */
data class MediaJobStatus(
    val jobID: String,
    val projectID: String,
    val state: MediaJobState,
    val updatedAt: String,
    /** Honest provider-reported/estimated hint 0...1, or null when unknown. */
    val progressHint: Double? = null,
    val resultAvailable: Boolean = false,
    val providerTaskReferencePresent: Boolean = false,
    val lastErrorCode: String? = null,
    val retryable: Boolean = false,
    val canCancel: Boolean = false,
)

data class DeliveredCandidate(
    val outcome: CandidateDeliveryOutcome,
    val candidate: MediaCandidate? = null,
    val reason: String? = null,
)

data class CandidateMutationReceipt(
    val candidateID: String,
    val projectID: String,
    val state: MediaCandidateState,
    val opID: String,
    val idempotent: Boolean,
)

/** Frozen state spellings on the `floe.creative/6` wire. */
object GenerationWire {
    val IMAGE_REQUEST_STATES: List<String> = listOf(
        "submitted", "running", "completed", "failed", "interrupted",
        "outcomeUnknown", "dismissed")
    val JOB_STATES: List<String> = listOf(
        "submitted", "running", "waitingForProvider", "downloading", "completed",
        "failed", "cancelled", "interrupted", "outcomeUnknown")
    val CANDIDATE_STATES: List<String> = listOf("pending", "accepted", "rejected", "stale")
    val CANDIDATE_DELIVERY_OUTCOMES: List<String> = listOf(
        "ready", "notReady", "outcomeUnknown")
}
