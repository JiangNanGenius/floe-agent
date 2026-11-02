// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable, bounded recovery journal.
 *
 * Durability contract: every mutation is written to a private temp file in
 * the same directory, fsynced, then atomically renamed over the journal. The
 * in-memory list advances ONLY after the rename. A process loss therefore
 * leaves either the old complete journal or the new complete journal — never
 * a torn record.
 *
 * Corruption contract: a malformed/oversized journal is preserved under a
 * `.corrupt-<timestamp>.json` / `.oversize-<timestamp>.json` name before an
 * empty/partial view is used. Nothing is silently deleted; malformed records
 * are skipped and counted in [loadDiagnostic].
 *
 * Bounded retention: the ledger holds at most [MAX_CANDIDATES]. A new record
 * may evict the OLDEST terminal record (SAVED / CLOSED_CLEAN / DISCARDED)
 * because the verified destination is the authoritative copy there; active,
 * uncertain and working-copy-only records are NEVER evicted. If no terminal
 * record exists, adding fails with [Full] and the caller refuses the new open
 * rather than silently dropping recoverable bytes.
 */
internal class OfficeRecoveryJournal(
    private val root: File,
    /**
     * LAST-GATE ownership check for a retention eviction. The journal knows
     * only its own records; the App knows which working copy is still mounted
     * or has scheduled save IO. A refused victim is never deleted, and the
     * add fails honestly if no other terminal record is safe to evict.
     */
    private val canEvict: (OfficeRecoveryCandidate) -> Boolean = { true },
    private val onEvict: (OfficeRecoveryCandidate) -> Unit = {},
) : OfficeRecoveryJournalSink {

    class Full : Exception("office recovery journal is full of unresolved candidates")

    private companion object {
        const val FILE_NAME = "recovery-journal.json"
        const val MAX_JOURNAL_BYTES = 512L * 1024L
        const val MAX_CANDIDATES = 20
        const val MAX_DISPLAY_NAME = 240
        const val MAX_PATH = 4096
        const val MAX_ID = 128
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")
        val PHASE_EVICTABLE = setOf(
            OfficeRecoveryPhase.SAVED,
            OfficeRecoveryPhase.CLOSED_CLEAN,
            OfficeRecoveryPhase.DISCARDED,
        )
    }

    private val lock = Any()
    private var loaded = false
    private var items: MutableList<OfficeRecoveryCandidate> = mutableListOf()

    /** Original load failure for diagnostics; never ordinary UI copy. */
    @Volatile
    var loadDiagnostic: String? = null
        private set

    /** Last failed write for diagnostics; a write failure never claims success. */
    @Volatile
    var writeDiagnostic: String? = null
        private set

    private val journalFile: File get() = File(root, FILE_NAME)

    fun snapshot(): List<OfficeRecoveryCandidate> = synchronized(lock) {
        ensureLoadedLocked()
        items.toList()
    }

    fun candidate(id: String): OfficeRecoveryCandidate? = synchronized(lock) {
        ensureLoadedLocked()
        items.firstOrNull { it.id == id }
    }

    /** True when a new record would require bounded retention first. */
    fun isFull(): Boolean = synchronized(lock) {
        ensureLoadedLocked()
        items.size >= MAX_CANDIDATES
    }

    /** Adds one NEW candidate, applying bounded retention. */
    fun add(candidate: OfficeRecoveryCandidate): OfficeRecoveryCandidate {
        var evicted: OfficeRecoveryCandidate? = null
        synchronized(lock) {
            ensureLoadedLocked()
            val next = items.toMutableList()
            next.removeAll { it.id == candidate.id }
            next += candidate
            if (next.size > MAX_CANDIDATES) {
                val victim = next
                    .filter {
                        it.id != candidate.id && it.phase in PHASE_EVICTABLE &&
                            runCatching { canEvict(it) }.getOrDefault(false)
                    }
                    .minByOrNull { it.updatedAtMillis }
                    ?: throw Full()
                next.remove(victim)
                evicted = victim
            }
            persistLocked(next)
            items = next
        }
        evicted?.let { runCatching { onEvict(it) } }
        return candidate
    }

    /** Replaces an existing candidate in one durable write. Returns null if absent. */
    fun update(id: String, transform: (OfficeRecoveryCandidate) -> OfficeRecoveryCandidate): OfficeRecoveryCandidate? =
        synchronized(lock) {
            ensureLoadedLocked()
            val index = items.indexOfFirst { it.id == id }
            if (index < 0) return null
            val next = items.toMutableList()
            val updated = transform(items[index]).copy(
                id = id,
                updatedAtMillis = System.currentTimeMillis(),
            )
            next[index] = updated
            persistLocked(next)
            items = next
            updated
        }

    /** Removes one record after its owned artifacts were handled. */
    fun remove(id: String): OfficeRecoveryCandidate? = synchronized(lock) {
        ensureLoadedLocked()
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return null
        val removed = items[index]
        val next = items.toMutableList()
        next.removeAt(index)
        persistLocked(next)
        items = next
        removed
    }

    /** Marks a viewer-confirmed discard; artifacts are handled by the controller. */
    fun markDiscarded(id: String): OfficeRecoveryCandidate? = update(id) {
        it.copy(phase = OfficeRecoveryPhase.DISCARDED, dirtyAtClose = true, updatedAtMillis = System.currentTimeMillis())
    }

    /**
     * Reconcile one viewer close. Only facts the module actually reported are
     * used; a missing result (process loss) changes nothing here.
     */
    fun markViewerClosed(
        id: String,
        resultPresent: Boolean,
        closedCleanly: Boolean,
        dirtyAtClose: Boolean,
        discarded: Boolean,
        /** Actual working-copy measurement supplied by the App, if available. */
        workingCopyChangedAfterSave: Boolean? = null,
    ): OfficeRecoveryCandidate? = update(id) { current ->
        val phase = when {
            discarded -> OfficeRecoveryPhase.DISCARDED
            current.phase == OfficeRecoveryPhase.DISCARDED -> OfficeRecoveryPhase.DISCARDED
            current.phase == OfficeRecoveryPhase.SAVED &&
                workingCopyChangedAfterSave == true -> OfficeRecoveryPhase.CLOSED_UNSAVED
            // A verified destination is not re-opened by close facts alone.
            // The App controller re-measures the actual working copy against
            // the EXACT verified output digest and preserves later bytes as
            // CLOSED_UNSAVED; this journal transition has no byte access.
            current.phase == OfficeRecoveryPhase.SAVED -> OfficeRecoveryPhase.SAVED
            current.phase == OfficeRecoveryPhase.TRANSFERRING ||
                current.phase == OfficeRecoveryPhase.UNCERTAIN -> current.phase
            current.phase == OfficeRecoveryPhase.EXPORT_READY -> OfficeRecoveryPhase.EXPORT_READY
            !resultPresent || !closedCleanly -> current.phase
            dirtyAtClose -> OfficeRecoveryPhase.CLOSED_UNSAVED
            else -> OfficeRecoveryPhase.CLOSED_CLEAN
        }
        current.copy(
            phase = phase,
            dirtyAtClose = when {
                discarded -> true
                resultPresent -> dirtyAtClose
                else -> current.dirtyAtClose
            },
            updatedAtMillis = System.currentTimeMillis(),
        )
    }

    /** Records the latest exact Office session token for a reopened candidate. */
    fun touchSessionToken(id: String, token: String): OfficeRecoveryCandidate? {
        if (token.isBlank() || token.length > 128 || token.any { it.code < 0x20 || it == '/' || it == '\\' }) {
            return null
        }
        return update(id) {
            it.copy(originSessionToken = token, updatedAtMillis = System.currentTimeMillis())
        }
    }

    /** Records the actual current working-copy digest after a successful open. */
    fun touchWorkingCopyBase(id: String, sha256: String, bytes: Long): OfficeRecoveryCandidate? {
        if (!SHA256_HEX.matches(sha256) || bytes !in 1..MAX_OFFICE_RECOVERY_BYTES) return null
        return update(id) {
            it.copy(
                workingCopyBaseSha256 = sha256,
                workingCopyBaseBytes = bytes,
                updatedAtMillis = System.currentTimeMillis(),
            )
        }
    }

    // ------------------------------------------------------------------
    // OfficeRecoveryJournalSink (called from Binder/IO threads)
    // ------------------------------------------------------------------

    override fun recordFlush(candidateId: String, workingCopySha256: String, workingCopyBytes: Long) {
        if (!SHA256_HEX.matches(workingCopySha256) || workingCopyBytes !in 1..MAX_OFFICE_RECOVERY_BYTES) return
        runCatching {
            update(candidateId) {
                it.copy(
                    workingCopyBaseSha256 = workingCopySha256,
                    workingCopyBaseBytes = workingCopyBytes,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            }
        }.onFailure { writeDiagnostic = it.javaClass.simpleName }
    }

    override fun recordOutputReady(candidateId: String, receipt: OfficeSaveReceipt): Boolean {
        val operation = receipt.operation
        val state = receipt.state
        if (operation != com.floe.android.core.officeengine.OfficeSaveOperation.STAGED_EXPORT ||
            state != OfficeSaveState.OUTPUT_READY
        ) {
            return false
        }
        val path = receipt.outputDocumentPath ?: return false
        if (path.isEmpty() || path.length > MAX_PATH || path.contains('\u0000') || !File(path).isAbsolute) {
            return false
        }
        val sha = receipt.outputSha256 ?: return false
        val format = receipt.format?.lowercase(Locale.ROOT) ?: return false
        if (!SHA256_HEX.matches(sha) ||
            receipt.outputBytes !in 1..MAX_OFFICE_RECOVERY_BYTES ||
            format !in OFFICE_RECOVERY_FORMATS ||
            receipt.opId.isEmpty() || receipt.opId.length > 64 ||
            receipt.generation < 1L
        ) {
            return false
        }
        return try {
            val updated = update(candidateId) { current ->
                if (current.phase == OfficeRecoveryPhase.DISCARDED) {
                    current
                } else if (current.outputOpId == receipt.opId &&
                    current.phase in setOf(
                        OfficeRecoveryPhase.TRANSFERRING,
                        OfficeRecoveryPhase.UNCERTAIN,
                        OfficeRecoveryPhase.SAVED,
                    )
                ) {
                    // A duplicate/late receipt for the SAME op must never
                    // roll back an in-flight or already-settled transaction.
                    current
                } else current.copy(
                    phase = OfficeRecoveryPhase.EXPORT_READY,
                    outputPath = path,
                    outputSha256 = sha,
                    outputBytes = receipt.outputBytes,
                    outputFormat = format,
                    outputOpId = receipt.opId,
                    outputNativeGeneration = receipt.generation,
                    outputWorkingCopyBaseSha256 = current.workingCopyBaseSha256,
                    destinationVerified = false,
                    destinationSha256 = null,
                    destinationBytes = 0L,
                    lastErrorCode = null,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            }
            updated != null && updated.phase != OfficeRecoveryPhase.DISCARDED
        } catch (failure: RuntimeException) {
            writeDiagnostic = failure.javaClass.simpleName
            false
        }
    }

    override fun markTransferStarted(candidateId: String, opId: String, targetUri: String): Boolean {
        if (targetUri.isEmpty() || targetUri.length > MAX_PATH || targetUri.contains('\u0000')) return false
        return try {
            val updated = update(candidateId) { current ->
                if (current.phase == OfficeRecoveryPhase.DISCARDED) current else current.copy(
                    phase = OfficeRecoveryPhase.TRANSFERRING,
                    destinationUri = targetUri,
                    destinationVerified = false,
                    destinationSha256 = null,
                    destinationBytes = 0L,
                    attemptCount = (current.attemptCount + 1).coerceAtMost(999),
                    lastErrorCode = null,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            }
            updated != null && updated.phase == OfficeRecoveryPhase.TRANSFERRING
        } catch (failure: RuntimeException) {
            writeDiagnostic = failure.javaClass.simpleName
            false
        }
    }

    override fun settleSave(candidateId: String, opId: String, facts: OfficeRecoverySaveFacts) {
        runCatching {
            update(candidateId) { current ->
                if (current.phase == OfficeRecoveryPhase.DISCARDED) current else when {
                    facts.saved -> current.copy(
                        phase = OfficeRecoveryPhase.SAVED,
                        destinationUri = facts.destinationUri ?: current.destinationUri,
                        destinationVerified = true,
                        destinationSha256 = facts.destinationSha256,
                        destinationBytes = facts.destinationBytes,
                        savedWorkingCopySha256 = current.outputWorkingCopyBaseSha256
                            ?: current.workingCopyBaseSha256,
                        lastErrorCode = null,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                    facts.uncertain -> current.copy(
                        phase = OfficeRecoveryPhase.UNCERTAIN,
                        destinationUri = facts.destinationUri ?: current.destinationUri,
                        destinationVerified = false,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                        lastErrorCode = facts.code,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                    else -> current.copy(
                        // A clean failure/cancel BEFORE the provider was touched
                        // returns to the verified-output state; a destination
                        // attempt is never silently relabeled success.
                        phase = if (current.phase == OfficeRecoveryPhase.TRANSFERRING) {
                            OfficeRecoveryPhase.EXPORT_READY
                        } else {
                            current.phase
                        },
                        destinationVerified = false,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                        lastErrorCode = facts.code,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                }
            }
        }.onFailure { writeDiagnostic = it.javaClass.simpleName }
    }

    // ------------------------------------------------------------------
    // Load / persist
    // ------------------------------------------------------------------

    private fun ensureLoadedLocked() {
        if (loaded) return
        loaded = true
        val file = journalFile
        if (!file.exists()) return
        if (Files.isSymbolicLink(file.toPath())) {
            loadDiagnostic = "journal-symlink-refused"
            return
        }
        val length = runCatching { file.length() }.getOrDefault(-1L)
        if (length < 0 || length > MAX_JOURNAL_BYTES) {
            quarantine(file, "oversize")
            loadDiagnostic = "journal-oversize"
            return
        }
        val raw = runCatching { file.readBytes() }.getOrElse {
            loadDiagnostic = "journal-unreadable"
            return
        }
        var corrupt = false
        val parsed = ArrayList<OfficeRecoveryCandidate>()
        try {
            val json = JSONObject(String(raw, Charsets.UTF_8))
            if (json.optInt("schema", -1) != OFFICE_RECOVERY_SCHEMA) {
                quarantine(file, "corrupt")
                loadDiagnostic = "journal-schema"
                return
            }
            val array = json.optJSONArray("candidates") ?: JSONArray()
            for (index in 0 until array.length()) {
                val objectValue = array.optJSONObject(index) ?: run {
                    corrupt = true
                    continue
                }
                val candidate = runCatching { candidateFromJson(objectValue) }.getOrNull()
                if (candidate == null) {
                    corrupt = true
                } else {
                    parsed += candidate
                }
            }
        } catch (_: RuntimeException) {
            quarantine(file, "corrupt")
            loadDiagnostic = "journal-corrupt"
            return
        }
        if (corrupt) {
            quarantine(file, "corrupt")
            loadDiagnostic = "journal-entries-skipped"
        }
        items = parsed.toMutableList()
    }

    private fun quarantine(file: File, reason: String) {
        val target = File(root, "recovery-journal.$reason-${System.currentTimeMillis()}.json")
        runCatching {
            if (!root.isDirectory && !root.mkdirs()) return
            Files.move(
                file.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }.onFailure {
            // If even the move fails the original is left untouched; the
            // diagnostic still records the refusal, and no write is attempted
            // against an unparseable journal.
            loadDiagnostic = "quarantine-failed"
        }
    }

    private fun persistLocked(next: List<OfficeRecoveryCandidate>) {
        if (!root.isDirectory && !root.mkdirs()) throw IllegalStateException("journal root unavailable")
        if (Files.isSymbolicLink(root.toPath())) throw IllegalStateException("journal root symlink refused")
        val target = journalFile
        if (Files.isSymbolicLink(target.toPath())) throw IllegalStateException("journal symlink refused")
        val payload = journalJson(next).toString().toByteArray(Charsets.UTF_8)
        if (payload.size.toLong() > MAX_JOURNAL_BYTES) throw IllegalStateException("journal payload over cap")
        val temp = File(root, "$FILE_NAME.tmp-${UUID.randomUUID()}.json")
        try {
            FileOutputStream(temp).use { output ->
                output.write(payload)
                output.flush()
                output.fd.sync()
            }
            try {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            runCatching { temp.delete() }
        }
    }

    private fun journalJson(next: List<OfficeRecoveryCandidate>): JSONObject {
        val array = JSONArray()
        next.forEach { array.put(candidateToJson(it)) }
        return JSONObject().apply {
            put("schema", OFFICE_RECOVERY_SCHEMA)
            put("candidates", array)
        }
    }

    private fun candidateToJson(candidate: OfficeRecoveryCandidate): JSONObject = JSONObject().apply {
        put("id", candidate.id)
        put("createdAt", candidate.createdAtMillis)
        put("updatedAt", candidate.updatedAtMillis)
        put("phase", candidate.phase.name)
        put("route", candidate.route.name)
        put("displayName", candidate.displayName)
        put("format", candidate.format)
        putOptional("ownerTaskId", candidate.ownerTaskId)
        putOptional("workspaceId", candidate.workspaceId)
        putOptional("nativeEpoch", candidate.nativeEpoch)
        putOptional("hostGeneration", candidate.hostGeneration)
        putOptional("sourceLogicalPath", candidate.sourceLogicalPath)
        putOptional("sourceId", candidate.sourceId)
        putOptional("sourceRevision", candidate.sourceRevision)
        putOptional("originalUri", candidate.originalUri)
        putOptional("originalDocumentId", candidate.originalDocumentId)
        put("sourceSha256", candidate.sourceSha256)
        put("sourceBytes", candidate.sourceBytes)
        put("workingCopyPath", candidate.workingCopyPath)
        put("workingCopyBaseSha256", candidate.workingCopyBaseSha256)
        put("workingCopyBaseBytes", candidate.workingCopyBaseBytes)
        putOptional("outputWorkingCopyBaseSha256", candidate.outputWorkingCopyBaseSha256)
        putOptional("savedWorkingCopySha256", candidate.savedWorkingCopySha256)
        putOptional("outputPath", candidate.outputPath)
        putOptional("outputSha256", candidate.outputSha256)
        put("outputBytes", candidate.outputBytes)
        putOptional("outputFormat", candidate.outputFormat)
        putOptional("outputOpId", candidate.outputOpId)
        put("outputNativeGeneration", candidate.outputNativeGeneration)
        putOptional("destinationUri", candidate.destinationUri)
        put("destinationVerified", candidate.destinationVerified)
        putOptional("destinationSha256", candidate.destinationSha256)
        put("destinationBytes", candidate.destinationBytes)
        put("attemptCount", candidate.attemptCount)
        putOptional("lastErrorCode", candidate.lastErrorCode)
        candidate.dirtyAtClose?.let { put("dirtyAtClose", it) }
        putOptional("originSessionToken", candidate.originSessionToken)
    }

    private fun JSONObject.putOptional(key: String, value: String?) {
        if (value == null) put(key, JSONObject.NULL) else put(key, value)
    }

    private fun candidateFromJson(json: JSONObject): OfficeRecoveryCandidate? {
        fun requiredString(key: String, max: Int): String? {
            if (json.isNull(key)) return null
            val value = json.optString(key, "")
            return value.takeIf { it.isNotEmpty() && it.length <= max && !it.contains('\u0000') }
        }
        fun optionalString(key: String, max: Int): String? {
            if (!json.has(key) || json.isNull(key)) return null
            val value = json.optString(key, "")
            return value.takeIf { it.isNotEmpty() && it.length <= max && !it.contains('\u0000') }
        }
        val id = requiredString("id", MAX_ID) ?: return null
        if (runCatching { UUID.fromString(id) }.isFailure) return null
        val phase = runCatching { OfficeRecoveryPhase.valueOf(json.optString("phase", "")) }.getOrNull() ?: return null
        val route = runCatching { OfficeRecoveryRoute.valueOf(json.optString("route", "")) }.getOrNull() ?: return null
        val displayName = requiredString("displayName", MAX_DISPLAY_NAME) ?: return null
        val format = requiredString("format", 8)?.lowercase(Locale.ROOT) ?: return null
        if (format !in OFFICE_RECOVERY_FORMATS) return null
        val sourceSha = requiredString("sourceSha256", 64) ?: return null
        if (!SHA256_HEX.matches(sourceSha)) return null
        val sourceBytes = json.optLong("sourceBytes", -1L)
        if (sourceBytes !in 1..MAX_OFFICE_RECOVERY_BYTES) return null
        val workingCopyPath = requiredString("workingCopyPath", MAX_PATH) ?: return null
        if (!File(workingCopyPath).isAbsolute) return null
        val baseSha = requiredString("workingCopyBaseSha256", 64) ?: return null
        if (!SHA256_HEX.matches(baseSha)) return null
        val baseBytes = json.optLong("workingCopyBaseBytes", -1L)
        if (baseBytes !in 1..MAX_OFFICE_RECOVERY_BYTES) return null
        val outputPath = optionalString("outputPath", MAX_PATH)
        val outputSha = optionalString("outputSha256", 64)
        val outputBytes = json.optLong("outputBytes", 0L)
        val outputFormat = optionalString("outputFormat", 8)?.lowercase(Locale.ROOT)
        val outputOpId = optionalString("outputOpId", 64)
        val outputGeneration = json.optLong("outputNativeGeneration", 0L)
        val hasOutput = outputPath != null || outputSha != null || outputFormat != null || outputOpId != null
        if (hasOutput) {
            if (outputPath == null || !File(outputPath).isAbsolute ||
                outputSha == null || !SHA256_HEX.matches(outputSha) ||
                outputBytes !in 1..MAX_OFFICE_RECOVERY_BYTES ||
                outputFormat == null || outputFormat !in OFFICE_RECOVERY_FORMATS ||
                outputOpId == null || outputOpId.isEmpty() || outputOpId.length > 64 ||
                outputGeneration < 1L
            ) {
                return null
            }
        }
        val createdAt = json.optLong("createdAt", -1L)
        val updatedAt = json.optLong("updatedAt", -1L)
        if (createdAt <= 0L || updatedAt <= 0L) return null
        val dirty = if (json.has("dirtyAtClose") && !json.isNull("dirtyAtClose")) {
            json.optBoolean("dirtyAtClose", false)
        } else {
            null
        }
        return OfficeRecoveryCandidate(
            id = id,
            createdAtMillis = createdAt,
            updatedAtMillis = updatedAt,
            phase = phase,
            route = route,
            displayName = displayName,
            format = format,
            ownerTaskId = optionalString("ownerTaskId", MAX_ID),
            workspaceId = optionalString("workspaceId", MAX_ID),
            nativeEpoch = optionalString("nativeEpoch", MAX_ID),
            hostGeneration = optionalString("hostGeneration", MAX_ID),
            sourceLogicalPath = optionalString("sourceLogicalPath", MAX_PATH),
            sourceId = optionalString("sourceId", MAX_ID),
            sourceRevision = optionalString("sourceRevision", MAX_ID),
            originalUri = optionalString("originalUri", MAX_PATH),
            originalDocumentId = optionalString("originalDocumentId", MAX_ID),
            sourceSha256 = sourceSha,
            sourceBytes = sourceBytes,
            workingCopyPath = workingCopyPath,
            workingCopyBaseSha256 = baseSha,
            workingCopyBaseBytes = baseBytes,
            outputWorkingCopyBaseSha256 = optionalString("outputWorkingCopyBaseSha256", 64),
            savedWorkingCopySha256 = optionalString("savedWorkingCopySha256", 64),
            outputPath = outputPath,
            outputSha256 = outputSha,
            outputBytes = outputBytes,
            outputFormat = outputFormat,
            outputOpId = outputOpId,
            outputNativeGeneration = outputGeneration,
            destinationUri = optionalString("destinationUri", MAX_PATH),
            destinationVerified = json.optBoolean("destinationVerified", false),
            destinationSha256 = optionalString("destinationSha256", 64),
            destinationBytes = json.optLong("destinationBytes", 0L).coerceAtLeast(0L),
            attemptCount = json.optInt("attemptCount", 0).coerceIn(0, 999),
            lastErrorCode = optionalString("lastErrorCode", 64),
            dirtyAtClose = dirty,
            originSessionToken = optionalString("originSessionToken", 128),
        )
    }
}
