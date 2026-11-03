// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.EnhancementCapability
import com.floe.android.feature.workbench.EnhancementJobState
import com.floe.android.feature.workbench.EnhancementMethod
import com.floe.android.feature.workbench.EnhancementOperation
import com.floe.android.feature.workbench.EnhancementPhase
import com.floe.android.feature.workbench.EnhancementProgress
import com.floe.android.feature.workbench.EnhancementReceipt
import com.floe.android.feature.workbench.EnhancementRequest
import com.floe.android.feature.workbench.EnhancementStatus
import com.floe.android.feature.workbench.WorkbenchEnhancementHostApi
import com.floe.android.feature.workbench.WorkbenchR2Limits
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * Production App adapter for the frozen [WorkbenchEnhancementHostApi].
 *
 * Every call crosses the existing `floe_bridge_exchange` C ABI as
 * `floe.creative/6` `media.enhancement.*`; nothing is persisted in Kotlin.
 * The native service owns the durable journal, the task-Linux ffmpeg job,
 * the configured fal.ai super-resolution backend, and the measured receipts.
 */
class CreativeR2EnhancementHost(
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : WorkbenchEnhancementHostApi {
    private val exchangeMutex = Mutex()

    override suspend fun enhancementCapability(
        context: CreativeProjectContext,
    ): EnhancementCapability = withContext(ioDispatcher) {
        val response = command("media.enhancement.capability", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
        })
        EnhancementCapability(
            interpolationReady = response.bool("interpolationReady") ?: false,
            interpolationEngine = response.string("interpolationEngine"),
            interpolationUnavailableReason =
                response.string("interpolationUnavailableReason"),
            superResolutionReady = response.bool("superResolutionReady") ?: false,
            superResolutionBackendName = response.string("superResolutionBackendName"),
            superResolutionUnavailableReason =
                response.string("superResolutionUnavailableReason"),
        )
    }

    override suspend fun submitEnhancement(
        context: CreativeProjectContext,
        request: EnhancementRequest,
    ): String = withContext(ioDispatcher) {
        val response = command("media.enhancement.submit", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            putJsonObject("request") {
                put("inputRelativePath", request.inputRelativePath)
                put("outputFileName", request.outputFileName)
                put("overwrite", request.overwrite)
                putJsonObject("operation") {
                    when (val op = request.operation) {
                        is EnhancementOperation.Interpolation -> {
                            put("kind", "interpolation")
                            put("targetFPS", op.targetFPS)
                        }
                        is EnhancementOperation.SuperResolution -> {
                            put("kind", "superResolution")
                            put("scaleFactor", op.scaleFactor)
                        }
                    }
                }
                put("bitDepth", when (val op = request.operation) {
                    is EnhancementOperation.SuperResolution -> op.bitDepth
                    else -> 8
                })
            }
        })
        response.string("jobID") ?: throw CreativeException(
            "invalidResponse", "missingEnhancementJobID")
    }

    override suspend fun enhancementStatus(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus = withContext(ioDispatcher) {
        val response = command("media.enhancement.status", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
        })
        decodeStatus(response)
    }

    override suspend fun cancelEnhancement(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus = withContext(ioDispatcher) {
        val response = command("media.enhancement.cancel", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
        })
        decodeStatus(response)
    }

    override suspend fun importEnhancementOutput(
        context: CreativeProjectContext,
        jobID: String,
    ): EnhancementStatus = withContext(ioDispatcher) {
        val response = command("media.enhancement.import", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("jobID", jobID)
        })
        decodeStatus(response)
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
            throw CreativeException("requestTooLarge", "enhancementRequestTooLarge")
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
                throw CreativeException("responseTooLarge", "enhancementResponseTooLarge")
            }
            R2MediaWire.response(raw)
        }
    }

    // MARK: - Decode

    private fun decodeStatus(value: JsonObject): EnhancementStatus {
        val state = when (value.string("state")) {
            "queued" -> EnhancementJobState.QUEUED
            "running" -> EnhancementJobState.RUNNING
            "cancelling" -> EnhancementJobState.CANCELLING
            "validating" -> EnhancementJobState.VALIDATING
            "completed" -> EnhancementJobState.COMPLETED
            "failed" -> EnhancementJobState.FAILED
            "cancelled" -> EnhancementJobState.CANCELLED
            else -> EnhancementJobState.OUTCOME_UNKNOWN
        }
        return EnhancementStatus(
            jobID = value.string("jobID").orEmpty(),
            state = state,
            progress = value.objectValue("progress")?.let { progress ->
                EnhancementProgress(
                    phase = when (progress.string("phase")) {
                        "processing" -> EnhancementPhase.PROCESSING
                        "validating" -> EnhancementPhase.VALIDATING
                        "committing" -> EnhancementPhase.COMMITTING
                        else -> EnhancementPhase.PREFLIGHT
                    },
                    completedUnits = progress.int("completedUnits") ?: 0,
                    totalUnits = progress.int("totalUnits") ?: 0,
                )
            },
            receipt = value.objectValue("receipt")?.let(::decodeReceipt),
            errorCode = value.string("errorCode"),
            errorDetail = value.string("errorDetail"),
            retryable = value.bool("retryable") ?: false,
            canCancel = value.bool("canCancel") ?: false,
        )
    }

    private fun decodeReceipt(value: JsonObject): EnhancementReceipt {
        val method = if (value.string("method") == "superResolution") {
            EnhancementMethod.SUPER_RESOLUTION
        } else {
            EnhancementMethod.INTERPOLATION
        }
        return EnhancementReceipt(
            outputRelativePath = value.string("outputRelativePath").orEmpty(),
            engine = value.string("engine").orEmpty(),
            method = method,
            inputKind = value.string("inputKind").orEmpty(),
            sourceWidth = value.int("sourceWidth") ?: 0,
            sourceHeight = value.int("sourceHeight") ?: 0,
            sourceFPS = value.double("sourceFPS") ?: 0.0,
            sourceDurationSeconds = value.double("sourceDurationSeconds") ?: 0.0,
            sourceFrameCount = value.int("sourceFrameCount") ?: 0,
            outputWidth = value.int("outputWidth") ?: 0,
            outputHeight = value.int("outputHeight") ?: 0,
            outputFPS = value.double("outputFPS") ?: 0.0,
            outputDurationSeconds = value.double("outputDurationSeconds") ?: 0.0,
            outputFrameCount = value.int("outputFrameCount") ?: 0,
            outputBytes = value.long("outputBytes") ?: 0L,
            outputSHA256 = value.string("outputSHA256").orEmpty(),
            remoteJobID = value.string("remoteJobID"),
            warnings = value.array("warnings")?.mapNotNull {
                (it as? kotlinx.serialization.json.JsonPrimitive)?.content
            }.orEmpty(),
            importedAssetID = value.string("importedAssetID"),
            importRevision = value.long("importRevision"),
            importErrorCode = value.string("importErrorCode"),
        )
    }
}
