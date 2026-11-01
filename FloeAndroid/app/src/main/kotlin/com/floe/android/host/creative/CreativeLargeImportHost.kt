// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.LargeImportCancelRequest
import com.floe.android.feature.workbench.LargeImportJobHandle
import com.floe.android.feature.workbench.LargeImportKind
import com.floe.android.feature.workbench.LargeImportPolicy
import com.floe.android.feature.workbench.LargeImportRequest
import com.floe.android.feature.workbench.LargeImportState
import com.floe.android.feature.workbench.LargeImportStatus
import com.floe.android.feature.workbench.LargeImportStatusRequest
import com.floe.android.feature.workbench.MediaAssetMetadata
import com.floe.android.feature.workbench.StagedImportMetadata
import com.floe.android.feature.workbench.StagedImportValidation
import com.floe.android.feature.workbench.WorkbenchLargeImportPort
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Exact host-measured commit input for the additive R1 commit bridges used by
 * the Main constructor patch. The V6 large-import action is now the only
 * production commit path; this DTO is retained so the R1 bridge remains
 * available without a second project authority.
 */
internal data class MediaImportCommit(
    val context: CreativeProjectContext,
    val expectedRevision: Long,
    val token: String,
    val fileName: String,
    val mimeType: String?,
    val byteCount: Long,
    val sha256: String,
    val opID: String,
)

/**
 * App host facade for the frozen [WorkbenchLargeImportPort] over the REAL
 * `floe.creative/6` large-import actions.
 *
 * The App stages the ACTUAL user URI in a service-owned job under the accepted
 * root (`FloeAgent/CreativeIncoming`, streamed, hashed, cancellable) and then
 * submits only metadata to the native `G09R2LargeImportService`. Native owns
 * the verified staged bytes from that point until its worker is terminal:
 *
 *  * the App NEVER deletes the staged token immediately after an accepted
 *    submit (the native job may still be hashing/committing);
 *  * an ambiguous submit outcome also retains the bytes and is reported as
 *    `importOutcomeUnknown`, never blindly retried or discarded;
 *  * `status`/`cancel` carry the jobID + session token + stable opID and are
 *    validated by native against the actual job owner and bound epoch;
 *  * the R2 per-kind policy (image 128 MiB / audio 1 GiB / video 8 GiB) is
 *    accepted through the real large path; the generic Canvas 64 MiB cap is
 *    untouched because this facade does not serve Canvas.
 *
 * Root stop first drains App-owned staging (active pumps) and then asks native
 * for the aggregate import/render/pin drain. A cancel request alone is never
 * reported as drained.
 */
