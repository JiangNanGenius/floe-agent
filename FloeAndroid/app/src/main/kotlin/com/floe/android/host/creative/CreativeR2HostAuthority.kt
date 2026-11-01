// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.bridge.MediaFoundationNative
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.feature.workbench.RenderTicketDescriptor
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Plain native-issued authority grant; the Main adapter maps it to the
 *  platform module's `AuthorityGrant` without this app host importing it. */
data class R2AuthorityGrant(
    val epoch: Long,
    val mediaRootPath: String,
    val projectID: String?,
    val revision: Long?,
    val timelineDigest: String?,
)

/**
 * Plain authority decision. `accepted=false` is a normal typed refusal, not an
 * exception; `code` is the frozen R2/R1 error code.
 */
data class R2AuthorityDecision(
    val accepted: Boolean,
    val grant: R2AuthorityGrant?,
    val code: String? = null,
    val reason: String? = null,
    val retryable: Boolean = false,
)

/** Native-prepared immutable binding for BOTH image and video projects. */
data class R2PreparedRenderBinding(
    val context: CreativeProjectContext,
    val mediaRootPath: String,
    val projectRevision: Long,
    val timelineDigest: String,
    val attemptID: String,
    val snapshot: RenderSnapshotLease,
)

/** Opaque native pin for a direct platform export/playback/preview worker. */
data class R2RenderBindingPin(
    val pinHandle: String,
    val epoch: Long,
    val leaseID: String,
    val mediaRootPath: String,
    val projectID: String,
    val revision: Long,
    val timelineDigest: String,
    val expiresAt: String,
    /** Native echo of the prepared attempt / platform lifecycle identity. */
    val attemptID: String = "",
    /** `playback` | `export` | `preview` | `operation` (generic retain). */
    val kind: String = "operation",
)

/** Authorized per-project root for recovery; `ownerProof` is stable per
 *  durable project owner (never the ephemeral editor session digest). */
data class R2ProjectMediaRoot(
    val epoch: Long,
    val mediaRootPath: String,
    val projectID: String,
    val revision: Long,
    val timelineDigest: String,
    val storage: CreativeStorageLayer,
    val ownerKind: String,
    val ownerID: String?,
    val ownerProof: String,
    /** Canonical durable scopes for the platform recovery journal. */
    val storageKey: String = "",
    val originKey: String? = null,
    val writable: Boolean,
)

data class R2HostGenerationStatus(
    val epoch: Long,
    val live: Boolean,
    val baseRootPath: String?,
)

/** Injectable JNI seam (kept small so JVM tests never load the native lib). */
interface MediaFoundationNativeTransport {
    fun status(epoch: Long): ByteArray?
    fun verify(epoch: Long, action: String, request: ByteArray): ByteArray?
    fun prepare(epoch: Long, request: ByteArray): ByteArray?
    fun rootStop(epoch: Long): Int
    fun drainPending(epoch: Long): Int
}

internal object JniMediaFoundationNativeTransport : MediaFoundationNativeTransport {
    override fun status(epoch: Long): ByteArray? = MediaFoundationNative.status(epoch)
    override fun verify(epoch: Long, action: String, request: ByteArray): ByteArray? =
        MediaFoundationNative.verify(epoch, action, request)
    override fun prepare(epoch: Long, request: ByteArray): ByteArray? =
        MediaFoundationNative.prepare(epoch, request)
    override fun rootStop(epoch: Long): Int = MediaFoundationNative.rootStop(epoch)
    override fun drainPending(epoch: Long): Int =
        MediaFoundationNative.drainPending(epoch)
}

/**
 * Plain App-host authority inputs for the platform media factory.
 *
 * Every mutating/proving call is NATIVE-record-backed: `prepare` resolves the
 * canonical digest + immutable lease from the bound creative cluster; `retain`
 * pins that exact lease until the real worker completes; `resolveRoot`
 * re-authorizes the current session/project/storage/origin and returns the
 * trusted per-project root plus a stable durable-owner proof.
 *
 * `currentEpoch`/`isEpochLive`/`acceptedBaseRootPath` mirror the App-accepted
 * root/epoch the native bind used. They are only the cheap synchronous fence;
 * no authority decision trusts them alone. `acceptedBaseRootPath` is the
 * accepted ANCESTOR root and is suitable only for journals — renderer roots
 * always come from a native lease or `resolveProjectMediaRoot`.
 *
 * This class deliberately imports no platform12/platformclosure module. Main
 * maps these plain DTOs to the concrete adapter interfaces in the integrated
 * batch.
 */
