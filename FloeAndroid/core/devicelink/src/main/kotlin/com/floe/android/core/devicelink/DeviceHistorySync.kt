// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import computer.iroh.IrohException
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
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject

/** One shareable conversation from the app-owned local store. */
data class DeviceHistoryOffer(
    val id: UUID,
    val title: String,
    val workspaceFiles: Boolean = false,
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

/** Shared catalog result: the offers for one peer plus the pages capability. */
data class DeviceHistoryCatalog(
    val offers: List<DeviceHistoryOffer>,
    val historyPages: Boolean,
)

/** One validated page of the canonical v1 history archive. [through] is the
 * sender's fixed sequence upper bound (the scan bound of the whole
 * conversation); [nextCursor] is the opaque resume cursor, echoed from the
 * request when the page carries nothing new, omitted only on the first page
 * of a completely empty conversation, and otherwise the page's last cursor.
 */
data class DeviceHistoryPage(
    val bytes: ByteArray,
    val nextCursor: String?,
    val through: Long,
    val hasMore: Boolean,
)

/**
 * A [DeviceHistorySource] that can additionally serve the canonical archive in
 * bounded pages. Throw [DeviceHistorySyncException] with
 * [DeviceHistorySyncError.CURSOR_EXPIRED] from [historyPage] when [after] no
 * longer resolves; the serving side turns it into the typed wire failure.
 */
interface DeviceHistoryPagedSource : DeviceHistorySource {
    /**
     * One page of the canonical archive bytes for [taskId]. [after] is null on
     * the first request of a conversation and the previous page's cursor
     * afterwards; [through] is null on the first request of a connection and
     * the echoed sequence upper bound afterwards.
     *
     * Cursor rules (shared v1 paging schema): a data-bearing last page
     * provides its last cursor; a page with nothing new echoes [after]; only
     * the first page of a completely empty conversation omits the cursor. A
     * non-terminal page must carry a fresh cursor. The canonical archive JSON
     * is non-empty even for an empty page.
     */
    suspend fun historyPage(taskId: UUID, after: String?, through: Long?): DeviceHistoryPage
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
    CURSOR_EXPIRED("cursorExpired"),
    ;

    companion object {
        fun fromWire(value: String): DeviceHistorySyncError? = entries.firstOrNull { it.wire == value }
    }
}

class DeviceHistorySyncException(
    val error: DeviceHistorySyncError,
    /**
     * Host retry short-circuit: set only when a refused FIRST preparePage
     * carrying a non-null resume cursor reports cursorExpired, which allows
     * the Host to restart the pull from scratch. The wire itself never retries.
     */
    val restartableCursor: Boolean = false,
) : IllegalStateException(error.wire)

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
 * The v1 paging extension adds the optional `historyPages` offers flag and the
 * preparePage operation, negotiated per connection; legacy peers keep the
 * whole-archive exchange unchanged. The host owns settings and identity
 * storage; this class owns session lifetime.
 */
class DeviceHistorySync(
    private val link: FloeDeviceLink,
    initialShares: Map<String, Set<UUID>>,
    private val source: DeviceHistorySource,
    private val workspaceSource: DeviceWorkspaceSource? = null,
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
    suspend fun offers(peer: FloeDeviceLinkAddress): List<DeviceHistoryOffer> = catalog(peer).offers

    /** Remote offers for [peer] plus whether the peer serves history pages. */
    suspend fun catalog(peer: FloeDeviceLinkAddress): DeviceHistoryCatalog =
        withConnection(peer) { connection ->
            val reply = request(SyncRequest(Operation.OFFERS), connection)
            DeviceHistoryCatalog(
                offers = validatedOffers(reply.offers),
                historyPages = reply.historyPages == true,
            )
        }

    /** A short-lived authenticated connection for one user-selected transfer. */
    class ReceiveSession internal constructor(
        private val client: DeviceHistorySync,
        private val connection: FloeDeviceLinkConnection,
    ) {
        suspend fun history(taskID: UUID): ByteArray = client.readHistory(connection, taskID)

        suspend fun historyPages(
            taskID: UUID,
            after: String?,
            consume: suspend (DeviceHistoryPage) -> Unit,
        ): Boolean = client.readHistoryPages(connection, taskID, after, consume)

        suspend fun workspace(taskID: UUID, receiver: DeviceWorkspaceReceiver): DeviceWorkspaceReceipt =
            client.readWorkspace(connection, taskID, receiver)
    }

    suspend fun <T> receiveFrom(peer: FloeDeviceLinkAddress, receive: suspend (ReceiveSession) -> T): T =
        withConnection(peer, connectTimeoutMillis = REQUEST_TIMEOUT_MILLIS) { connection ->
            receive(ReceiveSession(this, connection))
        }

    /** Pull one shared conversation and verify its digest. */
    suspend fun history(taskID: UUID, peer: FloeDeviceLinkAddress): ByteArray =
        withConnection(peer) { readHistory(it, taskID) }

    private suspend fun readHistory(connection: FloeDeviceLinkConnection, taskID: UUID): ByteArray {
        val manifest = request(SyncRequest(Operation.PREPARE, taskID = taskID), connection)
        val size = manifest.size ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        if (size <= 0 || size > MAXIMUM_ARCHIVE_BYTES) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
        val expected = ContentDigest.validating(
            manifest.digest ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE),
        )
        return pullPreparedBytes(connection, taskID, size, expected)
    }

    /** Pull the selected workspace after renegotiating the offer on this connection. */
    suspend fun workspace(
        taskID: UUID,
        peer: FloeDeviceLinkAddress,
        receiver: DeviceWorkspaceReceiver,
    ): DeviceWorkspaceReceipt = receiveFrom(peer) { it.workspace(taskID, receiver) }

    private suspend fun readWorkspace(
        connection: FloeDeviceLinkConnection,
        taskID: UUID,
        receiver: DeviceWorkspaceReceiver,
    ): DeviceWorkspaceReceipt {
        suspend fun exchange(input: SyncRequest): SyncReply = withTimeout(
            if (input.operation == Operation.PREPARE_WORKSPACE) WORKSPACE_PREPARE_TIMEOUT_MILLIS
            else REQUEST_TIMEOUT_MILLIS,
        ) {
            request(input, connection)
        }
        if (validatedOffers(exchange(SyncRequest(Operation.OFFERS)).offers).none {
                it.id == taskID && it.workspaceFiles
            }) throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        return DeviceWorkspaceTransfer.receive(taskID, receiver, ::exchange)
    }

    /**
     * Pull a shared conversation page-by-page over one negotiated connection.
     *
     * Returns false only when pages were not negotiated — the local source is
     * not a [DeviceHistoryPagedSource] or the remote offers reply omitted
     * `historyPages` — before any [consume] invocation; true once the terminal
     * page completes. [consume] runs once per fully validated page and owns
     * the incremental commit; the wire proceeds to the next page only after it
     * returns. Typed wire failures (invalidResponse / cursorExpired with the
     * restartableCursor short-circuit / notShared / disconnected), revocation,
     * cancellation and callback failures all abort without retry or downgrade.
     * [after] resumes with the last committed cursor; a refused first
     * preparePage carrying it reports cursorExpired as restartable.
     */
    suspend fun historyPages(
        taskID: UUID,
        peer: FloeDeviceLinkAddress,
        after: String?,
        consume: suspend (DeviceHistoryPage) -> Unit,
    ): Boolean {
        if (source !is DeviceHistoryPagedSource) return false
        return receiveFrom(peer) { it.historyPages(taskID, after, consume) }
    }

    private suspend fun readHistoryPages(
        connection: FloeDeviceLinkConnection,
        taskID: UUID,
        after: String?,
        consume: suspend (DeviceHistoryPage) -> Unit,
    ): Boolean {
        if (source !is DeviceHistoryPagedSource) return false
        if (!validCursor(after)) throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        // One offers exchange negotiates pages on this connection; a legacy
        // reply (or an unadvertised source) skips the pull before any
        // consume call. The task must still be offered to this peer.
        val reply = withRequestTimeout(REQUEST_TIMEOUT_MILLIS) {
            request(SyncRequest(Operation.OFFERS), connection)
        }
        val offered = validatedOffers(reply.offers)
        if (offered.none { it.id == taskID }) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        }
        if (reply.historyPages != true) return false

        var cursor = after
        var through: Long? = null
        val visitedCursors = HashSet<String>()
        while (true) {
            currentCoroutineContext().ensureActive()
            val manifest = try {
                withRequestTimeout(REQUEST_TIMEOUT_MILLIS) {
                    request(
                        SyncRequest(
                            Operation.PREPARE_PAGE,
                            taskID = taskID,
                            after = cursor,
                            through = through,
                        ),
                        connection,
                    )
                }
            } catch (failure: DeviceHistorySyncException) {
                // Host retry short-circuit: only a refused FIRST
                // preparePage carrying a non-null resume cursor is
                // restartable; later expiries are mid-transfer failures.
                if (failure.error == DeviceHistorySyncError.CURSOR_EXPIRED &&
                    cursor != null && through == null
                ) {
                    throw DeviceHistorySyncException(failure.error, restartableCursor = true)
                }
                throw failure
            }
            val upperBound = manifest.through
                ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (upperBound < 0 || through != null && through != upperBound) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            val hasMore = manifest.hasMore
                ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            val nextCursor = manifest.nextCursor
            if (!validCursor(nextCursor)) {
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            if (hasMore) {
                // Progress is mandatory while pages remain: a fresh cursor,
                // never seen on this transfer and fewer than the sequence
                // upper bound of them.
                if (nextCursor == null || nextCursor == cursor ||
                    !visitedCursors.add(nextCursor) ||
                    visitedCursors.size.toLong() >= upperBound
                ) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                }
            }
            val size = manifest.size
                ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (size <= 0 || size > MAXIMUM_ARCHIVE_BYTES) {
                // The canonical archive JSON is non-empty even for an
                // empty page, exactly like the legacy prepare manifest.
                throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            }
            val expected = ContentDigest.validating(
                manifest.digest ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE),
            )
            val data = pullPreparedBytes(connection, taskID, size, expected, REQUEST_TIMEOUT_MILLIS)
            // The callback owns incremental commit: exactly one call per
            // validated page, before the next page request.
            consume(DeviceHistoryPage(bytes = data, nextCursor = nextCursor, through = upperBound, hasMore = hasMore))
            if (!hasMore) break
            cursor = nextCursor
            through = upperBound
        }
        return true
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
        connectTimeoutMillis: Long? = null,
        operation: suspend (FloeDeviceLinkConnection) -> T,
    ): T {
        if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
        val connection = withRequestTimeout(connectTimeoutMillis) { transport { link.connect(peer) } }
        try {
            if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
            return operation(connection)
        } finally {
            runCatching { connection.close() }
        }
    }

    /** Bounds one network suspension when [timeoutMillis] is set; null keeps the caller's timing. */
    private suspend fun <T> withRequestTimeout(timeoutMillis: Long?, block: suspend () -> T): T =
        if (timeoutMillis == null) block() else withTimeout(timeoutMillis) { block() }

    private fun validatedOffers(raw: List<DeviceHistoryOffer>?): List<DeviceHistoryOffer> {
        val offers = raw ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        if (offers.size > MAXIMUM_SHARED_TASKS) throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        if (offers.mapTo(HashSet()) { it.id }.size != offers.size) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
        if (offers.any { it.title.isEmpty() || it.title.encodeToByteArray().size > MAXIMUM_TITLE_BYTES }) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
        return offers
    }

    private fun validCursor(value: String?): Boolean =
        value == null || value.isNotEmpty() && value.encodeToByteArray().size <= MAXIMUM_CURSOR_BYTES

    /** Pulls prepared bytes with legacy chunk offsets; the digest closes the integrity check. */
    private suspend fun pullPreparedBytes(
        connection: FloeDeviceLinkConnection,
        taskID: UUID,
        size: Int,
        expected: ContentDigest,
        timeoutMillis: Long? = null,
    ): ByteArray {
        val data = ByteArray(size)
        var position = 0
        while (position < size) {
            currentCoroutineContext().ensureActive()
            val reply = withRequestTimeout(timeoutMillis) {
                request(SyncRequest(Operation.CHUNK, taskID = taskID, offset = position.toLong()), connection)
            }
            val count = minOf(size - position, CHUNK_SIZE)
            val bytes = reply.bytes ?: throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            if (bytes.size != count) throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
            bytes.copyInto(data, position)
            position += count
        }
        if (ContentDigest.compute(data) != expected) {
            throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
        return data
    }

    private suspend fun <T> transport(request: suspend () -> T): T = try {
        request()
    } catch (_: IrohException) {
        currentCoroutineContext().ensureActive()
        throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
    }

    private suspend fun request(value: SyncRequest, connection: FloeDeviceLinkConnection): SyncReply =
        decodeReply(transport { connection.request(encodeRequest(value)) })

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
        var workspace: PreparedDeviceWorkspace? = null
        try {
            var archive: Archive? = null
            while (!stopped) {
                currentCoroutineContext().ensureActive()
                try {
                    val stream = connection.receiveRequest()
                    try {
                        val request = decodeRequest(stream.payload)
                        try {
                            val peer = connection.peerEndpointId
                            val reply = if (request.operation.isWorkspace) {
                                if (request.operation == Operation.PREPARE_WORKSPACE) {
                                    workspace?.close()
                                    workspace = null
                                    val prepared = prepareWorkspace(request, peer)
                                    workspace = prepared
                                    SyncReply(size = prepared.manifest.size, digest = prepared.digest)
                                } else {
                                    respondWorkspace(request, peer, workspace)
                                }
                            } else {
                                val (response, nextArchive) = respond(request, peer, archive)
                                archive = nextArchive
                                response
                            }
                            try {
                                stream.respond(encodeReply(reply))
                            } finally {
                                reply.bytes?.fill(0)
                            }
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
            runCatching { workspace?.close() }
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
            val projected = offers.filter { it.id in current }.take(MAXIMUM_SHARED_TASKS)
                .map { offer ->
                    offer.copy(workspaceFiles = workspaceSource?.available(peer, offer.id) == true)
                }
            val latest = currentShares(peer)
            val safe = projected.filter { it.id in latest }
            // Announce pages only when the local source actually supports them.
            val historyPages = (source as? DeviceHistoryPagedSource)?.let { true }
            return SyncReply(offers = safe, historyPages = historyPages) to null
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
            Operation.PREPARE_PAGE -> {
                // preparePage only arrives after both sides negotiated pages;
                // a non-paged source here speaks the legacy protocol.
                val paged = source as? DeviceHistoryPagedSource
                    ?: throw DeviceHistorySyncException(DeviceHistorySyncError.UNSUPPORTED_VERSION)
                if (request.offset != null || !validCursor(request.after)) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                }
                // through is the fixed sequence upper bound: non-negative, and
                // only sent together with an after cursor.
                if (request.through != null && (request.through < 0 || request.after == null)) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                }
                val page = paged.historyPage(taskID, request.after, request.through)
                // Re-check authorization after suspending to the source.
                if (stopped || taskID !in currentShares(peer)) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
                }
                if (page.through < 0 ||
                    request.through != null && request.through != page.through ||
                    !validCursor(page.nextCursor) ||
                    page.hasMore && (page.nextCursor == null || page.nextCursor == request.after)
                ) {
                    // The local source violated the paging schema; refuse with
                    // the same invalidResponse the peer would have distrusted.
                    throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
                }
                if (page.bytes.isEmpty() || page.bytes.size > MAXIMUM_ARCHIVE_BYTES) {
                    throw DeviceHistorySyncException(DeviceHistorySyncError.TOO_LARGE)
                }
                // The reply echoes the page's own sequence upper bound; the
                // client sends it back unchanged from the next request on.
                // Body chunks reuse the legacy arm, so each new prepare /
                // preparePage replaces (and clears) this connection's
                // obsolete bytes.
                SyncReply(
                    size = page.bytes.size,
                    digest = ContentDigest.compute(page.bytes).toString(),
                    nextCursor = page.nextCursor,
                    through = page.through,
                    hasMore = page.hasMore,
                ) to Archive(taskID, page.bytes)
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
            else -> throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)
        }
    }

    private suspend fun prepareWorkspace(request: SyncRequest, peer: String): PreparedDeviceWorkspace {
        val task = checkWorkspaceRequest(request, peer)
        if (request.offset != null || request.index != null || request.indexes != null) invalidWorkspace()
        val source = workspaceSource ?: throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        val snapshot = source.prepare(peer, task)
        return try {
            checkWorkspaceRequest(request, peer)
            snapshot.checkPermission()
            PreparedDeviceWorkspace(task, snapshot)
        } catch (failure: Throwable) {
            runCatching { snapshot.close() }
            throw failure
        }
    }

    private suspend fun respondWorkspace(
        request: SyncRequest,
        peer: String,
        prepared: PreparedDeviceWorkspace?,
    ): SyncReply {
        val task = checkWorkspaceRequest(request, peer)
        if (prepared == null || prepared.task != task) invalidWorkspace()
        prepared.snapshot.checkPermission()
        val reply = when (request.operation) {
            Operation.WORKSPACE_MANIFEST -> {
                if (request.index != null || request.indexes != null) invalidWorkspace()
                val offset = validWorkspaceOffset(request.offset, prepared.manifest.size.toLong()).toInt()
                val end = minOf(offset + DeviceWorkspaceManifest.CHUNK_SIZE, prepared.manifest.size)
                SyncReply(bytes = prepared.manifest.copyOfRange(offset, end))
            }
            Operation.WORKSPACE_FILE -> {
                if (request.indexes != null) invalidWorkspace()
                val index = request.index ?: invalidWorkspace()
                val entry = prepared.entries.getOrNull(index)?.takeIf { it.kind == DeviceWorkspaceEntry.Kind.FILE }
                    ?: invalidWorkspace()
                val size = checkNotNull(entry.size)
                val offset = validWorkspaceOffset(request.offset, size)
                val length = minOf(size - offset, DeviceWorkspaceManifest.CHUNK_SIZE.toLong()).toInt()
                val bytes = prepared.snapshot.read(index, offset, length)
                if (bytes.size != length) throw DeviceHistorySyncException(DeviceHistorySyncError.CONFLICT)
                SyncReply(bytes = bytes)
            }
            Operation.CONFIRM_WORKSPACE -> {
                if (request.offset != null || request.index != null) invalidWorkspace()
                val indexes = request.indexes ?: invalidWorkspace()
                if (indexes.isEmpty() || indexes.size > DeviceWorkspaceManifest.MAX_CONFIRM ||
                    indexes.toSet().size != indexes.size || indexes.any {
                        prepared.entries.getOrNull(it)?.kind != DeviceWorkspaceEntry.Kind.FILE
                    }) invalidWorkspace()
                prepared.snapshot.confirm(indexes)
                SyncReply()
            }
            else -> invalidWorkspace()
        }
        checkWorkspaceRequest(request, peer)
        prepared.snapshot.checkPermission()
        return reply
    }

    private fun validWorkspaceOffset(value: Long?, size: Long): Long =
        value?.takeIf { it in 0 until size } ?: invalidWorkspace()

    private suspend fun checkWorkspaceRequest(request: SyncRequest, peer: String): UUID {
        if (stopped) throw DeviceHistorySyncException(DeviceHistorySyncError.DISCONNECTED)
        if (request.version != WIRE_VERSION) throw DeviceHistorySyncException(DeviceHistorySyncError.UNSUPPORTED_VERSION)
        if (request.after != null || request.through != null) invalidWorkspace()
        val task = request.taskID ?: invalidWorkspace()
        if (task !in currentShares(peer)) throw DeviceHistorySyncException(DeviceHistorySyncError.NOT_SHARED)
        return task
    }

    private fun invalidWorkspace(): Nothing = throw DeviceHistorySyncException(DeviceHistorySyncError.INVALID_RESPONSE)

    private class Archive(val taskID: UUID, val data: ByteArray)

    internal enum class Operation(val wire: String) {
        OFFERS("offers"),
        PREPARE("prepare"),
        PREPARE_PAGE("preparePage"),
        CHUNK("chunk"),
        PREPARE_WORKSPACE("prepareWorkspace"),
        WORKSPACE_MANIFEST("workspaceManifest"),
        WORKSPACE_FILE("workspaceFile"),
        CONFIRM_WORKSPACE("confirmWorkspace"),
        ;

        val isWorkspace: Boolean get() = when (this) {
            PREPARE_WORKSPACE, WORKSPACE_MANIFEST, WORKSPACE_FILE, CONFIRM_WORKSPACE -> true
            else -> false
        }

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
        val after: String? = null,
        val through: Long? = null,
        val version: Int = WIRE_VERSION,
        val index: Int? = null,
        val indexes: List<Int>? = null,
    )

    internal class SyncReply(
        val failure: DeviceHistorySyncError? = null,
        val offers: List<DeviceHistoryOffer>? = null,
        val size: Int? = null,
        val digest: String? = null,
        val bytes: ByteArray? = null,
        val historyPages: Boolean? = null,
        val nextCursor: String? = null,
        val through: Long? = null,
        val hasMore: Boolean? = null,
    )

    companion object {
        const val MAXIMUM_ARCHIVE_BYTES = 32 * 1024 * 1024
        const val MAXIMUM_SHARED_TASKS = 200
        private const val CHUNK_SIZE = 384 * 1024
        private const val MAXIMUM_SESSIONS = 4
        private const val MAXIMUM_TITLE_BYTES = 1_024
        private const val MAXIMUM_CURSOR_BYTES = 160
        private const val LISTENER_RETRY_MILLIS = 100L

        /** Per-request ceiling for the staged page pull (connect, offers, each
         * preparePage and chunk). The whole multi-page transfer has no single
         * deadline, the consume callback settles outside it, and the legacy
         * whole-archive entry points keep their existing timing. */
        private const val REQUEST_TIMEOUT_MILLIS = 30_000L
        private const val WORKSPACE_PREPARE_TIMEOUT_MILLIS = 300_000L

        // The exact Swift v1 JSON shapes. Swift's synthesized Codable omits nil
        // optionals, so optional keys are absent (not null) on the wire; the
        // decoder below still tolerates explicit nulls for robustness. The v1
        // paging extension adds optional boolean historyPages to the offers
        // reply and, for preparePage, optional string after, integer through,
        // optional string nextCursor and boolean hasMore. through is a
        // non-negative Int64, never a string.
        internal fun encodeRequest(request: SyncRequest): ByteArray =
            JSONObject()
                .put("version", WIRE_VERSION)
                .put("operation", request.operation.wire)
                .putOptional("taskID", request.taskID?.toString())
                .putOptional("offset", request.offset)
                .putOptional("after", request.after)
                .putOptional("through", request.through)
                .putOptional("index", request.index)
                .putOptional("indexes", request.indexes?.let(::JSONArray))
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
                                .putOptional("workspaceFiles", true.takeIf { offer.workspaceFiles })
                        })
                    },
                )
                .putOptional("size", reply.size)
                .putOptional("digest", reply.digest)
                .putOptional("bytes", reply.bytes?.let { Base64.getEncoder().encodeToString(it) })
                // Pages are announced only when supported; false stays omitted.
                .putOptional("historyPages", reply.historyPages?.takeIf { it })
                .putOptional("nextCursor", reply.nextCursor)
                .putOptional("through", reply.through)
                .putOptional("hasMore", reply.hasMore)
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
            val after: String? = when (val raw = if (json.isNull("after")) null else json.get("after")) {
                null -> null
                is String -> raw
                else -> throw RequestDecodeException()
            }
            // through is the fixed sequence upper bound: an integer on the wire,
            // never a string or a double.
            val through: Long? = when (val raw = if (json.isNull("through")) null else json.get("through")) {
                null -> null
                is Int -> raw.toLong()
                is Long -> raw
                else -> throw RequestDecodeException()
            }
            val index = if (json.isNull("index")) null else json.get("index") as? Int
                ?: throw RequestDecodeException()
            val indexes = if (json.isNull("indexes")) null else {
                val list = json.get("indexes") as? JSONArray ?: throw RequestDecodeException()
                if (list.length() > DeviceWorkspaceManifest.MAX_CONFIRM) emptyList()
                else List(list.length()) { i -> list.get(i) as? Int ?: throw RequestDecodeException() }
            }
            return SyncRequest(operation, taskID, offset, after, through, version, index, indexes)
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
                    val workspaceFiles = if (item.isNull("workspaceFiles")) false
                        else item.get("workspaceFiles") as? Boolean ?: throw invalid()
                    DeviceHistoryOffer(id, title, workspaceFiles)
                }
            } else {
                null
            }
            val size = when (val raw = if (json.isNull("size")) null else json.get("size")) {
                null -> null
                is Int -> raw
                // Reject doubles and any integer that would wrap past a 32-bit size.
                is Long -> raw.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }
                    ?.toInt() ?: throw invalid()
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
            fun optionalBoolean(field: String): Boolean? =
                if (json.isNull(field)) null else json.get(field) as? Boolean ?: throw invalid()
            val nextCursor = if (json.isNull("nextCursor")) null
                else json.get("nextCursor") as? String ?: throw invalid()
            val through = when (val raw = json.opt("through")) {
                null, JSONObject.NULL -> null
                is Int -> raw.toLong()
                is Long -> raw
                else -> throw invalid()
            }
            return SyncReply(
                offers = offers,
                size = size,
                digest = digest,
                bytes = bytes,
                historyPages = optionalBoolean("historyPages"),
                nextCursor = nextCursor,
                through = through,
                hasMore = optionalBoolean("hasMore"),
            )
        }
    }
}