internal class CreativeLargeImportHost(
    private val resolverProvider: () -> android.content.ContentResolver,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val liveEpochProvider: () -> Long?,
    private val transport: CreativeTransport,
    private val ioDispatcher: CoroutineDispatcher,
) : WorkbenchLargeImportPort {
    constructor(
        context: Context,
        acceptedRootProvider: () -> CreativeAcceptedRoot?,
        liveEpochProvider: () -> Long?,
        transport: CreativeTransport = SwiftCreativeTransport,
        ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    ) : this(
        { context.applicationContext.contentResolver },
        acceptedRootProvider, liveEpochProvider, transport, ioDispatcher)

    private data class JobRef(
        val jobID: String,
        val epoch: Long,
        val sessionToken: String,
        val opID: String,
        var state: LargeImportState,
        var updatedAt: String,
    )

    private val resolver by lazy { resolverProvider() }
    private val pump = CreativeSourcePump(ioDispatcher)
    private val jobs = ConcurrentHashMap<String, JobRef>()
    /** Staged tokens this App still owns; removed on ownership transfer. */
    private val ownedTokens = ConcurrentHashMap.newKeySet<String>()
    private val activeStaging = AtomicInteger(0)
    @Volatile private var stoppingEpoch: Long? = null

    private companion object {
        const val MAX_TRACKED_JOBS = 32
    }

    // MARK: - Validate

    override fun validate(metadata: StagedImportMetadata): StagedImportValidation {
        val rule = LargeImportPolicy.rule(metadata.kind)
        var refusal: String? = null
        if (!LargeImportPolicy.accepts(metadata.kind, metadata.byteCount)) {
            refusal = "importTooLarge"
        } else if (!isDigest(metadata.sha256)) {
            refusal = "assetStagingInvalid"
        } else if (!CreativeOwnership.isSafeStagingToken(metadata.token)) {
            refusal = "assetStagingInvalid"
        } else if (metadata.fileName.isBlank()) {
            refusal = "assetStagingInvalid"
        }
        if (refusal == null) {
            val free = runCatching {
                File(CreativeOwnership.requireLive(
                    acceptedRootProvider(), liveEpochProvider()).path).usableSpace
            }.getOrNull()
            if (free != null &&
                free < LargeImportPolicy.requiredFreeBytes(metadata.byteCount)) {
                refusal = "insufficientStorage"
            }
        }
        return StagedImportValidation(
            accepted = refusal == null,
            requiredFreeBytes = LargeImportPolicy.requiredFreeBytes(metadata.byteCount),
            maxBytes = rule.maxBytes,
            refusalCode = refusal)
    }

    // MARK: - Service-owned URI staging

    /**
     * App-owned convenience (outside the frozen contract, like R1
     * `createMediaFromUri`): streams the URI once into service-owned staging
     * and returns measured metadata. The staged token stays App-owned until
     * the native submit is accepted, then becomes native-owned.
     */
    suspend fun stageSource(
        uri: Uri,
        kind: LargeImportKind,
        sessionToken: String,
    ): StagedImportMetadata = withContext(ioDispatcher) {
        CreativeOwnership.requireSessionToken(sessionToken)
        val accepted = CreativeOwnership.requireLive(
            acceptedRootProvider(), liveEpochProvider())
        if (stoppingEpoch == accepted.epoch) {
            throw CreativeException(
                "staleGeneration", "rootStopping", retryable = true)
        }
        val rule = LargeImportPolicy.rule(kind)
        val token = CreativeOwnership.newStagingToken(sessionToken)
        val target = CreativeOwnership.stagingFile(accepted, token)
        val (displayName, mimeType) = resolveSourceMetadata(uri)
        val input = try {
            resolver.openInputStream(uri)
        } catch (error: Throwable) {
            null
        } ?: throw CreativeException(
            "assetStagingUnavailable", "sourceUnreadable", retryable = true)
        activeStaging.incrementAndGet()
        val bytes = try {
            pump.stage(
                input, target, rule.maxBytes,
                isCancelled = { stoppingEpoch == accepted.epoch })
        } catch (cancelled: CancellationException) {
            // A real caller cancellation stays cancellation; only a Root-stop
            // fence is surfaced as the typed stale generation.
            currentCoroutineContext().ensureActive()
            throw CreativeException(
                "staleGeneration", "rootStopping", retryable = true)
        } finally {
            runCatching { input.close() }
            activeStaging.decrementAndGet()
        }
        ownedTokens.add(token)
        val metadata = inspectMediaMetadata(target, kind)
        StagedImportMetadata(
            token = token,
            kind = kind,
            fileName = displayName,
            mimeType = mimeType,
            byteCount = bytes.byteCount,
            sha256 = bytes.sha256,
            mediaMetadata = metadata)
    }

    // MARK: - Port

    override suspend fun submit(request: LargeImportRequest): LargeImportJobHandle =
        withContext(ioDispatcher) {
            val metadata = request.metadata
            val sessionToken = when (request) {
                is LargeImportRequest.ExistingProject -> request.context.sessionToken
                is LargeImportRequest.NewProject -> request.sessionToken
            }
            CreativeOwnership.requireSessionToken(sessionToken)
            val accepted = CreativeOwnership.requireLive(
                acceptedRootProvider(), liveEpochProvider())
            if (stoppingEpoch == accepted.epoch) {
                throw CreativeException(
                    "staleGeneration", "rootStopping", retryable = true)
            }
            if (!metadata.token.startsWith("$sessionToken.")) {
                throw CreativeException("assetStagingInvalid", "invalidStagingToken")
            }
            val validation = validate(metadata)
            if (!validation.accepted) {
                throw validationError(validation)
            }
            when (request) {
                is LargeImportRequest.NewProject -> {
                    val media = metadata.mediaMetadata
                        ?: throw CreativeException(
                            "invalidRequest", "missingSourceMetadata")
                    if (media.width == null || media.height == null) {
                        throw CreativeException(
                            "invalidRequest", "missingSourceDimensions")
                    }
                    if (request.kind.wire == "video" &&
                        (media.durationSeconds ?: 0.0) <= 0.0) {
                        throw CreativeException(
                            "invalidRequest", "missingSourceDuration")
                    }
                }
                is LargeImportRequest.ExistingProject -> {
                    // audio/video/image all allowed as an existing-project asset
                }
            }
            if (!request.opID.matches(Regex("[A-Za-z0-9._-]{1,128}"))) {
                throw CreativeException("invalidRequest", "invalidOperationID")
            }
            val epoch = accepted.epoch
            val response = try {
                exchange(
                    epoch = epoch,
                    action = "media.largeImport.submit",
                    payload = R2MediaWire.encodeLargeImportSubmit(request))
            } catch (error: CreativeException) {
                if (isDefiniteNativeRefusal(error)) {
                    // Native refused BEFORE creating a job: the App still owns
                    // the staged token and may release it.
                    discardOwned(metadata.token)
                } else {
                    // The request may have crossed the in-process bridge. Do
                    // not delete bytes a possible native job still reads; do
                    // not auto-retry.
                    ownedTokens.remove(metadata.token)
                    throw CreativeException(
                        "importOutcomeUnknown", "submitOutcomeUnknown",
                        retryable = false)
                }
                throw error
            } catch (error: Throwable) {
                ownedTokens.remove(metadata.token)
                throw CreativeException(
                    "importOutcomeUnknown", "submitOutcomeUnknown",
                    retryable = false)
            }
            val handle = R2MediaWire.decodeLargeImportHandle(response)
            // Ownership transferred to the native job. The App must NOT
            // delete this token while the job is in flight.
            ownedTokens.remove(metadata.token)
            track(JobRef(
                jobID = handle.jobID, epoch = epoch,
                sessionToken = sessionToken, opID = request.opID,
                state = handle.state, updatedAt = handle.acceptedAt))
            handle
        }

    override suspend fun status(
        request: LargeImportStatusRequest,
    ): LargeImportStatus = withContext(ioDispatcher) {
        val reference = jobs[request.jobID]
        val epoch = reference?.epoch ?: requireEpoch()
        val response = exchange(
            epoch = epoch,
            action = "media.largeImport.status",
            payload = buildJsonObject {
                put("jobID", request.jobID)
                put("sessionToken", request.sessionToken)
            })
        val status = R2MediaWire.decodeLargeImportStatus(response)
        reference?.let {
            it.state = status.state
            it.updatedAt = status.updatedAt
        }
        status
    }

    override suspend fun cancel(
        request: LargeImportCancelRequest,
    ): LargeImportJobHandle = withContext(ioDispatcher) {
        val reference = jobs[request.jobID]
        val epoch = reference?.epoch ?: requireEpoch()
        val response = exchange(
            epoch = epoch,
            action = "media.largeImport.cancel",
            payload = buildJsonObject {
                put("jobID", request.jobID)
                put("sessionToken", request.sessionToken)
                put("opID", request.opID)
            })
        val handle = R2MediaWire.decodeLargeImportHandle(response)
        reference?.let {
            it.state = handle.state
            it.updatedAt = handle.acceptedAt
        }
        handle
    }

    // MARK: - Root drain / ownership lifecycle

    /**
     * Phase 1 for App-owned staging only: refuse new staging and wait for the
     * real pumps to stop. Native-owned jobs are drained by the native
     * aggregate root-stop (they are not this App's bytes anymore).
     */
    suspend fun drainStaging(epoch: Long, timeoutMillis: Int = 10_000): Boolean {
        stoppingEpoch = epoch
        val deadline = System.currentTimeMillis() +
            timeoutMillis.coerceIn(100, 60_000).toLong()
        while (activeStaging.get() > 0 && System.currentTimeMillis() < deadline) {
            delay(20)
        }
        return activeStaging.get() == 0
    }

    /** App-owned staging + tracked native nonterminal jobs (diagnostic). */
    fun pendingCount(): Int =
        activeStaging.get() + jobs.values.count { !isTerminal(it.state) }

    fun activeStagingCount(): Int = activeStaging.get()

    /** Drops only App-owned, not-yet-transferred staging tokens. */
    fun shutdown() {
        stoppingEpoch = liveEpochProvider()
        val tokens = ownedTokens.toList()
        ownedTokens.clear()
        for (token in tokens) discardOwned(token)
    }

    // MARK: - Exchange

    private suspend fun exchange(
        epoch: Long,
        action: String,
        payload: JsonObject,
    ): JsonObject = withContext(ioDispatcher) {
        if (epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        val raw = try {
            transport.exchange(R2MediaWire.request(
                operation = "command",
                requestID = CreativeWire.newRequestID(),
                epoch = epoch,
                action = action,
                payload = payload).toString())
        } catch (error: CreativeException) {
            throw error
        } catch (error: Throwable) {
            throw CreativeException(
                "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
        }
        if (raw.toByteArray(Charsets.UTF_8).size > 16 * 1024 * 1024) {
            throw CreativeException("responseTooLarge", "bridgeResponseTooLarge")
        }
        R2MediaWire.response(raw)
    }

    private fun track(reference: JobRef) {
        jobs[reference.jobID] = reference
        if (jobs.size <= MAX_TRACKED_JOBS) return
        val terminal = jobs.values
            .filter { isTerminal(it.state) }
            .sortedBy { it.updatedAt }
        for (entry in terminal.take(jobs.size - MAX_TRACKED_JOBS)) {
            jobs.remove(entry.jobID)
        }
    }

    private fun isDefiniteNativeRefusal(error: CreativeException): Boolean =
        when (error.code) {
            "invalidCoreResponse", "needsCoreUpdate", "coreTooNew",
            "bridgeExchangeFailed", "importOutcomeUnknown" -> false
            else -> true
        }

    private fun discardOwned(token: String) {
        if (!ownedTokens.remove(token)) return
        val accepted = acceptedRootProvider() ?: return
        runCatching { CreativeOwnership.stagingFile(accepted, token).delete() }
    }

    // MARK: - Helpers

    private fun requireEpoch(): Long =
        liveEpochProvider()?.takeIf { it > 0L }
            ?: throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)

    private fun isTerminal(state: LargeImportState): Boolean = when (state) {
        LargeImportState.COMPLETED,
        LargeImportState.CANCELLED,
        LargeImportState.FAILED,
        LargeImportState.INTERRUPTED -> true
        else -> false
    }

    private fun validationError(validation: StagedImportValidation): CreativeException =
        when (validation.refusalCode) {
            "importTooLarge" -> CreativeException(
                "importTooLarge", "stagedAssetTooLarge")
            "insufficientStorage" -> CreativeException(
                "insufficientStorage", "notEnoughFreeSpace", retryable = true)
            "assetEmpty" -> CreativeException("assetEmpty", "stagedAssetEmpty")
            else -> CreativeException("assetStagingInvalid", "invalidStagedMetadata")
        }

    private fun isDigest(value: String): Boolean =
        value.length == 64 && value.all { it in "0123456789abcdefABCDEF" }

    private fun resolveSourceMetadata(uri: Uri): Pair<String, String?> {
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
        val display = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
                }
        }.getOrNull()
        val fallback = uri.lastPathSegment?.substringAfterLast('/') ?: "import"
        return (display ?: fallback) to mime
    }

    /**
     * Bounded local inspection only (size/extension/kind hint). Real
     * dimensions/duration for new-project atomic creation are host-measured by
     * this path and then native-verified; unknown values are refused by submit
     * for a new project.
     */
    private fun inspectMediaMetadata(target: File, kind: LargeImportKind):
        MediaAssetMetadata? {
        val inspected = CreativeSourceInspector.inspect(target) ?: return null
        val metadata = MediaAssetMetadata(
            width = inspected.width,
            height = inspected.height,
            durationSeconds = inspected.durationSeconds,
            frameRate = inspected.frameRate,
            rotationDegrees = inspected.rotationDegrees)
        return when (kind) {
            LargeImportKind.IMAGE ->
                if (metadata.width == null || metadata.height == null) null else metadata
            LargeImportKind.VIDEO ->
                if (metadata.width == null || metadata.height == null ||
                    (metadata.durationSeconds ?: 0.0) <= 0.0) null else metadata
            LargeImportKind.AUDIO ->
                if ((metadata.durationSeconds ?: 0.0) <= 0.0) null else metadata
        }
    }
}
