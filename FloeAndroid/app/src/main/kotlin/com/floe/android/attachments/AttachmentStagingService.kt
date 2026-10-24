// SPDX-License-Identifier: MPL-2.0
package com.floe.android.attachments

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import com.floe.android.bridge.AttachmentStagingNative
import com.floe.android.bridge.SwiftCore

/**
 * RB-7 attachment staging — the Android platform-side service.
 *
 * Responsibility split (Main architecture, unchanged):
 *  - THIS class owns nothing durable. It streams an ACTUAL user-picked
 *    content URI (SAF OpenDocument / PhotoPicker result) in bounded 64 KiB
 *    chunks through the trusted native ingress channel, then drives the
 *    EXISTING seven BridgeV3 attachment commands over the standard command/
 *    effect mailbox. No new wire labels, no new storage schema, no second
 *    business DB, no network.
 *  - The Swift service (FloeAndroidCore) owns paths, files, sizes, digests,
 *    handles, leases and the ORIGINAL schema-46 rows. Raw URIs, paths and
 *    bytes NEVER enter this class's logs, results' toString, prompts or
 *    fixtures; only opaque receipts, ids and typed codes cross back.
 *
 * Honesty rules implemented here:
 *  - scoped grants from the actual pick result only (no broad
 *    file permissions); persistable grants are taken ONLY when the caller
 *    asked for cross-restart re-read AND the source advertises the read
 *    grant; failures degrade honestly to the session-scoped read;
 *  - MIME/name/size are UNTRUSTED hints, clamped and re-validated natively;
 *  - the real byte count is measured by the pump; unknown provider sizes
 *    (pipes) and short/interrupted reads are supported truthfully;
 *  - no whole-file readBytes, no unbounded buffers, no base64 of file
 *    content, no binary inside JSON;
 *  - cancel closes the stream and aborts the native session; the original
 *    document is never deleted, moved or rewritten;
 *  - a staged result is independent of later URI revocation because the
 *    bytes were fully copied into app-private storage BEFORE publish.
 *
 * AUTHORED ONLY: not compiled, not executed, no device claim.
 */

/* ------------------------------ seams ------------------------------- */

/** The native staging channel (production: [com.floe.android.bridge.AttachmentStagingNative];
 *  JVM tests inject a scripted double — same contract). */
interface StagingNativeApi {
    fun ensureLoaded()
    fun routeOpen(conversationId: String?, incarnation: Long, draftRevision: Long): String
    fun routeClose(routeReceipt: String)
    /** Returns (ingressReceipt, stagingId). */
    fun begin(routeReceipt: String, reusingStagingId: String?): Pair<String, String>
    fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int)
    fun end(ingressReceipt: String, displayNameHint: String?, mimeTypeHint: String?)
    fun abort(ingressReceipt: String)
    fun progress(ingressReceipt: String): StagingProgress
    fun stagingRead(handle: String, offset: Long, buffer: ByteArray): Int
    fun attachmentRead(attachmentId: String, conversationId: String,
                       offset: Long, buffer: ByteArray): Int
    fun status(): String?
}

data class StagingProgress(val bytes: Long, val finished: Boolean, val cancelled: Boolean)

/** The bridge mailbox (same `SwiftCore.exchange` text channel the reviewed
 *  runtime bootstrap coordinator uses; injected for tests). */
interface StagingBridgeExchange {
    fun exchange(request: String): String
}

/** One actual content source behind a picked URI, abstracted so the pump is
 *  JVM-testable with a synthetic document provider double. */
interface StagingContentSource {
    /** Untrusted display-name hint (sanitized again natively). */
    val displayNameHint: String?
    /** Untrusted MIME hint. */
    val mimeTypeHint: String?
    /** Untrusted declared size; null when the provider cannot report one
     *  (unknown-size pipes). A wrong-but-declared size is caught by the
     *  pump's actual counting, never trusted. */
    fun declaredByteCount(): Long?
    /** Open the read stream. The ONLY place the source is touched; throws
     *  [StagingSourceUnavailable] / [StagingGrantRevoked] / IOException. */
    fun openRead(): StagingInputStream
    /** Release any grant this service actually took (never the source's own
     *  permissions; never after the copy settles for transient reads). */
    fun releaseTransientRead() {}
}

