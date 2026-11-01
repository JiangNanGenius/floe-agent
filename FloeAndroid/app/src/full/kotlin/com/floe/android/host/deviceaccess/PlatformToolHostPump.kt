// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.swiftbridge.PlatformToolsNative
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/** One authenticated platform-tool call derived ONLY from the trusted ticket. */
internal data class PlatformToolCall(
    val claim: Long,
    val tool: String,
    val taskID: UUID,
    val runID: UUID,
    val epoch: Long,
    val toolCallID: String,
    val idempotencyKey: String,
    val approvalGrantID: UUID?,
    val arguments: JSONObject,
    val argumentsBytes: ByteArray,
)

internal sealed interface PlatformToolOutcome {
    data class Success(
        val summary: String,
        val evidence: List<String> = emptyList(),
        val artifact: PlatformArtifactWriter.Artifact? = null,
    ) : PlatformToolOutcome

    data class Failure(
        val code: String,
        val detail: String? = null,
    ) : PlatformToolOutcome
}

internal interface PlatformToolsTransport {
    fun bind(epoch: Long, catalog: ByteArray): Int
    fun setAvailability(epoch: Long, namesJson: ByteArray): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): ByteArray?
    fun payload(claim: Long): ByteArray?
    fun isLive(claim: Long): Int
    fun shouldStop(claim: Long): Int
    fun complete(claim: Long, status: Int, value: ByteArray): Int
    fun close(epoch: Long): Int
    fun artifactRootPath(): String?
}

internal object NativePlatformToolsTransport : PlatformToolsTransport {
    override fun bind(epoch: Long, catalog: ByteArray): Int =
        PlatformToolsNative.bind(epoch, catalog)

    override fun setAvailability(epoch: Long, namesJson: ByteArray): Int =
        PlatformToolsNative.setAvailability(epoch, namesJson)

    override fun next(timeoutMillis: Int): Long = PlatformToolsNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = PlatformToolsNative.describe(claim)
    override fun payload(claim: Long): ByteArray? = PlatformToolsNative.payload(claim)
    override fun isLive(claim: Long): Int = PlatformToolsNative.isLive(claim)
    override fun shouldStop(claim: Long): Int = PlatformToolsNative.shouldStop(claim)
    override fun complete(claim: Long, status: Int, value: ByteArray): Int =
        PlatformToolsNative.complete(claim, status, value)
    override fun close(epoch: Long): Int = PlatformToolsNative.close(epoch)
    override fun artifactRootPath(): String? = PlatformToolsNative.artifactRootPath()
}

/**
 * Full-only serial pump over the generic trusted platform-tool mailbox.
 *
 * Lifecycle (all epochs are the ACTUAL accepted native root epoch):
 *  - [start] binds the ONE frozen Full-only catalog. Bind installs every
 *    reviewed potential tool but leaves the availability mask EMPTY; the pump
 *    immediately publishes the real usable subset for the same epoch.
 *  - Availability changes (Accessibility grant, ADB service, root toggle,
 *    user scope changes) call [publishAvailability], which never reopens the
 *    catalog and never fabricates a new epoch. Queued work for a hidden tool
 *    is fenced by Swift; already-claimed work settles exactly once.
 *  - [stopAndJoin] publishes an empty mask first (fences queued tickets), asks
 *    the host to cancel real in-flight backend work, waits for the current
 *    claim to settle, and only then closes the epoch. A refusal returns false
 *    so the root retire keeps the old generation pending instead of pretending
 *    the work is gone.
 *  - Every claimed ticket is settled exactly once. Success is never reported
 *    after the ticket was cancelled/fenced (-109 semantics preserved).
 */
