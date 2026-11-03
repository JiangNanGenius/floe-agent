// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CandidateDeliveryOutcome
import com.floe.android.feature.workbench.CandidateMutationReceipt
import com.floe.android.feature.workbench.CodecContract
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.DeliveredCandidate
import com.floe.android.feature.workbench.GenerationKind
import com.floe.android.feature.workbench.GenerationModelCatalog
import com.floe.android.feature.workbench.GenerationModelRoute
import com.floe.android.feature.workbench.GenerationParameterContract
import com.floe.android.feature.workbench.ImageGenerationRequest
import com.floe.android.feature.workbench.ImageRequestHandle
import com.floe.android.feature.workbench.ImageRequestState
import com.floe.android.feature.workbench.ImageRequestStatus
import com.floe.android.feature.workbench.MediaCandidate
import com.floe.android.feature.workbench.MediaCandidateState
import com.floe.android.feature.workbench.MediaJobState
import com.floe.android.feature.workbench.MediaJobStatus
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.ReferenceImagePolicy
import com.floe.android.feature.workbench.VideoGenerationRequest
import com.floe.android.feature.workbench.VideoJobHandle
import com.floe.android.feature.workbench.WorkbenchGenerationHostApi
import com.floe.android.feature.workbench.WorkbenchR2Limits
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Production App adapter for the frozen [WorkbenchGenerationHostApi].
 *
 * Every call crosses the existing `floe_bridge_exchange` C ABI as
 * `floe.creative/6`; nothing is persisted in Kotlin. The native service owns
 * the durable job/candidate state and the provider credentials. Unknown
 * outcomes throw [CreativeException] with `outcomeUnknown` and are never
 * retried here.
 *
 * The frozen action list has no separate jobs verb, so the bounded list uses
 * the existing `generation.video.status` action with no `jobID` (the native
 * owner returns `{jobs:[...]}` from the same durable store).
 */
