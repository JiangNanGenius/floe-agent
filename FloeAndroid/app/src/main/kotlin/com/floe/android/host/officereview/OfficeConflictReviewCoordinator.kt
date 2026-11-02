// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewRole
import com.floe.android.core.officeengine.revisionreview.OfficeConflictResolutionResult
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAction
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewHandler
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewState
import java.io.File
import java.nio.file.Files
import java.util.UUID

/** Result of writing one bounded, verified text projection into a review dir. */
internal sealed class OfficeConflictPreviewBuild {
    data class Ready(
        val sha256: String,
        val bytes: Long,
        val truncated: Boolean,
    ) : OfficeConflictPreviewBuild()

    /** Bounded failure code; never a path, exception or document text. */
    data class Refused(val code: String) : OfficeConflictPreviewBuild()
}

/**
 * Ports implemented by the one App-owned Office controller. Every method is
 * called on the review binder thread and must return only observed facts.
 */
internal interface OfficeConflictReviewHost {
    /**
     * Re-reads the LIVE operation for the exact token/generation. Returns
     * null when the viewer is not the current, owner-current, VIEWING mount
     * or when the engine generation no longer matches.
     */
    fun liveIdentity(sessionToken: String, generation: Long): OfficeConflictReviewIdentity?

    /** Immutable copy of the ACTUAL working copy for the exact identity. */
    fun captureMine(identity: OfficeConflictReviewIdentity, directory: File): OfficeConflictVersion?

    /** Immutable copy of the live ORIGINAL under its existing authority. */
    fun captureCurrent(identity: OfficeConflictReviewIdentity, directory: File): OfficeConflictVersion?

    /**
     * Re-verifies the retained snapshot and writes ONE bounded text
     * projection into the same review directory. The snapshot itself is
     * never modified, renamed or deleted here.
     */
    fun buildPreview(
        version: OfficeConflictVersion,
        directory: File,
        role: OfficeConflictPreviewRole,
        fileName: String,
        format: String,
        maxChars: Int,
    ): OfficeConflictPreviewBuild

    /** Deletes only a review directory this coordinator created. */
    fun deleteReviewDirectory(directory: File)
}

/**
 * App-owned conflict review transaction.
 *
 * A review captures BOTH versions before returning any CHANGED answer. A
 * resolution re-reads the live original; the only write offered by this
 * manual lane is "keep current" (no write) or "preserve mine as a copy"
 * (existing verified Save Copy). No original write/CAS is implemented here,
 * so RETRY is refused with a typed reason rather than pretending.
 *
 * Provider/workspace IO never runs while the record map is locked, so a slow
 * read cannot delay viewer settle/close. Temporary review snapshots are
 * deleted only after a decision, a stale review, a release, or the owning
 * session settles, AND every admitted preview lease has drained. The mutable
 * working copy and the real original are never deleted by this class.
 */