class CreativeR2HostAuthority(
    private val epochProvider: () -> Long?,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val native: MediaFoundationNativeTransport =
        JniMediaFoundationNativeTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun currentEpoch(): Long = epochProvider()?.takeIf { it > 0L } ?: 0L

    fun isEpochLive(epoch: Long): Boolean =
        epoch > 0L && epoch == epochProvider()

    fun acceptedBaseRootPath(): String? {
        val accepted = acceptedRootProvider() ?: return null
        if (accepted.epoch != epochProvider()) return null
        return accepted.path
    }

    suspend fun nativeStatus(): R2HostGenerationStatus = withContext(ioDispatcher) {
        val epoch = requireEpoch()
        val response = decode(native.status(epoch))
            ?: throw authorityUnavailable()
        if (response.bool("ok") != true) throw failure(response)
        R2HostGenerationStatus(
            epoch = response.long("epoch") ?: epoch,
            live = response.bool("live") ?: false,
            baseRootPath = response.string("baseRootPath"))
    }

    /** Image AND video: one native load + canonical digest + immutable lease. */
    suspend fun prepareRenderBinding(
        context: CreativeProjectContext,
        expectedRevision: Long,
        attemptID: String,
    ): R2PreparedRenderBinding = withContext(ioDispatcher) {
        if (expectedRevision < 0) {
            throw CreativeException("invalidRequest", "invalidRevision")
        }
        if (!attemptID.matches(Regex("[A-Za-z0-9._-]{1,64}"))) {
            throw CreativeException("invalidRequest", "invalidAttemptID")
        }
        val epoch = requireEpoch()
        val payload = buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("expectedRevision", expectedRevision)
            put("attemptID", attemptID)
        }
        val response = decode(native.prepare(epoch, payload.toString().toByteArray()))
            ?: throw authorityUnavailable()
        if (response.bool("ok") != true) throw failure(response)
        R2MediaWire.decodePreparedBinding(response, context)
    }

    /** Retains a prepared binding for one real direct platform worker. */
    suspend fun retainRenderBinding(
        binding: R2PreparedRenderBinding,
        ownerOperationID: String,
    ): R2RenderBindingPin = withContext(ioDispatcher) {
        if (ownerOperationID.isBlank() || ownerOperationID.length > 128) {
            throw CreativeException("invalidRequest", "invalidOwnerOperationID")
        }
        val epoch = requireEpoch()
        val payload = buildJsonObject {
            put("binding", R2MediaWire.encodePreparedBinding(binding))
            put("ownerOperationID", ownerOperationID)
        }
        val response = verify(epoch, "retainBinding", payload)
        R2MediaWire.decodeRenderBindingPin(response)
    }

    /** Release ONLY after the real worker/codec IO has actually completed. */
    suspend fun releaseRenderBindingPin(pin: R2RenderBindingPin): Boolean =
        releaseRenderBindingPin(pin.pinHandle)

    /** Platformclosure15 `WorkbenchMediaLifecycleAuthority.release(pinToken)`. */
    suspend fun releaseMediaLifecycle(pinToken: String): Boolean =
        releaseRenderBindingPin(pinToken)

    suspend fun releaseRenderBindingPin(pinHandle: String): Boolean =
        withContext(ioDispatcher) {
            val epoch = requireEpoch()
            val payload = buildJsonObject { put("pinHandle", pinHandle) }
            val response = verify(epoch, "releasePin", payload)
            response.bool("released") ?: true
        }

    /**
     * Platform `WorkbenchMediaLifecycleAuthority.pin` input: reauthorizes the
     * CURRENT editor session and pins the exact native-prepared lease for this
     * epoch/project/attempt. The caller cannot supply a lease or retarget a
     * root. Release only after the real player/encoder/renderer has stopped.
     */
    suspend fun pinMediaLifecycle(
        context: CreativeProjectContext,
        kind: String,
        epoch: Long,
        mediaRootPath: String,
        attemptID: String,
        jobID: String? = null,
    ): R2RenderBindingPin = withContext(ioDispatcher) {
        if (epoch <= 0L || epoch != requireEpoch()) {
            throw CreativeException("staleGeneration", "staleLifecycleEpoch")
        }
        val payload = buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("kind", kind)
            put("epoch", epoch)
            put("mediaRootPath", mediaRootPath)
            put("attemptID", attemptID)
            jobID?.let { put("jobID", it) }
        }
        val response = verify(epoch, "pinLifecycle", payload)
        R2MediaWire.decodeRenderBindingPin(response)
    }

    suspend fun resolveProjectMediaRoot(
        context: CreativeProjectContext,
    ): R2ProjectMediaRoot = withContext(ioDispatcher) {
        val epoch = requireEpoch()
        val payload = buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
        }
        val response = verify(epoch, "resolveRoot", payload)
        R2MediaWire.decodeProjectMediaRoot(response)
    }

    suspend fun validateRenderBinding(
        binding: R2PreparedRenderBinding,
    ): R2AuthorityDecision = decision(
        action = "renderBinding",
        payload = R2MediaWire.encodePreparedBinding(binding))

    suspend fun validateProbeRoot(
        context: CreativeProjectContext,
        mediaRootPath: String,
        relativePath: String,
    ): R2AuthorityDecision = decision(
        action = "probeRoot",
        payload = buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("mediaRootPath", mediaRootPath)
            put("relativePath", relativePath)
        })

    suspend fun validateTicket(
        descriptor: RenderTicketDescriptor,
        claimToken: String,
    ): R2AuthorityDecision = decision(
        action = "ticket",
        payload = buildJsonObject {
            put("descriptor", R2MediaWire.encodeDescriptor(descriptor))
            put("claimToken", claimToken)
        })

    /** Aggregate Root stop gate. FALSE = owned work remains; Root stays bound. */
    suspend fun rootStop(): Boolean = withContext(ioDispatcher) {
        val epoch = requireEpoch()
        native.rootStop(epoch) == 0
    }

    suspend fun drainPending(): Int = withContext(ioDispatcher) {
        val epoch = requireEpoch()
        native.drainPending(epoch)
    }

    private suspend fun decision(
        action: String,
        payload: JsonObject,
    ): R2AuthorityDecision = withContext(ioDispatcher) {
        val epoch = epochProvider()
        if (epoch == null || epoch <= 0L) {
            return@withContext R2AuthorityDecision(
                accepted = false, grant = null,
                code = "staleGeneration", reason = "acceptedRootNotLive",
                retryable = true)
        }
        try {
            val response = verify(epoch, action, payload)
            R2MediaWire.decodeAuthorityDecision(response)
        } catch (error: CreativeException) {
            R2AuthorityDecision(
                accepted = false, grant = null, code = error.code,
                reason = error.reason, retryable = error.retryable)
        }
    }

    private suspend fun verify(
        epoch: Long,
        action: String,
        payload: JsonObject,
    ): JsonObject {
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        if (body.size > 16 * 1024) {
            throw CreativeException("requestTooLarge", "authorityRequestTooLarge")
        }
        val response = decode(native.verify(epoch, action, body))
            ?: throw authorityUnavailable()
        if (response.bool("ok") != true) throw failure(response)
        return response
    }

    private fun decode(bytes: ByteArray?): JsonObject? = try {
        bytes?.let { json.parseToJsonElement(it.toString(Charsets.UTF_8)) as? JsonObject }
    } catch (_: Throwable) {
        null
    }

    private fun failure(response: JsonObject): CreativeException =
        CreativeException(
            code = response.string("error") ?: "invalidCoreResponse",
            reason = response.string("reason"),
            retryable = response.bool("retryable") ?: false)

    private fun authorityUnavailable(): CreativeException = CreativeException(
        "rendererUnavailable", "authorityUnavailable", retryable = true)

    private fun requireEpoch(): Long {
        val epoch = epochProvider()
        if (epoch == null || epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        return epoch
    }
}
