// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

import com.floe.android.core.workbenchmedia.util.Digests
import com.floe.android.core.workbenchmedia.util.MediaClock
import com.floe.android.core.workbenchmedia.util.MediaPaths
import com.floe.android.core.workbenchmedia.util.STORAGE_UNAVAILABLE
import com.floe.android.core.workbenchmedia.util.WRITE_FAILED
import com.floe.android.core.workbenchmedia.util.nowIso
import com.floe.android.core.workbenchmedia.util.refusal
import com.floe.android.core.workbenchmedia.util.writeFullySync
import com.floe.android.feature.workbench.ExportVerification
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Version of the durable owner/root binding written by this module. */
internal const val RECOVERY_OWNER_VERSION = 2

/**
 * Stable owner identity for a durable export. It deliberately contains no
 * editor session token: a new authorized editor session for the same accepted
 * project/storage/origin owner may recover the journal, while a different
 * project/storage/origin/owner generation cannot.
 */
internal data class RecoveryOwner(
    val projectID: String,
    val storageKey: String,
    val originKey: String?,
    val ownerKey: String,
) {
    val fingerprint: String
        get() = Digests.sha256(
            buildString {
                append("floe.workbench.export.owner.v2")
                listOf(projectID, storageKey, originKey ?: "", ownerKey).forEach { value ->
                    append('|').append(value.length).append(':').append(value)
                }
            }.toByteArray(Charsets.UTF_8),
        )
}

/** The exact native-authorised scope used to read one recovery journal. */
internal data class RecoveryExpectation(
    val owner: RecoveryOwner,
    val mediaRootPath: String,
)

/** A bounded, owner-scoped journal candidate. Its bytes/output are verified later. */
internal data class RecoveryCandidate(
    val jobID: String,
    val updatedAt: String,
)

internal data class RecoveryRecord(
    val jobID: String,
    val projectID: String,
    val attemptID: String,
    val kind: MediaExportKind,
    val state: MediaExportState,
    val updatedAt: String,
    val ownerFingerprint: String,
    val revision: Long,
    val timelineDigest: String,
    val ownerVersion: Int = RECOVERY_OWNER_VERSION,
    val ownerKey: String = "",
    val storageKey: String = "",
    val originKey: String? = null,
    val mediaRootPath: String = "",
    val writtenEpoch: Long = 0L,
    val progress: Double? = null,
    val outputRelativePath: String? = null,
    val mimeType: String? = null,
    val byteCount: Long? = null,
    val sha256: String? = null,
    val verification: ExportVerification? = null,
    val errorCode: String? = null,
    val retryable: Boolean = false,
)

/**
 * Bounded, atomic operation journal under `<trusted project root>/MediaRecovery/Exports`.
 * It is NOT a project store or Agent queue: it persists only the terminal
 * receipt/status facts needed to recover an interrupted export and to avoid
 * presenting a partial or tampered file as success.
 *
 * The journal lives in the same project root as the immutable export binding.
 * Recovery must resolve that root through the required native
 * `WorkbenchRecoveryAuthority`; it must never substitute the accepted base root
 * or a caller path.
 */
