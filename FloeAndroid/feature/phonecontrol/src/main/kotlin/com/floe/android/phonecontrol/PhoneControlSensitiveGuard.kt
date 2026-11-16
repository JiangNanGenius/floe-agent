// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.content.Context
import android.util.AtomicFile
import com.floe.android.contracts.SensitiveUiGuardPolicy
import com.floe.android.contracts.SensitiveUiGuardSnapshot
import com.floe.android.contracts.SensitiveUiGuardTicket
import com.floe.android.contracts.SensitiveUiLabelKey
import com.floe.android.contracts.SensitiveUiLabelIdentity
import com.floe.android.contracts.SensitiveUiLabelBaseline
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Durable metadata only; never stores field values or screenshots. */
object PhoneControlSensitiveGuard {
    /** Shared by every host instance, including during host replacement. */
    val operationMutex = kotlinx.coroutines.sync.Mutex()
    enum class ArmResult { STORED, LIMIT, UNAVAILABLE }
    internal data class Key(val pkg: String?, val window: Int, val display: Int,
        val path: List<Int>, val className: String, val viewId: String?)
    private val gate = Any()
    private var loaded = false
    private var unavailable = false
    private var tickets: List<SensitiveUiGuardTicket> = emptyList()
    private var revision = 1L
    private var guardEpoch: String = ""
    private var pendingRemoval: SensitiveUiGuardTicket? = null
    private var labelKey: SensitiveUiLabelKey? = null
    private var labelBaselines: List<SensitiveUiLabelBaseline> = emptyList()
    /** Window ids are only reusable within the same Android boot. */
    private var labelBoot: Int? = null
    private data class StoredState(val snapshot: SensitiveUiGuardSnapshot, val pending: SensitiveUiGuardTicket?, val boot: Int?)
    private fun file(context: Context): AtomicFile {
        val directory = context.noBackupFilesDir ?: throw java.io.IOException("private storage unavailable")
        if (!directory.isDirectory) throw java.io.IOException("private storage unavailable")
        return AtomicFile(File(directory, "sensitive-ui-guard-v1.json"))
    }

    private fun currentSnapshot() = SensitiveUiGuardSnapshot(guardEpoch, revision, tickets.toList(), labelKey, labelBaselines.toList())

    /** Null means the persisted state cannot be trusted; callers must fail closed. */
    fun snapshot(context: Context): List<SensitiveUiGuardTicket>? = state(context)?.tickets
    fun state(context: Context): SensitiveUiGuardSnapshot? = synchronized(gate) {
        ensureLoaded(context)
        if (!unavailable) {
            // The snapshot sent to a newly connected helper is re-read from
            // durable storage immediately before IPC, never from a queued copy.
            val stored = runCatching { readSnapshot(file(context)) }.getOrNull()
            if (stored != StoredState(currentSnapshot(), pendingRemoval, labelBoot)) {
                // Keep the last trusted metadata for conservative retries.
                unavailable = true
            }
        }
        if (unavailable || pendingRemoval != null) null else currentSnapshot()
    }
    /**
     * Explicit user-triggered recovery. This reads only the existing base
     * file: it never creates, repairs, migrates or discards pending state.
     * A known guard may only be retained or strengthened, never silently
     * removed by a transient error or a stale/foreign file.
     * Caller serializes this with [operationMutex] and re-syncs any helper.
     */
    fun retryReadOnly(context: Context): SensitiveUiGuardSnapshot? = synchronized(gate) {
        // A first refresh on a genuinely fresh install must take the normal
        // initialization path. Once initialization fails, only the existing
        // file may be consulted; absence can never reset prior protection.
        if (!loaded) {
            ensureLoaded(context)
            return if (unavailable) null else state(context)
        }
        if (!unavailable) return state(context)
        val recovered = runCatching { readSnapshot(file(context), readOnly = true) }.getOrNull()
            ?: return rejectReadOnly()
        val candidate = recovered.snapshot
        if (recovered.pending != null || candidate.labelKey == null) return rejectReadOnly()
        if (candidate.labelBaselines.isNotEmpty() &&
            (recovered.boot == null || bootCount(context) != recovered.boot)) return rejectReadOnly()
        if (guardEpoch.isNotEmpty()) {
            if (candidate.epoch != guardEpoch || candidate.revision < revision ||
                !candidate.tickets.containsAll(tickets) ||
                (pendingRemoval != null && pendingRemoval !in candidate.tickets) ||
                (labelKey != null && candidate.labelKey != labelKey)
            ) return rejectReadOnly()
            if (candidate.revision == revision && candidate != currentSnapshot()) return rejectReadOnly()
            if ((tickets.isNotEmpty() || candidate.tickets.isNotEmpty()) &&
                !labelBaselines.containsAll(candidate.labelBaselines)) return rejectReadOnly()
        }
        guardEpoch = candidate.epoch
        revision = candidate.revision
        tickets = candidate.tickets.toList()
        labelKey = candidate.labelKey
        labelBaselines = candidate.labelBaselines.toList()
        labelBoot = recovered.boot
        pendingRemoval = null
        loaded = true
        unavailable = false
        currentSnapshot()
    }