internal class OfficeConflictReviewCoordinator(
    private val root: File,
    private val host: OfficeConflictReviewHost,
) : OfficeConflictReviewHandler {
    private data class Record(
        val id: String,
        val identity: OfficeConflictReviewIdentity,
        val mine: OfficeConflictVersion,
        val current: OfficeConflictVersion,
        val directory: File,
        val createdAtElapsedMs: Long,
        /** Serialises the bounded projection write for this exact record. */
        val previewLock: Any = Any(),
        /** Active preview leases; cleanup waits for every one to drain. */
        var readers: Int = 0,
        /** No new preview may be admitted after a decision/settle/eviction. */
        var retired: Boolean = false,
        /** The directory is only deleted when readers reaches zero. */
        var deleteWhenDrained: Boolean = false,
    )

    private data class PreviewLease(
        val id: String,
        val record: Record,
        val role: OfficeConflictPreviewRole,
    )

    private val lock = Any()
    private val records = LinkedHashMap<String, Record>()
    /** Reader leases survive record retirement until the viewer closes. */
    private val leases = HashMap<String, PreviewLease>()
    /** Exact tokens whose owning session already settled; bounded history. */
    private val closedSessions = LinkedHashSet<String>()

    /** Bounded; only one live viewer normally exists. */
    private val maxRecords = 4
    private val maxClosedSessions = 64
    private val maxLeases = 8

    override fun review(
        sessionToken: String,
        generation: Long,
        requestId: String,
    ): OfficeConflictReviewAnswer {
        if (synchronized(lock) { sessionToken in closedSessions }) {
            return OfficeConflictReviewPolicy.unavailable("sessionFenced")
        }
        val identity = runCatching { host.liveIdentity(sessionToken, generation) }.getOrNull()
            ?: return OfficeConflictReviewPolicy.unavailable("sessionFenced")
        if (!OfficeConflictReviewPolicy.hasOriginal(identity.route)) {
            return OfficeConflictReviewPolicy.notApplicable("noOriginal")
        }
        val directory = createReviewDirectory()
            ?: return OfficeConflictReviewPolicy.unavailable("reviewStorageUnavailable")
        try {
            val capturedMine = runCatching { host.captureMine(identity, directory) }.getOrNull()
                ?: return unavailableAndDelete(directory, "mineUnavailable")
            val capturedCurrent = runCatching { host.captureCurrent(identity, directory) }.getOrNull()
            val state = OfficeConflictReviewPolicy.reviewState(
                baseSha256 = identity.baseSha256,
                baseRevision = identity.baseRevision,
                currentSha256 = capturedCurrent?.sha256,
                currentRevision = capturedCurrent?.revision,
                currentAvailable = capturedCurrent != null,
            )
            if (state != OfficeConflictReviewState.CHANGED) {
                val answer = OfficeConflictReviewPolicy.answer(
                    state = state,
                    recordId = null,
                    baseSha256 = identity.baseSha256,
                    baseRevision = identity.baseRevision,
                    mine = capturedMine,
                    current = capturedCurrent,
                    reason = when (state) {
                        OfficeConflictReviewState.UNCHANGED -> null
                        OfficeConflictReviewState.UNAVAILABLE -> "originalUnavailable"
                        else -> null
                    },
                )
                deleteReviewDirectory(directory)
                return answer
            }
            // The capture can take a bounded provider/workspace read; a
            // settle or replacement may have happened meanwhile. Re-prove the
            // exact live generation before publishing any record.
            if (runCatching { host.liveIdentity(sessionToken, generation) }.getOrNull() == null ||
                synchronized(lock) { sessionToken in closedSessions }
            ) {
                deleteReviewDirectory(directory)
                return OfficeConflictReviewPolicy.unavailable("sessionFenced")
            }
            val recordId = newRecordId()
            synchronized(lock) {
                if (sessionToken in closedSessions) {
                    deleteReviewDirectory(directory)
                    return OfficeConflictReviewPolicy.unavailable("sessionFenced")
                }
                retireExcessLocked()
                records[recordId] = Record(
                    id = recordId,
                    identity = identity,
                    mine = capturedMine,
                    current = capturedCurrent!!,
                    directory = directory,
                    createdAtElapsedMs = System.currentTimeMillis(),
                )
            }
            return OfficeConflictReviewPolicy.answer(
                state = OfficeConflictReviewState.CHANGED,
                recordId = recordId,
                baseSha256 = identity.baseSha256,
                baseRevision = identity.baseRevision,
                mine = capturedMine,
                current = capturedCurrent,
                reason = null,
            )
        } catch (_: Throwable) {
            deleteReviewDirectory(directory)
            return OfficeConflictReviewPolicy.unavailable("reviewFailed")
        }
    }

    override fun resolve(
        sessionToken: String,
        generation: Long,
        recordId: String,
        action: OfficeConflictReviewAction,
    ): OfficeConflictResolutionResult {
        val record = synchronized(lock) { records[recordId] }
            ?: return OfficeConflictResolutionResult(false, "reviewExpired", "Review again before deciding.")
        if (record.identity.sessionToken != sessionToken || record.identity.generation != generation) {
            return OfficeConflictResolutionResult(false, "sessionMismatch", null)
        }
        val live = runCatching { host.liveIdentity(sessionToken, generation) }.getOrNull()
            ?: return OfficeConflictResolutionResult(false, "sessionFenced", null)
        if (live.baseSha256 != record.identity.baseSha256 || live.route != record.identity.route) {
            return OfficeConflictResolutionResult(false, "sessionMismatch", null)
        }
        // Re-read the actual current original into a SEPARATE temp directory:
        // the reviewed current snapshot must stay byte-identical while the
        // decision is checked. The recheck files are cleanup-only.
        val recheckDir = createReviewDirectory()
        val recheck = recheckDir?.let {
            runCatching { host.captureCurrent(live, it) }.getOrNull()
        }
        if (recheckDir != null) deleteReviewDirectory(recheckDir)
        if (recheck == null) {
            return OfficeConflictResolutionResult(
                false,
                "originalUnavailable",
                "The current original could not be re-read; nothing was written and the review is retained.",
            )
        }
        val currentStillMatches = recheck.sha256 == record.current.sha256 &&
            revisionsAgree(recheck.revision, record.current.revision)
        val result = OfficeConflictReviewPolicy.resolve(
            state = OfficeConflictReviewState.CHANGED,
            action = action,
            // Even a non-writing choice is based on the version the user
            // actually saw. If the original changed again, the review is
            // stale and must be re-read before any deliberate decision.
            currentStillMatches = currentStillMatches,
            originalCasAuthority = false,
        )
        if (result.accepted || result.code == "reviewStale") {
            if (!retireRecord(record)) {
                return OfficeConflictResolutionResult(false, "reviewExpired", "Review again before deciding.")
            }
        }
        return result
    }

    override fun release(sessionToken: String, generation: Long, recordId: String?) {
        val targets = synchronized(lock) {
            val matched = records.values.filter {
                it.identity.sessionToken == sessionToken &&
                    (generation <= 0L || it.identity.generation == generation) &&
                    (recordId == null || it.id == recordId)
            }
            matched
        }
        for (record in targets) retireRecord(record)
    }

    /**
     * Prepares one bounded text projection of the exact retained version.
     *
     * Admission re-proves the exact record/role/source digest AND the live
     * owner/generation before any file is read. The projection is written as
     * a small App-owned text file beside the immutable snapshots; the viewer
     * receives only a relative receipt plus a cleanup lease. The lease keeps
     * the directory alive until the viewer closes the preview, even if a
     * decision/settle retires the record meanwhile.
     */
    override fun preview(
        sessionToken: String,
        generation: Long,
        recordId: String,
        role: OfficeConflictPreviewRole,
        expectedSha256: String,
    ): OfficeConflictPreviewAnswer {
        val fileName = OfficeConflictPreviewNaming.fileName(role)
        val admission: Pair<Record, OfficeConflictVersion> = synchronized(lock) {
            if (sessionToken in closedSessions) {
                return OfficeConflictPreviewAnswer.refused("sessionFenced")
            }
            val found = records[recordId]
                ?: return OfficeConflictPreviewAnswer.refused("reviewExpired")
            if (found.retired) {
                return OfficeConflictPreviewAnswer.refused("reviewExpired")
            }
            if (found.identity.sessionToken != sessionToken ||
                found.identity.generation != generation
            ) {
                return OfficeConflictPreviewAnswer.refused("sessionMismatch")
            }
            val selected = when (role) {
                OfficeConflictPreviewRole.MINE -> found.mine
                OfficeConflictPreviewRole.CURRENT -> found.current
            }
            if (!selected.sha256.equals(expectedSha256, ignoreCase = true)) {
                return OfficeConflictPreviewAnswer.refused(
                    reason = "snapshotMismatch",
                    recordId = found.id,
                    role = role,
                    snapshotSha256 = expectedSha256,
                )
            }
            if (OfficeConflictPreviewNaming.relativePath(found.directory.name, role) == null) {
                return OfficeConflictPreviewAnswer.refused("previewUnavailable")
            }
            if (found.readers >= maxLeases) {
                return OfficeConflictPreviewAnswer.refused("previewBusy")
            }
            found.readers += 1
            found to selected
        }
        val record = admission.first
        val version = admission.second
        var readerFinished = false
        fun finishOnce() {
            if (readerFinished) return
            readerFinished = true
            finishReader(record)
        }
        try {
            // The capture identity is immutable; re-prove that THIS viewer is
            // still the current owner/current generation before touching files.
            val live = runCatching { host.liveIdentity(sessionToken, generation) }.getOrNull()
            if (live == null || live.sessionToken != record.identity.sessionToken ||
                live.generation != record.identity.generation ||
                live.baseSha256 != record.identity.baseSha256 ||
                live.route != record.identity.route
            ) {
                finishOnce()
                return OfficeConflictPreviewAnswer.refused("sessionFenced")
            }
            val build = synchronized(record.previewLock) {
                if (record.retired) {
                    null
                } else {
                    runCatching {
                        host.buildPreview(
                            version = version,
                            directory = record.directory,
                            role = role,
                            fileName = fileName,
                            format = record.identity.extension,
                            maxChars = OfficeConflictPreviewAnswer.MAX_TEXT_CHARS,
                        )
                    }.getOrElse { OfficeConflictPreviewBuild.Refused("previewUnavailable") }
                }
            }
            if (build !is OfficeConflictPreviewBuild.Ready) {
                finishOnce()
                return OfficeConflictPreviewAnswer.refused(
                    reason = (build as? OfficeConflictPreviewBuild.Refused)?.code
                        ?: "reviewExpired",
                    recordId = record.id,
                    role = role,
                    snapshotSha256 = version.sha256,
                    snapshotBytes = version.bytes,
                )
            }
            if (!OfficeConflictPreviewNaming.isSha256(build.sha256) ||
                build.bytes !in 1L..OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES
            ) {
                finishOnce()
                return OfficeConflictPreviewAnswer.refused(
                    reason = "previewUnavailable",
                    recordId = record.id,
                    role = role,
                    snapshotSha256 = version.sha256,
                    snapshotBytes = version.bytes,
                )
            }
            val leaseId = UUID.randomUUID().toString()
            val answer = OfficeConflictPreviewAnswer(
                ready = true,
                recordId = record.id,
                role = role,
                snapshotSha256 = version.sha256,
                snapshotBytes = version.bytes,
                relativePath = OfficeConflictPreviewNaming.relativePath(record.directory.name, role),
                previewSha256 = build.sha256,
                previewBytes = build.bytes,
                truncated = build.truncated,
                leaseId = leaseId,
                reason = null,
            )
            var refusedAfterDrain: String? = null
            var deleteAfterDrain = false
            synchronized(lock) {
                when {
                    record.retired -> {
                        // A decision/settle won the race after the projection
                        // was written. Nothing is served; the reader is
                        // dropped and the directory drains (or is already gone).
                        refusedAfterDrain = "reviewExpired"
                        readerFinished = true
                        deleteAfterDrain = finishReaderLocked(record)
                    }
                    leases.size >= maxLeases -> {
                        refusedAfterDrain = "previewBusy"
                        readerFinished = true
                        deleteAfterDrain = finishReaderLocked(record)
                    }
                    else -> leases[leaseId] = PreviewLease(leaseId, record, role)
                }
            }
            if (refusedAfterDrain != null) {
                if (deleteAfterDrain) deleteReviewDirectory(record.directory)
                return OfficeConflictPreviewAnswer.refused(refusedAfterDrain!!)
            }
            return answer
        } catch (_: Throwable) {
            finishOnce()
            return OfficeConflictPreviewAnswer.refused("previewUnavailable")
        }
    }

    override fun releasePreview(sessionToken: String, generation: Long, leaseId: String) {
        val lease = synchronized(lock) { leases[leaseId] } ?: return
        if (lease.record.identity.sessionToken != sessionToken ||
            lease.record.identity.generation != generation
        ) {
            return
        }
        val removed = synchronized(lock) { leases.remove(leaseId) }
        if (removed != null) finishReader(removed.record)
    }

    /** Called when the owning viewer/session settles; idempotent. */
    fun releaseSession(sessionToken: String, generation: Long? = null) {
        synchronized(lock) {
            closedSessions.add(sessionToken)
            while (closedSessions.size > maxClosedSessions) {
                closedSessions.remove(closedSessions.first())
            }
        }
        release(sessionToken, generation ?: -1L, null)
    }

    fun activeRecordCount(): Int = synchronized(lock) { records.size }

    private fun unavailableAndDelete(directory: File, reason: String): OfficeConflictReviewAnswer {
        deleteReviewDirectory(directory)
        return OfficeConflictReviewPolicy.unavailable(reason)
    }

    private fun revisionsAgree(left: String?, right: String?): Boolean =
        left == null || right == null || left == right

    private fun newRecordId(): String = UUID.randomUUID().toString()

    private fun createReviewDirectory(): File? = try {
        val canonicalRoot = root.canonicalFile
        if (!canonicalRoot.isDirectory && !canonicalRoot.mkdirs()) return null
        val directory = File(canonicalRoot, "review-" + UUID.randomUUID())
        if (!directory.mkdirs()) return null
        directory.canonicalFile.takeIf { it.parentFile?.canonicalFile == canonicalRoot }
    } catch (_: Exception) {
        null
    }

    private fun deleteReviewDirectory(directory: File) {
        runCatching { host.deleteReviewDirectory(directory) }
        runCatching {
            val canonicalRoot = root.canonicalFile
            val canonical = directory.canonicalFile
            if (canonical.parentFile?.canonicalFile != canonicalRoot) return
            canonical.listFiles()?.forEach { child ->
                if (child.isFile && !Files.isSymbolicLink(child.toPath())) child.delete()
            }
            canonical.delete()
        }
    }

    /**
     * Retires a record exactly once. With no active preview reader the
     * directory is deleted immediately; otherwise deletion is deferred until
     * the last lease drains. Returns false when a different record now owns
     * the id (a stale caller must never delete the replacement).
     */
    private fun retireRecord(record: Record): Boolean {
        val deleteNow = synchronized(lock) {
            if (records[record.id] !== record) return false
            records.remove(record.id)
            record.retired = true
            when {
                record.readers == 0 -> true
                else -> {
                    record.deleteWhenDrained = true
                    false
                }
            }
        }
        if (deleteNow) deleteReviewDirectory(record.directory)
        return true
    }

    /** One preview lease finished; delete only when retired and fully drained. */
    private fun finishReader(record: Record) {
        val delete = synchronized(lock) { finishReaderLocked(record) }
        if (delete) deleteReviewDirectory(record.directory)
    }

    /** Lock-held half of [finishReader]; true means the caller deletes. */
    private fun finishReaderLocked(record: Record): Boolean {
        if (record.readers > 0) record.readers -= 1
        return record.readers == 0 && record.deleteWhenDrained
    }

    private fun retireExcessLocked() {
        while (records.size >= maxRecords) {
            // A record with a live preview reader is retained: its directory
            // must not disappear while the viewer is still displaying it.
            val oldest = records.values
                .filter { it.readers == 0 }
                .minByOrNull { it.createdAtElapsedMs } ?: break
            records.remove(oldest.id)
            oldest.retired = true
            deleteReviewDirectory(oldest.directory)
        }
    }
}