internal class PlatformToolHostPump(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentEpoch: () -> Long?,
    private val handler: suspend (PlatformToolCall) -> PlatformToolOutcome,
    private val availability: () -> Set<String>,
    private val onCancelBackend: (PlatformToolCall) -> Unit,
    private val catalog: ByteArray = DeviceAccessToolCatalog.catalogJson(),
    private val transport: PlatformToolsTransport = NativePlatformToolsTransport,
    private val timing: Timing = Timing(),
) {
    internal data class Timing(
        val nextPollMillis: Int = 250,
        val settleWaitMillis: Long = 8_000,
        val operationTimeoutMillis: Long = 25_000,
    )

    private data class Session(val epoch: Long) {
        val stopping = AtomicBoolean(false)
        var reader: Job? = null
        val inFlight = AtomicReference<PlatformToolCall?>(null)
    }

    private val starts = Mutex()
    private val availabilityLock = Any()

    @Volatile
    private var session: Session? = null

    @Volatile
    private var lastPublished: Set<String>? = null

    @Volatile
    private var lastBindStatus: Int = Int.MIN_VALUE

    /** Actual bound epoch (0 when nothing is bound). */
    val boundEpoch: Long get() = session?.epoch ?: 0L

    fun isRunning(): Boolean =
        session?.reader?.isActive == true && session?.stopping?.get() == false

    fun lastBindStatus(): Int = lastBindStatus

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (!scope.isActive || epoch <= 0 || currentEpoch() != epoch) return@withLock false
        val existing = session
        if (existing != null && existing.epoch == epoch) {
            return@withLock existing.reader?.isActive == true && !existing.stopping.get()
        }
        if (existing != null) {
            // A generation replacement must drain the old one first; a refused
            // drain keeps the old claim honestly pending, so do not bind.
            if (!stopInternal(existing)) return@withLock false
        }
        val bound = try {
            transport.bind(epoch, catalog)
        } catch (_: LinkageError) {
            -1
        } catch (_: Throwable) {
            -1
        }
        lastBindStatus = bound
        if (bound != 0) return@withLock false
        val created = Session(epoch)
        session = created
        lastPublished = null
        publishAvailabilityNow(created)
        created.reader = scope.launch(ioDispatcher, start = CoroutineStart.ATOMIC) {
            claimLoop(created)
        }
        true
    }

    /**
     * Recompute the actual usable subset for the CURRENT bound epoch. Returns
     * false when the mask could not be published (native refused/fenced).
     */
    fun publishAvailability(): Boolean {
        val current = session ?: return false
        if (current.stopping.get()) return false
        return publishAvailabilityNow(current)
    }

    private fun publishAvailabilityNow(target: Session): Boolean {
        val names = try {
            availability().filter { it in DeviceAccessToolCatalog.allNames }.toSortedSet()
        } catch (_: Throwable) {
            emptySet()
        }
        synchronized(availabilityLock) {
            if (lastPublished == names) return true
            if (currentEpoch() != target.epoch) return false
            val json = names.joinToString(
                prefix = "[", postfix = "]", separator = ",",
            ) { "\"" + it + "\"" }
            val status = try {
                transport.setAvailability(target.epoch, json.toByteArray(Charsets.UTF_8))
            } catch (_: Throwable) {
                -1
            }
            if (status == 0) lastPublished = names
            return status == 0
        }
    }

    private suspend fun claimLoop(target: Session) {
        try {
            while (scope.isActive && !target.stopping.get()) {
                val claim = try {
                    transport.next(timing.nextPollMillis)
                } catch (_: Throwable) {
                    0L
                }
                if (claim <= 0) continue
                if (target.stopping.get()) {
                    // The claim was already handed to this host; settle it as a
                    // cancellation rather than leaving the caller waiting.
                    completeFailure(claim, "cancelled")
                    continue
                }
                processClaim(target, claim)
            }
        } finally {
            target.inFlight.set(null)
        }
    }

    private suspend fun processClaim(target: Session, claim: Long) {
        val descriptorBytes = try {
            transport.describe(claim)
        } catch (_: Throwable) {
            null
        }
        val payload = try {
            transport.payload(claim)
        } catch (_: Throwable) {
            null
        }
        if (descriptorBytes == null || payload == null) {
            completeFailure(claim, "invalid_ticket")
            return
        }
        val descriptorText = PlatformToolsNative.strictText(descriptorBytes)
        val call = descriptorText?.let { parseTicket(claim, it, payload) }
        if (call == null) {
            completeFailure(claim, "invalid_ticket")
            return
        }
        if (call.epoch != target.epoch || currentEpoch() != target.epoch ||
            transport.isLive(claim) != 1
        ) {
            completeFailure(claim, "epoch_fenced")
            return
        }
        if (transport.shouldStop(claim) == 1) {
            completeFailure(claim, "cancelled")
            return
        }
        target.inFlight.set(call)
        val outcome = try {
            withTimeout(timing.operationTimeoutMillis) { handler(call) }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            PlatformToolOutcome.Failure("timeout")
        } catch (_: Throwable) {
            PlatformToolOutcome.Failure("internal")
        } finally {
            target.inFlight.compareAndSet(call, null)
        }
        if (target.stopping.get() || currentEpoch() != target.epoch ||
            transport.shouldStop(claim) == 1
        ) {
            completeFailure(claim, "cancelled")
            return
        }
        when (outcome) {
            is PlatformToolOutcome.Success -> {
                val encoded = encodeSuccess(
                    outcome.summary, outcome.evidence, outcome.artifact)
                try {
                    transport.complete(claim, 0, encoded)
                } catch (_: Throwable) {
                    // A typed refusal (-109/-101/-108) is terminal; the
                    // backend work already happened and is honestly reported
                    // as not-successful by the bridge. Never retry as success.
                }
            }
            is PlatformToolOutcome.Failure ->
                completeFailure(claim, outcome.code, outcome.detail)
        }
    }

    private fun parseTicket(claim: Long, text: String, payload: ByteArray): PlatformToolCall? {
        val root = try {
            JSONObject(text)
        } catch (_: Throwable) {
            return null
        }
        if (root.optInt("version", -1) != 1) return null
        if (root.optString("operation") != "platformTool.execute") return null
        val tool = root.optString("tool")
        if (tool !in DeviceAccessToolCatalog.allNames) return null
        val epoch = root.optString("epoch").toLongOrNull() ?: return null
        if (epoch <= 0) return null
        val taskID = runCatching { UUID.fromString(root.optString("taskID")) }.getOrNull()
            ?: return null
        val runID = runCatching { UUID.fromString(root.optString("runID")) }.getOrNull()
            ?: return null
        val toolCallID = root.optString("toolCallID")
        val idempotencyKey = root.optString("idempotencyKey")
        if (toolCallID.length > 128 || idempotencyKey.length > 128) return null
        val grantRaw = root.optString("approvalGrantID")
        val grant = if (grantRaw.isEmpty()) null else {
            runCatching { UUID.fromString(grantRaw) }.getOrNull() ?: return null
        }
        if (root.optLong("argumentsBytes", -1) != payload.size.toLong()) return null
        val digest = root.optString("argumentsSHA256")
        if (digest.length != 64 || !digest.all { it in "0123456789abcdef" }) return null
        val actual = MessageDigest.getInstance("SHA-256").digest(payload)
            .joinToString("") { "%02x".format(it) }
        if (!actual.equals(digest, ignoreCase = false)) return null
        val arguments = try {
            JSONObject(String(payload, Charsets.UTF_8))
        } catch (_: Throwable) {
            return null
        }
        return PlatformToolCall(
            claim = claim,
            tool = tool,
            taskID = taskID,
            runID = runID,
            epoch = epoch,
            toolCallID = toolCallID,
            idempotencyKey = idempotencyKey,
            approvalGrantID = grant,
            arguments = arguments,
            argumentsBytes = payload,
        )
    }

    private fun completeFailure(claim: Long, code: String, detail: String? = null) {
        val encoded = encodeFailure(code, detail)
        try {
            transport.complete(claim, 1, encoded)
        } catch (_: Throwable) {
            // Exactly-once settlement: a typed failure is not retried.
        }
    }

    /**
     * User stop/disable without root retirement: publish the reduced mask
     * (fences queued work) and cancel the real backend operation behind the
     * already-claimed ticket. The epoch stays open so unrelated host work can
     * still settle; the ticket itself is settled as a failure by its handler.
     */
    fun cancelInFlight() {
        val current = session ?: return
        publishAvailabilityNow(current)
        current.inFlight.get()?.let { call -> runCatching { onCancelBackend(call) } }
    }

    /**
     * Fence queued work, cancel actual in-flight backend work, then close the
     * epoch. Returns true only when the current claim actually settled.
     */
    suspend fun stopAndJoin(): Boolean = starts.withLock {
        val current = session ?: return@withLock true
        stopInternal(current)
    }

    private suspend fun stopInternal(target: Session): Boolean {
        target.stopping.set(true)
        // 1) Fence queued/new dispatch FIRST for the same epoch.
        val emptyNames = "[]".toByteArray(Charsets.UTF_8)
        val current = currentEpoch()
        if (current == target.epoch) {
            runCatching { transport.setAvailability(target.epoch, emptyNames) }
        }
        // 2) Cancel real backend work for the claimed ticket.
        target.inFlight.get()?.let { call -> runCatching { onCancelBackend(call) } }
        val reader = target.reader
        val drained = if (reader == null) true else {
            withTimeoutOrNull(timing.settleWaitMillis) { reader.join() } != null
        }
        if (!drained) return false
        // 3) Exact-epoch teardown only after the claim settled.
        if (current == target.epoch) {
            runCatching { transport.close(target.epoch) }
        }
        if (session === target) {
            session = null
            lastPublished = null
        }
        return true
    }

    /** Terminal close after the native root already retired. */
    fun forceClose() {
        val target = session ?: return
        target.stopping.set(true)
        target.inFlight.get()?.let { call -> runCatching { onCancelBackend(call) } }
        target.reader?.cancel()
        runCatching { transport.close(target.epoch) }
        session = null
        lastPublished = null
    }

    // ------------------------------------------------------------- encoding

    private fun encodeSuccess(
        summary: String,
        evidence: List<String>,
        artifact: PlatformArtifactWriter.Artifact?,
    ): ByteArray {
        val root = JSONObject()
            .put("version", 1)
            .put("summary", BoundedResultText.summary(summary))
        val lines = evidence.map { BoundedResultText.evidence(it) }
            .filter { it.isNotEmpty() }
            .take(8)
        if (lines.isNotEmpty()) root.put("evidence", org.json.JSONArray(lines))
        if (artifact != null) root.put("artifact", artifact.toJson())
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    private fun encodeFailure(code: String, detail: String?): ByteArray {
        val root = JSONObject()
            .put("version", 1)
            .put("code", BoundedResultText.token(code))
        detail?.let { root.put("detail", BoundedResultText.detail(it)) }
        return root.toString().toByteArray(Charsets.UTF_8)
    }
}