    private fun rejectReadOnly(): SensitiveUiGuardSnapshot? {
        loaded = true
        unavailable = true
        return null
    }

    internal fun baseline(key: Key): SensitiveUiLabelBaseline? = synchronized(gate) {
        labelBaselines.firstOrNull { it.identity.packageName == key.pkg && it.identity.windowId == key.window &&
            it.identity.displayId == key.display && it.identity.path == key.path &&
            it.identity.className == key.className && it.identity.viewId == key.viewId }
    }

    internal fun arm(context: Context, ticket: SensitiveUiGuardTicket,
                     records: Collection<PhoneControlNodeRecord>): ArmResult = synchronized(gate) {
        ensureLoaded(context)
        if (state(context) == null || !ticket.isWellFormed()) return ArmResult.UNAVAILABLE
        val next = (tickets + ticket).distinct()
        if (next.size > SensitiveUiGuardPolicy.MAX_TICKETS) return ArmResult.LIMIT
        if (!SensitiveUiGuardPolicy.valid(next)) return ArmResult.UNAVAILABLE
        val nextBaselines = if (tickets.isEmpty()) baselineRecords(ticket, records) else labelBaselines
        val nextBoot = if (tickets.isEmpty()) bootCount(context) else labelBoot
        if (revision == Long.MAX_VALUE || !write(context, next, revision + 1, guardEpoch,
                key = labelKey, bases = nextBaselines, boot = nextBoot)) return ArmResult.UNAVAILABLE
        tickets = next
        labelBaselines = nextBaselines
        labelBoot = nextBoot
        revision++
        ArmResult.STORED
    }

    /** ADB entries are hashes of pre-guard server observations, never model input. */
    fun armExternal(context: Context, ticket: SensitiveUiGuardTicket,
                    preInputBaselines: List<SensitiveUiLabelBaseline> = emptyList()): ArmResult = synchronized(gate) {
        ensureLoaded(context)
        if (state(context) == null || !ticket.isWellFormed()) return ArmResult.UNAVAILABLE
        val next = (tickets + ticket).distinct()
        if (next.size > SensitiveUiGuardPolicy.MAX_TICKETS) return ArmResult.LIMIT
        val bases = if (tickets.isEmpty()) preInputBaselines else labelBaselines
        val nextBoot = if (tickets.isEmpty()) bootCount(context) else labelBoot
        val candidate = SensitiveUiGuardSnapshot(guardEpoch, revision + 1, next, labelKey, bases)
        if (revision == Long.MAX_VALUE || !SensitiveUiGuardPolicy.valid(candidate) ||
            !write(context, next, revision + 1, guardEpoch, key = labelKey, bases = bases, boot = nextBoot)) return ArmResult.UNAVAILABLE
        tickets = next
        labelBaselines = bases
        labelBoot = nextBoot
        revision++
        ArmResult.STORED
    }

