// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/** One shareable conversation from the app-owned local store. */
data class DeviceHistoryOffer(
    val id: UUID,
    val title: String,
)

/**
 * App-owned endpoints for a single native conversation store. The wire only
 * reads through this boundary; the recipient explicitly imports verified
 * bytes from its own UI after selecting an offered conversation.
 */
interface DeviceHistorySource {
    /** Return the offers the app is willing to share for [allowed] task IDs. */
    suspend fun offers(allowed: Set<UUID>): List<DeviceHistoryOffer>

    /** Opaque native canonical bytes for one previously offered task. */
    suspend fun export(taskId: UUID): ByteArray
}

/** Typed v1 wire failures. The wire value matches Swift's rawValue exactly. */
enum class DeviceHistorySyncError(val wire: String) {
    UNSUPPORTED_VERSION("unsupportedVersion"),
    UNAVAILABLE("unavailable"),
    NOT_SHARED("notShared"),
    INVALID_RESPONSE("invalidResponse"),
    TOO_LARGE("tooLarge"),
    DISCONNECTED("disconnected"),
    BUSY("busy"),
    CONFLICT("conflict"),
    ;

    companion object {
        fun fromWire(value: String): DeviceHistorySyncError? = entries.firstOrNull { it.wire == value }
    }
}

class DeviceHistorySyncException(val error: DeviceHistorySyncError) : IllegalStateException(error.wire)

/**
 * Pairing ticket: `floe-device:` + standard base64 of the v1 JSON ticket.
 * Only the endpoint ID authenticates the peer; addresses are hints.
 */