interface StagingInputStream {
    /** Standard stream contract: -1 EOF, 0 = nothing right now (retry up
     *  to [MAX_ZERO_READS] then honest interruption), >0 bytes copied. */
    fun read(buffer: ByteArray, offset: Int, length: Int): Int
    fun close()
}

class StagingSourceUnavailable(message: String) : Exception(message)
class StagingGrantRevoked(message: String) : Exception(message)
class StagingInterruptedRead : Exception("staging_interrupted_read")

/* ------------------------------ results ------------------------------ */

/** Closed typed outcomes. Values carry ONLY opaque identifiers and codes —
 *  never URIs, paths or file bytes (safe for logs/toString/diagnostics). */
sealed class StagingOutcome {
    data class Staged(val stagingId: String, val handle: String,
                      val byteCount: Long, val sha256: String) : StagingOutcome()
    data class Accepted(val fields: Map<String, String>) : StagingOutcome()
    data class Refused(val code: String) : StagingOutcome()
    object Timeout : StagingOutcome()
    object Unavailable : StagingOutcome()
}

/** One registered compose route (opaque receipt + the REAL identity parts
 *  the caller already owns). */
class StagingRoute internal constructor(
    val receipt: String,
    val conversationId: String?,
    val incarnation: Long,
    val draftRevision: Long,
) {
    override fun toString(): String =
        "StagingRoute(receipt=<opaque>, conversation=${conversationId != null}, " +
            "incarnation=$incarnation, draftRevision=$draftRevision)"
}

/* ------------------------------ service ------------------------------ */

