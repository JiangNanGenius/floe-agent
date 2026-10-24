// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.safgateway.*
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/** Trusted OS actuator only. Swift owns source registration, journal/CAS,
 * recovery, exact task/workspace and the real IO lease. No model-facing entry
 * exists here. One Root owns one serialized provider pump and gateway.
 */
internal class WorkspaceSourcePump(
    context: Context,
    private val scope: CoroutineScope,
    private val currentNativeEpoch: () -> Long?,
) {
    private val context = context.applicationContext
    private val starts = Mutex()
    private class Session(val epoch: Long, context: Context) {
        val backend = AndroidSafBackend(context)
        val gateway = SafGatewayService(backend, releaseBroker = SharedUriGrantAuthority.broker)
        val stopping = AtomicBoolean()
        @Volatile var operation: SafOperation<ByteArray>? = null
        var reader: Job? = null
    }
    @Volatile private var session: Session? = null
    val boundNativeEpoch: Long get() = session?.epoch ?: 0L

    fun gatewayForEpoch(epoch: Long): SafGatewayService? = session?.takeIf {
        it.epoch == epoch && !it.stopping.get() && !it.gateway.isClosed && currentNativeEpoch() == epoch
    }?.gateway

    /** The SAME session's platform backend for read-only provider
     * classification (URI kind, virtual-document stream types, tree child
     * URI derivation). Additive only; lifecycle and drain semantics are the
     * delivered gatewayForEpoch checks, unchanged. */
    fun backendForEpoch(epoch: Long): SafPlatformBackend? = session?.takeIf {
        it.epoch == epoch && !it.stopping.get() && !it.gateway.isClosed && currentNativeEpoch() == epoch
    }?.backend

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (!scope.isActive || epoch <= 0 || currentNativeEpoch() != epoch) return@withLock false
        session?.let { return@withLock it.epoch == epoch && it.reader?.isActive == true && !it.stopping.get() }
        val value = Session(epoch, context)
        val bound = try { WorkspaceSourceNative.bindEpoch(epoch) == 0 } catch (_: LinkageError) { false }
        if (!bound) { withContext(Dispatchers.IO) { value.gateway.close() }; return@withLock false }
        session = value
        value.reader = scope.launch(Dispatchers.IO, start = CoroutineStart.ATOMIC) {
            try {
                while (isActive && !value.stopping.get() && currentNativeEpoch() == epoch) {
                    val claim = WorkspaceSourceNative.next(250)
                    if (claim <= 0) continue
                    // Parent cancellation cannot detach the native IO lease
                    // while a provider stream/finalizer remains active.
                    withContext(NonCancellable + Dispatchers.IO) { execute(value, claim) }
                }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) {
                    value.stopping.set(true); value.operation?.cancel()
                    value.gateway.close(); value.gateway.awaitIdle()
                    WorkspaceSourceNative.close(value.epoch)
                }
            }
        }
        true
    }

    /** False means the old generation remains owned/pending; it is never
     * replaced or declared stopped merely because a wait expired. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean = starts.withLock {
        require(waitMillis > 0)
        val value = session ?: return@withLock true
        if (value.epoch != expectedEpoch) return@withLock false
        value.stopping.set(true); value.operation?.cancel()
        val joined = withTimeoutOrNull(waitMillis) { value.reader?.join(); true } ?: false
        if (!joined || !value.gateway.isDrained) return@withLock false
        if (session === value) session = null
        true
    }

    private fun admitted(value: Session, claim: Long): Boolean = !value.stopping.get() &&
        currentNativeEpoch() == value.epoch && WorkspaceSourceNative.isLive(claim) == 1 &&
        WorkspaceSourceNative.shouldStop(claim) != 1

    private suspend fun execute(value: Session, claim: Long) {
        var result: SafOutcome<ByteArray> = SafOutcome.failure(SafFailure.Failed("invalid native source ticket"))
        try {
            val ticket = descriptor(WorkspaceSourceNative.describe(claim) ?: throw TicketFailure(), value.epoch)
            if (!admitted(value, claim)) throw CancellationException()
            val payload = if (ticket.operation == "source.write") {
                val bytes = WorkspaceSourceNative.payload(claim) ?: throw TicketFailure()
                if (bytes.size != ticket.byteCount || sha(bytes) != ticket.sha256) throw TicketFailure()
                bytes
            } else ByteArray(0)
            val op = value.gateway.submit<ByteArray> { cancel ->
                if (!admitted(value, claim)) return@submit SafOutcome.failure(SafFailure.Cancelled)
                val flags = if (ticket.operation == "source.write") listOf(SafAccessFlag.READ, SafAccessFlag.WRITE)
                    else listOf(SafAccessFlag.READ)
                val references = ArrayList<SafSharedGrantBroker.Lease>()
                try {
                    for (flag in flags) references += SharedUriGrantAuthority.broker.retain(ticket.source, flag)
                    val ref = resolve(value.backend, ticket, cancel)
                    cancel.ensureActive()
                    if (ticket.operation == "source.read") {
                        value.gateway.operations.readBounded(ref, ticket.maximumBytes.toLong(), null, cancel)
                    } else write(value, claim, ref, payload, cancel)
                } finally { references.asReversed().forEach { it.close() } }
            }
            value.operation = op
            coroutineScope {
                val cancellationWatch = launch {
                    while (!op.isDone) {
                        if (!admitted(value, claim)) op.cancel()
                        delay(50)
                    }
                }
                try {
                    // No hostBudget -> detach shortcut. Only actual IO and
                    // its stream closes can complete the native claim.
                    result = op.await()
                } finally { cancellationWatch.cancelAndJoin() }
            }
        } catch (_: CancellationException) {
            result = SafOutcome.failure(SafFailure.Cancelled)
        } catch (_: Exception) {
            result = SafOutcome.failure(SafFailure.Failed("source transport failed"))
        } finally {
            value.operation = null
            when (val settled = result) {
                is SafOutcome.Success -> WorkspaceSourceNative.complete(claim, 0, settled.value)
                is SafOutcome.Failure -> {
                    val code = nativeCode(settled.failure)
                    val body = buildJsonObject { put("code", code) }.toString().toByteArray(Charsets.UTF_8)
                    WorkspaceSourceNative.complete(claim, 1, body)
                }
            }
        }
    }

    private fun resolve(backend: SafPlatformBackend, ticket: Ticket, cancel: SafCancelToken): SafDocumentRef {
        cancel.ensureActive()
        return when (backend.classifyUri(ticket.source.uriString)) {
            SafUriKind.TREE -> if (ticket.documentID != null) {
                val uri = backend.documentUriFor(ticket.source, ticket.documentID) ?: throw TicketFailure()
                SafDocumentRef(ticket.source, ticket.documentID, null, uri)
            } else backend.resolveTreeRoot(ticket.source) ?: throw TicketFailure()
            SafUriKind.DOCUMENT -> SafDocumentRef(null, ticket.documentID, null, ticket.source)
            else -> throw TicketFailure()
        }
    }

    private fun write(value: Session, claim: Long, ref: SafDocumentRef, bytes: ByteArray,
                      cancel: SafCancelToken): SafOutcome<ByteArray> {
        val metadata = value.gateway.operations.metadata(ref, cancel)
        if (metadata is SafOutcome.Failure) return SafOutcome.failure(metadata.failure, metadata.detail)
        if (metadata !is SafOutcome.Success || !metadata.value.capabilities.write) return SafOutcome.failure(SafFailure.ReadOnly)
        val access = value.gateway.grants.currentAccess(ref.uri)
        if (!access.write || access.probeWrite == ProbeFlag.DENIED) return SafOutcome.failure(SafFailure.ReadOnly)
        cancel.ensureActive()
        if (!admitted(value, claim)) return SafOutcome.failure(SafFailure.Cancelled)
        val output = when (val opened = value.backend.openWriteTruncate(ref, cancel)) {
            is WriteOpen.Opened -> opened.output
            WriteOpen.NotFound -> return SafOutcome.failure(SafFailure.NotFound)
            WriteOpen.UnsupportedMode -> return SafOutcome.failure(SafFailure.Unsupported("provider cannot replace this document"))
        }
        return try {
            output.use { stream ->
                var offset = 0
                while (offset < bytes.size) {
                    cancel.ensureActive()
                    val count = minOf(32 * 1024, bytes.size - offset)
                    stream.write(bytes, offset, count); offset += count
                }
                stream.flush()
            }
            // Transport settled only. The Swift coordinator issues a NEW
            // read ticket and verifies actual bytes before committing journal47.
            SafOutcome.success(ByteArray(0))
        } catch (_: IOException) { SafOutcome.failure(SafFailure.Io("provider write failed")) }
    }

    private class TicketFailure : IllegalArgumentException("invalid source ticket")
    private data class Ticket(val operation: String, val source: SafUriRef, val documentID: String?,
        val maximumBytes: Int, val byteCount: Int, val sha256: String?)

    private fun descriptor(bytes: ByteArray, epoch: Long): Ticket {
        if (bytes.size !in 1..2048) throw TicketFailure()
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        val fields = Json.parseToJsonElement(text) as? JsonObject ?: throw TicketFailure()
        fun field(key: String): String = (fields[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw TicketFailure()
        val operation = field("operation")
        if (operation !in setOf("source.read", "source.write") || field("epoch") != epoch.toString()) throw TicketFailure()
        val allowed = setOf("operation", "epoch", "taskID", "workspaceID", "logicalPath", "sourceReference", "sourceDocumentID") +
            if (operation == "source.read") setOf("maxBytes") else setOf("byteCount", "sha256")
        if (fields.keys.any { it !in allowed }) throw TicketFailure()
        for (name in listOf("taskID", "workspaceID")) {
            val raw = field(name)
            if (!UUID.fromString(raw).toString().equals(raw, true)) throw TicketFailure()
        }
        if (field("logicalPath").isBlank()) throw TicketFailure()
        val source = SafUriRef(field("sourceReference"))
        val documentID = if (fields.containsKey("sourceDocumentID")) field("sourceDocumentID") else null
        val maximum = if (operation == "source.read") field("maxBytes").toIntOrNull() ?: throw TicketFailure() else 4 * 1024 * 1024
        val count = if (operation == "source.write") field("byteCount").toIntOrNull() ?: throw TicketFailure() else 0
        val digest = if (operation == "source.write") field("sha256").also {
            if (it.length != 64 || it.any { c -> c !in '0'..'9' && c !in 'a'..'f' }) throw TicketFailure()
        } else null
        if (maximum !in 1..4 * 1024 * 1024 || count !in 0..4 * 1024 * 1024) throw TicketFailure()
        return Ticket(operation, source, documentID, maximum, count, digest)
    }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun nativeCode(failure: SafFailure): String = when (failure) {
        SafFailure.Revoked -> "revoked"; SafFailure.GrantMissing -> "grantMissing"
        is SafFailure.RePickRequired -> "rePickRequired"; SafFailure.ReadOnly -> "readOnly"
        is SafFailure.Unsupported -> "unsupported"; SafFailure.Cancelled -> "cancelled"
        is SafFailure.Conflict -> "conflict"; SafFailure.NotFound -> "notFound"
        is SafFailure.AmbiguousIdentity -> "ambiguousIdentity"; is SafFailure.SizeLimitExceeded -> "sizeLimit"
        SafFailure.ProviderOffline -> "providerOffline"; is SafFailure.Io -> "io"; is SafFailure.Failed -> "failed"
    }
}