internal class ExportRecoveryStore(private val clock: MediaClock) {
    fun write(root: File, record: RecoveryRecord) {
        val directory = recoveryDirectory(root)
        val target = File(directory, "${record.jobID}.json")
        val staging = File(directory, ".${record.jobID}.json.part")
        val json = toJson(record).toString()
        try {
            staging.delete()
            writeFullySync(staging, json.toByteArray(Charsets.UTF_8))
            Files.move(
                staging.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (failure: Exception) {
            staging.delete()
            throw refusal(WRITE_FAILED, "Export recovery journal could not be written: ${failure.message}")
        }
    }

    fun read(root: File, jobID: String): RecoveryRecord? {
        if (!MediaPaths.safeComponent(jobID, max = 200)) return null
        val directory = recoveryDirectory(root, create = false)
        val file = File(directory, "$jobID.json")
        if (!file.isFile || Files.isSymbolicLink(file.toPath()) ||
            file.length() !in 1L..MAX_RECORD_BYTES
        ) {
            return null
        }
        return try {
            parse(Json.parseToJsonElement(file.readText()) as? JsonObject ?: return null)
                ?.takeIf { it.jobID == jobID }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Bounded journal enumeration for a recovered-export list. Only regular
     * non-symlink `*.json` entries are considered; each record is read with the
     * same 256 KiB cap as [read]. The scan is capped by both candidate count and
     * visited directory entries so a large recovery directory cannot make a UI
     * listing unbounded. Selection/owner verification and output proof are done
     * by the caller through [statusFromRecovery].
     */
    fun recoveryCandidates(
        root: File,
        maxScan: Int,
        expected: RecoveryExpectation? = null,
    ): List<RecoveryCandidate> {
        val scanLimit = maxScan.coerceIn(1, MAX_RECOVERY_SCAN)
        val visitedLimit = scanLimit * 4
        val candidates = ArrayList<RecoveryCandidate>(scanLimit)
        val directory = try {
            recoveryDirectory(root, create = false)
        } catch (_: Exception) {
            return candidates
        }
        var visited = 0
        try {
            Files.newDirectoryStream(directory.toPath(), "*.json").use { stream ->
                val iterator = stream.iterator()
                while (iterator.hasNext() && candidates.size < scanLimit && visited < visitedLimit) {
                    visited += 1
                    val path = iterator.next()
                    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) continue
                    val name = path.fileName.toString()
                    if (!name.endsWith(".json")) continue
                    val jobID = name.substring(0, name.length - ".json".length)
                    if (!MediaPaths.safeComponent(jobID, max = 200)) continue
                    val record = read(root, jobID) ?: continue
                    if (expected != null && !ownerMatches(record, expected)) continue
                    candidates += RecoveryCandidate(record.jobID, record.updatedAt)
                }
            }
        } catch (_: Exception) {
            // A directory race/IO failure yields the bounded candidates found
            // so far; it never fabricates a record or success.
        }
        return candidates
    }

    /**
     * Removes a journal that was written for a submission which never became an
     * accepted job (pin/snapshot/insert failure). It is never used for a job
     * that reached the service or a worker.
     */
    fun delete(root: File, jobID: String) {
        if (!MediaPaths.safeComponent(jobID, max = 200)) return
        val directory = try {
            recoveryDirectory(root, create = false)
        } catch (_: Exception) {
            return
        }
        File(directory, "$jobID.json").delete()
        File(directory, ".$jobID.json.part").delete()
    }

    /**
     * Recovery must prove the complete native owner/root binding and re-hash
     * the exact output bytes before reporting COMPLETED. The output is hashed
     * with a bounded streaming digest; when the caller recorded no byte count
     * there is no full-file heap read and no success claim.
     */
    fun statusFromRecovery(
        root: File,
        expected: RecoveryExpectation,
        jobID: String,
    ): MediaExportStatus? {
        val record = read(root, jobID) ?: return null
        if (record.projectID != expected.owner.projectID) return null
        val expectedRoot = MediaPaths.canonicalRoot(expected.mediaRootPath) ?: return null
        val actualRoot = MediaPaths.canonicalRoot(root.path) ?: return null
        if (expectedRoot.path != actualRoot.path) return null
        if (record.ownerVersion != RECOVERY_OWNER_VERSION) {
            // Old/unknown journal formats cannot prove the owner/root binding.
            // Return an explicit non-success instead of a stale COMPLETED
            // receipt, and leave the durable record untouched as evidence.
            return status(
                record = record,
                state = MediaExportState.FAILED,
                receipt = null,
                errorCode = if (record.ownerVersion < RECOVERY_OWNER_VERSION) {
                    "recoveryRecordMigrationRequired"
                } else {
                    "recoveryRecordVersionUnsupported"
                },
                retryable = false,
            )
        }
        if (!ownerMatches(record, expected)) return null

        var state = if (!terminal(record.state)) MediaExportState.INTERRUPTED else record.state
        var receipt: MediaExportReceipt? = null
        var errorCode: String? = if (state == MediaExportState.INTERRUPTED) {
            record.errorCode ?: "processInterrupted"
        } else {
            record.errorCode
        }
        var retryable = record.retryable
        if (state == MediaExportState.COMPLETED) {
            val relative = record.outputRelativePath
            val mimeType = record.mimeType
            val byteCount = record.byteCount
            val sha256 = record.sha256
            val verification = record.verification
            if (relative == null || mimeType == null || byteCount == null ||
                sha256 == null || verification == null || !Digests.isSha256(sha256) ||
                byteCount <= 0L
            ) {
                state = MediaExportState.FAILED
                errorCode = "recoveryReceiptIncomplete"
                retryable = false
            } else {
                val output = MediaPaths.resolveExistingUnder(root, relative)
                if (output == null || output.length() != byteCount) {
                    state = MediaExportState.FAILED
                    errorCode = "recoveryOutputMissingOrChanged"
                    retryable = false
                } else {
                    // Streaming, bounded by the recorded length. The file
                    // length was already matched, so a same-size tamper is
                    // detected by the digest without reading it into a heap
                    // buffer.
                    val actual = Digests.sha256(output, byteCount)
                    if (actual == null || actual != sha256) {
                        state = MediaExportState.FAILED
                        errorCode = "recoveryOutputChanged"
                        retryable = false
                    } else {
                        receipt = MediaExportReceipt(
                            binding = MediaExportReceiptBinding(
                                projectID = record.projectID,
                                mediaRootPath = actualRoot.path,
                                projectRevision = record.revision,
                                timelineDigest = record.timelineDigest,
                                attemptID = record.attemptID,
                            ),
                            kind = record.kind,
                            outputRelativePath = relative,
                            mimeType = mimeType,
                            byteCount = byteCount,
                            sha256 = sha256,
                            verification = verification,
                            completedAt = record.updatedAt,
                        )
                    }
                }
            }
        }
        return status(record, state, receipt, errorCode, retryable)
    }

    fun initial(
        jobID: String,
        owner: RecoveryOwner,
        attemptID: String,
        kind: MediaExportKind,
        revision: Long,
        timelineDigest: String,
        mediaRootPath: String,
        writtenEpoch: Long,
    ): RecoveryRecord = RecoveryRecord(
        jobID = jobID,
        projectID = owner.projectID,
        attemptID = attemptID,
        kind = kind,
        state = MediaExportState.QUEUED,
        updatedAt = clock.nowIso(),
        ownerFingerprint = owner.fingerprint,
        revision = revision,
        timelineDigest = timelineDigest,
        ownerVersion = RECOVERY_OWNER_VERSION,
        ownerKey = owner.ownerKey,
        storageKey = owner.storageKey,
        originKey = owner.originKey,
        mediaRootPath = mediaRootPath,
        writtenEpoch = writtenEpoch,
    )

    fun ownerFingerprint(owner: RecoveryOwner): String = owner.fingerprint

    companion object {
        private const val MAX_RECORD_BYTES = 256L * 1024L

        /** Upper bound for one list enumeration; the public result cap is 24. */
        const val MAX_RECOVERY_SCAN = 96
    }

    fun terminal(state: MediaExportState): Boolean =
        state == MediaExportState.COMPLETED || state == MediaExportState.CANCELLED ||
            state == MediaExportState.FAILED || state == MediaExportState.INTERRUPTED ||
            state == MediaExportState.TIMEOUT

    /** Exact v2 owner/root/storage/origin fence used by status and list scans. */
    private fun ownerMatches(record: RecoveryRecord, expected: RecoveryExpectation): Boolean {
        if (record.ownerVersion != RECOVERY_OWNER_VERSION) return false
        if (record.projectID != expected.owner.projectID) return false
        if (record.ownerKey != expected.owner.ownerKey ||
            record.storageKey != expected.owner.storageKey ||
            record.originKey != expected.owner.originKey ||
            record.ownerFingerprint != expected.owner.fingerprint
        ) {
            return false
        }
        val expectedRoot = MediaPaths.canonicalRoot(expected.mediaRootPath) ?: return false
        val recordRoot = MediaPaths.canonicalRoot(record.mediaRootPath) ?: return false
        return recordRoot.path == expectedRoot.path
    }

    private fun status(
        record: RecoveryRecord,
        state: MediaExportState,
        receipt: MediaExportReceipt?,
        errorCode: String?,
        retryable: Boolean,
    ): MediaExportStatus = MediaExportStatus(
        jobID = record.jobID,
        kind = record.kind,
        state = state,
        updatedAt = record.updatedAt,
        progress = record.progress,
        receipt = receipt,
        errorCode = errorCode,
        retryable = retryable,
    )

    private fun recoveryDirectory(root: File, create: Boolean = true): File {
        val canonicalRoot = root.canonicalFile
        val path = "MediaRecovery/Exports"
        val directory = MediaPaths.resolveOutputUnder(canonicalRoot, path)
            ?: throw refusal(STORAGE_UNAVAILABLE, "Recovery directory escapes the trusted media root")
        if (!directory.isDirectory) {
            if (!create) return directory
            if (!directory.mkdirs()) {
                throw refusal(STORAGE_UNAVAILABLE, "Recovery directory could not be created")
            }
        }
        return directory
    }

    private fun toJson(record: RecoveryRecord): JsonObject = buildJsonObject {
        put("jobID", record.jobID)
        put("projectID", record.projectID)
        put("attemptID", record.attemptID)
        put("kind", record.kind.wire)
        put("state", record.state.wire)
        put("updatedAt", record.updatedAt)
        put("ownerVersion", record.ownerVersion)
        put("ownerFingerprint", record.ownerFingerprint)
        put("ownerKey", record.ownerKey)
        put("storageKey", record.storageKey)
        record.originKey?.let { put("originKey", it) }
        put("mediaRootPath", record.mediaRootPath)
        put("writtenEpoch", record.writtenEpoch)
        put("revision", record.revision)
        put("timelineDigest", record.timelineDigest)
        record.progress?.let { put("progress", it) }
        record.outputRelativePath?.let { put("outputRelativePath", it) }
        record.mimeType?.let { put("mimeType", it) }
        record.byteCount?.let { put("byteCount", it) }
        record.sha256?.let { put("sha256", it) }
        record.errorCode?.let { put("errorCode", it) }
        put("retryable", record.retryable)
        record.verification?.let { verification ->
            put("verification", buildJsonObject {
                put("playable", verification.playable)
                verification.decodedDurationSeconds?.let { put("decodedDurationSeconds", it) }
                put("width", verification.width)
                put("height", verification.height)
                put("audioTrackCount", verification.audioTrackCount)
                put("container", verification.container)
                put("codec", verification.codec)
            })
        }
    }

    private fun parse(obj: JsonObject): RecoveryRecord? {
        fun string(key: String): String? = (obj[key] as? JsonPrimitive)?.content
        fun long(key: String): Long? = string(key)?.toLongOrNull()
        fun int(key: String): Int? = string(key)?.toIntOrNull()
        fun double(key: String): Double? = string(key)?.toDoubleOrNull()
        fun boolean(key: String): Boolean? = string(key)?.toBooleanStrictOrNull()
        val jobID = string("jobID") ?: return null
        val projectID = string("projectID") ?: return null
        val attemptID = string("attemptID") ?: return null
        val kind = MediaExportKind.entries.firstOrNull { it.wire == string("kind") } ?: return null
        val state = MediaExportState.entries.firstOrNull { it.wire == string("state") } ?: return null
        val ownerFingerprint = string("ownerFingerprint") ?: return null
        val revision = long("revision") ?: return null
        val timelineDigest = string("timelineDigest") ?: return null
        val verificationObj = obj["verification"] as? JsonObject
        val verification = verificationObj?.let {
            fun inner(key: String) = (it[key] as? JsonPrimitive)?.content
            ExportVerification(
                playable = inner("playable")?.toBooleanStrictOrNull() ?: false,
                decodedDurationSeconds = inner("decodedDurationSeconds")?.toDoubleOrNull(),
                width = inner("width")?.toIntOrNull() ?: 0,
                height = inner("height")?.toIntOrNull() ?: 0,
                audioTrackCount = inner("audioTrackCount")?.toIntOrNull() ?: 0,
                container = inner("container") ?: "",
                codec = inner("codec") ?: "",
            )
        }
        return RecoveryRecord(
            jobID = jobID,
            projectID = projectID,
            attemptID = attemptID,
            kind = kind,
            state = state,
            updatedAt = string("updatedAt") ?: clock.nowIso(),
            ownerFingerprint = ownerFingerprint,
            revision = revision,
            timelineDigest = timelineDigest,
            ownerVersion = int("ownerVersion") ?: 0,
            ownerKey = string("ownerKey") ?: "",
            storageKey = string("storageKey") ?: "",
            originKey = string("originKey"),
            mediaRootPath = string("mediaRootPath") ?: "",
            writtenEpoch = long("writtenEpoch") ?: 0L,
            progress = double("progress"),
            outputRelativePath = string("outputRelativePath"),
            mimeType = string("mimeType"),
            byteCount = long("byteCount"),
            sha256 = string("sha256"),
            verification = verification,
            errorCode = string("errorCode"),
            retryable = boolean("retryable") ?: false,
        )
    }
}
