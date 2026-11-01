// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.bridge.SwiftCore
import com.floe.android.feature.canvas.CanvasAssetReceipt
import com.floe.android.feature.canvas.CanvasAssetReferenceOperation
import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CanvasMutationReceipt
import com.floe.android.feature.canvas.CanvasOperationResult
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CanvasRecoveryState
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeLimits
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeServiceStatus
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaMutationReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.WorkbenchHostApi
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

fun interface CreativeTransport {
    fun exchange(request: String): String
}

object SwiftCreativeTransport : CreativeTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

/**
 * Host-side typed adapter for `floe.creative/5`.
 *
 * Every call crosses the EXISTING `floe_bridge_exchange` C ABI; there is no
 * Kotlin project store, no in-memory fallback and no path argument in any
 * request. An installed core that predates v5 answers with the ordinary v1
 * `unsupportedVersion`; that is mapped to `needsCoreUpdate` and every data
 * method fails typed instead of fabricating success.
 */
class CreativeProjectController(
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : CanvasHostApi, WorkbenchHostApi {
    private val exchangeMutex = Mutex()
    private val bindMutex = Mutex()
    @Volatile private var handshake: CreativeServiceStatus? = null
    @Volatile private var boundEpoch: Long? = null
    @Volatile private var rootFingerprint: String? = null

    // MARK: - Binding / status

    override suspend fun bind(epoch: Long): CreativeBinding = withContext(ioDispatcher) {
        if (epoch <= 0L) throw CreativeException("invalidRequest", "missingEpoch")
        bindMutex.withLock {
            if (boundEpoch == epoch && rootFingerprint != null) {
                return@withLock CreativeBinding(epoch, true, rootFingerprint)
            }
            requireHandshake()
            val response = exchangeLocked(
                CreativeWire.request(
                    operation = "bind", requestID = CreativeWire.newRequestID(),
                    epoch = epoch))
            if (response.boolValue("bound") != true) {
                throw CreativeException("runtimeUnavailable", "creativeNotBound", retryable = true)
            }
            val bound = response.longValue("epoch") ?: epoch
            if (bound != epoch) {
                throw CreativeException("staleGeneration", "epochMismatch")
            }
            boundEpoch = bound
            rootFingerprint = response.stringValue("rootFingerprint")
            CreativeBinding(bound, true, rootFingerprint)
        }
    }

    override suspend fun status(): CreativeServiceStatus = withContext(ioDispatcher) {
        val handshakeState = try {
            handshake ?: requireHandshake()
        } catch (error: CreativeException) {
            return@withContext CreativeServiceStatus(
                availability = if (error.code == "needsCoreUpdate" || error.code == "coreTooNew") {
                    CreativeAvailability.NeedsCoreUpdate
                } else {
                    CreativeAvailability.WaitingForRuntime
                },
                schema = null,
                reason = error.reason ?: error.code,
            )
        }
        val epoch = boundEpoch
        if (epoch == null) {
            return@withContext handshakeState.copy(
                availability = CreativeAvailability.WaitingForRuntime)
        }
        try {
            val response = exchangeLocked(
                CreativeWire.request(operation = "status",
                                     requestID = CreativeWire.newRequestID()))
            handshakeState.copy(
                availability = if (response.boolValue("bound") == true) {
                    CreativeAvailability.Available
                } else {
                    CreativeAvailability.WaitingForRuntime
                },
                boundEpoch = response.longValue("epoch"),
                reason = null,
            )
        } catch (error: CreativeException) {
            handshakeState.copy(
                availability = CreativeAvailability.Unavailable,
                boundEpoch = epoch,
                reason = error.reason ?: error.code,
            )
        }
    }

    private suspend fun requireHandshake(): CreativeServiceStatus {
        handshake?.let { return it }
        val response = exchangeLocked(
            CreativeWire.request(
                operation = "handshake", requestID = CreativeWire.newRequestID()))
        val value = CreativeWire.handshakeState(response)
        handshake = value
        return value
    }

    private fun requireBoundEpoch(): Long {
        val epoch = epochProvider()?.takeIf { it > 0 }
            ?: throw CreativeException("runtimeUnavailable", "acceptedRootNotLive", retryable = true)
        if (boundEpoch != epoch) {
            throw CreativeException("staleGeneration", "creativeNotBoundAtEpoch", retryable = true)
        }
        return epoch
    }

    // MARK: - Canvas

    override suspend fun canvasLibrary(): List<CanvasProjectSummary> {
        val epoch = requireBoundEpoch()
        val response = command(epoch, "canvas.library", buildJsonObject { })
        return response.arrayValue("projects")?.map(CreativeWire::decodeCanvasSummary).orEmpty()
    }

    override suspend fun open(canvasID: String, sessionToken: String): CanvasProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        val response = command(epoch, "canvas.load", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeCanvasEnvelope(response)
    }

    override suspend fun create(
        name: String,
        workspaceID: String?,
        sessionToken: String,
    ): CanvasProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireName(name)
        val response = command(epoch, "canvas.create", buildJsonObject {
            put("name", name)
            if (workspaceID != null) put("workspaceID", requireUUID(workspaceID, "workspaceID"))
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeCanvasEnvelope(response)
    }

    override suspend fun patch(request: CanvasPatchRequest): CanvasOperationResult {
        val epoch = requireBoundEpoch()
        requireSession(request.sessionToken)
        requireOperationID(request.opID)
        if (request.patch.canvasID != request.canvasID) {
            throw CreativeException("invalidRequest", "patchCanvasMismatch")
        }
        val response = command(epoch, "canvas.patch", CreativeWire.encodeCanvasPatch(request))
        return CreativeWire.decodeCanvasResult(response)
    }

    override suspend fun rename(
        canvasID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        opID: String?,
    ): CanvasMutationReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireName(name)
        requireRevision(expectedRevision)
        val response = command(epoch, "canvas.rename", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
            put("expectedRevision", expectedRevision)
            put("name", name)
            put("sessionToken", sessionToken)
            opID?.let {
                requireOperationID(it)
                put("opID", it)
            }
        })
        return CreativeWire.decodeCanvasMutation(response)
    }

    override suspend fun delete(
        canvasID: String,
        expectedRevision: Long,
        sessionToken: String,
        opID: String?,
    ) {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        command(epoch, "canvas.delete", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
            put("expectedRevision", expectedRevision)
            put("sessionToken", sessionToken)
            opID?.let {
                requireOperationID(it)
                put("opID", it)
            }
        })
    }

    override suspend fun importAsset(
        token: String,
        opID: String,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
        sessionToken: String,
    ): CanvasAssetReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireOperationID(opID)
        requireStaging(token, sessionToken)
        val response = command(epoch, "creative.asset.importStaged", buildJsonObject {
            put("token", token)
            put("opID", opID)
            put("fileName", boundedName(fileName))
            if (mimeType != null) put("mimeType", mimeType)
            put("byteCount", byteCount)
            put("sha256", sha256)
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeCanvasAssetReceipt(response)
    }

    override suspend fun discardAsset(token: String) {
        val epoch = requireBoundEpoch()
        if (!CreativeOwnership.isSafeStagingToken(token)) {
            throw CreativeException("assetStagingInvalid", "invalidStagingToken")
        }
        command(epoch, "creative.asset.discard", buildJsonObject { put("token", token) })
    }

    override suspend fun referenceOp(
        canvasID: String,
        sessionToken: String,
        operations: List<CanvasAssetReferenceOperation>,
    ): CanvasRecoveryState {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        if (operations.isEmpty() || operations.size > CreativeLimits.RECOVERY_OPERATIONS) {
            throw CreativeException("invalidRequest", "invalidReferenceOperations")
        }
        val response = command(epoch, "creative.asset.referenceOp", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
            put("sessionToken", sessionToken)
            putJsonArray("operations") {
                operations.forEach { operation ->
                    requireOperationID(operation.opID)
                    add(buildJsonObject {
                        put("opID", operation.opID)
                        put("assetID", requireUUID(operation.assetID, "assetID"))
                        put("delta", operation.delta)
                    })
                }
            }
        })
        return CreativeWire.decodeRecovery(response)
    }

    override suspend fun recover(canvasID: String): CanvasRecoveryState {
        val epoch = requireBoundEpoch()
        val response = command(epoch, "creative.recovery", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
        })
        return CreativeWire.decodeRecovery(response)
    }

    // MARK: - Media

    override suspend fun mediaLibrary(): List<MediaProjectSummary> {
        val epoch = requireBoundEpoch()
        val response = command(epoch, "media.project.library", buildJsonObject { })
        return response.arrayValue("projects")?.map(CreativeWire::decodeMediaSummary).orEmpty()
    }

    override suspend fun open(
        projectID: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
    ): MediaProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        val response = command(epoch, "media.project.load", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
        })
        return CreativeWire.decodeMediaEnvelope(response)
    }

    override suspend fun create(
        name: String,
        kind: String,
        width: Int,
        height: Int,
        frameRate: Double?,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext,
        sessionToken: String,
    ): MediaProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireName(name)
        requireOrigin(origin)
        if (kind != "image" && kind != "video") {
            throw CreativeException("invalidRequest", "invalidProjectKind")
        }
        val response = command(epoch, "media.project.create", buildJsonObject {
            put("name", name)
            put("kind", kind)
            put("width", width)
            put("height", height)
            frameRate?.let { put("frameRate", it) }
            put("storage", CreativeWire.encodeStorage(storage))
            put("origin", CreativeWire.encodeOrigin(origin))
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeMediaEnvelope(response)
    }

    override suspend fun apply(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
        commands: List<MediaEditCommand>,
    ): MediaProjectReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        requireOperationID(opID)
        if (commands.isEmpty() || commands.size > CreativeLimits.MEDIA_COMMANDS) {
            throw CreativeException("invalidRequest", "invalidCommandCount")
        }
        val response = command(epoch, "media.project.apply", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            put("opID", opID)
            putJsonArray("commands") {
                commands.forEach { add(CreativeWire.encodeMediaCommand(it)) }
            }
        })
        return CreativeWire.decodeMediaReceipt(response)
    }

    override suspend fun undo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt = undoRedo(
        "media.project.undo", projectID, expectedRevision, sessionToken, storage, origin, opID)

    override suspend fun redo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt = undoRedo(
        "media.project.redo", projectID, expectedRevision, sessionToken, storage, origin, opID)

    private suspend fun undoRedo(
        action: String,
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        requireOperationID(opID)
        val response = command(epoch, action, buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            put("opID", opID)
        })
        return CreativeWire.decodeMediaReceipt(response)
    }

    override suspend fun rename(
        projectID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ): MediaMutationReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        requireName(name)
        val response = command(epoch, "media.project.rename", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            put("name", name)
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            opID?.let {
                requireOperationID(it)
                put("opID", it)
            }
        })
        return CreativeWire.decodeMediaMutation(response)
    }

    override suspend fun delete(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ) {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        command(epoch, "media.project.delete", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            opID?.let {
                requireOperationID(it)
                put("opID", it)
            }
        })
    }

    override suspend fun importAsset(
        token: String,
        opID: String,
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
    ): MediaAssetReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireOperationID(opID)
        requireStaging(token, sessionToken)
        val response = command(epoch, "media.asset.importStaged", buildJsonObject {
            put("token", token)
            put("opID", opID)
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            put("sessionToken", sessionToken)
            put("fileName", boundedName(fileName))
            if (mimeType != null) put("mimeType", mimeType)
            put("byteCount", byteCount)
            put("sha256", sha256)
        })
        return CreativeWire.decodeMediaAssetReceipt(response)
    }

    override suspend fun relink(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        assetID: String,
        relativePath: String,
        opID: String?,
    ): MediaProjectReceipt {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        requireRevision(expectedRevision)
        if (!CreativeOwnership.isSafeRelativePath(relativePath) || relativePath.isEmpty()) {
            throw CreativeException("invalidRequest", "invalidAssetPath")
        }
        val response = command(epoch, "media.asset.relink", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("expectedRevision", expectedRevision)
            put("sessionToken", sessionToken)
            storage?.let { put("storage", CreativeWire.encodeStorage(it)) }
            origin?.let { requireOrigin(it); put("origin", CreativeWire.encodeOrigin(it)) }
            put("assetID", requireUUID(assetID, "assetID"))
            put("relativePath", relativePath)
            opID?.let {
                requireOperationID(it)
                put("opID", it)
            }
        })
        return CreativeWire.decodeMediaReceipt(response)
    }

    // MARK: - Atomic source-import creation

    /**
     * ONE closed native action publishes a complete non-empty canvas whose
     * initial document already references the ingested source asset. The
     * project ID is derived by native from [CreativeCanvasSourceRequest.opID],
     * so a retry cannot create a second project.
     */
    internal suspend fun createCanvasFromStaged(
        request: CreativeCanvasSourceRequest,
    ): CanvasProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(request.sessionToken)
        requireName(request.name)
        requireOperationID(request.opID)
        requireStaging(request.token, request.sessionToken)
        requireDigest(request.sha256)
        val response = command(epoch, "canvas.createFromStaged", buildJsonObject {
            put("token", request.token)
            put("opID", request.opID)
            put("name", request.name)
            request.workspaceID?.let {
                put("workspaceID", requireUUID(it, "workspaceID"))
            }
            put("fileName", boundedName(request.fileName))
            request.mimeType?.let { put("mimeType", it) }
            put("byteCount", request.byteCount)
            put("sha256", request.sha256)
            put("sourceKind", request.sourceKind)
            request.width?.let { put("width", it) }
            request.height?.let { put("height", it) }
            put("sessionToken", request.sessionToken)
        })
        return CreativeWire.decodeCanvasEnvelope(response)
    }

    /**
     * ONE closed native action publishes an image/video project whose initial
     * asset + image layer or video clip already exist. Dimensions/duration
     * come from the host's byte measurement and are re-validated natively.
     */
    internal suspend fun createMediaFromStaged(
        request: CreativeMediaSourceRequest,
    ): MediaProjectEnvelope {
        val epoch = requireBoundEpoch()
        requireSession(request.sessionToken)
        requireName(request.name)
        requireOperationID(request.opID)
        requireStaging(request.token, request.sessionToken)
        requireDigest(request.sha256)
        request.origin?.let { requireOrigin(it) }
        if (request.kind != "image" && request.kind != "video") {
            throw CreativeException("invalidRequest", "invalidProjectKind")
        }
        if (request.kind != request.sourceKind) {
            throw CreativeException("invalidRequest", "sourceKindMismatch")
        }
        if (request.width !in 2..8192 || request.height !in 2..8192) {
            throw CreativeException("invalidRequest", "invalidSourceDimensions")
        }
        request.durationSeconds?.let {
            if (request.kind == "video" && (!it.isFinite() || it <= 0.0)) {
                throw CreativeException("invalidRequest", "invalidSourceDuration")
            }
        }
        val response = command(epoch, "media.project.createFromStaged", buildJsonObject {
            put("token", request.token)
            put("opID", request.opID)
            put("name", request.name)
            put("kind", request.kind)
            put("storage", CreativeWire.encodeStorage(request.storage))
            request.origin?.let { put("origin", CreativeWire.encodeOrigin(it)) }
            put("fileName", boundedName(request.fileName))
            request.mimeType?.let { put("mimeType", it) }
            put("byteCount", request.byteCount)
            put("sha256", request.sha256)
            put("sourceKind", request.sourceKind)
            put("width", request.width)
            put("height", request.height)
            request.durationSeconds?.let { put("durationSeconds", it) }
            request.frameRate?.let { put("frameRate", it) }
            request.rotationDegrees?.let { put("rotationDegrees", it) }
            put("sessionToken", request.sessionToken)
        })
        return CreativeWire.decodeMediaEnvelope(response)
    }

    override suspend fun closeCanvasEditor(canvasID: String,
                                           sessionToken: String): Boolean {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        val response = command(epoch, "canvas.session.close", buildJsonObject {
            put("canvasID", requireUUID(canvasID, "canvasID"))
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeClosed(response)
    }

    override suspend fun closeWorkbenchEditor(projectID: String,
                                              sessionToken: String): Boolean {
        val epoch = requireBoundEpoch()
        requireSession(sessionToken)
        val response = command(epoch, "media.session.close", buildJsonObject {
            put("projectID", requireUUID(projectID, "projectID"))
            put("sessionToken", sessionToken)
        })
        return CreativeWire.decodeClosed(response)
    }

    internal suspend fun shutdownBinding() {
        // Wait for an already-dispatched exchange to settle before the root
        // is retired. A committed mutation keeps its native intent/receipt;
        // the next bind starts from the new accepted generation.
        exchangeMutex.withLock {
            handshake = null
            boundEpoch = null
            rootFingerprint = null
        }
    }

    // MARK: - Exchange

    private suspend fun command(epoch: Long, action: String,
                               payload: JsonObject): JsonObject = withContext(ioDispatcher) {
        exchangeLocked(CreativeWire.request(
            operation = "command", requestID = CreativeWire.newRequestID(),
            epoch = epoch, action = action, payload = payload))
    }

    private suspend fun exchangeLocked(request: JsonObject): JsonObject =
        exchangeMutex.withLock {
            val raw = try {
                transport.exchange(request.toString())
            } catch (error: CreativeException) {
                throw error
            } catch (error: Throwable) {
                throw CreativeException(
                    "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
            }
            if (raw.toByteArray(Charsets.UTF_8).size > CreativeLimits.RESPONSE_BYTES) {
                throw CreativeException("responseTooLarge", "bridgeResponseTooLarge")
            }
            CreativeWire.response(raw)
        }

    // MARK: - Guards

    private fun requireOrigin(origin: CreativeOriginContext) {
        if (!origin.isValid()) {
            throw CreativeException("invalidOrigin", "invalidOrigin")
        }
    }

    private fun requireSession(token: String) {
        CreativeOwnership.requireSessionToken(token)
    }

    private fun requireRevision(value: Long) {
        if (value < 0) throw CreativeException("invalidRequest", "invalidRevision")
    }

    private fun requireOperationID(value: String) {
        if (!value.matches(Regex("[A-Za-z0-9._-]{1,128}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
    }

    private fun requireUUID(value: String, field: String): String {
        return try {
            UUID.fromString(value).toString()
        } catch (_: IllegalArgumentException) {
            throw CreativeException("invalidRequest", "invalid_$field")
        }
    }

    private fun requireName(value: String) {
        val trimmed = value.trim()
        if (trimmed.isEmpty() ||
            trimmed.toByteArray(Charsets.UTF_8).size > CreativeLimits.NAME_BYTES) {
            throw CreativeException("invalidRequest", "invalidName")
        }
    }

    private fun boundedName(value: String): String {
        requireName(value)
        return value.trim()
    }

    private fun requireDigest(value: String) {
        if (value.length != 64 ||
            !value.all { it in "0123456789abcdefABCDEF" }
        ) {
            throw CreativeException("invalidRequest", "invalidDigest")
        }
    }

    private fun requireStaging(token: String, sessionToken: String) {
        if (!CreativeOwnership.isSafeStagingToken(token) ||
            !token.startsWith("$sessionToken.")) {
            throw CreativeException("assetStagingInvalid", "invalidStagingToken")
        }
    }

    private fun JsonObject.stringValue(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.boolValue(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()

    private fun JsonObject.longValue(key: String): Long? =
        (this[key] as? JsonPrimitive)?.content?.toLongOrNull()

    private fun JsonObject.arrayValue(key: String) =
        this[key] as? kotlinx.serialization.json.JsonArray
}