/**
 * UTF-8/codepoint-safe bounds for the transport's closed result contract.
 * Control characters (other than newline in the summary) are replaced, never
 * smuggled into model-facing text.
 */
internal object BoundedResultText {
    fun summary(value: String): String {
        val cleaned = buildString(value.length.coerceAtMost(2_048)) {
            value.forEach { ch ->
                when {
                    ch == '\n' || ch == '\t' -> append(ch)
                    ch.code < 0x20 || ch.code == 0x7F -> append(' ')
                    else -> append(ch)
                }
            }
        }.trim()
        if (cleaned.isEmpty()) return "Completed."
        return clip(cleaned, 2_048)
    }

    fun evidence(value: String): String {
        val cleaned = buildString(value.length.coerceAtMost(192)) {
            value.forEach { ch ->
                append(if (ch.code < 0x20 || ch.code == 0x7F) ' ' else ch)
            }
        }.trim()
        return clipBytes(cleaned, 192)
    }

    fun detail(value: String): String {
        val cleaned = buildString(value.length.coerceAtMost(200)) {
            value.forEach { ch ->
                append(if (ch.code < 0x20 || ch.code == 0x7F) ' ' else ch)
            }
        }.trim()
        return clip(cleaned, 200)
    }

    fun token(value: String): String {
        // Swift's failure-code grammar is ASCII alphanumeric plus '_'/'-'
        // and must start with a letter. Keep a colon only as a separator is
        // NOT allowed on the wire, so it is dropped here.
        val cleaned = value.filter {
            it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
        }.take(64)
        return if (cleaned.isEmpty() || !cleaned.first().isLetter()) "failed" else cleaned
    }

    fun clip(value: String, maxChars: Int): String {
        if (value.length <= maxChars) return value
        val budget = (maxChars - 1).coerceAtLeast(0)
        val builder = StringBuilder(budget + 1)
        var index = 0
        while (index < value.length && builder.length < budget) {
            val codePoint = Character.codePointAt(value, index)
            val width = Character.charCount(codePoint)
            if (builder.length + width > budget) break
            builder.appendCodePoint(codePoint)
            index += width
        }
        return builder.append('…').toString()
    }

    fun clipBytes(value: String, maxBytes: Int): String {
        if (value.toByteArray(Charsets.UTF_8).size <= maxBytes) return value
        val builder = StringBuilder()
        var index = 0
        var bytes = 0
        while (index < value.length) {
            val codePoint = Character.codePointAt(value, index)
            val width = Character.charCount(codePoint)
            val encoded = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8).size
            if (bytes + encoded > maxBytes - 3) break
            builder.appendCodePoint(codePoint)
            bytes += encoded
            index += width
        }
        return builder.append('…').toString()
    }
}