    /** Begin a user-confirmed removal; readers remain fenced until the helper acknowledges. */
    fun beginRemoval(context: Context, ticket: SensitiveUiGuardTicket): SensitiveUiGuardSnapshot? = synchronized(gate) {
        ensureLoaded(context)
        if (state(context) == null || ticket !in tickets || revision == Long.MAX_VALUE) return null
        val next = tickets - ticket
        if (!write(context, next, revision + 1, guardEpoch, ticket)) return null
        tickets = next
        revision++
        pendingRemoval = ticket
        currentSnapshot()
    }

    /** Validate the exact durable pending state before accepting an IPC acknowledgement. */
    fun pendingMatches(context: Context, expected: SensitiveUiGuardSnapshot): Boolean = synchronized(gate) {
        if (unavailable || pendingRemoval == null) return false
        val stored = runCatching { readSnapshot(file(context)) }.getOrNull()
        stored == StoredState(expected, pendingRemoval, labelBoot) &&
            expected == currentSnapshot()
    }

    /** Commit only after ACK; failure/crash restores the old guard at a newer revision. */
    fun finishRemoval(context: Context, acknowledged: Boolean): Boolean = synchronized(gate) {
        ensureLoaded(context)
        val pending = pendingRemoval ?: return false
        val expected = currentSnapshot()
        if (!pendingMatches(context, expected)) { unavailable = true; return false }
        val restored = if (acknowledged) tickets else (tickets + pending).distinct()
        val nextVersion = if (acknowledged) revision else {
            if (revision == Long.MAX_VALUE) { unavailable = true; return false }
            revision + 1
        }
        if (!SensitiveUiGuardPolicy.valid(restored) || !write(context, restored, nextVersion, guardEpoch)) {
            unavailable = true
            return false
        }
        tickets = restored
        revision = nextVersion
        pendingRemoval = null
        acknowledged
    }

    /** User-confirmed removal without an active external helper. */
    fun remove(context: Context, ticket: SensitiveUiGuardTicket): Boolean =
        beginRemoval(context, ticket) != null && finishRemoval(context, true)