class DeviceHistoryPairingTicket private constructor(
    val address: FloeDeviceLinkAddress,
    private val version: Int,
) {
    val id: String get() = address.endpointId
    val fingerprint: String get() = address.endpointId

    fun code(): String {
        val json = JSONObject()
            .put("version", version)
            .put("address", JSONObject(address.toJson()))
        return PAIRING_PREFIX + Base64.getEncoder().encodeToString(json.toString().encodeToByteArray())
    }

    companion object {
        private const val PAIRING_PREFIX = "floe-device:"
        private const val MAXIMUM_CODE_BYTES = 8_192
        private const val MAXIMUM_ENDPOINT_ID_BYTES = 128
        private const val MAXIMUM_DIRECT_ADDRESS_BYTES = 256
        private const val MAXIMUM_RELAY_URL_BYTES = 512
        private const val MAXIMUM_TICKET_DIRECT_ADDRESSES = 16

        /** Build the v1 ticket for a locally observed address. */
        operator fun invoke(address: FloeDeviceLinkAddress): DeviceHistoryPairingTicket =
            DeviceHistoryPairingTicket(address, WIRE_VERSION)

        /** Parse and strictly validate a peer-supplied pairing code. */
        fun parse(code: String): DeviceHistoryPairingTicket {
            val trimmed = code.trim()
            if (trimmed.encodeToByteArray().size > MAXIMUM_CODE_BYTES) throw invalidTicket()
            if (!trimmed.startsWith(PAIRING_PREFIX)) throw invalidTicket()
            val payload = try {
                Base64.getDecoder().decode(trimmed.substring(PAIRING_PREFIX.length))
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            val json = try {
                JSONObject(payload.decodeToString(throwOnInvalidSequence = true))
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            val version = try {
                json.getInt("version")
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            if (version != WIRE_VERSION) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.UNSUPPORTED_VERSION)
            }
            val addressJson = try {
                json.getJSONObject("address")
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            val address = try {
                FloeDeviceLinkAddress.fromJson(addressJson.toString())
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            val id = address.endpointId
            if (id.isEmpty() || id.encodeToByteArray().size > MAXIMUM_ENDPOINT_ID_BYTES) throw invalidTicket()
            val canonical = try {
                FloeDeviceLink.canonicalEndpointID(id)
            } catch (failure: Exception) {
                throw invalidTicket()
            }
            if (canonical != id) throw invalidTicket()
            if (address.directAddresses.size > MAXIMUM_TICKET_DIRECT_ADDRESSES) throw invalidTicket()
            if (address.directAddresses.any { it.encodeToByteArray().size > MAXIMUM_DIRECT_ADDRESS_BYTES }) {
                throw invalidTicket()
            }
            if ((address.relayUrl?.encodeToByteArray()?.size ?: 0) > MAXIMUM_RELAY_URL_BYTES) {
                throw invalidTicket()
            }
            return DeviceHistoryPairingTicket(address, version)
        }

        private fun invalidTicket() = DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
    }
}

/** Lowercase `sha256:<64 hex>` digest, compared on the validated digest only. */
internal class ContentDigest private constructor(val hex: String) {
    init {
        require(hex.length == 64 && hex.all { it.isDigit() || it in 'a'..'f' })
    }

    override fun equals(other: Any?): Boolean = other is ContentDigest && other.hex == hex
    override fun hashCode(): Int = hex.hashCode()
    override fun toString(): String = DIGEST_PREFIX + hex

    companion object {
        private const val DIGEST_PREFIX = "sha256:"
        private const val HEX = "0123456789abcdef"

        fun validating(value: String): ContentDigest {
            if (!value.startsWith(DIGEST_PREFIX)) throw invalidDigest()
            val raw = value.substring(DIGEST_PREFIX.length).lowercase(Locale.US)
            return try {
                ContentDigest(raw)
            } catch (failure: IllegalArgumentException) {
                throw invalidDigest()
            }
        }

        fun compute(bytes: ByteArray): ContentDigest {
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            val hex = buildString(64) {
                digest.forEach { byte ->
                    val value = byte.toInt()
                    append(HEX[(value ushr 4) and 0x0f])
                    append(HEX[value and 0x0f])
                }
            }
            return ContentDigest(hex)
        }

        private fun invalidDigest() = DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
    }
}

private const val WIRE_VERSION = 1

/**
 * The device-history wire over an authenticated [FloeDeviceLink]. Mirrors the
 * shipped Swift v1 protocol: one bidirectional stream per request, offers /
 * prepare / chunk operations, SHA-256 of the actual bytes, and typed failures.
 * The host owns settings and identity storage; this class owns session lifetime.
 */
class DeviceHistorySync(
    private val link: FloeDeviceLink,
    initialShares: Map<String, Set<UUID>>,
    private val source: DeviceHistorySource,
) {
    val address: FloeDeviceLinkAddress get() = link.address()

    @Volatile private var stopped = false
    @Volatile private var listenerJob: Job? = null
    @Volatile private var scope: CoroutineScope? = null

    private val state = Mutex()
    private var shares: Map<String, Set<UUID>> = initialShares
    private val sessions = ConcurrentHashMap<UUID, FloeDeviceLinkConnection>()
    private val serveJobs = ConcurrentHashMap<UUID, Job>()

    fun start(scope: CoroutineScope) {
        if (stopped || listenerJob != null) return
        this.scope = scope
        listenerJob = scope.launch { listenerLoop() }
    }

    /** Swap the share map and trusted set; sessions of removed peers are closed. */
    suspend fun replaceShares(next: Map<String, Set<UUID>>) {
        link.replaceTrustedEndpointIDs(next.keys.toSet())
        state.withLock { shares = next }
        sessions.values.filter { it.peerEndpointId !in next.keys }.forEach { connection ->
            runCatching { connection.close() }
        }
    }

    /** Explicitly approved remote offers for [peer]. One short-lived connection. */
    suspend fun offers(peer: FloeDeviceLinkAddress): List<DeviceHistoryOffer> =
        withConnection(peer) { connection ->
            val reply = request(SyncRequest(Operation.OFFERS), connection)
            val offers = reply.offers ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (offers.size > MAXIMUM_SHARED_TASKS) throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (offers.mapTo(HashSet()) { it.id }.size != offers.size) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            if (offers.any { it.title.isEmpty() || it.title.encodeToByteArray().size > MAXIMUM_TITLE_BYTES }) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            offers
        }

    /** Pull one shared conversation and verify its digest. One short-lived connection. */
    suspend fun history(taskID: UUID, peer: FloeDeviceLinkAddress): ByteArray =
        withConnection(peer) { connection ->
            val manifest = request(SyncRequest(Operation.PREPARE, taskID = taskID), connection)
            val size = manifest.size ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (size <= 0 || size > MAXIMUM_ARCHIVE_BYTES) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            val expected = ContentDigest.validating(
                manifest.digest ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE),
            )
            val data = ByteArray(size)
            var position = 0
            while (position < size) {
                currentCoroutineContext().ensureActive()
                val reply = request(SyncRequest(Operation.CHUNK, taskID = taskID, offset = position.toLong()), connection)
                val count = minOf(size - position, CHUNK_SIZE)
                val bytes = reply.bytes ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                if (bytes.size != count) throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                bytes.copyInto(data, position)
                position += count
            }
            if (ContentDigest.compute(data) != expected) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            data
        }

    suspend fun stop() {
        stopped = true
        listenerJob?.cancel()
        listenerJob = null
        serveJobs.values.forEach { it.cancel() }
        serveJobs.clear()
        sessions.values.forEach { runCatching { it.close() } }
        sessions.clear()
        runCatching { link.close() }
    }

    private suspend fun <T> withConnection(
        peer: FloeDeviceLinkAddress,
        operation: suspend (FloeDeviceLinkConnection) -> T,
    ): T {
        if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
        val connection = link.connect(peer)
        try {
            if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
            return operation(connection)
        } finally {
            runCatching { connection.close() }
        }
    }

    private suspend fun request(value: SyncRequest, connection: FloeDeviceLinkConnection): SyncReply =
        decodeReply(connection.request(encodeRequest(value)))

    private suspend fun listenerLoop() {
        while (true) {
            if (stopped) return
            currentCoroutineContext().ensureActive()
            try {
                val connection = link.acceptNext() ?: return
                accept(connection)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                // Authentication, transport closure and failed handshakes never
                // enter the request handler; keep listening unless stopping.
                if (stopped) return
                try {
                    delay(LISTENER_RETRY_MILLIS)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                }
            }
        }
    }

    private fun accept(connection: FloeDeviceLinkConnection) {
        val hostScope = scope
        if (stopped || hostScope == null || sessions.size >= MAXIMUM_SESSIONS) {
            runCatching { connection.close() }
            return
        }
        val id = UUID.randomUUID()
        sessions[id] = connection
        // Register before the job can run so a fast-failing serve never leaks
        // a completed job in the map.
        val job = hostScope.launch(start = CoroutineStart.LAZY) { serve(connection, id) }
        serveJobs[id] = job
        job.start()
    }

    private suspend fun serve(connection: FloeDeviceLinkConnection, id: UUID) {
        try {
            var archive: Archive? = null
            while (!stopped) {
                currentCoroutineContext().ensureActive()
                try {
                    val stream = connection.receiveRequest()
                    try {
                        val request = decodeRequest(stream.payload)
                        try {
                            val (reply, nextArchive) = respond(request, connection.peerEndpointId, archive)
                            archive = nextArchive
                            stream.respond(encodeReply(reply))
                        } catch (failure: DeviceHistorySyncException) {
                            stream.respond(encodeReply(SyncReply(failure = failure.error)))
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: Exception) {
                            stream.respond(encodeReply(SyncReply(failure = DeviceHistorySyncError.UNAVAILABLE)))
                        }
                    } finally {
                        stream.close()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    return
                }
            }
        } finally {
            serveJobs.remove(id)
            sessions.remove(id)
            runCatching { connection.close() }
        }
    }

    private suspend fun currentShares(peer: String): Set<UUID> =
        state.withLock { shares[peer] }.orEmpty()

    private suspend fun respond(
        request: SyncRequest,
        peer: String,
        archive: Archive?,
    ): Pair<SyncReply, Archive?> {
        if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
        if (request.version != WIRE_VERSION) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.UNSUPPORTED_VERSION)
        }
        val allowed = currentShares(peer)
        if (request.operation == Operation.OFFERS) {
            val offers = source.offers(allowed)
            if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
            // Re-authorize against the share map after the await, then apply the cap.
            val current = currentShares(peer)
            val safe = offers.filter { it.id in current }.take(MAXIMUM_SHARED_TASKS)
            return SyncReply(offers = safe) to null
        }
        val taskID = request.taskID ?: throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        if (taskID !in allowed) throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        return when (request.operation) {
            Operation.OFFERS -> throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            Operation.PREPARE -> {
                val data = source.export(taskID)
                if (stopped || taskID !in currentShares(peer)) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
                }
                if (data.isEmpty() || data.size > MAXIMUM_ARCHIVE_BYTES) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.TOO_LARGE)
                }
                SyncReply(size = data.size, digest = ContentDigest.compute(data).toString()) to
                    Archive(taskID, data)
            }
            Operation.CHUNK -> {
                val offset = request.offset
                val active = archive
                if (active == null || active.taskID != taskID || offset == null ||
                    offset < 0 || offset >= active.data.size) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                }
                val start = offset.toInt()
                val end = minOf(start + CHUNK_SIZE, active.data.size)
                SyncReply(bytes = active.data.copyOfRange(start, end)) to
                    if (end == active.data.size) null else active
            }
        }
    }

    private class Archive(val taskID: UUID, val data: ByteArray)

    internal enum class Operation(val wire: String) {
        OFFERS("offers"),
        PREPARE("prepare"),
        CHUNK("chunk"),
        ;

        companion object {
            fun fromWire(value: String): Operation? = entries.firstOrNull { it.wire == value }
        }
    }

    /** A malformed request ends the serve loop without a failure reply. */
    internal class RequestDecodeException : Exception()

    internal class SyncRequest(
        val operation: Operation,
        val taskID: UUID? = null,
        val offset: Long? = null,
        val version: Int = WIRE_VERSION,
    )

    internal class SyncReply(
        val failure: DeviceHistorySyncError? = null,
        val offers: List<DeviceHistoryOffer>? = null,
        val size: Int? = null,
        val digest: String? = null,
        val bytes: ByteArray? = null,
    )

    companion object {
        const val MAXIMUM_ARCHIVE_BYTES = 32 * 1024 * 1024
        const val MAXIMUM_SHARED_TASKS = 200
        private const val CHUNK_SIZE = 384 * 1024
        private const val MAXIMUM_SESSIONS = 4
        private const val MAXIMUM_TITLE_BYTES = 1_024
        private const val LISTENER_RETRY_MILLIS = 100L

        // The exact Swift v1 JSON shapes. Swift's synthesized Codable omits nil
        // optionals, so optional keys are absent (not null) on the wire; the
        // decoder below still tolerates explicit nulls for robustness.
        internal fun encodeRequest(request: SyncRequest): ByteArray =
            JSONObject()
                .put("version", WIRE_VERSION)
                .put("operation", request.operation.wire)
                .putOptional("taskID", request.taskID?.toString())
                .putOptional("offset", request.offset)
                .toString()
                .encodeToByteArray()

        internal fun encodeReply(reply: SyncReply): ByteArray =
            JSONObject()
                .put("version", WIRE_VERSION)
                .putOptional("failure", reply.failure?.wire)
                .putOptional(
                    "offers",
                    reply.offers?.let { offers ->
                        JSONArray(offers.map { offer ->
                            JSONObject()
                                .put("id", offer.id.toString())
                                .put("title", offer.title)
                        })
                    },
                )
                .putOptional("size", reply.size)
                .putOptional("digest", reply.digest)
                .putOptional("bytes", reply.bytes?.let { Base64.getEncoder().encodeToString(it) })
                .toString()
                .encodeToByteArray()

        internal fun JSONObject.putOptional(name: String, value: Any?): JSONObject {
            if (value != null) put(name, value)
            return this
        }

        internal fun decodeRequest(payload: ByteArray): SyncRequest {
            val json = try {
                JSONObject(payload.decodeToString(throwOnInvalidSequence = true))
            } catch (failure: Exception) {
                throw RequestDecodeException()
            }
            if (!json.has("version") || json.isNull("version") || json.get("version") !is Int) {
                throw RequestDecodeException()
            }
            val version = json.getInt("version")
            val rawOperation = json.get("operation") as? String ?: throw RequestDecodeException()
            val operation = Operation.fromWire(rawOperation) ?: throw RequestDecodeException()
            val taskID: UUID? = when (val raw = if (json.isNull("taskID")) null else json.get("taskID")) {
                null -> null
                is String -> try {
                    UUID.fromString(raw)
                } catch (failure: IllegalArgumentException) {
                    throw RequestDecodeException()
                }
                else -> throw RequestDecodeException()
            }
            val offset: Long? = when (val raw = if (json.isNull("offset")) null else json.get("offset")) {
                null -> null
                // Reject doubles and oversized integers; offsets never exceed the archive.
                is Int -> raw.toLong()
                is Long -> raw
                else -> throw RequestDecodeException()
            }
            return SyncRequest(operation, taskID, offset, version)
        }

        internal fun decodeReply(payload: ByteArray): SyncReply {
            val invalid = { DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE) }
            val json = try {
                JSONObject(payload.decodeToString(throwOnInvalidSequence = true))
            } catch (failure: Exception) {
                throw invalid()
            }
            if (!json.has("version") || json.isNull("version") || json.get("version") !is Int) throw invalid()
            if (json.getInt("version") != WIRE_VERSION) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.UNSUPPORTED_VERSION)
            }
            if (json.has("failure") && !json.isNull("failure")) {
                val wire = json.get("failure") as? String ?: throw invalid()
                throw DeviceHistorySyncException(
                    DeviceHistorySyncError.fromWire(wire) ?: DeviceHistorySyncError.INVALID_RESPONSE,
                )
            }
            val offers = if (json.has("offers") && !json.isNull("offers")) {
                val array = json.get("offers") as? JSONArray ?: throw invalid()
                (0 until array.length()).map { index ->
                    val item = array.get(index) as? JSONObject ?: throw invalid()
                    val id = when (val raw = item.get("id")) {
                        is String -> try {
                            UUID.fromString(raw)
                        } catch (failure: IllegalArgumentException) {
                            throw invalid()
                        }
                        else -> throw invalid()
                    }
                    val title = item.get("title") as? String ?: throw invalid()
                    DeviceHistoryOffer(id, title)
                }
            } else {
                null
            }
            val size = when (val raw = if (json.isNull("size")) null else json.get("size")) {
                null -> null
                is Int -> raw
                // Reject doubles and any integer that would wrap past a 32-bit size.
                is Long -> raw.takeIf { it <= Int.MAX_VALUE }?.toInt() ?: throw invalid()
                else -> throw invalid()
            }
            val digest = when (val raw = if (json.isNull("digest")) null else json.get("digest")) {
                null -> null
                is String -> raw
                else -> throw invalid()
            }
            val bytes = when (val raw = if (json.isNull("bytes")) null else json.get("bytes")) {
                null -> null
                is String -> try {
                    Base64.getDecoder().decode(raw)
                } catch (failure: IllegalArgumentException) {
                    throw invalid()
                }
                else -> throw invalid()
            }
            return SyncReply(
                failure = null,
                offers = offers,
                size = size,
                digest = digest,
                bytes = bytes,
            )
        }
    }
}