class CreativeR2GenerationHost(
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val foreground: GenerationForegroundPort = GenerationForegroundOwner,
) : WorkbenchGenerationHostApi {
    private val exchangeMutex = Mutex()

    override suspend fun models(): GenerationModelCatalog = withContext(ioDispatcher) {
        decodeCatalog(command("generation.models", buildJsonObject { }))
    }

    override suspend fun submitImage(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: ImageGenerationRequest,
    ): ImageRequestHandle = withContext(ioDispatcher) {
        requireOperation(opID)
        if (expectedRevision < 0) {
            throw CreativeException("invalidRequest", "invalidRevision")
        }
        if (request.count !in 1..4) {
            throw CreativeException("invalidRequest", "invalidImageCount")
        }
        val response = command("generation.image.submit", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonObject("request") {
                put("prompt", request.prompt)
                put("modelRouteID", request.modelRouteID)
                request.size?.let { put("size", it) }
                put("count", request.count)
                request.sourceAssetID?.let { put("sourceAssetID", it) }
                putJsonArray("referenceAssetIDs") {
                    request.referenceAssetIDs.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) }
                }
                put("idempotencyKey", request.idempotencyKey)
            }
        })
        val handle = decodeImageHandle(response)
        if (!imageTerminal(handle.state)) {
            epoch()?.let { liveEpoch ->
                // The native submit response is already accepted; only a
                // confirmed registered foreground claim may capture the REAL
                // submitted storage/origin for notification return.
                foreground.acquire(handle.requestID, liveEpoch, context.projectID)
                    ?.let { claim ->
                        foreground.captureReturnContext(claim, context)
                    }
            }
        }
        handle
    }

    override suspend fun imageStatus(
        context: CreativeProjectContext,
        requestID: String,
    ): ImageRequestStatus = withContext(ioDispatcher) {
        val response = command("generation.image.status", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("requestID", requestID)
        })
        decodeImageStatus(response)
    }

    override suspend fun dismissImageRequest(
        context: CreativeProjectContext,
        requestID: String,
        opID: String,
    ) {
        withContext(ioDispatcher) {
            requireOperation(opID)
            command("generation.image.dismiss", buildJsonObject {
                put("context", R2MediaWire.encodeContext(context))
                put("requestID", requestID)
                put("opID", opID)
            })
            epoch()?.let { liveEpoch ->
                foreground.cancel(requestID, liveEpoch)
            }
        }
    }

    override suspend fun submitVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        request: VideoGenerationRequest,
    ): VideoJobHandle = withContext(ioDispatcher) {
        requireOperation(opID)
        if (expectedRevision < 0) {
            throw CreativeException("invalidRequest", "invalidRevision")
        }
        val response = command("generation.video.submit", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonObject("request") {
                put("prompt", request.prompt)
                put("modelRouteID", request.modelRouteID)
                request.durationSeconds?.let { put("durationSeconds", it) }
                request.aspectRatio?.let { put("aspectRatio", it) }
                request.resolution?.let { put("resolution", it) }
                request.sourceAssetID?.let { put("sourceAssetID", it) }
                putJsonArray("referenceAssetIDs") {
                    request.referenceAssetIDs.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) }
                }
                put("idempotencyKey", request.idempotencyKey)
            }
        })
        val handle = decodeVideoHandle(response)
        if (!jobTerminal(handle.state)) {
            epoch()?.let { liveEpoch ->
                foreground.acquire(handle.jobID, liveEpoch, context.projectID)
                    ?.let { claim ->
                        foreground.captureReturnContext(claim, context)
                    }
            }
        }
        handle
    }

    override suspend fun jobs(
        context: CreativeProjectContext,
        limit: Int,
    ): List<MediaJobStatus> = withContext(ioDispatcher) {
        val bounded = limit.coerceIn(1, WorkbenchR2Limits.JOB_LIST_MAX)
        val response = command("generation.video.status", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("limit", bounded)
        })
        val jobs = response.array("jobs")
            ?: throw CreativeException("invalidResponse", "missingJobList")
        val decoded = jobs.mapNotNull { (it as? JsonObject)?.let(::decodeJobStatus) }
        // Keep the real dataSync owner for every active durable job; a
        // terminal job releases its exact lease immediately. An active claim
        // also retains the exact submitted context for notification return.
        epoch()?.let { liveEpoch ->
            decoded.forEach { job ->
                if (jobTerminal(job.state)) {
                    foreground.release(job.jobID, liveEpoch)
                } else {
                    foreground.acquire(job.jobID, liveEpoch, context.projectID)
                        ?.let { claim ->
                            foreground.captureReturnContext(claim, context)
                        }
                }
            }
        }
        decoded
    }

    override suspend fun refreshJob(
        context: CreativeProjectContext,
        jobID: String,
    ): MediaJobStatus = withContext(ioDispatcher) {
        val liveEpoch = epoch()
        val claim = liveEpoch?.let {
            foreground.acquire(jobID, it, context.projectID)
        }
        claim?.let { foreground.captureReturnContext(it, context) }
        val response = command("generation.video.status", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
        })
        val status = decodeJobStatus(response)
        if (claim != null && jobTerminal(status.state)) {
            foreground.release(claim)
        }
        status
    }

    override suspend fun cancelJob(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): MediaJobStatus = withContext(ioDispatcher) {
        requireOperation(opID)
        val response = command("generation.video.cancel", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
            put("opID", opID)
        })
        epoch()?.let { liveEpoch -> foreground.release(jobID, liveEpoch) }
        decodeJobStatus(response)
    }

    override suspend fun deliverResult(
        context: CreativeProjectContext,
        jobID: String,
        opID: String,
    ): DeliveredCandidate = withContext(ioDispatcher) {
        requireOperation(opID)
        val liveEpoch = epoch()
        val claim = liveEpoch?.let {
            foreground.acquire(jobID, it, context.projectID)
        }
        claim?.let { foreground.captureReturnContext(it, context) }
        val response = command("generation.video.deliver", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
            put("opID", opID)
        })
        val delivered = decodeDelivered(response)
        if (claim != null &&
            (delivered.outcome == CandidateDeliveryOutcome.READY ||
                delivered.outcome == CandidateDeliveryOutcome.OUTCOME_UNKNOWN)) {
            foreground.release(claim)
        }
        delivered
    }

    override suspend fun candidates(
        context: CreativeProjectContext,
    ): List<MediaCandidate> = withContext(ioDispatcher) {
        val response = command("generation.candidates.list", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
        })
        val values = response.array("candidates")
            ?: throw CreativeException("invalidResponse", "missingCandidates")
        values.mapNotNull { (it as? JsonObject)?.let(::decodeCandidate) }
    }

    override suspend fun acceptCandidate(
        context: CreativeProjectContext,
        expectedRevision: Long,
        candidateID: String,
        opID: String,
    ): MediaProjectReceipt = withContext(ioDispatcher) {
        requireOperation(opID)
        if (expectedRevision < 0) {
            throw CreativeException("invalidRequest", "invalidRevision")
        }
        val response = command("generation.candidates.accept", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("expectedRevision", expectedRevision)
            put("candidateID", candidateID)
            put("opID", opID)
        })
        CreativeWire.decodeMediaReceipt(response)
    }

    override suspend fun rejectCandidate(
        context: CreativeProjectContext,
        candidateID: String,
        opID: String,
    ): CandidateMutationReceipt = withContext(ioDispatcher) {
        requireOperation(opID)
        val response = command("generation.candidates.reject", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("candidateID", candidateID)
            put("opID", opID)
        })
        CandidateMutationReceipt(
            candidateID = response.string("candidateID").orEmpty(),
            projectID = response.string("projectID").orEmpty(),
            state = decodeCandidateState(response.string("state")),
            opID = response.string("opID").orEmpty(),
            idempotent = response.bool("idempotent") ?: false,
        )
    }

    // MARK: - Transport

    private suspend fun command(action: String, payload: JsonObject): JsonObject {
        val epoch = epochProvider()
            ?: throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        if (epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        val request = R2MediaWire.request(
            operation = "command",
            requestID = CreativeWire.newRequestID(),
            epoch = epoch,
            action = action,
            payload = payload).toString()
        if (request.toByteArray(Charsets.UTF_8).size >
            WorkbenchR2Limits.BRIDGE_REQUEST_BYTES) {
            throw CreativeException("requestTooLarge", "generationRequestTooLarge")
        }
        return exchangeMutex.withLock {
            val raw = try {
                transport.exchange(request)
            } catch (error: CreativeException) {
                throw error
            } catch (error: Throwable) {
                throw CreativeException(
                    "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
            }
            if (raw.toByteArray(Charsets.UTF_8).size >
                WorkbenchR2Limits.BRIDGE_RESPONSE_BYTES) {
                throw CreativeException("responseTooLarge", "bridgeResponseTooLarge")
            }
            R2MediaWire.response(raw)
        }
    }

    private fun epoch(): Long? = epochProvider()?.takeIf { it > 0L }

    private fun imageTerminal(state: ImageRequestState): Boolean =
        state == ImageRequestState.COMPLETED ||
            state == ImageRequestState.FAILED ||
            state == ImageRequestState.INTERRUPTED ||
            state == ImageRequestState.OUTCOME_UNKNOWN ||
            state == ImageRequestState.DISMISSED

    private fun jobTerminal(state: MediaJobState): Boolean =
        state == MediaJobState.COMPLETED ||
            state == MediaJobState.FAILED ||
            state == MediaJobState.CANCELLED ||
            state == MediaJobState.INTERRUPTED ||
            state == MediaJobState.OUTCOME_UNKNOWN

    private fun requireOperation(opID: String) {
        if (!opID.matches(Regex("[A-Za-z0-9._-]{1,100}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
    }

    // MARK: - Decode

    private fun decodeCatalog(value: JsonObject): GenerationModelCatalog =
        GenerationModelCatalog(
            image = value.array("image")?.mapNotNull {
                (it as? JsonObject)?.let { route ->
                    decodeRoute(route, GenerationKind.IMAGE)
                }
            }.orEmpty(),
            video = value.array("video")?.mapNotNull {
                (it as? JsonObject)?.let { route ->
                    decodeRoute(route, GenerationKind.VIDEO)
                }
            }.orEmpty(),
        )

    private fun decodeRoute(value: JsonObject, kind: GenerationKind): GenerationModelRoute {
        val parameters = value.objectValue("parameters") ?: JsonObject(emptyMap())
        val policy = value.objectValue("referenceImagePolicy") ?: JsonObject(emptyMap())
        return GenerationModelRoute(
            routeID = value.string("routeID").orEmpty(),
            remoteModelID = value.string("remoteModelID").orEmpty(),
            providerID = value.string("providerID").orEmpty(),
            providerName = value.string("providerName").orEmpty(),
            kind = kind,
            enabled = value.bool("enabled") ?: false,
            available = value.bool("available") ?: false,
            unavailableReason = value.string("unavailableReason"),
            parameters = GenerationParameterContract(
                sizes = parameters.array("sizes")?.mapNotNull {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.content
                },
                aspectRatios = parameters.array("aspectRatios")?.mapNotNull {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.content
                },
                resolutions = parameters.array("resolutions")?.mapNotNull {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.content
                },
                durationSeconds = parameters.array("durationSeconds")?.mapNotNull {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.doubleOrNull
                },
                maxCount = parameters.int("maxCount") ?: 1,
                maxReferenceImages = parameters.int("maxReferenceImages") ?: 0,
                supportsImageToVideo = parameters.bool("supportsImageToVideo") ?: false,
                supportsFirstFrame = parameters.bool("supportsFirstFrame") ?: false,
                codecs = parameters.array("codecs")?.mapNotNull {
                    (it as? JsonObject)?.let { codec ->
                        CodecContract(
                            mimeType = codec.string("mimeType").orEmpty(),
                            width = codec.int("width") ?: 0,
                            height = codec.int("height") ?: 0,
                            frameRate = codec.double("frameRate") ?: 0.0,
                        )
                    }
                }.orEmpty(),
            ),
            referenceImagePolicy = ReferenceImagePolicy(
                maxImages = policy.int("maxImages") ?: 0,
                maxBytesPerImage = policy.long("maxBytesPerImage") ?: 0L,
                acceptedMimeTypes = policy.array("acceptedMimeTypes")?.mapNotNull {
                    (it as? kotlinx.serialization.json.JsonPrimitive)?.content
                }.orEmpty(),
                minWidth = policy.int("minWidth"),
                maxWidth = policy.int("maxWidth"),
                minHeight = policy.int("minHeight"),
                maxHeight = policy.int("maxHeight"),
            ),
            costNote = value.string("costNote").orEmpty(),
        )
    }

    private fun decodeImageHandle(value: JsonObject): ImageRequestHandle =
        ImageRequestHandle(
            requestID = value.string("requestID")
                ?: throw CreativeException("invalidResponse", "missingRequestID"),
            projectID = value.string("projectID")
                ?: throw CreativeException("invalidResponse", "missingProjectID"),
            acceptedAt = value.string("acceptedAt").orEmpty(),
            state = decodeImageState(value.string("state")),
            idempotent = value.bool("idempotent") ?: false,
        )

    private fun decodeVideoHandle(value: JsonObject): VideoJobHandle =
        VideoJobHandle(
            jobID = value.string("jobID")
                ?: throw CreativeException("invalidResponse", "missingJobID"),
            projectID = value.string("projectID")
                ?: throw CreativeException("invalidResponse", "missingProjectID"),
            acceptedAt = value.string("acceptedAt").orEmpty(),
            state = decodeJobState(value.string("state")),
            idempotent = value.bool("idempotent") ?: false,
        )

    private fun decodeImageStatus(value: JsonObject): ImageRequestStatus =
        ImageRequestStatus(
            requestID = value.string("requestID").orEmpty(),
            projectID = value.string("projectID").orEmpty(),
            state = decodeImageState(value.string("state")),
            submittedAt = value.string("submittedAt").orEmpty(),
            updatedAt = value.string("updatedAt").orEmpty(),
            candidate = value.objectValue("candidate")?.let(::decodeCandidate),
            errorCode = value.string("errorCode"),
            retryable = value.bool("retryable") ?: false,
        )

    private fun decodeJobStatus(value: JsonObject): MediaJobStatus =
        MediaJobStatus(
            jobID = value.string("jobID").orEmpty(),
            projectID = value.string("projectID").orEmpty(),
            state = decodeJobState(value.string("state")),
            updatedAt = value.string("updatedAt").orEmpty(),
            progressHint = value.double("progressHint"),
            resultAvailable = value.bool("resultAvailable") ?: false,
            providerTaskReferencePresent =
                value.bool("providerTaskReferencePresent") ?: false,
            lastErrorCode = value.string("lastErrorCode"),
            retryable = value.bool("retryable") ?: false,
            canCancel = value.bool("canCancel") ?: false,
        )

    private fun decodeDelivered(value: JsonObject): DeliveredCandidate {
        val outcome = when (value.string("outcome")) {
            "ready" -> CandidateDeliveryOutcome.READY
            "notReady" -> CandidateDeliveryOutcome.NOT_READY
            else -> CandidateDeliveryOutcome.OUTCOME_UNKNOWN
        }
        return DeliveredCandidate(
            outcome = outcome,
            candidate = value.objectValue("candidate")?.let(::decodeCandidate),
            reason = value.string("reason"),
        )
    }

    private fun decodeCandidate(value: JsonObject): MediaCandidate =
        MediaCandidate(
            candidateID = value.string("candidateID").orEmpty(),
            projectID = value.string("projectID").orEmpty(),
            kind = if (value.string("kind") == "video") {
                GenerationKind.VIDEO
            } else {
                GenerationKind.IMAGE
            },
            modelDisplayName = value.string("modelDisplayName"),
            createdAt = value.string("createdAt").orEmpty(),
            byteCount = value.long("byteCount") ?: 0L,
            sha256 = value.string("sha256").orEmpty(),
            relativePath = value.string("relativePath").orEmpty(),
            requestID = value.string("requestID"),
            state = decodeCandidateState(value.string("state")),
        )

    private fun decodeImageState(raw: String?): ImageRequestState =
        ImageRequestState.entries.firstOrNull { it.wire == raw }
            ?: ImageRequestState.OUTCOME_UNKNOWN

    private fun decodeJobState(raw: String?): MediaJobState =
        MediaJobState.entries.firstOrNull { it.wire == raw }
            ?: MediaJobState.OUTCOME_UNKNOWN

    private fun decodeCandidateState(raw: String?): MediaCandidateState =
        MediaCandidateState.entries.firstOrNull { it.wire == raw }
            ?: MediaCandidateState.PENDING
}