    private fun ensureLoaded(context: Context) {
        if (loaded) return
        loaded = true
        try {
            val atomic = file(context)
            val stored = try {
                readSnapshot(atomic)
            } catch (error: java.io.FileNotFoundException) {
                val base = atomic.baseFile
                if (base.exists() || File(base.path + ".bak").exists() || File(base.path + ".new").exists()) throw error
                tickets = emptyList()
                guardEpoch = java.util.UUID.randomUUID().toString()
                labelKey = newKey()
                if (labelKey == null || !write(context, tickets, revision, guardEpoch)) unavailable = true
                return
            }
            guardEpoch = stored.snapshot.epoch
            revision = stored.snapshot.revision
            tickets = stored.snapshot.tickets
            labelKey = stored.snapshot.labelKey
            labelBaselines = stored.snapshot.labelBaselines
            labelBoot = stored.boot
            if (labelKey == null) {
                require(revision < Long.MAX_VALUE)
                labelKey = newKey() ?: error("key unavailable")
                labelBaselines = emptyList()
                require(write(context, tickets, revision + 1, guardEpoch, stored.pending))
                revision++
            }
            if (labelBaselines.isNotEmpty() && (labelBoot == null || bootCount(context) != labelBoot)) {
                // An unknown or different boot cannot prove that a recycled
                // window id still denotes the original pre-input button.
                require(revision < Long.MAX_VALUE)
                require(write(context, tickets, revision + 1, guardEpoch, stored.pending,
                    key = labelKey, bases = emptyList(), boot = null))
                revision++
                labelBaselines = emptyList()
                labelBoot = null
            }
            val pending = stored.pending
            if (pending != null) {
                // A process died before the helper ACK was committed: restore
                // protection before exposing any screen, without old labels.
                require(revision < Long.MAX_VALUE)
                val restored = (tickets + pending).distinct()
                require(SensitiveUiGuardPolicy.valid(restored))
                require(write(context, restored, revision + 1, guardEpoch))
                tickets = restored
                revision++
            }
            pendingRemoval = null
        } catch (_: Exception) { unavailable = true }
    }
    private fun readSnapshot(atomic: AtomicFile, readOnly: Boolean = false): StoredState {
        val input = if (readOnly) {
            val base = atomic.baseFile
            if (File(base.path + ".bak").exists() || File(base.path + ".new").exists()) {
                throw java.io.IOException("pending atomic write")
            }
            java.io.FileInputStream(base)
        } else atomic.openRead()
        val bytes = input.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= 65536)
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        val root = JSONObject(String(bytes, Charsets.UTF_8))
        require(root.getInt("version") == 1)
        val epoch = root.getString("epoch")
        java.util.UUID.fromString(epoch)
        val version = root.getLong("revision")
        val list = root.getJSONArray("tickets")
        require(list.length() <= SensitiveUiGuardPolicy.MAX_TICKETS)
        val key = if (!root.has("key") || root.isNull("key")) null else decodeKey(root.getString("key"))
        val labels = root.optJSONArray("labels") ?: JSONArray()
        require(labels.length() <= SensitiveUiGuardPolicy.MAX_LABEL_BASELINES)
        val bases = (0 until labels.length()).map { decodeBaseline(labels.getJSONObject(it)) }
        val state = SensitiveUiGuardSnapshot(epoch, version, (0 until list.length()).map { decode(list.getJSONObject(it)) }, key, bases)
        require(SensitiveUiGuardPolicy.valid(state))
        val pending = if (!root.has("pending") || root.isNull("pending")) null else decode(root.getJSONObject("pending"))
        require(pending == null || (pending.isWellFormed() && pending !in state.tickets))
        val boot = if (!root.has("boot") || root.isNull("boot")) null else root.getInt("boot").also { require(it >= 0) }
        return StoredState(state, pending, boot)
    }
    private fun write(context: Context, values: List<SensitiveUiGuardTicket>, version: Long, epoch: String,
                      pending: SensitiveUiGuardTicket? = null,
                      key: SensitiveUiLabelKey? = labelKey,
                      bases: List<SensitiveUiLabelBaseline> = labelBaselines,
                      boot: Int? = labelBoot): Boolean {
        var atomic: AtomicFile? = null
        var stream: java.io.FileOutputStream? = null
        return try {
            val target = file(context)
            atomic = target
            val array = JSONArray(); values.forEach { array.put(encode(it)) }
            val labels = JSONArray(); bases.forEach { labels.put(encodeBaseline(it)) }
            val keyBytes = key?.copyBytes()
            val keyHex = try { keyBytes?.joinToString("") { "%02x".format(it.toInt() and 0xff) } }
                finally { keyBytes?.fill(0) }
            val bytes = JSONObject().put("version", 1).put("epoch", epoch).put("revision", version)
                .put("tickets", array).put("pending", pending?.let(::encode) ?: JSONObject.NULL)
                .put("key", keyHex ?: JSONObject.NULL).put("labels", labels)
                .put("boot", boot ?: JSONObject.NULL)
                .toString().toByteArray(Charsets.UTF_8)
            require(bytes.size <= 65536)
            stream = target.startWrite(); stream.write(bytes); stream.fd.sync(); target.finishWrite(stream); true
        } catch (_: Exception) {
            stream?.let { output -> runCatching { atomic?.failWrite(output) } }
            false
        }
    }
    private fun bootCount(context: Context): Int? = runCatching {
        android.provider.Settings.Global.getInt(context.contentResolver, "boot_count", -1).takeIf { it >= 0 }
    }.getOrNull()
    private fun newKey(): SensitiveUiLabelKey? {
        val bytes = ByteArray(32)
        return try { java.security.SecureRandom().nextBytes(bytes); SensitiveUiLabelKey.fromBytes(bytes) }
        finally { bytes.fill(0) }
    }
    private fun decodeKey(encoded: String): SensitiveUiLabelKey {
        require(encoded.length == 64 && encoded.all { it in '0'..'9' || it in 'a'..'f' })
        val bytes = ByteArray(32) { encoded.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        return try { SensitiveUiLabelKey.fromBytes(bytes) ?: error("key invalid") } finally { bytes.fill(0) }
    }
    private fun encodeIdentity(i: SensitiveUiLabelIdentity) = JSONObject()
        .put("package", i.packageName).put("window", i.windowId).put("display", i.displayId)
        .put("path", JSONArray(i.path)).put("class", i.className).put("view", i.viewId ?: JSONObject.NULL)
    private fun decodeIdentity(o: JSONObject): SensitiveUiLabelIdentity {
        val path = o.getJSONArray("path"); require(path.length() <= 32)
        return SensitiveUiLabelIdentity(o.getString("package"), o.getInt("window"), o.getInt("display"),
            (0 until path.length()).map(path::getInt), o.getString("class"), if (o.isNull("view")) null else o.getString("view"))
    }
    private fun encodeBaseline(b: SensitiveUiLabelBaseline) = JSONObject()
        .put("identity", encodeIdentity(b.identity)).put("parent", b.safeParent?.let(::encodeIdentity) ?: JSONObject.NULL)
        .put("digest", b.digest)
    private fun decodeBaseline(o: JSONObject) = SensitiveUiLabelBaseline(
        decodeIdentity(o.getJSONObject("identity")), if (o.isNull("parent")) null else decodeIdentity(o.getJSONObject("parent")),
        o.getString("digest"),
    )
    private fun baselineRecords(ticket: SensitiveUiGuardTicket, records: Collection<PhoneControlNodeRecord>): List<SensitiveUiLabelBaseline> {
        fun identity(n: PhoneControlNodeRecord) = SensitiveUiLabelIdentity(ticket.packageName, ticket.windowId,
            ticket.displayId, n.path, n.className, n.viewId)
        fun clickable(n: PhoneControlNodeRecord) = n.clickable || PhoneControlNodeAction.CLICK in n.actions
        val byPath = records.associateBy { it.path }
        return records.asSequence().filter { it.packageName == ticket.packageName &&
            PhoneControlGuardedLabel.canBaseline(it, records) && it.safeLabelHmac != null }
            .mapNotNull { n ->
                val parent = if (clickable(n)) null else byPath[n.path.dropLast(1)]?.let(::identity) ?: return@mapNotNull null
                SensitiveUiLabelBaseline(identity(n), parent, n.safeLabelHmac!!).takeIf { it.isWellFormed() }
            }.distinctBy { it.identity }.take(SensitiveUiGuardPolicy.MAX_LABEL_BASELINES).toList()
    }
    private fun encode(t: SensitiveUiGuardTicket) = JSONObject()
        .put("task", t.taskId).put("run", t.runId).put("epoch", t.epoch).put("grant", t.grantId)
        .put("observation", t.observationId).put("node", t.nodeRef).put("package", t.packageName)
        .put("window", t.windowId).put("display", t.displayId).put("path", JSONArray(t.path))
        .put("class", t.className).put("view", t.viewId ?: JSONObject.NULL)
    private fun decode(o: JSONObject): SensitiveUiGuardTicket {
        val path = o.getJSONArray("path")
        require(path.length() <= 32)
        return SensitiveUiGuardTicket(o.getString("task"), o.getString("run"), o.getLong("epoch"),
            o.getString("grant"), o.getString("observation"), o.getString("node"), o.getString("package"),
            o.getInt("window"), o.getInt("display"), (0 until path.length()).map(path::getInt),
            o.getString("class"), if (o.isNull("view")) null else o.getString("view"))
    }
}