class AttachmentStagingService(
    private val native: StagingNativeApi,
    private val bridge: StagingBridgeExchange,
    private val json: Json = Json { ignoreUnknownKeys = false; isLenient = false },
    private val pollDelayMillis: Long = 25,
    private val pollDeadlineMillis: Long = 30_000,
) {
    companion object {
        /** Hard chunk bound (matches AttachmentStagingLimits.maximumChunkBytes). */
        const val CHUNK_BYTES = 65536
        /** Per-operation handle budget (matches the native maximum). */
        const val MAX_HANDLES_PER_OPERATION = 8
        const val MAX_DECLARED_BYTES = 128L * 1024L * 1024L
        private const val MAX_ZERO_READS = 3
        private const val POLL_MAX_ADVANCE = 64
    }

    /** Typed, secret-free failures surfaced to callers. */
    class StagingFailure(val code: String) : Exception(code)

    private val correlationFloor = java.util.concurrent.atomic.AtomicLong(0)
    private fun nextCorrelation(): String =
        "stg-" + (correlationFloor.incrementAndGet()) + "-" + UUID.randomUUID()

    /* ------------------------------ routes ------------------------------ */

    /**
     * Register the composer's CURRENT route with the trusted native host.
     * Temporary sessions are refused BEFORE any source is touched (RB5
     * owns the RAM ceiling; attachments are simply not offered there) —
     * this is the first of the two gates; the native gate is the second.
     */
    fun openRoute(conversationId: UUID?, incarnation: Long, draftRevision: Long,
                  isTemporarySession: Boolean): StagingRoute {
        if (isTemporarySession) throw StagingFailure("temporaryRefused")
        require(incarnation > 0) { "incarnation must be a real session epoch" }
        native.ensureLoaded()
        val receipt = native.routeOpen(conversationId?.toString(),
                                       incarnation, draftRevision)
        return StagingRoute(receipt, conversationId?.toString(), incarnation,
                             draftRevision)
    }

    /** Navigation-away only (never UI reconstruction/background): aborts
     *  that route's live ingresses; staged bytes survive for explicit
     *  discard/consumption. */
    fun closeRoute(route: StagingRoute) {
        native.routeClose(route.receipt)
    }

    /* ------------------------------ import ------------------------------ */

    /**
     * Stream ONE actual picked source into host staging and finalize it
     * through the existing `attachment.stage` command.
     *
     * `reusingStagingId` is the retry contract (same attachment id, host
     * re-derives the bytes).
     */
    suspend fun importPicked(
        route: StagingRoute,
        source: StagingContentSource,
        maxBytes: Long = MAX_DECLARED_BYTES,
        reusingStagingId: String? = null,
        requirePersistableGrant: Boolean = false,
        onProgress: (suspend (StagingProgress) -> Unit)? = null,
        cancelCheck: () -> Boolean = { false },
    ): StagingOutcome {
        require(maxBytes in 1..MAX_DECLARED_BYTES) { "maxBytes outside contract" }
        if (reusingStagingId != null) {
            UUID.fromString(reusingStagingId)  // typed refusal otherwise
        }
        // Declared size (UNTRUSTED) is checked BEFORE the source opens so a
        // known-oversized file never touches IO. Actual bytes are bounded
        // again during the pump.
        val declared = source.declaredByteCount()
        declared?.let {
            if (it <= 0) throw StagingFailure("sourceUnavailable")
            if (it > maxBytes) throw StagingFailure("sizeExceeded")
        }
        val (ingressReceipt, stagingId) = try {
            native.begin(route.receipt, reusingStagingId)
        } catch (failure: com.floe.android.bridge.AttachmentStagingNativeException) {
            throw StagingFailure(nativeStatusName(failure.status))
        }
        var stream: StagingInputStream? = null
        var delivered = 0L
        var pumpError: String? = null
        try {
            (source as? AndroidContentResolverSource)?.retainReadGrant(requirePersistableGrant)
            stream = try {
                source.openRead()
            } catch (_: FileNotFoundException) {
                // Unavailable URI: the begun ingress is aborted (temp
                // removed), the grant released, and the caller gets the
                // typed outcome — never a staged record.
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused("sourceUnavailable")
            } catch (_: SecurityException) {
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused("grantRevoked")
            } catch (_: StagingGrantRevoked) {
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused("grantRevoked")
            } catch (_: StagingSourceUnavailable) {
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused("sourceUnavailable")
            }
            val buffer = ByteArray(CHUNK_BYTES)
            var zeroReads = 0
            while (true) {
                if (cancelCheck()) {
                    pumpError = "cancelled"
                    break
                }
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                val n = try {
                    stream.read(buffer, 0, CHUNK_BYTES)
                } catch (_: IOException) {
                    pumpError = "readFailed"
                    break
                } catch (_: SecurityException) {
                    // Revocation mid-stream: the PARTIAL temp is aborted;
                    // no staged record can exist from it.
                    pumpError = "grantRevoked"
                    break
                }
                if (n < 0) break                       // clean EOF
                if (n == 0) {
                    if (++zeroReads > MAX_ZERO_READS) {
                        pumpError = "interruptedRead"
                        break
                    }
                    delay(pollDelayMillis)
                    continue
                }
                zeroReads = 0
                delivered += n
                // Untrusted declared size: ACTUAL bytes beyond the declared
                // total are a typed refusal, never a silent over-stage.
                if (delivered > maxBytes
                        || (declared != null && delivered > declared)) {
                    pumpError = "sizeExceeded"
                    break
                }
                try {
                    native.write(ingressReceipt, buffer, 0, n)
                } catch (failure: com.floe.android.bridge.AttachmentStagingNativeException) {
                    pumpError = nativeStatusName(failure.status)
                    break
                }
                onProgress?.invoke(safeProgress(ingressReceipt))
            }
            if (pumpError != null) {
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused(pumpError!!)
            }
            if (delivered == 0L) {
                // A zero-byte "file" is not staged: honest refusal, temp
                // removed, no record, no row.
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused("sourceUnavailable")
            }
            try {
                native.end(ingressReceipt, source.displayNameHint, source.mimeTypeHint)
            } catch (failure: com.floe.android.bridge.AttachmentStagingNativeException) {
                abortQuietly(ingressReceipt)
                return StagingOutcome.Refused(nativeStatusName(failure.status))
            }
        } catch (cancellation: CancellationException) {
            abortQuietly(ingressReceipt)
            throw cancellation
        } catch (_: Exception) {
            abortQuietly(ingressReceipt)
            return StagingOutcome.Refused("sourceUnavailable")
        } finally {
            try { stream?.close() } catch (_: IOException) {}
            // Keep the shared reference through the actual stream close,
            // including cancellation/failure. No other feature loses it early.
            runCatching { source.releaseTransientRead() }
        }
        // Submit the EXISTING attachment.stage command; the native host
        // performs the atomic rename/verify/publish. Arrival never sends
        // anything.
        val payload = buildMap<String, JsonElement> {
            put("ingressReceipt", JsonPrimitive(ingressReceipt))
        }
        // NOTE: a persistable grant is NOT taken just because a URI
        // "might" survive; only when the caller proved the need and the
        // source advertised the read grant (requirePersistableGrant above).
        return submitAndAwait(
            scopeCommand = ScopeCommand.Configuration(
                command = "attachment.stage",
                configurationScope = "attachmentStaging",
            ),
            payload = JsonObject(payload),
        )
    }

    private fun safeProgress(ingressReceipt: String): StagingProgress = try {
        native.progress(ingressReceipt)
    } catch (_: Exception) {
        StagingProgress(0, false, true)
    }

    private fun abortQuietly(ingressReceipt: String) {
        try { native.abort(ingressReceipt) } catch (_: Exception) {}
    }

    /* ------------------------------ commands ------------------------------ */

    /** `attachment.staging.cancel` for a LIVE ingress by staging id. */
    suspend fun cancelStaging(stagingId: UUID): StagingOutcome =
        submitAndAwait(
            ScopeCommand.Configuration("attachment.staging.cancel", "attachmentStaging"),
            JsonObject(mapOf("stagingID" to JsonPrimitive(stagingId.toString()))),
        )

    /** Immediate native fast-abort for the owner coroutine (the command
     *  above is the model-visible record; both are idempotent truths). */
    fun abortIngressNow(ingressReceipt: String) = abortQuietly(ingressReceipt)

    /** `attachment.staging.discard` for one staged handle. */
    suspend fun discardStaged(handle: String): StagingOutcome =
        submitAndAwait(
            ScopeCommand.Configuration("attachment.staging.discard", "attachmentStaging"),
            JsonObject(mapOf("stagingHandle" to JsonPrimitive(handle))),
        )

    /** `attachment.staging.read` metadata/progress for one staged record. */
    suspend fun stagedSnapshot(stagingId: UUID): StagingOutcome =
        submitAndAwait(
            ScopeCommand.Configuration("attachment.staging.read", "attachmentStaging"),
            JsonObject(mapOf("stagingID" to JsonPrimitive(stagingId.toString()))),
        )

    /** `attachment.commit`: persist exact owned staged handles as
     *  conversation-level rows through the ORIGINAL store CAS. */
    suspend fun commitStaged(
        conversationId: UUID,
        conversationDigest: String,
        handles: List<String>,
    ): StagingOutcome {
        if (handles.isEmpty() || handles.size > MAX_HANDLES_PER_OPERATION) {
            throw StagingFailure("payloadInvalid")
        }
        val payload = JsonObject(mapOf(
            "stagingHandles" to JsonArray(handles.map { JsonPrimitive(it) }),
        ))
        return submitAndAwait(
            ScopeCommand.Lifecycle(
                command = "attachment.commit",
                taskID = conversationId.toString(),
                revisionResourceID = "conversation." + conversationId,
                revisionVersion = conversationDigest,
            ),
            payload,
        )
    }

    /** `attachment.read`: ownership verify + mint the native read grant. */
    suspend fun readAttachment(attachmentId: UUID, conversationId: UUID): StagingOutcome =
        submitAndAwait(
            ScopeCommand.Lifecycle(
                command = "attachment.read",
                taskID = conversationId.toString(),
                revisionResourceID = null,
                revisionVersion = null,
            ),
            JsonObject(mapOf("attachmentID" to JsonPrimitive(attachmentId.toString()))),
        )

    /** `attachment.cancel`: cancel a committed pre-run row (digest CAS). */
    suspend fun cancelCommittedRow(
        conversationId: UUID,
        attachmentId: UUID,
        rowDigest: String,
    ): StagingOutcome =
        submitAndAwait(
            ScopeCommand.Lifecycle(
                command = "attachment.cancel",
                taskID = conversationId.toString(),
                revisionResourceID = "attachment." + attachmentId,
                revisionVersion = rowDigest,
            ),
            JsonObject(mapOf("attachmentID" to JsonPrimitive(attachmentId.toString()))),
        )

    /** Bounded preview bytes of a STAGED file (host-only channel). */
    fun readStagedPreview(handle: String, offset: Long = 0,
                          maxBytes: Int = CHUNK_BYTES): ByteArray {
        require(maxBytes in 1..CHUNK_BYTES)
        val buffer = ByteArray(maxBytes)
        val copied = native.stagingRead(handle, offset, buffer)
        if (copied < 0) throw StagingFailure(nativeStatusName(copied))
        return if (copied == maxBytes) buffer else buffer.copyOf(maxOf(copied, 0))
    }

    /** Bounded preview bytes of a COMMITTED attachment (grant-gated). */
    fun readAttachmentPreview(attachmentId: UUID, conversationId: UUID,
                              offset: Long = 0,
                              maxBytes: Int = CHUNK_BYTES): ByteArray {
        require(maxBytes in 1..CHUNK_BYTES)
        val buffer = ByteArray(maxBytes)
        val copied = native.attachmentRead(attachmentId.toString(),
                                           conversationId.toString(), offset, buffer)
        if (copied < 0) throw StagingFailure(nativeStatusName(copied))
        return if (copied == maxBytes) buffer else buffer.copyOf(maxOf(copied, 0))
    }

    /* ------------------------------ wire helpers ------------------------------ */

    sealed class ScopeCommand {
        abstract val command: String
        data class Configuration(override val command: String,
                                 val configurationScope: String) : ScopeCommand()
        data class Lifecycle(override val command: String, val taskID: String,
                             val revisionResourceID: String?,
                             val revisionVersion: String?) : ScopeCommand()
    }

    /** Build one closed v3 command.submit envelope (all values escaped via
     *  the structured library — never string concatenation), submit it, and
     *  pump its operation effects through the EXISTING effect.poll channel
     *  until terminal. Queue receipt carries no domain identity; a staged
     *  identity exists only when the native file effect settled accepted. */
    private suspend fun submitAndAwait(scopeCommand: ScopeCommand,
                                       payload: JsonObject): StagingOutcome {
        val correlation = nextCorrelation()
        val envelope = buildMap<String, JsonElement> {
            put("schema", JsonPrimitive("floe.command-envelope/3"))
            when (scopeCommand) {
                is ScopeCommand.Configuration -> {
                    put("scope", JsonPrimitive("applicationConfiguration"))
                    put("configurationScope", JsonPrimitive(scopeCommand.configurationScope))
                    put("stateful", JsonPrimitive(false))
                }
                is ScopeCommand.Lifecycle -> {
                    put("scope", JsonPrimitive("conversationLifecycle"))
                    put("owner", JsonObject(mapOf(
                        "taskID" to JsonPrimitive(scopeCommand.taskID),
                    )))
                    val stateful = scopeCommand.revisionResourceID != null
                    put("stateful", JsonPrimitive(stateful))
                    if (scopeCommand.revisionResourceID != null
                            && scopeCommand.revisionVersion != null) {
                        put("revision", JsonObject(mapOf(
                            "resourceID" to JsonPrimitive(scopeCommand.revisionResourceID),
                            "version" to JsonPrimitive(scopeCommand.revisionVersion),
                        )))
                    }
                }
            }
            put("command", JsonPrimitive(scopeCommand.command))
            put("correlationID", JsonPrimitive(correlation))
            put("payload", payload)
        }
        val request = JsonObject(mapOf(
            "version" to JsonPrimitive(3),
            "requestID" to JsonPrimitive(correlation),
            "operation" to JsonPrimitive("command.submit"),
            "envelope" to JsonObject(envelope),
        ))
        val submit = parseObject(bridge.exchange(request.toString()))
            ?: return StagingOutcome.Unavailable
        if (submit["ok"] !is JsonPrimitive || submit["ok"]?.jsonBoolean() != true) {
            return StagingOutcome.Refused(submit["reason"]?.stringOr("rejected")
                ?: "rejected")
        }
        val receipt = submit["operationReceiptID"]?.stringOrNull() ?: return StagingOutcome.Unavailable
        return pumpEffects(correlation, receipt)
    }

    private suspend fun pumpEffects(correlation: String, receipt: String): StagingOutcome {
        var sequence = 0L
        var resyncWalk = false
        var waited = 0L
        var advanced = 0
        while (waited < pollDeadlineMillis) {
            advanced += 1
            if (advanced > POLL_MAX_ADVANCE * 8) return StagingOutcome.Timeout
            val poll = buildMap<String, JsonElement> {
                put("schema", JsonPrimitive("floe.effect-cursor/3"))
                put("scope", JsonPrimitive("applicationConfiguration"))
                put("configurationScope", JsonPrimitive("operations"))
                put("command", JsonPrimitive("effect.poll"))
                put("stateful", JsonPrimitive(false))
                put("correlationID", JsonPrimitive(correlation))
                put("effect", JsonObject(mapOf(
                    "operationReceiptID" to JsonPrimitive(receipt),
                    "sequence" to JsonPrimitive(sequence),
                )))
            }
            val request = JsonObject(mapOf(
                "version" to JsonPrimitive(3),
                "requestID" to JsonPrimitive(correlation),
                "operation" to JsonPrimitive("effect.poll"),
                "envelope" to JsonObject(poll),
            ))
            val response = parseObject(bridge.exchange(request.toString()))
                ?: return StagingOutcome.Unavailable
            if (response["ok"]?.jsonBoolean() != true) {
                val reason = response["reason"]?.stringOrNull()
                return StagingOutcome.Refused(reason ?: "unavailable")
            }
            val effects = response["effects"] as? JsonArray ?: JsonArray(emptyList())
            for (raw in effects) {
                val item = raw as? JsonObject ?: continue
                val kind = item["kind"]?.stringOrNull() ?: continue
                val detail = item["detail"]?.detailMap() ?: emptyMap()
                val nextSequence = (item["sequence"] as? JsonPrimitive)?.longOrNull
                    ?: return StagingOutcome.Unavailable
                if (resyncWalk) {
                    // Explicit resync: the next reported sequence restarts
                    // the walk; never a skip-confirm gap refusal.
                    resyncWalk = false
                    sequence = nextSequence
                } else if (nextSequence != sequence + 1) {
                    if (kind == "resyncRequired") {
                        resyncWalk = true
                        sequence = nextSequence
                    } else {
                        return StagingOutcome.Unavailable
                    }
                } else {
                    sequence = nextSequence
                }
                when (kind) {
                    "accepted" -> return mapAccepted(detail)
                    "rejected", "failed" -> return StagingOutcome.Refused(
                        detail["code"] ?: item["code"]?.stringOrNull() ?: kind)
                    "cancelled" -> return StagingOutcome.Refused("cancelled")
                    "replaced", "closed" -> return StagingOutcome.Refused("generationFenced")
                    "resyncRequired" -> { resyncWalk = true }
                    else -> Unit  // prepared/started stages: keep pumping
                }
            }
            if (response["hasMore"]?.jsonBoolean() != true) delay(pollDelayMillis)
            waited += pollDelayMillis
        }
        return StagingOutcome.Timeout
    }

    private fun mapAccepted(detail: Map<String, String>): StagingOutcome {
        val result = detail["result"]
        if (result == "refused") return StagingOutcome.Refused(detail["code"] ?: "refused")
        val stagingId = detail["stagingID"]
        val handle = detail["stagingHandle"]
        val sha = detail["sha256"]
        val bytes = detail["byteCount"]?.toLongOrNull()
        if (stagingId != null && handle != null && sha != null && bytes != null) {
            return StagingOutcome.Staged(stagingId, handle, bytes, sha)
        }
        return StagingOutcome.Accepted(detail)
    }

    private fun parseObject(text: String): JsonObject? =
        try { json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null }

    private fun JsonElement.stringOrNull(): String? {
        val primitive = this as? JsonPrimitive ?: return null
        return if (primitive.isString) primitive.content else null
    }

    private fun JsonElement.jsonBoolean(): Boolean? =
        (this as? JsonPrimitive)?.booleanOrNull

    private fun JsonElement.longOrNull(): Long? =
        (this as? JsonPrimitive)?.longOrNull

    private fun JsonElement.detailMap(): Map<String, String> {
        val array = this as? JsonArray ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (raw in array) {
            val pair = raw as? JsonObject ?: continue
            val key = pair["key"]?.stringOrNull() ?: continue
            val value = pair["value"]?.stringOrNull() ?: continue
            out[key] = value
        }
        return out
    }

    private fun JsonElement?.stringOr(fallback: String): String =
        this?.stringOrNull() ?: fallback

    private fun nativeStatusName(status: Int): String = when (status) {
        -105 -> "payloadInvalid"
        -106 -> "payloadTooLarge"
        -301 -> "notInstalled"
        -302 -> "generationFenced"
        -303 -> "routeUnknown"
        -304 -> "temporaryRefused"
        -305 -> "ingressUnknown"
        -306 -> "stateConflict"
        -307 -> "sizeExceeded"
        -308 -> "aggregateExceeded"
        -309 -> "diskFull"
        -310 -> "saturated"
        -311 -> "writeFailed"
        -312 -> "readFailed"
        -313 -> "handleUnknown"
        -314 -> "grantMissing"
        -315 -> "digestMismatch"
        -316 -> "partial"
        else -> "internal"
    }

}

/**
 * Production bindings of the two seams. The app composes the service with
 * these objects; JVM tests use scripted doubles with the same contracts.
 * No path/URI/bytes ever appears in these adapters' error paths.
 */
object ProductionStagingNative : StagingNativeApi {
    override fun ensureLoaded() {
        // The object initializer loads libfloe_jni exactly once; this call
        // forces the class-init on the worker thread (never Application main).
        AttachmentStagingNative.stagingStatus()
    }
    override fun routeOpen(conversationId: String?, incarnation: Long,
                           draftRevision: Long): String =
        AttachmentStagingNative.stagingRouteOpen(conversationId, incarnation,
                                                 draftRevision, false)
    override fun routeClose(routeReceipt: String) =
        AttachmentStagingNative.stagingRouteClose(routeReceipt)
    override fun begin(routeReceipt: String, reusingStagingId: String?): Pair<String, String> {
        val joined = AttachmentStagingNative.stagingBegin(routeReceipt, reusingStagingId)
        val parts = joined.split(' ', limit = 2)
        require(parts.size == 2 && parts[0].isNotEmpty() && parts[1].isNotEmpty()) {
            "staging_begin_shape"
        }
        return parts[0] to parts[1]
    }
    override fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int) =
        AttachmentStagingNative.stagingWrite(ingressReceipt, data, offset, length)
    override fun end(ingressReceipt: String, displayNameHint: String?,
                     mimeTypeHint: String?) =
        AttachmentStagingNative.stagingEnd(ingressReceipt, displayNameHint, mimeTypeHint)
    override fun abort(ingressReceipt: String) =
        AttachmentStagingNative.stagingAbort(ingressReceipt)
    override fun progress(ingressReceipt: String): StagingProgress {
        val raw = AttachmentStagingNative.stagingProgress(ingressReceipt)
        val parts = raw.split(' ')
        require(parts.size == 3) { "staging_progress_shape" }
        return StagingProgress(
            bytes = parts[0].toLongOrNull() ?: throw IllegalStateException("staging_progress_bytes"),
            finished = parts[1] == "1",
            cancelled = parts[2] == "1",
        )
    }
    override fun stagingRead(handle: String, offset: Long, buffer: ByteArray): Int =
        AttachmentStagingNative.stagingRead(handle, offset, buffer)
    override fun attachmentRead(attachmentId: String, conversationId: String,
                                offset: Long, buffer: ByteArray): Int =
        AttachmentStagingNative.attachmentRead(attachmentId, conversationId, offset, buffer)
    override fun status(): String? = AttachmentStagingNative.stagingStatus()
}

/** The frozen, reviewed `SwiftCore.exchange` text channel. */
object ProductionStagingExchange : StagingBridgeExchange {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

/**
 * The Android content-source implementation over a REAL SAF / PhotoPicker
 * result. Grants are scoped to the pick result only; this class never holds
 * broad file permissions, never deletes or rewrites the original document,
 * and never logs the URI.
 */
class AndroidContentResolverSource(
    private val uri: Uri,
    private val resolver: ContentResolver,
    /** True only when the pick Intent carried the read grant and the host
     *  caller explicitly asked for re-read durability. */
    private val pickedWithReadGrant: Boolean = true,
) : StagingContentSource {

    private var readGrantLease: com.floe.android.safgateway.SafSharedGrantBroker.Lease? = null

    private val displayName: String? by lazy {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) cursor.getString(index) else null
                    } else null
                }
        }.getOrNull()
    }

    private val mimeType: String? by lazy {
        runCatching { resolver.getType(uri) }.getOrNull()
    }

    private val declaredSize: Long? by lazy {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (index >= 0 && !cursor.isNull(index)) {
                            cursor.getLong(index).takeIf { it > 0 }
                        } else null
                    } else null
                }
        }.getOrNull()
    }

    override fun openRead(): StagingInputStream {
        val stream = try {
            resolver.openInputStream(uri)
                ?: throw StagingSourceUnavailable("no stream")
        } catch (_: FileNotFoundException) {
            throw StagingSourceUnavailable("unavailable")
        } catch (_: SecurityException) {
            throw StagingGrantRevoked("revoked")
        }
        return object : StagingInputStream {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                try { stream.read(buffer, offset, length) }
                catch (_: java.io.InterruptedIOException) { -1 }
            override fun close() { try { stream.close() } catch (_: IOException) {} }
        }
    }

    /** Persistable ONLY when the pick carried a read grant and the caller
     *  needs durability; failures degrade to the session-scoped read
     *  truthfully (never pretend any URI is permanent). */
    fun takePersistableReadGrant() = retainReadGrant(true)

    @Synchronized
    internal fun retainReadGrant(persist: Boolean) {
        if (readGrantLease != null) return
        readGrantLease = com.floe.android.host.SharedUriGrantAuthority.acquireRead(
            resolver, uri, allowPersistence = persist && pickedWithReadGrant)
    }

    @Synchronized
    override fun releaseTransientRead() {
        readGrantLease?.close()
        readGrantLease = null
    }

    override val displayNameHint: String? get() = displayName
    override val mimeTypeHint: String? get() = mimeType
    override fun declaredByteCount(): Long? = declaredSize

    /** Secret hygiene: never print the URI. */
    override fun toString(): String = "AndroidContentResolverSource(<uri-redacted>)"
}
